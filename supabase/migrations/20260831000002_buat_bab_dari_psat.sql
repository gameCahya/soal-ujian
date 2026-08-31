-- =============================================================================
-- PSAT: guru boleh membuat bab dari halaman Matrix
-- =============================================================================
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
-- Prasyarat: 20260831000001 (bab_id + jembatan) dan LMS 20260831a sudah diapply.
--
-- MASALAH
-- 20260831000001 mengganti input nama bab bebas dengan <select> dari
-- psat.get_bab_ujian(). Itu perlu — nama bebas tak bisa dipetakan ke
-- bab_pelajaran — tapi akibatnya guru MENTOK bila babnya belum ada di LMS:
-- PSAT hanya bisa MEMBACA bab, tak ada satu pun jalur menulis.
--
-- Bab dibuat di tingkat MAPEL (ujian_id NULL), bukan terikat ujian. Keputusan
-- pemilik produk: bab bisa dipakai ulang oleh ujian lain pada mapel yang sama.
-- Ini juga menyamai perilaku public.impor_soal_psat, yang sudah membuat bab
-- tingkat-mapel saat mengimpor soal.
--
-- ⚠️ Sengaja HANYA membuat. Menghapus bab memicu ON DELETE SET NULL pada
--    bank_soal.bab_id — soal kehilangan babnya diam-diam, dan sejak jalur ketat
--    itu berarti generate DITOLAK. Aksi merusak seperti itu tetap di LMS, di
--    layar yang memang memperingatkannya.
--
-- Tabrakan nama tidak lagi jadi masalah sejak LMS 20260831a memecah UNIQUE
-- lama jadi dua indeks parsial: nama unik per ujian untuk bab terikat, dan unik
-- per mapel untuk bab warisan/tingkat-mapel.
--
-- ⚠️ Cara apply: pnpm db:migrate supabase/migrations/20260831000002_buat_bab_dari_psat.sql
--    JANGAN menjalankan seluruh folder (berkas init gagal — psat.profiles kini VIEW).
-- ROLLBACK: supabase/rollback/20260831000002_buat_bab_dari_psat_rollback.sql
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION psat.buat_bab_ujian(
  p_ujian_id uuid,
  p_nama_bab text
)
RETURNS TABLE (bab_id uuid, nama_bab text, urutan integer, sudah_ada boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE
  v_aktor  uuid := auth.uid();
  v_role   text;
  v_nama   text := btrim(COALESCE(p_nama_bab, ''));
  v_mapel  uuid;
  v_level  text;
  v_ada    record;
  v_baru   record;
BEGIN
  -- ⚠️ DEFINER melewati RLS. Pemeriksaan di bawah INILAH batas keamanannya.
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  IF v_nama = '' THEN
    RAISE EXCEPTION 'Nama bab tidak boleh kosong.' USING HINT = 'nama-kosong';
  END IF;
  IF length(v_nama) > 120 THEN
    RAISE EXCEPTION 'Nama bab terlalu panjang (maksimal 120 karakter).' USING HINT = 'nama-panjang';
  END IF;

  SELECT u.mata_pelajaran_id INTO v_mapel FROM public.ujian u WHERE u.id = p_ujian_id;
  IF v_mapel IS NULL THEN
    RAISE EXCEPTION 'Ujian tidak ditemukan atau belum punya mata pelajaran.'
      USING HINT = 'ujian-tanpa-mapel';
  END IF;

  -- Otorisasi: pengampu mapel+tingkat ujian ini, atau admin.
  -- Sengaja TIDAK memakai filter penulis-ditunjuk: membuat bab itu tak merusak
  -- dan hasilnya dipakai bersama, jadi guru boleh menyiapkannya sebelum ada
  -- penunjukan. Yang dijaga ketat adalah menulis konfigurasi, bukan ini.
  v_role  := COALESCE(psat.current_user_role()::text, '');
  v_level := psat.level_ujian(p_ujian_id);

  IF v_role <> 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.guru_mengajar gm
    WHERE gm.guru_id = v_aktor
      AND gm.mapel_id = v_mapel
      AND (v_level IS NULL
           OR substring(gm.kelas FROM '^[[:space:]]*([0-9])') = v_level)
  ) THEN
    RAISE EXCEPTION 'Anda tidak mengampu mata pelajaran ujian ini.'
      USING HINT = 'bukan-pengampu';
  END IF;

  -- Ambil-atau-buat. Kalau sudah ada bab bernama sama yang TERLIHAT oleh ujian
  -- ini — terikat ujian maupun tingkat mapel — kembalikan yang itu. Menyisipkan
  -- kembar hanya akan memunculkan dua entri sama di dropdown.
  SELECT bp.id, bp.nama_bab, bp.urutan INTO v_ada
  FROM public.bab_pelajaran bp
  WHERE (bp.ujian_id = p_ujian_id
         OR (bp.ujian_id IS NULL AND bp.mata_pelajaran_id = v_mapel))
    AND lower(btrim(bp.nama_bab)) = lower(v_nama)
  ORDER BY bp.ujian_id NULLS LAST
  LIMIT 1;

  IF v_ada.id IS NOT NULL THEN
    bab_id := v_ada.id; nama_bab := v_ada.nama_bab;
    urutan := v_ada.urutan; sudah_ada := true;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO public.bab_pelajaran (mata_pelajaran_id, ujian_id, nama_bab, urutan)
  VALUES (
    v_mapel,
    NULL,                                  -- tingkat mapel: dipakai ulang lintas ujian
    v_nama,
    COALESCE((SELECT max(bp.urutan) + 1 FROM public.bab_pelajaran bp
               WHERE bp.mata_pelajaran_id = v_mapel), 1)
  )
  RETURNING id, public.bab_pelajaran.nama_bab, public.bab_pelajaran.urutan INTO v_baru;

  bab_id := v_baru.id; nama_bab := v_baru.nama_bab;
  urutan := v_baru.urutan; sudah_ada := false;
  RETURN NEXT;
END
$function$;

REVOKE ALL ON FUNCTION psat.buat_bab_ujian(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.buat_bab_ujian(uuid, text) TO authenticated;

COMMENT ON FUNCTION psat.buat_bab_ujian(uuid, text) IS
  'Membuat bab tingkat mapel dari halaman Matrix PSAT. Ambil-atau-buat: nama yang sudah terlihat oleh ujian itu dikembalikan apa adanya. Sengaja tidak bisa menghapus/mengganti nama — itu merusak bank_soal.bab_id dan tetap di LMS.';

DO $gate$
BEGIN
  IF to_regprocedure('psat.buat_bab_ujian(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'buat_bab_ujian tidak terbentuk';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- ⚠️ WAJIB menyamar — service-role & Management API BYPASS RLS dan auth.uid().
--    Jalankan tiap assersi dalam varian benar DAN varian rusak; `[]` dari
--    Management API berarti "sukses" MAUPUN "tanpa hasil".
--
--   BEGIN;
--     -- 1. tanpa login → ditolak
--     -- 2. SET LOCAL ROLE authenticated + jwt.claims guru pengampu → bab terbuat
--     -- 3. panggil lagi dengan nama sama → sudah_ada = true, tidak menggandakan
--     -- 4. jwt.claims guru yang TIDAK mengampu → ditolak 'bukan-pengampu'
--     -- 5. nama kosong / >120 karakter → ditolak
--   ROLLBACK;
