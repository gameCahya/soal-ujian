-- Migration: izin menulis menyala lewat TRIGGER, bukan hanya lewat RPC
-- Plan: /home/bangcs/.claude/plans/yak-benar-ict-ada-magical-raven.md
-- Prasyarat: 20260901000005 sudah diapply.
--
-- MASALAH
-- 20260901000005 memindahkan penunjukan penulis ke psat.tetapkan_penulis(), yang
-- menyalakan is_penulis_soal sekalian. Tapi jaminannya hanya berlaku bagi klien
-- yang MEMANGGIL RPC itu. Build halaman Patokan yang sedang tayang masih memakai
-- jalur lama — upsert langsung ke psat.psat_ujian_penulis — dan jalur itu tidak
-- menyalakan izin apa pun.
--
-- Akibatnya ada jendela: admin mengisi 33 penunjukan sebelum build baru tayang,
-- lalu 33 guru itu masuk ke PSAT dan mendapati view psat.profiles tidak
-- mengembalikan baris mereka sendiri. Tak ada galat di mana pun.
--
-- PERBAIKAN
-- Invariannya dipindah ke lapisan data: SIAPA PUN yang menulis baris penunjukan —
-- RPC baru, klien lama, atau perbaikan manual lewat SQL — penulisnya otomatis
-- mendapat izin. Ini menjadikan urutan deploy tidak lagi penting.
--
-- Trigger dan RPC sengaja BERDAMPINGAN, bukan saling menggantikan:
--   - trigger  → menjamin izin, apa pun jalur penulisannya
--   - RPC      → menjamin VALIDASI (calon yang benar, akun aktif) dan memberi
--                pesan yang menjelaskan saat ditolak
-- Trigger tidak bisa menggantikan validasi RPC karena penolakan di trigger
-- muncul sebagai galat mentah tanpa konteks di layar admin.
--
-- ROLLBACK: supabase/rollback/20260901000006_izin_penulis_lewat_trigger_rollback.sql

BEGIN;

CREATE OR REPLACE FUNCTION psat.penulis_dapat_izin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'psat'
AS $function$
BEGIN
  -- Hanya menyalakan, tidak pernah mematikan: satu guru bisa jadi penulis
  -- beberapa ujian, dan mencabut izin di sini akan mematikan tugasnya di ujian
  -- lain secara diam-diam.
  UPDATE public.profiles
  SET is_penulis_soal = true
  WHERE id = NEW.profile_id
    AND NOT is_penulis_soal;

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_penulis_dapat_izin ON psat.psat_ujian_penulis;
CREATE TRIGGER trg_penulis_dapat_izin
  AFTER INSERT OR UPDATE OF profile_id ON psat.psat_ujian_penulis
  FOR EACH ROW EXECUTE FUNCTION psat.penulis_dapat_izin();

COMMENT ON FUNCTION psat.penulis_dapat_izin() IS
  'Menyalakan public.profiles.is_penulis_soal bagi penulis yang baru ditunjuk, lewat jalur penulisan mana pun. Tanpa izin itu view psat.profiles tidak mengembalikan baris guru itu sendiri dan dashboard PSAT tidak bisa memuat profilnya.';

-- =============================================================================
-- Gerbang assertion — dengan bukti perilaku, bukan sekadar keberadaan objek
-- =============================================================================
DO $gate$
DECLARE
  v_ujian uuid;
  v_guru  uuid;
  v_awal  boolean;
  v_akhir boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                 WHERE tgrelid = 'psat.psat_ujian_penulis'::regclass
                   AND tgname = 'trg_penulis_dapat_izin') THEN
    RAISE EXCEPTION 'Trigger tidak terpasang';
  END IF;

  -- Buktikan trigger benar-benar menyala pada jalur LAMA (INSERT langsung,
  -- tanpa RPC). Seluruhnya dibatalkan di akhir blok.
  SELECT a.ujian_id, c.profile_id INTO v_ujian, v_guru
  FROM psat.get_ujian_aktif() a
  CROSS JOIN LATERAL psat.get_calon_penulis(a.ujian_id) c
  WHERE NOT c.siap
  LIMIT 1;

  IF v_guru IS NULL THEN
    RAISE NOTICE 'Tidak ada calon tanpa izin untuk diuji — lewati uji perilaku.';
    RETURN;
  END IF;

  SELECT is_penulis_soal INTO v_awal FROM public.profiles WHERE id = v_guru;

  INSERT INTO psat.psat_ujian_penulis (ujian_id, profile_id)
  VALUES (v_ujian, v_guru)
  ON CONFLICT (ujian_id) DO UPDATE SET profile_id = EXCLUDED.profile_id;

  SELECT is_penulis_soal INTO v_akhir FROM public.profiles WHERE id = v_guru;

  IF v_awal OR NOT v_akhir THEN
    RAISE EXCEPTION
      'Trigger tidak menyalakan izin lewat jalur lama (sebelum=%, sesudah=%)',
      v_awal, v_akhir;
  END IF;

  -- Batalkan jejak uji
  DELETE FROM psat.psat_ujian_penulis WHERE ujian_id = v_ujian;
  UPDATE public.profiles SET is_penulis_soal = false WHERE id = v_guru;

  RAISE NOTICE 'Trigger terbukti menyalakan izin lewat INSERT langsung.';
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- Jumlah guru ber-izin harus SAMA dengan jumlah penulis yang ditunjuk (plus akun
-- yang izinnya dinyalakan manual). Kalau penunjukan bertambah tapi angka ini
-- tidak, triggernya tidak bekerja:
--   SELECT (SELECT count(*) FROM psat.psat_ujian_penulis)              AS penunjukan,
--          (SELECT count(DISTINCT profile_id) FROM psat.psat_ujian_penulis) AS penulis_unik,
--          (SELECT count(*) FROM public.profiles WHERE is_penulis_soal) AS berizin;
