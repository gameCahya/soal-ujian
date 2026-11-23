-- Rollback: kembalikan policy hapus soal ke 'draft' saja.
-- Jalankan manual bila migrasi 20261123000001 perlu dibatalkan.

BEGIN;

DROP POLICY IF EXISTS "soal_delete_own_belum_approved" ON psat.bank_soal;

DROP POLICY IF EXISTS "soal_delete_own_draft" ON psat.bank_soal;
CREATE POLICY "soal_delete_own_draft" ON psat.bank_soal
  FOR DELETE USING (
    auth.uid() = guru_id
    AND status = 'draft'
    AND psat.boleh_menulis_soal()
  );

COMMIT;
