-- ROLLBACK untuk 20260831000002_buat_bab_dari_psat.sql
--
-- Hanya melepas fungsinya. Bab yang sudah terlanjur dibuat guru TIDAK dihapus:
-- soal dan konfigurasi matriks mungkin sudah menunjuk ke sana, dan menghapusnya
-- akan meng-NULL-kan bank_soal.bab_id lalu membuat generate ditolak.
-- Daftar bab yang lahir dari sini:
--   SELECT * FROM public.bab_pelajaran WHERE ujian_id IS NULL ORDER BY created_at DESC;

BEGIN;
DROP FUNCTION IF EXISTS psat.buat_bab_ujian(uuid, text);
COMMIT;

NOTIFY pgrst, 'reload schema';
