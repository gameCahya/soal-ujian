-- Migration: baris matriks tidak bisa lagi meninggalkan soal
--
-- MASALAHNYA, TERUKUR DI PRODUKSI 5 SEP 2026
-- 94 soal dari 2 guru lenyap dari halaman Soal penulisnya (diperbaiki datanya
-- lewat 20260905000002). Sebabnya: akordeon halaman Soal dibangun dari
-- psat_matrix_input dan mencocokkan soal lewat NAMA bab, tanpa keranjang
-- "lain-lain". Begitu baris matriks pindah ke bab lain — atau dihapus — soal
-- yang sudah ditulis tidak punya grup untuk ditampilkan.
--
-- KENAPA DI DATABASE, BUKAN DI TOMBOL
-- Penjaga di matrix/page.tsx hanya menjaga satu tombol di satu halaman, dan
-- justru penjaga di sanalah yang sudah ada tapi menjaga hal yang salah
-- (`is_submitted`, bukan "bab ini punya soal?"). Aturan ini milik datanya,
-- jadi tempatnya di trigger: klien mana pun — halaman guru, layar admin,
-- skrip — tunduk pada aturan yang sama.
--
-- DUA ATURAN
--   UPDATE bab_id  → soal guru itu IKUT pindah. Ini yang guru kira sedang
--                    mereka lakukan saat "mengganti nama bab".
--   DELETE         → ditolak selama babnya masih punya soal.
--
-- Sejalan dengan sebar_ganti_nama_bab() (lms-new 20260904c) yang sudah
-- menyebarkan GANTI NAMA. Yang ini menutup jalur satunya: PINDAH bab.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260905000003_matriks_tak_boleh_meninggalkan_soal_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Soal ikut saat baris matriks menunjuk bab lain
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.matriks_pindah_bawa_soal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $function$
DECLARE
  v_ikut int;
BEGIN
  -- Ganti NAMA bab tidak lewat sini: sebar_ganti_nama_bab() menulis
  -- bab_id_text tanpa menyentuh bab_id, jadi syarat ini tidak terpicu.
  IF NEW.bab_id IS DISTINCT FROM OLD.bab_id AND NEW.bab_id IS NOT NULL THEN
    UPDATE psat.bank_soal b
       SET bab_id = NEW.bab_id
     WHERE b.guru_id  = OLD.profile_id
       AND b.ujian_id = OLD.ujian_id
       AND lower(btrim(b.bab_id_text)) = lower(btrim(OLD.bab_id_text));
    GET DIAGNOSTICS v_ikut = ROW_COUNT;
    IF v_ikut > 0 THEN
      RAISE NOTICE '% soal ikut pindah ke bab %', v_ikut, NEW.bab_id;
    END IF;
  END IF;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_matriks_pindah_bawa_soal ON psat.psat_matrix_input;
CREATE TRIGGER trg_matriks_pindah_bawa_soal
  BEFORE UPDATE OF bab_id ON psat.psat_matrix_input
  FOR EACH ROW EXECUTE FUNCTION psat.matriks_pindah_bawa_soal();

-- =============================================================================
-- 2. Bab yang masih berisi soal tidak boleh dilepas dari matriks
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.matriks_tolak_hapus_berisi()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $function$
DECLARE
  v_soal int;
BEGIN
  SELECT count(*) INTO v_soal
    FROM psat.bank_soal b
   WHERE b.guru_id  = OLD.profile_id
     AND b.ujian_id = OLD.ujian_id
     AND lower(btrim(b.bab_id_text)) = lower(btrim(OLD.bab_id_text));

  IF v_soal > 0 THEN
    RAISE EXCEPTION 'Bab "%" masih berisi % soal. Pindahkan bab ini ke bab lain (soalnya ikut) atau hapus soalnya dulu.',
                    OLD.bab_id_text, v_soal
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN OLD;
END
$function$;

DROP TRIGGER IF EXISTS trg_matriks_tolak_hapus_berisi ON psat.psat_matrix_input;
CREATE TRIGGER trg_matriks_tolak_hapus_berisi
  BEFORE DELETE ON psat.psat_matrix_input
  FOR EACH ROW EXECUTE FUNCTION psat.matriks_tolak_hapus_berisi();

-- =============================================================================
-- 3. Gerbang — empat perilaku, masing-masing di subtransaksi yang dibatalkan
-- =============================================================================
DO $gate$
DECLARE
  v_baris    record;
  v_bab_lain uuid;
  v_soal     int;
  v_pindah   int;
  v_ditolak  boolean := false;
  v_kosong   uuid;
  v_ids      uuid[];
BEGIN
  -- Baris matriks yang BENAR-BENAR berisi soal, dipilih dari data nyata.
  SELECT m.* INTO v_baris
    FROM psat.psat_matrix_input m
   WHERE (SELECT count(*) FROM psat.bank_soal b
           WHERE b.guru_id = m.profile_id AND b.ujian_id = m.ujian_id
             AND lower(btrim(b.bab_id_text)) = lower(btrim(m.bab_id_text))) > 0
   LIMIT 1;
  IF v_baris.id IS NULL THEN
    RAISE EXCEPTION 'Tidak ada baris matriks berisi soal — gerbang ini akan lolos tanpa menguji apa pun';
  END IF;

  SELECT count(*) INTO v_soal FROM psat.bank_soal b
   WHERE b.guru_id = v_baris.profile_id AND b.ujian_id = v_baris.ujian_id
     AND lower(btrim(b.bab_id_text)) = lower(btrim(v_baris.bab_id_text));

  -- Bab lain milik ujian yang sama, sebagai tujuan pindah
  SELECT v.bab_id INTO v_bab_lain
    FROM public.bab_terlihat_ujian(v_baris.ujian_id) v
   WHERE v.bab_id IS DISTINCT FROM v_baris.bab_id
   LIMIT 1;
  IF v_bab_lain IS NULL THEN
    RAISE EXCEPTION 'Tidak ada bab tujuan untuk menguji perpindahan';
  END IF;

  -- (a) HAPUS baris berisi soal → harus DITOLAK
  BEGIN
    DELETE FROM psat.psat_matrix_input WHERE id = v_baris.id;
    RAISE EXCEPTION 'batalkan-tanpa-tolak';
  EXCEPTION
    WHEN restrict_violation THEN v_ditolak := true;
    WHEN raise_exception THEN
      IF SQLERRM <> 'batalkan-tanpa-tolak' THEN RAISE; END IF;
  END;
  IF NOT v_ditolak THEN
    RAISE EXCEPTION 'Penghapusan bab berisi soal TIDAK ditolak';
  END IF;

  -- (b) KONTROL: hapus baris yang TIDAK punya soal → harus BOLEH.
  -- Tanpa ini, trigger yang menolak segalanya pun akan lolos gerbang (a).
  SELECT m.id INTO v_kosong
    FROM psat.psat_matrix_input m
   WHERE NOT EXISTS (SELECT 1 FROM psat.bank_soal b
                      WHERE b.guru_id = m.profile_id AND b.ujian_id = m.ujian_id
                        AND lower(btrim(b.bab_id_text)) = lower(btrim(m.bab_id_text)))
   LIMIT 1;
  IF v_kosong IS NULL THEN
    RAISE EXCEPTION 'Tidak ada baris matriks kosong untuk kontrol positif';
  END IF;
  BEGIN
    DELETE FROM psat.psat_matrix_input WHERE id = v_kosong;
    RAISE EXCEPTION 'batalkan-hapus-kosong';
  EXCEPTION
    WHEN restrict_violation THEN
      RAISE EXCEPTION 'Bab KOSONG ikut ditolak — penjaganya terlalu rakus';
    WHEN raise_exception THEN
      IF SQLERRM <> 'batalkan-hapus-kosong' THEN RAISE; END IF;
  END;

  -- (c) PINDAH bab → soal harus ikut.
  -- Soalnya dilacak per ID, bukan dengan menghitung isi bab tujuan: bab tujuan
  -- bisa saja sudah berisi soal lain, dan gerbang yang cuma membandingkan
  -- jumlah akan lolos tanpa satu soal pun benar-benar berpindah.
  SELECT array_agg(b.id) INTO v_ids FROM psat.bank_soal b
   WHERE b.guru_id = v_baris.profile_id AND b.ujian_id = v_baris.ujian_id
     AND lower(btrim(b.bab_id_text)) = lower(btrim(v_baris.bab_id_text));

  BEGIN
    UPDATE psat.psat_matrix_input SET bab_id = v_bab_lain WHERE id = v_baris.id;
    SELECT count(*) INTO v_pindah FROM psat.bank_soal b
     WHERE b.id = ANY(v_ids) AND b.bab_id = v_bab_lain;
    RAISE EXCEPTION 'batalkan-pindah';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'batalkan-pindah' THEN RAISE; END IF;
  END;
  IF v_pindah <> v_soal THEN
    RAISE EXCEPTION 'Hanya % dari % soal ikut pindah', v_pindah, v_soal;
  END IF;

  -- (d) UPDATE yang tidak menyentuh bab_id → soal TIDAK boleh bergeser
  BEGIN
    UPDATE psat.psat_matrix_input SET updated_at = now() WHERE id = v_baris.id;
    SELECT count(*) INTO v_pindah FROM psat.bank_soal b
     WHERE b.guru_id = v_baris.profile_id AND b.ujian_id = v_baris.ujian_id
       AND lower(btrim(b.bab_id_text)) = lower(btrim(v_baris.bab_id_text));
    RAISE EXCEPTION 'batalkan-sentuh';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'batalkan-sentuh' THEN RAISE; END IF;
  END;
  IF v_pindah <> v_soal THEN
    RAISE EXCEPTION 'Update biasa ikut menggeser soal: % → %', v_soal, v_pindah;
  END IF;

  RAISE NOTICE 'Gerbang lolos: hapus-berisi ditolak, hapus-kosong boleh, pindah membawa % soal, update biasa tidak menggeser apa pun.', v_soal;
END
$gate$;

COMMIT;
