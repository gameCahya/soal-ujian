-- Migration (1/2): psat.bank_soal dapat bab_id, nama jadi cermin
-- Pasangannya: lms-new/supabase/migrations/20260904c_bab_rename_dan_impor.sql
-- URUTAN: berkas INI dulu — pasangannya memasang trigger yang menulis kolom
-- yang baru dibuat di sini, dan mengubah impor supaya memakainya.
--
-- MASALAHNYA
-- psat.bank_soal menautkan soal ke bab HANYA lewat nama (`bab_id_text` text).
-- Akibatnya nama bab tidak bisa diganti di mana pun tanpa memutus sesuatu:
--   - ganti di LMS  → soal PSAT tetap memegang nama lama, hilang dari tampilan
--                     bab guru (soal/page.tsx menyaring s.bab_id_text === activeBab)
--   - impor         → nama lama tak cocok dengan bab mana pun → bab_id NULL di
--                     public.bank_soal → generate mode ketat menolak "soal tanpa bab"
-- Karena itu halaman Matrix menolak nama bebas (matrix/page.tsx:373-378) —
-- gejalanya "nama bab tidak bisa diedit", padahal kotak teksnya mengundang.
--
-- Bukan hipotesis. Era teks bebas dulu meninggalkan:
--   2025/2026 : 691 dari 1.523 soal bernama bab yang TIDAK ADA di LMS
--   2026/2027 :   0 dari   541  (dropdown wajib sudah mencegahnya)
--
-- BENTUK PERBAIKANNYA
-- bab_id jadi sumber kebenaran; bab_id_text tetap ada tapi turun jadi CERMIN
-- yang dijaga trigger. Alasannya bukan malas: bab_id_text adalah kunci
-- pengelompokan di ~25 tempat di soal/page.tsx (activeBab, expandedBabs, kunci
-- `${bab}_${tipe}_${kesulitan}`, progres per bab). Menukar semuanya ke UUID
-- sepuluh hari sebelum PTS adalah risiko yang tidak dibayar oleh manfaat apa pun
-- yang tidak sudah didapat dari mencerminkan namanya.
--
-- KOMPATIBEL MUNDUR: kolomnya nullable dan trigger hanya bertindak saat bab_id
-- terisi. Kode yang belum mengirim bab_id berperilaku persis seperti sekarang.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260904000001_bab_id_di_bank_soal_rollback.sql

BEGIN;

-- Prasyarat: aturan bab satu badan harus sudah ada (lms-new 20260901b).
DO $pra$
BEGIN
  IF to_regprocedure('public.bab_terlihat_ujian(uuid)') IS NULL THEN
    RAISE EXCEPTION 'public.bab_terlihat_ujian() belum ada — apply lms-new 20260901b dulu';
  END IF;
END
$pra$;

-- =============================================================================
-- 1. Kolom
-- =============================================================================
-- ON DELETE SET NULL menyamai psat_matrix_input.bab_id yang sudah ada. Bukan
-- RESTRICT: menghapus bab tidak boleh menyandera soal, dan bab_id_text tetap
-- tertinggal sebagai jejak nama supaya guru masih tahu soal itu dulu milik apa.
ALTER TABLE psat.bank_soal
  ADD COLUMN IF NOT EXISTS bab_id uuid REFERENCES public.bab_pelajaran(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS bank_soal_bab_id_idx ON psat.bank_soal (bab_id);

COMMENT ON COLUMN psat.bank_soal.bab_id IS
  'Tautan bab yang bertahan terhadap ganti nama. Sumber kebenaran; bab_id_text adalah cerminnya, dijaga trigger psat_bank_soal_cermin_bab.';
COMMENT ON COLUMN psat.bank_soal.bab_id_text IS
  'Nama bab untuk tampilan & pengelompokan. Diturunkan dari bab_id bila bab_id terisi — jangan diandalkan sebagai tautan.';

-- =============================================================================
-- 2. Backfill — aturan yang SAMA dengan impor, bukan salinannya
-- =============================================================================
-- bab_terlihat_ujian() sudah memberi kolom prioritas (0 milik ujian ini, 1
-- warisan setingkat, 2 warisan tanpa tingkat). Memakainya di sini berarti
-- backfill dan impor tidak mungkin menyimpul beda — kelas bug yang sudah dua
-- kali terjadi di repo ini.
WITH cocok AS (
  SELECT b.id AS soal_id,
         (SELECT v.bab_id
            FROM public.bab_terlihat_ujian(b.ujian_id) v
           WHERE lower(btrim(v.nama_bab)) = lower(btrim(b.bab_id_text))
           ORDER BY v.prioritas, v.bab_id
           LIMIT 1) AS bab_id
  FROM psat.bank_soal b
  WHERE b.bab_id IS NULL
    AND b.ujian_id IS NOT NULL
    AND coalesce(btrim(b.bab_id_text), '') <> ''
)
UPDATE psat.bank_soal b
SET bab_id = c.bab_id
FROM cocok c
WHERE b.id = c.soal_id AND c.bab_id IS NOT NULL;

-- =============================================================================
-- 3. Trigger cermin: nama mengikuti bab_id
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.cermin_nama_bab()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
BEGIN
  IF NEW.bab_id IS NOT NULL THEN
    SELECT bp.nama_bab INTO NEW.bab_id_text
    FROM public.bab_pelajaran bp WHERE bp.id = NEW.bab_id;
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS psat_bank_soal_cermin_bab ON psat.bank_soal;
CREATE TRIGGER psat_bank_soal_cermin_bab
  BEFORE INSERT OR UPDATE OF bab_id, bab_id_text ON psat.bank_soal
  FOR EACH ROW EXECUTE FUNCTION psat.cermin_nama_bab();

-- =============================================================================
-- 4. Gerbang
-- =============================================================================
DO $gate$
DECLARE
  v_kini int; v_kini_null int; v_lalu_null int; v_bab uuid; v_soal uuid; v_nama text;
BEGIN
  -- Soal tahun ini harus terpetakan SELURUHNYA — 0 yatim sebelum migrasi ini.
  SELECT count(*), count(*) FILTER (WHERE b.bab_id IS NULL)
    INTO v_kini, v_kini_null
  FROM psat.bank_soal b
  JOIN public.ujian u ON u.id = b.ujian_id
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  WHERE coalesce(btrim(b.bab_id_text), '') <> '';

  IF v_kini = 0 THEN
    RAISE EXCEPTION 'Gerbang tidak memeriksa apa pun: nol soal tahun aktif';
  END IF;
  IF v_kini_null <> 0 THEN
    RAISE EXCEPTION '% dari % soal tahun aktif gagal dipetakan ke bab', v_kini_null, v_kini;
  END IF;

  -- Tahun lalu memang tidak akan penuh; yang penting sebagian besar tertolong.
  SELECT count(*) FILTER (WHERE b.bab_id IS NULL) INTO v_lalu_null
  FROM psat.bank_soal b
  JOIN public.ujian u ON u.id = b.ujian_id
  JOIN public.event_ujian ev ON ev.id = u.event_id AND NOT ev.is_active
  WHERE coalesce(btrim(b.bab_id_text), '') <> '';
  RAISE NOTICE 'Soal tahun lalu yang tetap tanpa bab_id: % (nama bebas era lama)', v_lalu_null;

  -- Trigger cermin benar-benar menyala. Diuji dengan MENULIS, bukan membaca
  -- definisinya: trigger bisa terpasang dan tetap tidak berpengaruh.
  SELECT b.id, b.bab_id INTO v_soal, v_bab
  FROM psat.bank_soal b WHERE b.bab_id IS NOT NULL LIMIT 1;
  IF v_soal IS NULL THEN
    RAISE EXCEPTION 'Tidak ada soal ber-bab_id untuk menguji trigger';
  END IF;

  UPDATE psat.bank_soal SET bab_id_text = 'NAMA-SALAH-UJI' WHERE id = v_soal;
  SELECT bab_id_text INTO v_nama FROM psat.bank_soal WHERE id = v_soal;
  IF v_nama = 'NAMA-SALAH-UJI' THEN
    RAISE EXCEPTION 'Trigger cermin tidak menyala: nama palsu bertahan';
  END IF;
  IF v_nama <> (SELECT nama_bab FROM public.bab_pelajaran WHERE id = v_bab) THEN
    RAISE EXCEPTION 'Trigger cermin menulis nama yang salah: %', v_nama;
  END IF;

  RAISE NOTICE 'Gerbang lolos: % soal tahun aktif terpetakan, trigger cermin aktif.', v_kini;
END
$gate$;

COMMIT;
