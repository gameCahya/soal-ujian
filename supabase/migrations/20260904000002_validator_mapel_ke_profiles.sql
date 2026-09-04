-- Migration: penugasan validator berhenti menunjuk akun yang tak punya peran
--
-- MASALAHNYA, TERUKUR DI PRODUKSI 4 SEP 2026
-- psat.psat_validator_mapel punya 13 baris penugasan, dan SELURUHNYA menunjuk
-- dua akun yang tidak punya baris di public.profiles:
--     validator1@psat.com  (7 mapel)  — login terakhir 4 Sep 2026 09:12 WIB
--     validator2@psat.com  (6 mapel)
-- Keduanya akun aplikasi PSAT lama. Sejak cutover identitas 21 Agu 2026
-- (lms-new 20260821_psat_identitas_bersama.sql) peran diturunkan dari
-- public.profiles, jadi akun tanpa baris di sana mendapat
-- psat.current_user_role() = NULL → view psat.profiles nol baris → ditolak
-- di pintu masuk. Guru melihat "Akun Anda belum diberi akses" sementara layar
-- admin memperlihatkan penugasan yang seolah masih hidup.
--
-- KENAPA BARIS YATIM BISA BERTAHAN
-- FK-nya menunjuk auth.users, BUKAN public.profiles:
--     psat_validator_mapel_validator_id_fkey
--       FOREIGN KEY (validator_id) REFERENCES auth.users(id) ON DELETE CASCADE
-- Akun lama masih ada di auth.users (karena itu login-nya berhasil), jadi tidak
-- ada satu pun penjaga yang keberatan. Sesudah cutover, public.profiles adalah
-- satu-satunya sumber identitas — FK-nya harus ikut pindah ke sana.
--
-- YANG TIDAK BERUBAH: tidak ada kemampuan siapa pun yang dicabut. Baris yang
-- dihapus sudah tidak memberi akses apa pun sejak 21 Agustus; yang dihapus
-- adalah kesalahpahamannya, bukan izinnya.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260904000002_validator_mapel_ke_profiles_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Potret sebelum — dipakai gerbang, bukan sekadar catatan
-- =============================================================================
CREATE TEMP TABLE _sebelum ON COMMIT DROP AS
SELECT v.id, v.validator_id, (p.id IS NULL) AS yatim
FROM psat.psat_validator_mapel v
LEFT JOIN public.profiles p ON p.id = v.validator_id;

DO $pra$
DECLARE v_yatim int; v_sah int;
BEGIN
  SELECT count(*) FILTER (WHERE yatim), count(*) FILTER (WHERE NOT yatim)
    INTO v_yatim, v_sah FROM _sebelum;

  -- Angka ini diukur saat berkas ditulis. Kalau berbeda saat apply, keadaannya
  -- sudah bergeser dan berkas ini tidak lagi menggambarkan apa yang dikerjakan
  -- — lebih baik berhenti daripada menghapus sesuatu yang tak pernah diperiksa.
  IF v_yatim <> 13 THEN
    RAISE EXCEPTION 'Baris yatim % (diharapkan 13). Keadaan berubah sejak migrasi ditulis — periksa dulu.', v_yatim;
  END IF;
  RAISE NOTICE 'Sebelum: % yatim, % sah', v_yatim, v_sah;
END
$pra$;

-- =============================================================================
-- 2. Bersihkan
-- =============================================================================
DELETE FROM psat.psat_validator_mapel v
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v.validator_id);

-- =============================================================================
-- 3. FK pindah ke sumber identitas yang sebenarnya
-- =============================================================================
ALTER TABLE psat.psat_validator_mapel
  DROP CONSTRAINT IF EXISTS psat_validator_mapel_validator_id_fkey;

ALTER TABLE psat.psat_validator_mapel
  ADD CONSTRAINT psat_validator_mapel_validator_id_fkey
  FOREIGN KEY (validator_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

COMMENT ON COLUMN psat.psat_validator_mapel.validator_id IS
  'Menunjuk public.profiles — sumber identitas sejak cutover 21 Agu 2026. Dulu menunjuk auth.users, yang membiarkan penugasan bertahan untuk akun tanpa peran.';

-- =============================================================================
-- 4. Gerbang
-- =============================================================================
DO $gate$
DECLARE v_hapus int; v_sisa_yatim int; v_sah_sebelum int; v_sah_sesudah int; v_gigit boolean := false;
BEGIN
  SELECT count(*) FILTER (WHERE yatim), count(*) FILTER (WHERE NOT yatim)
    INTO v_hapus, v_sah_sebelum FROM _sebelum;

  SELECT count(*) INTO v_sisa_yatim
  FROM psat.psat_validator_mapel v
  WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = v.validator_id);
  IF v_sisa_yatim <> 0 THEN
    RAISE EXCEPTION 'Masih ada % baris yatim', v_sisa_yatim;
  END IF;

  -- Penugasan yang SAH tidak boleh ikut terbawa. Hari ini nol, jadi assersinya
  -- berbentuk "jumlahnya tidak berubah" — supaya tetap berarti kalau kelak ada.
  SELECT count(*) INTO v_sah_sesudah FROM psat.psat_validator_mapel;
  IF v_sah_sesudah <> v_sah_sebelum THEN
    RAISE EXCEPTION 'Penugasan sah ikut terhapus: % → %', v_sah_sebelum, v_sah_sesudah;
  END IF;

  -- FK yang terpasang tapi tidak menggigit adalah gerbang yang lolos dengan
  -- tangan kosong. Diuji dengan MENULIS, di subtransaksi yang dibatalkan.
  --
  -- Sengaja memakai id validator1@psat.com: ia ADA di auth.users tapi TIDAK ada
  -- di public.profiles. Itu satu-satunya bentuk yang membedakan FK baru dari FK
  -- lama — uuid acak ditolak keduanya, jadi ia tidak membuktikan apa-apa.
  BEGIN
    INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id)
    SELECT 'e3ad1d2e-8716-47bf-b2f7-5ed5421f424e'::uuid, id FROM psat.mata_pelajaran LIMIT 1;
  EXCEPTION WHEN foreign_key_violation THEN
    v_gigit := true;
  END;
  IF NOT v_gigit THEN
    RAISE EXCEPTION 'FK baru tidak menolak validator_id yang bukan profil';
  END IF;

  RAISE NOTICE 'Gerbang lolos: % baris yatim dihapus, % sah utuh, FK menggigit.', v_hapus, v_sah_sesudah;
END
$gate$;

COMMIT;
