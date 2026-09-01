-- Migration: satukan nama "Bahasa Indonesia" dan "Social" di kedua schema
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
-- Prasyarat: 20260901000002 dan 20260901000003 sudah diapply.
--
-- LATAR
-- Dua mata pelajaran masih bernama beda di LMS dan PSAT, disambung oleh sinonim
-- tulisan tangan di 20260827000001:
--     LMS "Indonesia" → PSAT "Bahasa Indonesia"  (140 soal ada di sisi PSAT)
--     LMS "Social"    → PSAT "IPS"               (140 soal ada di sisi PSAT)
-- Dan PSAT masih menyimpan DUA baris bayangan bernama "Indonesia" dan "Social"
-- yang nol soal — sisa pendataan ganda, sama seperti PKn.
--
-- Keputusan pemilik produk (1 Sep 2026): pakai "Bahasa Indonesia" dan "Social".
-- Jadi LMS mengikuti PSAT untuk yang pertama, PSAT mengikuti LMS untuk yang kedua.
--
-- URUTAN ITU MENGIKAT: bayangan "Social" harus lenyap SEBELUM "IPS" diganti nama
-- jadi "Social", kalau tidak akan ada dua baris bernama sama di psat.
--
-- ⚠️ TABRAKAN ID LINTAS SCHEMA — ini yang membuat pekerjaan ini perlu hati-hati.
--    psat "Indonesia" ber-id 754edf07…, dan id yang SAMA PERSIS dipakai
--    public.mata_pelajaran "Indonesia". Begitu juga psat "Social"
--    (aaaaaaaa-…-04). Menghitung rujukan lewat id saja MENYESATKAN: kueri audit
--    pertama saya melaporkan 24 psat_patokan_ujian untuk kedua bayangan itu,
--    padahal itu ujian LMS yang kebetulan ber-mata_pelajaran_id sama, bukan
--    rujukan ke baris psat-nya. Yang dihapus di bawah HANYA baris di schema
--    psat; public.mata_pelajaran tidak disentuh selain namanya.
--
-- BUKTI KEDUA BAYANGAN AMAN DIHAPUS (produksi, 1 Sep 2026):
--                        psat "Indonesia" | psat "Social" | pembandingnya
--   bank_soal                  0          |      0        | 140 di Bahasa Indonesia / IPS
--   psat_guru_data             0          |      0        | 2 masing-masing
--   psat_matrix_input          0          |      0        | 4 masing-masing
--   mapel_alias (dirujuk)      0          |      0        | 1 masing-masing
--   psat_validator_mapel       0          |      1        | validator_id SAMA dengan IPS
--
-- ⚠️ 20260901000002 memuat gerbang yang memeriksa sinonim lama LEWAT NAMA
--    ('Indonesia' → 'Bahasa Indonesia', 'Social' → 'IPS'). Sesudah migrasi ini,
--    menjalankan ULANG berkas itu akan GAGAL di gerbang tersebut — bukan karena
--    ada yang rusak, tapi karena namanya memang sudah berubah. Gerbang itu
--    pemeriksaan sesaat, bukan invarian abadi.
--
-- ROLLBACK: supabase/rollback/20260901000004_satukan_nama_indonesia_social_rollback.sql

BEGIN;

DO $kerja$
DECLARE
  v_bayangan uuid;
  v_asli     uuid;
  n          int;
  r          record;
BEGIN
  -- ── Hapus dua baris bayangan ─────────────────────────────────────────────
  FOR r IN
    SELECT * FROM (VALUES
      ('Indonesia', 'Bahasa Indonesia'),
      ('Social',    'IPS')
    ) AS t(bayangan, asli)
  LOOP
    SELECT id INTO v_bayangan FROM psat.mata_pelajaran WHERE nama = r.bayangan;
    SELECT id INTO v_asli     FROM psat.mata_pelajaran WHERE nama = r.asli;

    IF v_bayangan IS NULL THEN
      RAISE NOTICE 'psat "%" sudah tidak ada — dilewati.', r.bayangan;
      CONTINUE;
    END IF;
    IF v_asli IS NULL THEN
      RAISE EXCEPTION 'psat "%" tidak ditemukan; membatalkan agar "%" tidak dihapus tanpa penggantinya.',
        r.asli, r.bayangan;
    END IF;

    SELECT count(*) INTO n FROM psat.bank_soal WHERE mata_pelajaran_id = v_bayangan;
    IF n > 0 THEN
      RAISE EXCEPTION 'psat "%" punya % soal — bukan lagi bayangan kosong.', r.bayangan, n;
    END IF;

    SELECT count(*) INTO n FROM psat.psat_matrix_input WHERE mapel_id = v_bayangan;
    IF n > 0 THEN RAISE EXCEPTION 'psat "%" dipakai % baris matriks.', r.bayangan, n; END IF;

    SELECT count(*) INTO n FROM psat.psat_guru_data WHERE mapel_id = v_bayangan;
    IF n > 0 THEN RAISE EXCEPTION 'psat "%" dipakai % penugasan guru.', r.bayangan, n; END IF;

    SELECT count(*) INTO n FROM psat.mapel_alias WHERE psat_mapel_id = v_bayangan;
    IF n > 0 THEN
      RAISE EXCEPTION 'psat "%" dirujuk % alias — ada mapel LMS yang mengambil soal dari sini.',
        r.bayangan, n;
    END IF;

    -- Validator dihapus, bukan dipindah: UNIQUE (validator_id, mapel_id) akan
    -- menolak pemindahan bila orangnya sudah terdaftar di baris asli. Yang wajib
    -- dipastikan: tidak ada yang kehilangan tugasnya.
    SELECT count(*) INTO n
    FROM psat.psat_validator_mapel v
    WHERE v.mapel_id = v_bayangan
      AND NOT EXISTS (SELECT 1 FROM psat.psat_validator_mapel w
                      WHERE w.mapel_id = v_asli AND w.validator_id = v.validator_id);
    IF n > 0 THEN
      RAISE EXCEPTION
        '% validator psat "%" belum terdaftar di "%" — menghapus akan mencabut tugas mereka.',
        n, r.bayangan, r.asli;
    END IF;

    DELETE FROM psat.psat_validator_mapel WHERE mapel_id = v_bayangan;
    DELETE FROM psat.bobot_config         WHERE mapel_id = v_bayangan;
    DELETE FROM psat.psat_patokan_soal    WHERE mapel_id = v_bayangan;
    DELETE FROM psat.mata_pelajaran       WHERE id = v_bayangan;

    RAISE NOTICE 'psat "%" dihapus (bayangan dari "%").', r.bayangan, r.asli;
  END LOOP;
END
$kerja$;

-- ── Satukan namanya ────────────────────────────────────────────────────────
-- Baris alias menunjuk lewat id, jadi penggantian nama tidak memutus apa pun;
-- yang berubah hanya yang terbaca manusia.

UPDATE psat.mata_pelajaran SET nama = 'Social'
WHERE nama = 'IPS'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'Social');

UPDATE public.mata_pelajaran SET nama = 'Bahasa Indonesia'
WHERE nama = 'Indonesia'
  AND NOT EXISTS (SELECT 1 FROM public.mata_pelajaran x WHERE x.nama = 'Bahasa Indonesia');

-- Catatan alias ikut diperbarui supaya tidak menyesatkan pembaca berikutnya:
-- keduanya bukan lagi sinonim, melainkan nama yang sama.
UPDATE psat.mapel_alias a
SET catatan = format('nama sama di kedua schema: "%s"', mp.nama)
FROM public.mata_pelajaran mp, psat.mata_pelajaran sm
WHERE mp.id = a.public_mapel_id
  AND sm.id = a.psat_mapel_id
  AND a.catatan LIKE 'sinonim:%'
  AND lower(btrim(mp.nama)) = lower(btrim(sm.nama));

-- =============================================================================
-- Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE n int; sisa text;
BEGIN
  -- Nama lama harus benar-benar lenyap di kedua sisi
  IF EXISTS (SELECT 1 FROM psat.mata_pelajaran WHERE nama IN ('Indonesia', 'IPS')) THEN
    RAISE EXCEPTION 'Masih ada psat.mata_pelajaran bernama Indonesia atau IPS';
  END IF;
  IF EXISTS (SELECT 1 FROM public.mata_pelajaran WHERE nama = 'Indonesia') THEN
    RAISE EXCEPTION 'public.mata_pelajaran "Indonesia" belum berganti nama';
  END IF;

  -- Soalnya harus tetap menempel di baris yang benar — inti dari seluruh
  -- pekerjaan ini. Kalau alias tergeser ke bayangan, angkanya jadi 0.
  SELECT count(*) INTO n FROM psat.bank_soal
  WHERE mata_pelajaran_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Bahasa Indonesia');
  IF n < 140 THEN RAISE EXCEPTION 'Soal Bahasa Indonesia jadi % (harusnya >= 140)', n; END IF;

  SELECT count(*) INTO n FROM psat.bank_soal
  WHERE mata_pelajaran_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Social');
  IF n < 140 THEN RAISE EXCEPTION 'Soal Social jadi % (harusnya >= 140)', n; END IF;

  -- Setiap mapel LMS tetap punya alias, dan alias itu menunjuk baris senama
  SELECT count(*), COALESCE(string_agg(mp.nama, ', '), '') INTO n, sisa
  FROM public.mata_pelajaran mp
  LEFT JOIN psat.mapel_alias a ON a.public_mapel_id = mp.id
  WHERE a.public_mapel_id IS NULL;
  IF n > 0 THEN RAISE EXCEPTION '% mapel LMS tanpa alias: %', n, sisa; END IF;

  SELECT count(*), COALESCE(string_agg(mp.nama || ' → ' || sm.nama, ', '), '') INTO n, sisa
  FROM psat.mapel_alias a
  JOIN public.mata_pelajaran mp ON mp.id = a.public_mapel_id
  JOIN psat.mata_pelajaran sm   ON sm.id = a.psat_mapel_id
  WHERE lower(btrim(mp.nama)) <> lower(btrim(sm.nama));
  IF n > 0 THEN RAISE EXCEPTION 'Masih ada % alias yang namanya beda: %', n, sisa; END IF;

  -- Tidak ada baris PSAT yang tertinggal tanpa padanan LMS
  SELECT count(*), COALESCE(string_agg(sm.nama, ', '), '') INTO n, sisa
  FROM psat.mata_pelajaran sm
  WHERE NOT EXISTS (SELECT 1 FROM psat.mapel_alias a WHERE a.psat_mapel_id = sm.id);
  IF n > 0 THEN RAISE EXCEPTION '% mapel PSAT tanpa padanan LMS: %', n, sisa; END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- Daftar mapel kedua schema harus sama persis:
--   SELECT mp.nama AS lms, sm.nama AS psat, (mp.nama = sm.nama) AS sama,
--          (SELECT count(*) FROM psat.bank_soal b WHERE b.mata_pelajaran_id = sm.id) AS soal
--   FROM psat.mapel_alias a
--   JOIN public.mata_pelajaran mp ON mp.id = a.public_mapel_id
--   JOIN psat.mata_pelajaran sm   ON sm.id = a.psat_mapel_id
--   ORDER BY mp.nama;
