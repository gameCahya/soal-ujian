-- Migration: daftar unit sekolah dibaca dari LMS, bukan di-hardcode di PSAT
--
-- MASALAH
-- UNIT_OPTIONS di PSAT adalah larik 8 nama yang ditulis tangan, DISALIN di dua
-- berkas (dashboard/profile dan admin/users). LMS punya 11 sekolah. Tiga tidak
-- pernah ikut tersalin:
--
--   SMPII Al Abidin Magelang    5 guru
--   SMP ABBS Sragen             5 guru
--   Alabidin Learning Center    4 guru
--
-- Guru dari ketiga unit itu tidak bisa memilih unitnya sendiri di profil PSAT,
-- padahal unit itu wajib diisi. Menambal satu nama tidak menyelesaikannya —
-- sekolah berikutnya yang dibuat di LMS akan hilang lagi dengan cara yang sama.
--
-- PERBAIKAN
-- Satu RPC yang membaca public.sekolah. Daftar tidak bisa menyimpang lagi
-- karena tidak ada lagi salinan yang perlu dijaga tetap sinkron.
--
-- Hanya sekolah aktif yang dikembalikan: unit yang sudah dimatikan di LMS tidak
-- pantas ditawarkan sebagai pilihan baru.
--
-- Diukur sebelum migrasi ini: 9 profil PSAT punya unit_sekolah terisi, dan
-- KESEMUANYA sudah cocok persis dengan nama di public.sekolah — jadi mengganti
-- sumber daftarnya tidak membuat satu profil pun jadi tidak sah.
--
-- ROLLBACK: supabase/rollback/20260902000005_unit_sekolah_dari_lms_rollback.sql

BEGIN;

CREATE OR REPLACE FUNCTION psat.get_unit_sekolah()
RETURNS TABLE (nama text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $unit$
  -- SECURITY DEFINER karena klien PSAT terikat schema `psat` dan tidak bisa
  -- membaca public.sekolah langsung. Yang diekspos hanya nama unit — bukan
  -- data pribadi, dan sudah tampil di layar mana pun yang menyebut sekolah.
  SELECT sk.nama::text
  FROM public.sekolah sk
  WHERE sk.is_active
  ORDER BY sk.nama;
$unit$;

GRANT EXECUTE ON FUNCTION psat.get_unit_sekolah() TO authenticated;

COMMENT ON FUNCTION psat.get_unit_sekolah() IS
  'Daftar unit sekolah aktif dari public.sekolah, untuk mengisi pilihan di profil PSAT. Menggantikan larik UNIT_OPTIONS yang di-hardcode dan tertinggal 3 sekolah.';

DO $gate$
DECLARE
  n_rpc int;
  n_tbl int;
BEGIN
  SELECT count(*) INTO n_rpc FROM psat.get_unit_sekolah();
  SELECT count(*) INTO n_tbl FROM public.sekolah WHERE is_active;

  IF n_rpc <> n_tbl THEN
    RAISE EXCEPTION 'RPC mengembalikan % unit, tabel punya % aktif', n_rpc, n_tbl;
  END IF;

  -- Ketiga yang selama ini hilang harus benar-benar ada. Menghitung jumlah saja
  -- tidak membuktikan yang BENAR yang keluar.
  IF NOT EXISTS (SELECT 1 FROM psat.get_unit_sekolah() u
                  WHERE u.nama = 'SMPII Al Abidin Magelang') THEN
    RAISE EXCEPTION 'Magelang tidak muncul — justru unit yang diminta';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM psat.get_unit_sekolah() u
                  WHERE u.nama = 'SMP ABBS Sragen') THEN
    RAISE EXCEPTION 'Sragen tidak muncul';
  END IF;

  RAISE NOTICE 'OK: % unit sekolah aktif tersedia untuk profil PSAT', n_rpc;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
