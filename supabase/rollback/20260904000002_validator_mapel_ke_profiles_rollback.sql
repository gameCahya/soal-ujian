-- ROLLBACK untuk 20260904000002_validator_mapel_ke_profiles.sql
--
-- ⚠️ Mengembalikan FK ke auth.users berarti penugasan validator boleh lagi
-- menunjuk akun yang tidak punya baris di public.profiles — yaitu akun yang
-- TIDAK BISA masuk PSAT. Itu persis keadaan yang membuat 13 penugasan terlihat
-- hidup padahal tak memberi akses apa pun.
--
-- 13 baris yang dihapus TIDAK dikembalikan: keduanya milik validator1@psat.com
-- dan validator2@psat.com, akun aplikasi lama yang menurut keputusan pemilik
-- produk memang dipensiunkan. Kalau benar-benar dibutuhkan, penugasannya
-- ditulis ulang lewat soal-ujian /admin/users untuk akun LMS yang sah.

BEGIN;

ALTER TABLE psat.psat_validator_mapel
  DROP CONSTRAINT IF EXISTS psat_validator_mapel_validator_id_fkey;

ALTER TABLE psat.psat_validator_mapel
  ADD CONSTRAINT psat_validator_mapel_validator_id_fkey
  FOREIGN KEY (validator_id) REFERENCES auth.users(id) ON DELETE CASCADE;

COMMENT ON COLUMN psat.psat_validator_mapel.validator_id IS NULL;

COMMIT;
