-- =============================================================================
-- Guru boleh menghapus soal sendiri selama BELUM approved
-- =============================================================================
-- Sebelumnya policy `soal_delete_own_draft` hanya mengizinkan status 'draft'.
-- Akibatnya guru tidak bisa menarik kembali soal yang sudah dikirim ke validator
-- (atau yang sedang berstatus revisi) — padahal itu justru saat paling sering
-- dibutuhkan: salah kirim, salah slot matrix, atau ingin menulis ulang.
--
-- Aturan baru:
--   * 'draft'          → boleh (salah ketik, belum lengkap)
--   * 'needs_revision' → boleh (mau ditulis ulang, bukan diperbaiki)
--   * 'submitted'      → boleh (tarik kembali sebelum divalidasi)
--   * 'approved'       → TIDAK boleh. Soal sudah divalidasi dan mungkin sudah
--                        diimpor ke LMS/dipakai ujian.
--
-- Soal yang sedang dikunci validator (lihat halaman validasi: lock 10 menit)
-- tidak boleh dihapus sampai kuncinya kedaluwarsa, supaya validator tidak
-- kehilangan soal di tengah review.
--
-- Komentar soal ikut terhapus lewat ON DELETE CASCADE di psat.soal_komentar.
--
-- ROLLBACK: supabase/rollback/20261123000001_hapus_soal_belum_approved_rollback.sql

BEGIN;

-- Kolom kunci validator sudah ada di produksi tetapi belum pernah masuk
-- migrasi. Ditambahkan di sini (IF NOT EXISTS) supaya migrasi ini utuh untuk
-- database baru, dan tidak mengubah apa pun di produksi.
ALTER TABLE psat.bank_soal
  ADD COLUMN IF NOT EXISTS locked_by uuid,
  ADD COLUMN IF NOT EXISTS locked_at timestamptz;

COMMENT ON COLUMN psat.bank_soal.locked_by IS
  'Validator yang sedang membuka soal ini. Dipakai untuk kunci sementara 10 menit.';
COMMENT ON COLUMN psat.bank_soal.locked_at IS
  'Waktu kunci diambil. Kunci dianggap kedaluwarsa setelah 10 menit.';

DROP POLICY IF EXISTS "soal_delete_own_draft" ON psat.bank_soal;
DROP POLICY IF EXISTS "soal_delete_own_belum_approved" ON psat.bank_soal;

CREATE POLICY "soal_delete_own_belum_approved" ON psat.bank_soal
  FOR DELETE USING (
    auth.uid() = guru_id
    AND psat.boleh_menulis_soal()
    AND status IN ('draft', 'needs_revision', 'submitted')
    AND (
      locked_at IS NULL
      OR locked_at < now() - interval '10 minutes'
    )
  );

COMMENT ON POLICY "soal_delete_own_belum_approved" ON psat.bank_soal IS
  'Guru boleh menghapus soal miliknya selama belum approved dan tidak sedang dikunci validator.';

-- =============================================================================
-- Gerbang
-- =============================================================================
DO $gate$
DECLARE
  v_qual text;
BEGIN
  SELECT qual INTO v_qual
  FROM pg_policies
  WHERE schemaname = 'psat'
    AND tablename  = 'bank_soal'
    AND policyname = 'soal_delete_own_belum_approved';

  IF v_qual IS NULL THEN
    RAISE EXCEPTION 'Policy soal_delete_own_belum_approved tidak terbentuk';
  END IF;

  IF v_qual NOT LIKE '%needs_revision%' OR v_qual NOT LIKE '%submitted%' THEN
    RAISE EXCEPTION 'Policy hapus belum memuat status revisi/submitted: %', v_qual;
  END IF;

  IF v_qual LIKE '%approved%' THEN
    RAISE EXCEPTION 'Policy hapus tidak boleh mengizinkan status approved: %', v_qual;
  END IF;

  RAISE NOTICE 'Gerbang lolos: guru boleh hapus draft/revisi/submitted, bukan approved.';
END
$gate$;

COMMIT;
