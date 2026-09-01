-- Rollback: 20260901000006_izin_penulis_lewat_trigger.sql
--
-- Melepas trigger yang menyalakan is_penulis_soal saat penulis ditunjuk.
--
-- ⚠️ Sesudah ini, penunjukan lewat jalur LAMA (upsert langsung ke
--    psat.psat_ujian_penulis, seperti build halaman Patokan sebelum
--    20260901000005) kembali menghasilkan penulis TANPA izin — yang berarti
--    view psat.profiles tidak mengembalikan baris guru itu sendiri dan dashboard
--    PSAT tidak bisa memuat profilnya, tanpa galat apa pun.
--    psat.tetapkan_penulis() tetap menyalakan izin; yang hilang adalah jaminan
--    bagi jalur penulisan lain.
--
-- Izin yang SUDAH terlanjur menyala sengaja TIDAK dicabut: mencabutnya akan
-- mematikan tugas penulis yang sedang bekerja.

BEGIN;

DROP TRIGGER IF EXISTS trg_penulis_dapat_izin ON psat.psat_ujian_penulis;
DROP FUNCTION IF EXISTS psat.penulis_dapat_izin();

DO $gate$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_trigger
             WHERE tgrelid = 'psat.psat_ujian_penulis'::regclass
               AND tgname = 'trg_penulis_dapat_izin') THEN
    RAISE EXCEPTION 'Trigger masih terpasang';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
