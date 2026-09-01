-- Migration: setiap mata pelajaran LMS punya padanan di PSAT
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
--
-- LATAR
-- psat.mapel_alias memetakan public.mata_pelajaran → psat.mata_pelajaran, dan
-- impor_soal_psat memakainya sebagai sumber (p_psat_mapel_id). Baris alias hanya
-- pernah dibuat untuk mapel yang id-nya KEBETULAN sama di kedua schema, plus dua
-- sinonim yang ditulis tangan (Indonesia→Bahasa Indonesia, Social→IPS).
-- Akibatnya 4 dari 18 mapel LMS tidak punya sumber sama sekali:
--
--   LMS                      PSAT                        soal  keadaan
--   English Cambridge        English Cambridge (id beda)    0   ada, tak teralias
--   Mathematics Cambridge    "Math Cambridge"               0   ada, nama beda
--   Science Cambridge        "IPA Cambridge"                0   ada, nama beda
--   Javanese                 —                              —   tidak ada
--
-- Ketiga mapel Cambridge di PSAT BUKAN baris kosong: masing-masing sudah punya
-- 1 validator, 12 baris bobot_config, dan 1 patokan lama. Jadi yang benar adalah
-- MENAUTKAN yang sudah ada, bukan membuat duplikat.
--
-- KEPUTUSAN PEMILIK PRODUK (1 Sep 2026): "semua mapel psat dan lms sama".
-- Dua PSAT diganti namanya agar sama persis dengan LMS. Aman dilakukan sekarang
-- justru karena ketiganya masih 0 soal — tidak ada guru yang sudah terbiasa
-- dengan nama lamanya, dan semua rujukan memakai id, bukan nama.
--
-- YANG SENGAJA TIDAK DISENTUH
-- psat.mata_pelajaran masih menyimpan tiga baris tanpa padanan LMS:
--   PKn (0 soal, 1 validator)       — duplikat lama dari Civics
--   Indonesia (0 soal)              — id-nya justru dipakai LMS "Indonesia",
--                                     yang aliasnya sengaja diarahkan ke
--                                     "Bahasa Indonesia" oleh 20260827000001
--   Social (0 soal, 1 validator)    — sama, diarahkan ke "IPS"
-- Ketiganya masih dirujuk bobot_config/validator, jadi menghapusnya bukan
-- pekerjaan sepele dan tidak dibutuhkan untuk impor. Dibiarkan; kalau nanti mau
-- dibersihkan, itu keputusan tersendiri.
--
-- ROLLBACK: supabase/rollback/20260901000002_lengkapi_mapel_alias_rollback.sql
-- Cara apply: Management API / pnpm db:migrate berkas ini SAJA.

BEGIN;

-- =============================================================================
-- 1. Samakan nama yang cuma beda sebutan
-- =============================================================================
-- Dijaga NOT EXISTS supaya migrasi ini aman dijalankan dua kali dan tidak
-- menabrak nama yang mungkin sudah ada.

UPDATE psat.mata_pelajaran SET nama = 'Mathematics Cambridge'
WHERE nama = 'Math Cambridge'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'Mathematics Cambridge');

UPDATE psat.mata_pelajaran SET nama = 'Science Cambridge'
WHERE nama = 'IPA Cambridge'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'Science Cambridge');

-- =============================================================================
-- 2. Mapel LMS yang belum punya padanan sama sekali
-- =============================================================================
-- Hanya Javanese hari ini, tapi ditulis sebagai kueri umum supaya mapel LMS baru
-- yang ditambahkan nanti ikut terbuat padanannya saat migrasi ini dijalankan
-- ulang — bukan daftar tangan yang langsung basi.

INSERT INTO psat.mata_pelajaran (nama, kode, deskripsi)
SELECT mp.nama, mp.kode, 'Dibuat otomatis agar setiap mapel LMS punya padanan PSAT'
FROM public.mata_pelajaran mp
WHERE NOT EXISTS (
        SELECT 1 FROM psat.mata_pelajaran sm
        WHERE lower(btrim(sm.nama)) = lower(btrim(mp.nama)))
  AND NOT EXISTS (
        SELECT 1 FROM psat.mapel_alias a WHERE a.public_mapel_id = mp.id);

-- =============================================================================
-- 3. Alias untuk setiap mapel LMS yang belum punya
-- =============================================================================
-- Dicocokkan lewat NAMA, bukan id — justru karena id-nya memang berbeda; itulah
-- sebabnya baris identitas di 20260827000001 melewatkan keempatnya.
-- Mapel yang SUDAH punya alias tidak diusik: dua sinonim yang ditulis tangan
-- (Indonesia→Bahasa Indonesia, Social→IPS) harus tetap seperti apa adanya,
-- padahal nama LMS-nya juga cocok dengan baris PSAT lain yang bernama sama.

INSERT INTO psat.mapel_alias (public_mapel_id, psat_mapel_id, catatan)
SELECT mp.id, sm.id, format('nama sama di kedua schema: "%s"', mp.nama)
FROM public.mata_pelajaran mp
JOIN psat.mata_pelajaran sm
  ON lower(btrim(sm.nama)) = lower(btrim(mp.nama))
WHERE NOT EXISTS (SELECT 1 FROM psat.mapel_alias a WHERE a.public_mapel_id = mp.id)
ON CONFLICT (public_mapel_id) DO NOTHING;

-- =============================================================================
-- 4. Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE n int; sisa text;
BEGIN
  SELECT count(*), COALESCE(string_agg(mp.nama, ', '), '')
    INTO n, sisa
  FROM public.mata_pelajaran mp
  LEFT JOIN psat.mapel_alias a ON a.public_mapel_id = mp.id
  WHERE a.public_mapel_id IS NULL;

  IF n > 0 THEN
    RAISE EXCEPTION 'Masih ada % mapel LMS tanpa alias PSAT: %', n, sisa;
  END IF;

  -- Alias tidak boleh menunjuk baris PSAT yang tidak ada (FK sudah menjamin,
  -- tapi assertion ini yang akan bicara kalau FK-nya nanti dilepas).
  SELECT count(*) INTO n
  FROM psat.mapel_alias a
  LEFT JOIN psat.mata_pelajaran sm ON sm.id = a.psat_mapel_id
  WHERE sm.id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION '% alias menunjuk mapel PSAT yang tidak ada', n;
  END IF;

  -- Dua sinonim lama harus SELAMAT. Kalau bagian 3 sampai menimpanya, impor
  -- Bahasa Indonesia dan IPS akan menarik dari mapel kosong.
  IF NOT EXISTS (
    SELECT 1 FROM psat.mapel_alias a
    JOIN public.mata_pelajaran mp ON mp.id = a.public_mapel_id
    JOIN psat.mata_pelajaran sm   ON sm.id = a.psat_mapel_id
    WHERE mp.nama = 'Indonesia' AND sm.nama = 'Bahasa Indonesia')
  THEN
    RAISE EXCEPTION 'Sinonim Indonesia → Bahasa Indonesia hilang';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM psat.mapel_alias a
    JOIN public.mata_pelajaran mp ON mp.id = a.public_mapel_id
    JOIN psat.mata_pelajaran sm   ON sm.id = a.psat_mapel_id
    WHERE mp.nama = 'Social' AND sm.nama = 'IPS')
  THEN
    RAISE EXCEPTION 'Sinonim Social → IPS hilang';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- 1. Nol mapel LMS tanpa alias:
--      SELECT count(*) FROM public.mata_pelajaran mp
--      LEFT JOIN psat.mapel_alias a ON a.public_mapel_id = mp.id
--      WHERE a.public_mapel_id IS NULL;                       -- harap 0
--
-- 2. Keempat mapel yang tadinya kosong kini menunjuk baris PSAT yang BENAR —
--    yang sudah punya validator/bobot, bukan duplikat baru:
--      SELECT mp.nama, sm.nama,
--             (SELECT count(*) FROM psat.psat_validator_mapel v WHERE v.mapel_id = sm.id) AS validator
--      FROM psat.mapel_alias a
--      JOIN public.mata_pelajaran mp ON mp.id = a.public_mapel_id
--      JOIN psat.mata_pelajaran sm   ON sm.id = a.psat_mapel_id
--      WHERE mp.nama IN ('English Cambridge','Mathematics Cambridge','Science Cambridge','Javanese');
--
-- 3. Tidak ada duplikat nama di psat.mata_pelajaran:
--      SELECT lower(btrim(nama)), count(*) FROM psat.mata_pelajaran
--      GROUP BY 1 HAVING count(*) > 1;                        -- harap kosong
