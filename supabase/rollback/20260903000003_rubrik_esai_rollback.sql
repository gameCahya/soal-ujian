-- ROLLBACK untuk 20260903000003_rubrik_esai.sql
--
-- ⚠️ URUTAN: mundurkan lms-new 20260903d LEBIH DULU. impor_soal_psat di sana
-- membaca b.rubrik dari tabel ini; menghapus kolomnya duluan membuat SELURUH
-- impor gagal dengan "column b.rubrik does not exist".

BEGIN;

DO $jaga$
DECLARE v int;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'impor_soal_psat'
      AND pg_get_functiondef(p.oid) LIKE '%b.rubrik,%'
  ) THEN
    RAISE EXCEPTION
      'MENOLAK MUNDUR: public.impor_soal_psat masih membaca b.rubrik. Mundurkan lms-new 20260903d lebih dulu, atau impor akan mati total.';
  END IF;

  SELECT count(*) INTO v FROM psat.bank_soal WHERE rubrik IS NOT NULL;
  IF v > 0 THEN
    RAISE EXCEPTION 'MENOLAK MUNDUR: % soal sudah punya rubrik — menghapus kolomnya membuangnya permanen.', v;
  END IF;
END
$jaga$;

ALTER TABLE psat.bank_soal DROP CONSTRAINT IF EXISTS bank_soal_rubrik_bentuk;
ALTER TABLE psat.bank_soal DROP COLUMN IF EXISTS rubrik;

COMMIT;
