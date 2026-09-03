-- Migration: tipe "Pilgan berkategori" di sisi PSAT
-- Prasyarat: lms-new 20260903c_tipe_pilgan_kategori.sql sudah diapply.
--
-- ============================================================================
-- LATAR
-- ============================================================================
-- SOP PTS 1 profil TKA menuntut tiga tipe: Pilgan, Pilgan Kompleks, dan Pilgan
-- berkategori — yang terakhir 8 dari 30 soal keluar dan 15 dari 50 bank soal.
-- Sisi LMS sudah mengenalnya (20260903c). Sisi PSAT belum, dan tanpa ini super
-- admin TIDAK BISA mengisi pagu TKA sama sekali: barisnya ditolak CHECK.
--
-- ============================================================================
-- ⚠️ CACAT DI DRAF YANG DIPERBAIKI DI SINI
-- ============================================================================
-- psat.tipe_ke_lms() memetakan nama tipe PSAT ke kosakata LMS lewat CASE dengan
-- cabang `ELSE p_tipe`. Untuk 'pilgan_kategori' cabang itu meneruskan namanya
-- apa adanya, sedangkan LMS menyimpannya sebagai 'pilihan_ganda_kategori'.
-- Akibatnya impor akan ditolak CHECK bank_soal — dan pesannya tidak akan
-- menyebut sebabnya.
--
-- Draf 20260901h melewatkan ini karena ia hanya menyentuh schema public;
-- pemetaan namanya tinggal di schema psat. Persis pola yang sama dengan bug
-- bab-lintas-tingkat: satu sisi diubah, penyebut di sisi lain tertinggal.
--
-- ============================================================================
-- DAMPAK
-- ============================================================================
--   • psat_patokan_ujian menerima tipe keenam → pagu TKA bisa diisi utuh.
--   • psat.bank_soal.tipe adalah TEXT polos tanpa constraint, jadi tidak ada
--     yang perlu dilebarkan di sana (diperiksa, bukan diasumsikan).
--   • Tidak ada baris lama yang berubah: tidak ada satu pun soal atau pagu
--     bertipe 'pilgan_kategori' hari ini.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260903000002_tipe_pilgan_kategori_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Pagu menerima tipe keenam
-- =============================================================================
ALTER TABLE psat.psat_patokan_ujian DROP CONSTRAINT IF EXISTS psat_patokan_ujian_tipe_check;
ALTER TABLE psat.psat_patokan_ujian ADD CONSTRAINT psat_patokan_ujian_tipe_check
  CHECK (tipe = ANY (ARRAY[
    'pilgan', 'ceklist', 'isian_singkat', 'essay', 'benar_salah', 'pilgan_kategori'
  ]));

-- =============================================================================
-- 2. Pemetaan nama tipe ke kosakata LMS
-- =============================================================================
-- Cabang ELSE dipertahankan untuk tipe yang namanya memang sama di kedua sisi
-- (ceklist, isian_singkat, benar_salah); yang berbeda disebut satu per satu.
CREATE OR REPLACE FUNCTION psat.tipe_ke_lms(p_tipe text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE p_tipe
           WHEN 'pilgan'          THEN 'pilihan_ganda'
           WHEN 'essay'           THEN 'esai'
           WHEN 'pilgan_kategori' THEN 'pilihan_ganda_kategori'
           ELSE p_tipe   -- ceklist, isian_singkat, benar_salah sama di kedua sisi
         END;
$function$;

COMMENT ON FUNCTION psat.tipe_ke_lms(text) IS
  'Nama tipe soal PSAT → kosakata LMS. Satu-satunya tempat pemetaan ini boleh ditulis; impor_soal_psat memanggilnya, tidak menyalinnya.';

-- =============================================================================
-- 3. GERBANG — perilaku
-- =============================================================================
DO $gate$
DECLARE
  v_lms   text;
  v_ujian uuid;
BEGIN
  -- a. Pemetaan harus mendarat pada nama yang DITERIMA CHECK di LMS. Ini cacat
  --    yang membuat migrasi ini ada; assersinya memanggil fungsinya, lalu
  --    mencocokkan hasilnya dengan constraint sungguhan di seberang.
  v_lms := psat.tipe_ke_lms('pilgan_kategori');
  IF v_lms <> 'pilihan_ganda_kategori' THEN
    RAISE EXCEPTION 'tipe_ke_lms memetakan pilgan_kategori ke "%" — LMS tidak mengenalnya', v_lms;
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'bank_soal_tipe_check')
     NOT LIKE '%' || v_lms || '%' THEN
    RAISE EXCEPTION
      'CHECK bank_soal di LMS belum menerima "%" — apply lms-new 20260903c lebih dulu', v_lms;
  END IF;

  -- b. Tipe lama tidak boleh bergeser.
  IF psat.tipe_ke_lms('pilgan') <> 'pilihan_ganda'
     OR psat.tipe_ke_lms('essay') <> 'esai'
     OR psat.tipe_ke_lms('ceklist') <> 'ceklist'
     OR psat.tipe_ke_lms('isian_singkat') <> 'isian_singkat'
     OR psat.tipe_ke_lms('benar_salah') <> 'benar_salah' THEN
    RAISE EXCEPTION 'REGRESI: pemetaan tipe lama berubah';
  END IF;

  -- c. Pagu harus benar-benar menerima tipe baru — diuji dengan INSERT sungguhan
  --    di subtransaksi yang dibatalkan, bukan dengan membaca teks constraint.
  SELECT g.ujian_id INTO v_ujian FROM psat.get_ujian_aktif() g LIMIT 1;
  IF v_ujian IS NULL THEN
    RAISE EXCEPTION 'tidak ada ujian aktif — gerbang pagu tidak bisa mengukur apa pun';
  END IF;

  BEGIN
    INSERT INTO psat.psat_patokan_ujian (ujian_id, tipe, tingkat_kesulitan, jumlah_keluar, jumlah_bank)
    VALUES (v_ujian, 'pilgan_kategori', 'mudah', 2, 5);
    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION
    WHEN check_violation THEN
      RAISE EXCEPTION 'CHECK psat_patokan_ujian masih menolak pilgan_kategori — pagu TKA tak bisa diisi';
    WHEN OTHERS THEN
      IF SQLERRM <> 'BATALKAN' THEN
        RAISE EXCEPTION 'gerbang pagu tersandung galat lain: [%] %', SQLSTATE, SQLERRM;
      END IF;
  END;

  RAISE NOTICE 'gerbang lolos: pilgan_kategori diterima pagu dan terpetakan ke %', v_lms;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
