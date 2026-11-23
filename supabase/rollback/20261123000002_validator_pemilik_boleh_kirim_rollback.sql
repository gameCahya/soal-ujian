-- Rollback: kembalikan trigger ke definisi produksi 22 Nov 2026
-- (validator ber-peran 'validator' tidak boleh mengubah status selain dari submitted).

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
    IF NEW.guru_id IS NOT NULL
       AND NEW.guru_id = auth.uid()
       AND peran = 'validator'
       AND NEW.status IN ('approved', 'needs_revision') THEN
      RAISE EXCEPTION 'Validator tidak boleh memvalidasi soal yang ia tulis sendiri.'
        USING ERRCODE = '42501',
              HINT = 'Minta validator lain atau admin untuk memeriksa soal ini.';
    END IF;

    IF peran = 'validator' AND OLD.status <> 'submitted' THEN
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

COMMIT;
