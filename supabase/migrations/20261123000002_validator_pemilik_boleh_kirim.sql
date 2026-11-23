-- =============================================================================
-- Guru yang juga validator boleh mengirim soalnya sendiri
-- =============================================================================
-- MASALAH
-- Trigger psat.cegah_validasi_soal_sendiri() (versi produksi, 22 Nov) memblokir
-- SEMUA perubahan status oleh pemanggil ber-peran 'validator' selama status lama
-- bukan 'submitted', kecuali membatalkan keputusan sendiri:
--
--   IF peran = 'validator' AND OLD.status <> 'submitted' THEN
--     ... RAISE EXCEPTION 'Soal ini tidak sedang menunggu validasi' ...
--
-- psat.current_user_role() mengembalikan 'validator' untuk setiap profil dengan
-- is_soal_validator = true, termasuk guru penulis yang juga diberi flag
-- validator. Akibatnya dua guru (Achmad Munaja, Putri Nurika — total 120 draft)
-- tidak bisa menekan "Kirim ke Validator": draft -> submitted ditolak 403
-- dengan hint "Hanya validator yang memutuskan soal ini (atau admin)...".
-- Alur kirim ulang setelah revisi (needs_revision -> submitted oleh guru) juga
-- ikut rusak.
--
-- PERBAIKAN
-- Blokir validator TIDAK berlaku ketika pelakunya adalah pemilik soal dan
-- tujuannya mengirim soal itu sendiri (NEW.status = 'submitted'). Aturan lain
-- tidak berubah:
--   * validator tetap tidak boleh approve/revisi soal miliknya sendiri;
--   * validator tetap tidak boleh memutuskan soal yang tidak sedang menunggu
--     validasi, kecuali membatalkan keputusan sendiri;
--   * admin tidak dibatasi.
--
-- CATATAN DRIFT
-- Definisi fungsi ini di produksi lebih baru daripada migrasi
-- 20261114000002_validasi_tanpa_soal_sendiri.sql di repo (blok "validator hanya
-- boleh memutuskan soal yang menunggu validasi" belum pernah masuk repo).
-- Migrasi ini menulis ulang fungsi secara UTUH agar database baru dan produksi
-- memakai definisi yang sama.
--
-- ROLLBACK: supabase/rollback/20261123000002_validator_pemilik_boleh_kirim_rollback.sql

BEGIN;

CREATE OR REPLACE FUNCTION psat.cegah_validasi_soal_sendiri()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
DECLARE
  peran psat.user_role := psat.current_user_role();
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    -- Validator tidak boleh memvalidasi soal yang ia tulis sendiri.
    IF NEW.guru_id IS NOT NULL
       AND NEW.guru_id = auth.uid()
       AND peran = 'validator'
       AND NEW.status IN ('approved', 'needs_revision') THEN
      RAISE EXCEPTION 'Validator tidak boleh memvalidasi soal yang ia tulis sendiri.'
        USING ERRCODE = '42501',
              HINT = 'Minta validator lain atau admin untuk memeriksa soal ini.';
    END IF;

    -- Validator hanya boleh memutuskan soal yang sedang menunggu validasi,
    -- kecuali membatalkan keputusan yang ia sendiri buat. Pemilik soal yang
    -- juga ber-flag validator dikecualikan saat mengirim soalnya sendiri.
    IF peran = 'validator'
       AND OLD.status <> 'submitted'
       AND NOT (OLD.guru_id = auth.uid() AND NEW.status = 'submitted') THEN
      IF NOT (
        (OLD.status = 'approved' AND NEW.status = 'submitted'
          AND OLD.approved_by IS NOT NULL AND OLD.approved_by = auth.uid())
        OR
        (OLD.status = 'needs_revision' AND NEW.status = 'submitted'
          AND OLD.rejected_by IS NOT NULL AND OLD.rejected_by = auth.uid())
      ) THEN
        RAISE EXCEPTION 'Soal ini tidak sedang menunggu validasi (status: %).', OLD.status
          USING ERRCODE = '42501',
                HINT = 'Muat ulang halaman. Hanya validator yang memutuskan soal ini (atau admin) yang dapat membatalkannya.';
      END IF;
    END IF;

    -- Pemilik keputusan dicatat server-side agar tidak bisa dipalsukan klien.
    IF NEW.status = 'approved' THEN
      NEW.approved_by := auth.uid();
      NEW.rejected_by := NULL;
    ELSIF NEW.status = 'needs_revision' THEN
      NEW.rejected_by := auth.uid();
      NEW.approved_by := NULL;
    ELSE
      NEW.approved_by := NULL;
      NEW.rejected_by := NULL;
    END IF;
  END IF;
  RETURN NEW;
END
$fn$;

COMMENT ON FUNCTION psat.cegah_validasi_soal_sendiri() IS
  'Menolak validator memvalidasi soal miliknya dan memutuskan soal yang tidak menunggu validasi. Pemilik soal yang juga validator tetap boleh mengirim soalnya sendiri (status → submitted).';

-- =============================================================================
-- Gerbang
-- =============================================================================
DO $gate$
DECLARE
  v_src text;
BEGIN
  SELECT prosrc INTO v_src
  FROM pg_proc
  WHERE oid = 'psat.cegah_validasi_soal_sendiri()'::regprocedure;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'Fungsi cegah_validasi_soal_sendiri tidak ditemukan';
  END IF;

  IF v_src NOT LIKE '%OLD.guru_id = auth.uid() AND NEW.status = ''submitted''%' THEN
    RAISE EXCEPTION 'Pengecualian pemilik soal belum ada di fungsi';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'psat.bank_soal'::regclass
      AND tgname = 'psat_bank_soal_tolak_validasi_sendiri'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'Trigger psat_bank_soal_tolak_validasi_sendiri tidak aktif';
  END IF;

  RAISE NOTICE 'Gerbang lolos: pemilik soal boleh mengirim soalnya sendiri.';
END
$gate$;

COMMIT;
