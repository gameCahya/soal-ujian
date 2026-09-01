-- Migration: menunjuk penulis sekalian memberinya izin menulis
-- Plan: /home/bangcs/.claude/plans/yak-benar-ict-ada-magical-raven.md
--
-- MASALAH
-- Menunjuk penulis matriks hari ini menulis SATU baris (`psat_ujian_penulis`) dan
-- berhenti di situ. Tapi supaya guru itu benar-benar bisa bekerja, ia juga harus
-- ber-`public.profiles.is_penulis_soal = true`:
--
--   psat.current_user_role() → 'guru' HANYA bila role='guru' AND is_penulis_soal
--                              AND status='aktif'; selain itu NULL
--
-- Yang rusak tanpa flag itu BUKAN daftar tugasnya. Diukur di produksi:
--   tanpa izin → psat.profiles untuk dirinya sendiri: 0 BARIS
--                get_tugas_menulis()                : 1 ujian (tetap muncul)
--   dengan izin→ psat.profiles                      : 1 baris
--                get_tugas_menulis()                : 1 ujian
--
-- `get_tugas_menulis()` SECURITY DEFINER sehingga melewati gerbang itu, tapi
-- view `psat.profiles` menyaring `WHERE psat_role IS NOT NULL AND (id = uid …)`
-- — jadi guru tanpa izin tidak bisa membaca barisnya sendiri. Dashboard PSAT
-- memuat profil di `dashboard/page.tsx:84` lalu jatuh ke `user?.role || "guru"`
-- dengan objek user kosong: nama tidak muncul, dan sejumlah policy psat lain
-- yang bercabang pada current_user_role() memperlakukannya sebagai bukan siapa-
-- siapa. Penulis yang ditunjuk tanpa izin karena itu masuk ke aplikasi yang
-- setengah lumpuh, tanpa satu pun pesan yang menjelaskan sebabnya.
--
-- SKALANYA (produksi, 1 Sep 2026):
--   guru                                  : 200
--   ber-is_penulis_soal                   : 1
--   calon penulis untuk 33 ujian PTS 1    : 162 orang
--   di antaranya yang BISA bekerja hari ini: 1
--   calon ber-status <> 'aktif'           : 7   ← juga menghasilkan role NULL
--
-- Artinya: menunjuk 33 penulis sekarang menghasilkan 32 orang yang tidak melihat
-- apa pun, dan tak ada satu pun pesan yang memberi tahu.
--
-- PERBAIKAN
-- Penunjukan jadi satu tindakan yang utuh: memvalidasi calon, menyalakan izinnya,
-- lalu mencatat penunjukannya — dalam satu transaksi. Calon yang tidak aktif
-- DITOLAK dengan pesan yang menyebut sebabnya, bukan diterima lalu diam.
--
-- ROLLBACK: supabase/rollback/20260901000005_tetapkan_penulis_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Calon penulis: tambahkan yang dibutuhkan untuk MEMILIH
-- =============================================================================
-- Tiga kolom baru. Dengan 33 ujian × 7-11 calon dari 10 unit, memilih hanya dari
-- nama adalah menebak: `sekolah` dan `jml_kelas` memberi dasar, dan `siap`
-- menunjukkan siapa yang sudah bisa langsung bekerja.
-- Kolom lama (profile_id, nama, sudah_isi, ditunjuk) dipertahankan urutannya
-- supaya klien lama tidak patah.

-- Tipe kembalian berubah (3 kolom baru), jadi CREATE OR REPLACE tidak cukup —
-- Postgres menolak mengubah row type dari OUT parameter. Aman di dalam
-- transaksi: pemanggilnya (tetapkan_penulis) dibuat sesudah ini.
DROP FUNCTION IF EXISTS psat.get_calon_penulis(uuid);

CREATE OR REPLACE FUNCTION psat.get_calon_penulis(p_ujian_id UUID)
RETURNS TABLE (
  profile_id UUID,
  nama       TEXT,
  sudah_isi  BOOLEAN,
  ditunjuk   BOOLEAN,
  sekolah    TEXT,
  jml_kelas  BIGINT,
  siap       BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $calon$
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  )
  SELECT
    gm.guru_id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = gm.guru_id),
    EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pen
             WHERE pen.ujian_id = p_ujian_id AND pen.profile_id = gm.guru_id),
    sk.nama,
    count(*),
    (pr.is_penulis_soal AND pr.status = 'aktif')
  FROM a
  JOIN public.guru_mengajar gm
    ON gm.mapel_id = a.mapel_id
   AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
  JOIN public.profiles pr ON pr.id = gm.guru_id
  LEFT JOIN public.sekolah sk ON sk.id = pr.sekolah_id
  GROUP BY gm.guru_id, pr.nama, sk.nama, pr.is_penulis_soal, pr.status
  ORDER BY pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

COMMENT ON FUNCTION psat.get_calon_penulis(UUID) IS
  'Guru yang boleh ditunjuk menulis matriks satu ujian, beserta asal sekolah, jumlah kelas yang diampu untuk mapel+tingkat itu, dan apakah izinnya sudah siap.';

-- =============================================================================
-- 2. Menunjuk penulis — sekalian memberinya izin
-- =============================================================================

CREATE OR REPLACE FUNCTION psat.tetapkan_penulis(
  p_ujian_id   uuid,
  p_profile_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE
  v_aktor  uuid := auth.uid();
  v_role   text;
  v_nama   text;
  v_status text;
  v_prole  text;
  v_flag   boolean;
  v_nyala  boolean := false;
BEGIN
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  -- COALESCE wajib: current_user_role() NULL untuk siapa pun tanpa baris aktif
  -- di public.profiles, dan `NULL <> 'admin'` bernilai NULL sehingga penjaganya
  -- tidak menyala. Sudah pernah terjadi di fungsi lain; jangan dilepas.
  v_role := COALESCE(psat.current_user_role()::text, '');
  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh menunjuk penulis matriks.'
      USING HINT = 'bukan-admin';
  END IF;

  -- Calon harus benar-benar mengampu mapel+tingkat ujian ini. Tanpa cek ini,
  -- siapa pun bisa ditunjuk dan get_tugas_menulis() tidak akan pernah
  -- memberinya tugas — penunjukan yang tampak berhasil tapi mati.
  IF NOT EXISTS (
    SELECT 1 FROM psat.get_calon_penulis(p_ujian_id) c
    WHERE c.profile_id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'Guru itu tidak mengampu mata pelajaran dan tingkat ujian ini.'
      USING HINT = 'bukan-calon';
  END IF;

  SELECT pr.nama, pr.status::text, pr.role::text, pr.is_penulis_soal
    INTO v_nama, v_status, v_prole, v_flag
  FROM public.profiles pr WHERE pr.id = p_profile_id;

  -- status <> 'aktif' membuat current_user_role() NULL — penulis yang ditunjuk
  -- tidak akan melihat tugasnya. Ditolak di muka supaya kegagalannya terlihat
  -- SEKARANG, bukan sebagai laporan "gurunya bilang tidak ada tugas" minggu depan.
  IF v_status IS DISTINCT FROM 'aktif' THEN
    RAISE EXCEPTION 'Akun % berstatus "%" — aktifkan dulu, kalau tidak ia tidak akan melihat tugasnya.',
      COALESCE(v_nama, p_profile_id::text), COALESCE(v_status, 'tidak diketahui')
      USING HINT = 'akun-tidak-aktif';
  END IF;

  IF v_prole IS DISTINCT FROM 'guru' THEN
    RAISE EXCEPTION 'Akun % bukan berperan guru.' , COALESCE(v_nama, p_profile_id::text)
      USING HINT = 'bukan-guru';
  END IF;

  -- Inti perbaikan: izin menulis dinyalakan bersamaan dengan penunjukan.
  IF NOT COALESCE(v_flag, false) THEN
    UPDATE public.profiles SET is_penulis_soal = true WHERE id = p_profile_id;
    v_nyala := true;
  END IF;

  INSERT INTO psat.psat_ujian_penulis (ujian_id, profile_id, ditetapkan_oleh)
  VALUES (p_ujian_id, p_profile_id, v_aktor)
  ON CONFLICT (ujian_id) DO UPDATE
    SET profile_id      = EXCLUDED.profile_id,
        ditetapkan_oleh = EXCLUDED.ditetapkan_oleh,
        updated_at      = now();

  RETURN jsonb_build_object(
    'ok', true,
    'ujian_id', p_ujian_id,
    'profile_id', p_profile_id,
    'nama', v_nama,
    'izin_baru_dinyalakan', v_nyala
  );
END
$function$;

REVOKE ALL ON FUNCTION psat.tetapkan_penulis(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.tetapkan_penulis(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION psat.tetapkan_penulis(uuid, uuid) IS
  'Menunjuk penulis matriks satu ujian DAN menyalakan is_penulis_soal-nya dalam satu transaksi. Menunjuk tanpa izin itu menghasilkan penulis yang tidak melihat tugas apa pun tanpa galat.';

-- =============================================================================
-- 3. Mencabut penunjukan
-- =============================================================================
-- Izinnya SENGAJA tidak ikut dicabut: satu guru bisa jadi penulis beberapa ujian,
-- dan mencabut flag di sini akan mematikan tugasnya di ujian lain secara diam-diam.

CREATE OR REPLACE FUNCTION psat.hapus_penulis(p_ujian_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE v_role text; v_n int;
BEGIN
  v_role := COALESCE(psat.current_user_role()::text, '');
  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh mencabut penunjukan penulis.'
      USING HINT = 'bukan-admin';
  END IF;

  DELETE FROM psat.psat_ujian_penulis WHERE ujian_id = p_ujian_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'dihapus', v_n);
END
$function$;

REVOKE ALL ON FUNCTION psat.hapus_penulis(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.hapus_penulis(uuid) TO authenticated;

COMMENT ON FUNCTION psat.hapus_penulis(uuid) IS
  'Mencabut penunjukan penulis satu ujian. is_penulis_soal TIDAK ikut dicabut — guru yang sama bisa menulis ujian lain.';

-- =============================================================================
-- 4. Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE n int;
BEGIN
  IF to_regprocedure('psat.tetapkan_penulis(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'tetapkan_penulis tidak terbentuk';
  END IF;
  IF to_regprocedure('psat.hapus_penulis(uuid)') IS NULL THEN
    RAISE EXCEPTION 'hapus_penulis tidak terbentuk';
  END IF;

  -- Inti perbaikan harus benar-benar ada di badan fungsi.
  IF pg_get_functiondef(to_regprocedure('psat.tetapkan_penulis(uuid,uuid)'))
     NOT LIKE '%is_penulis_soal = true%' THEN
    RAISE EXCEPTION 'tetapkan_penulis tidak menyalakan is_penulis_soal';
  END IF;

  -- get_calon_penulis harus mengembalikan 7 kolom
  SELECT count(*) INTO n
  FROM information_schema.parameters
  WHERE specific_schema = 'psat'
    AND specific_name = (SELECT p.oid::regprocedure::text FROM pg_proc p
                         WHERE p.oid = to_regprocedure('psat.get_calon_penulis(uuid)'))
    AND parameter_mode = 'TABLE';
  -- (informational; bentuk nama specific_name berbeda antar versi, jadi tidak
  --  dijadikan syarat gagal — yang menentukan uji perilaku di bawah.)
  RAISE NOTICE 'get_calon_penulis kolom TABLE terdeteksi: %', n;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply — WAJIB menyamar peran
-- =============================================================================
-- Management API & service-role MELEWATI RLS, dan fungsi ini membaca auth.uid().
-- Buktikan current_user = 'authenticated' di keluaran, dan jalankan tiap assersi
-- sekali lagi dalam varian yang sengaja dirusak.
--
-- 1. Guru biasa mencoba menunjuk → DITOLAK 'bukan-admin'.
-- 2. Admin menunjuk calon yang sah → berhasil, dan profiles.is_penulis_soal
--    orang itu berubah false → true dalam transaksi yang sama.
-- 3. Admin menunjuk guru yang TIDAK mengampu → DITOLAK 'bukan-calon'.
-- 4. Admin menunjuk akun ber-status non-aktif → DITOLAK 'akun-tidak-aktif'.
-- 5. Sesudah ditunjuk, get_tugas_menulis() milik guru itu memuat ujiannya —
--    inilah bukti bahwa penunjukan benar-benar berfungsi, bukan sekadar tercatat.
