-- ROLLBACK untuk 20260902000005_unit_sekolah_dari_lms.sql
--
-- Sesudah mundur, halaman profil PSAT kehilangan sumber daftar unitnya. Kode
-- klien harus ikut dikembalikan ke larik UNIT_OPTIONS yang di-hardcode — dan
-- larik itu tertinggal 3 sekolah (Magelang, Sragen, Learning Center), sehingga
-- 14 guru kembali tidak bisa memilih unitnya sendiri.

BEGIN;

DROP FUNCTION IF EXISTS psat.get_unit_sekolah();

COMMIT;

NOTIFY pgrst, 'reload schema';
