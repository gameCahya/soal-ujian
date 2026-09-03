-- Migration: TKA lintas sekolah masuk daftar ujian aktif PSAT
-- Prasyarat: lms-new/supabase/migrations/20260903a_alur_psat_tka_lintas_sekolah.sql
--            HARUS diapply lebih dulu — migrasi ini memanggil fungsi yang dibuat
--            di sana. Urutan terbalik = get_ujian_aktif() gagal di setiap panggilan.
--
-- ============================================================================
-- LATAR
-- ============================================================================
-- psat.get_ujian_aktif() adalah pintu masuk SATU-SATUNYA ke seluruh alur PSAT:
-- halaman Patokan membacanya untuk menetapkan pagu, dan get_tugas_menulis()
-- dibangun persis di atasnya sehingga daftar tugas guru ikut ditentukan olehnya.
--
-- Saringannya hari ini `tu.soal_oleh = 'super_admin'`. TKA ber-soal_oleh='guru',
-- jadi tidak pernah lewat — pagunya tak bisa ditetapkan, penulisnya tak bisa
-- ditunjuk, dan gurunya tak pernah melihat tugasnya. Itulah sebabnya keempat
-- ujian TKA di produksi punya 0 pagu, 0 penulis, 0 matriks.
--
-- ============================================================================
-- PERBAIKANNYA: pinjam aturannya, jangan menyalinnya
-- ============================================================================
-- Syarat "ujian ini dikoordinasi terpusat" ditulis SEKALI di LMS sebagai
-- public.ujian_alur_psat_terpusat(): tipenya ber-alur_psat DAN ujiannya berlaku
-- lintas sekolah. Fungsi ini memanggilnya, tidak menyalin syaratnya.
--
-- Menyalin aturan ke dua sisi persis cara bug bab-lintas-tingkat lahir (satu
-- sisi menerima bab yang sisi lain tolak) dan cara parser video pecah. Aturan
-- yang dipakai dua aplikasi harus punya satu badan.
--
-- ============================================================================
-- DAMPAK
-- ============================================================================
--   • MASUK   : 2 TKA lintas sekolah (buatan super admin, di event PTS aktif).
--   • TETAP   : seluruh UTS/UAS di event aktif — tipe ber-min_level >= 2 selalu
--               ber-scope NULL, jadi syarat kedua otomatis terpenuhi.
--   • TIDAK MASUK: TKA lokal buatan admin sekolah (tetap jalur Bank Soal LMS,
--                  sesuai keputusan pemilik produk), dan UH/Tugas.
--   • Tidak ada perubahan UI yang diperlukan: halaman Patokan dan daftar tugas
--     menulis membaca fungsi ini apa adanya.
--
-- CATATAN OPERASIONAL — dua hal yang masih perlu tangan manusia sesudah ini:
--   1. Kedua mapel TKA (TKA IND, TKA Math) belum punya SATU bab pun. Alur PSAT
--      mensyaratkan bab. Penulis yang ditunjuk sudah boleh membuatnya sendiri
--      sejak 20260902000006, jadi cukup tunjuk penulisnya lebih dulu.
--   2. Keempat ujian TKA ber-mode_soal='tetap'. Jalur generate patuh bab hanya
--      menyala untuk 'acak'. Itu setelan per-ujian di form admin LMS.
--
-- ⚠️ Cara apply: Management API (curl).
-- ROLLBACK: supabase/rollback/20260903000001_tka_masuk_alur_psat_rollback.sql

BEGIN;

-- =============================================================================
-- 0. Prasyarat, diperiksa bukan diasumsikan
-- =============================================================================
DO $pra$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'ujian_alur_psat_terpusat'
  ) THEN
    RAISE EXCEPTION
      'public.ujian_alur_psat_terpusat() belum ada. Apply lms-new 20260903a_alur_psat_tka_lintas_sekolah.sql LEBIH DULU.';
  END IF;
END
$pra$;

-- =============================================================================
-- 1. Pintu masuk alur PSAT
-- =============================================================================
-- Hanya baris JOIN tipe_ujian yang berubah, menjadi WHERE yang memanggil aturan
-- bersama. Seluruh kolom keluaran dibiarkan persis sama — tanda tangan fungsi
-- tidak boleh bergeser sedikit pun (2 Sep: varchar vs TEXT pada satu kolom
-- membuat fungsi lolos gerbang struktural tapi gagal di setiap pemanggilan).

CREATE OR REPLACE FUNCTION psat.get_ujian_aktif()
RETURNS TABLE(
  ujian_id uuid, ujian_nama text, mapel_id uuid, psat_mapel_id uuid,
  mapel_nama text, level text, kelas_list text[],
  event_nama text, tahun_ajaran text, semester integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'psat', 'public'
AS $function$
  SELECT
    u.id,
    u.nama,
    u.mata_pelajaran_id,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ARRAY(
      SELECT uk.kelas FROM public.ujian_kelas uk
      WHERE uk.ujian_id = u.id ORDER BY uk.kelas
    ),
    ev.nama,
    ev.tahun_ajaran,
    ev.semester
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  WHERE public.ujian_alur_psat_terpusat(u.id)
  ORDER BY mp.nama, psat.level_ujian(u.id);
$function$;

COMMENT ON FUNCTION psat.get_ujian_aktif() IS
  'Ujian pada event aktif yang soalnya dikoordinasi terpusat lewat PSAT. Aturannya milik LMS (public.ujian_alur_psat_terpusat) dan dipinjam di sini, bukan disalin: UTS/UAS selalu ikut, TKA hanya yang lintas sekolah, TKA lokal dan UH/Tugas tidak.';

-- =============================================================================
-- 2. GERBANG — memanggil fungsinya terhadap data produksi
-- =============================================================================
DO $gate$
DECLARE
  v_hilang  int;
  v_bocor   int;
  v_tka_in  int;
  v_tka_out int;
BEGIN
  -- a. TIDAK ADA REGRESI: setiap UTS/UAS di event aktif harus tetap terdaftar.
  SELECT count(*) INTO v_hilang
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  WHERE u.tipe_ujian IN ('UTS', 'UAS')
    AND NOT EXISTS (SELECT 1 FROM psat.get_ujian_aktif() g WHERE g.ujian_id = u.id);
  IF v_hilang > 0 THEN
    RAISE EXCEPTION 'REGRESI: % ujian UTS/UAS hilang dari get_ujian_aktif()', v_hilang;
  END IF;

  -- b. UH/Tugas dan TKA lokal tidak boleh ikut terbawa.
  SELECT count(*) INTO v_bocor
  FROM psat.get_ujian_aktif() g
  JOIN public.ujian u ON u.id = g.ujian_id
  WHERE u.tipe_ujian IN ('UH', 'tugas')
     OR public.ujian_scope_sekolah_id(u.id) IS NOT NULL;
  IF v_bocor > 0 THEN
    RAISE EXCEPTION 'BOCOR: % ujian milik guru atau milik satu sekolah ikut masuk', v_bocor;
  END IF;

  -- c. TKA lintas sekolah HARUS masuk — ini alasan migrasi ini ada.
  SELECT count(*) INTO v_tka_in
  FROM psat.get_ujian_aktif() g
  JOIN public.ujian u ON u.id = g.ujian_id
  WHERE u.tipe_ujian = 'TKA';

  SELECT count(*) INTO v_tka_out
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  WHERE u.tipe_ujian = 'TKA' AND public.ujian_scope_sekolah_id(u.id) IS NULL;

  IF v_tka_out = 0 THEN
    RAISE EXCEPTION
      'tidak ada TKA lintas sekolah di event aktif — gerbang tidak bisa membuktikan apa pun';
  END IF;
  IF v_tka_in <> v_tka_out THEN
    RAISE EXCEPTION 'GAGAL: % dari % TKA lintas sekolah masuk daftar', v_tka_in, v_tka_out;
  END IF;

  RAISE NOTICE 'gerbang lolos: % TKA lintas sekolah masuk, 0 kebocoran', v_tka_in;
END
$gate$;

COMMIT;
