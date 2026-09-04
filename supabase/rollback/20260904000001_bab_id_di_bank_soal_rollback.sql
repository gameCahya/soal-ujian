-- ROLLBACK untuk 20260904000001_bab_id_di_bank_soal.sql
--
-- ⚠️ URUTAN MUNDUR TERBALIK DARI URUTAN MAJU.
-- lms-new 20260904c membuat impor_soal_psat MEMBACA psat.bank_soal.bab_id.
-- Menghapus kolomnya lebih dulu membuat SETIAP impor gagal. Penjaga di bawah
-- menolak kalau sisi LMS belum dimundurkan.
--
-- ⚠️ APA YANG HILANG
-- Tautan bab yang bertahan terhadap ganti nama. Sesudah ini soal kembali
-- ditautkan ke bab HANYA lewat nama, jadi mengganti nama bab di LMS kembali
-- memutus soal PSAT tanpa gejala — dan impor berikutnya membuat bab kembar
-- bernama lama. bab_id_text tetap utuh, jadi tak ada data tampilan yang hilang.

BEGIN;

DO $jaga$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'impor_soal_psat';

  IF v_def IS NOT NULL AND position('src_bab_id' in v_def) > 0 THEN
    RAISE EXCEPTION 'impor_soal_psat masih membaca bab_id — mundurkan lms-new 20260904c LEBIH DULU';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'bab_pelajaran_sebar_nama') THEN
    RAISE EXCEPTION 'Trigger penyebar nama masih terpasang — mundurkan lms-new 20260904c LEBIH DULU';
  END IF;
END
$jaga$;

DROP TRIGGER IF EXISTS psat_bank_soal_cermin_bab ON psat.bank_soal;
DROP FUNCTION IF EXISTS psat.cermin_nama_bab();
DROP INDEX IF EXISTS psat.bank_soal_bab_id_idx;
ALTER TABLE psat.bank_soal DROP COLUMN IF EXISTS bab_id;

COMMIT;
