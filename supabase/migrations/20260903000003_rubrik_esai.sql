-- Migration: kolom rubrik penilaian esai di PSAT (2/3)
-- ⚠️ Urutan: SESUDAH lms-new 20260903d_rubrik_kolom.sql (aturan bentuknya di sana),
--    dan SEBELUM lms-new 20260903e_rubrik_impor.sql.
--    20260903e membuat impor_soal_psat membaca b.rubrik dari tabel ini; terbalik
--    urutannya = impor gagal di setiap panggilan dengan "column b.rubrik does
--    not exist". Persis cacat yang menghentikan impor 2-3 September.
--
-- LATAR
-- Penulis soal di PSAT yang mendaftar kriteria penilaian esai; LMS yang
-- menampilkannya ke penilai. Kolomnya karena itu harus ada di kedua sisi, dan
-- bentuk datanya identik supaya impor tinggal menyalin.
--
-- BENTUK: [{"kriteria": "...", "poin": 2.0}, ...]
-- Larik, bukan objek berkunci — urutan kriteria bermakna bagi penilai.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260903000003_rubrik_esai_rollback.sql

BEGIN;

-- Prasyarat: aturan bentuk milik LMS, dipinjam bukan disalin.
DO $pra$
BEGIN
  IF to_regprocedure('public.rubrik_bentuk_sah(jsonb)') IS NULL THEN
    RAISE EXCEPTION
      'public.rubrik_bentuk_sah() belum ada. Apply lms-new 20260903d_rubrik_kolom.sql LEBIH DULU.';
  END IF;
END
$pra$;

ALTER TABLE psat.bank_soal ADD COLUMN IF NOT EXISTS rubrik jsonb;

-- Aturannya MILIK public.rubrik_bentuk_sah() — satu badan untuk kedua schema.
-- Menyalinnya ke sini berarti kedua sisi bisa menyimpang dan salah satu menerima
-- rubrik yang lain tolak; itu persis cacat psat.tipe_ke_lms() kemarin.
ALTER TABLE psat.bank_soal DROP CONSTRAINT IF EXISTS bank_soal_rubrik_bentuk;
ALTER TABLE psat.bank_soal ADD CONSTRAINT bank_soal_rubrik_bentuk
  CHECK (public.rubrik_bentuk_sah(rubrik));

COMMENT ON COLUMN psat.bank_soal.rubrik IS
  'Rubrik penilaian esai: larik [{"kriteria": teks, "poin": angka}]. Menyeberang apa adanya ke public.bank_soal.rubrik lewat impor_soal_psat, hanya untuk tipe esai.';

-- =============================================================================
-- GERBANG
-- =============================================================================
DO $gate$
DECLARE v_soal uuid;
BEGIN
  SELECT id INTO v_soal FROM psat.bank_soal WHERE tipe = 'essay' LIMIT 1;
  IF v_soal IS NULL THEN
    RAISE EXCEPTION 'tidak ada soal essay di PSAT — gerbang tidak bisa mengukur apa pun';
  END IF;

  -- Bentuk sah harus DITERIMA.
  BEGIN
    UPDATE psat.bank_soal
       SET rubrik = '[{"kriteria":"Menyebutkan definisi","poin":2},
                      {"kriteria":"Rumus benar","poin":1.5}]'::jsonb
     WHERE id = v_soal;
    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION
    WHEN check_violation THEN
      RAISE EXCEPTION 'CHECK menolak rubrik yang SAH — penulis tidak akan bisa menyimpan';
    WHEN OTHERS THEN
      IF SQLERRM <> 'BATALKAN' THEN
        RAISE EXCEPTION 'gerbang tersandung galat lain: [%] %', SQLSTATE, SQLERRM;
      END IF;
  END;

  -- Bentuk rusak harus DITOLAK — tanpa ini, constraint yang selalu true lolos.
  BEGIN
    UPDATE psat.bank_soal SET rubrik = '[{"kriteria":"","poin":2}]'::jsonb WHERE id = v_soal;
    RAISE EXCEPTION 'CHECK MELOLOSKAN kriteria kosong';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    UPDATE psat.bank_soal SET rubrik = '[{"kriteria":"Ada","poin":"dua"}]'::jsonb WHERE id = v_soal;
    RAISE EXCEPTION 'CHECK MELOLOSKAN poin bukan angka';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'gerbang rubrik PSAT lolos';
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
