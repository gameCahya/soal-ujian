-- Perbaikan data: 94 soal yang tak terlihat karena babnya tidak ada di matriks
--
-- MASALAHNYA, TERUKUR DI PRODUKSI 5 SEP 2026
-- Halaman Soal membangun akordeon dari psat_matrix_input dan mencocokkan soal
-- lewat NAMA bab (soal/page.tsx:266,283). Soal yang nama babnya tidak ada di
-- matriks tidak masuk grup mana pun — tidak ada keranjang "lain-lain", jadi
-- soalnya lenyap dari layar penulisnya meski barisnya utuh.
--
-- Dua guru terkena, keduanya lewat jalur yang sama: bab BARU dibuat, lalu
-- baris matriks dipindah ke sana (matrix/page.tsx:365 `handleRenameBab` —
-- namanya "rename" tapi yang dilakukannya memindahkan baris matriks ke bab
-- lain, dan ia tidak pernah menyentuh psat.bank_soal).
--
--   Isnaini Umi Nurhasanah, PTS 1 English LEVEL 7
--     bab "Food and Drink" dibuat 3 Sep 03:40, 24 soal ditulis 4-5 Sep,
--     bab "Chapter 2: Food and Drink" dibuat 5 Sep 03:24, matriks pindah 03:29
--   Muhammad Taufiqqulhidayat Nur Waarits, PTS 1 IFE LEVEL 8
--     70 soal di "Bab 6"/"Bab 8" (2-3 Sep), bab "bab 1"/"bab 2" dibuat
--     4 Sep 05:29, matriks pindah 05:33
--
-- DASAR PEMETAANNYA — bukan tebakan berdasarkan urutan
-- Target matriks tujuan cocok PERSIS dengan sebaran soal yang sudah ditulis,
-- termasuk di sel yang membedakan kedua bab satu sama lain:
--     "Bab 6" pilgan mudah 5, esai sedang 1  →  target "bab 1"  = 5 dan 1
--     "Bab 8" pilgan mudah 4, esai sedang 2  →  target "bab 2"  = 4 dan 2
--     Isnaini pilgan mudah 5                 →  "Chapter 2"     = 5 (Chapter 1 = 4)
-- Untuk Isnaini namanya pun sejalan. Dua isyarat bebas menunjuk arah sama.
--
-- YANG SENGAJA TIDAK DISENTUH: 57 soal yatim di siklus 2025/2026. Semuanya
-- ICT Non Progul milik akun warisan @psat.com yang sudah tidak punya profil,
-- status approved, siklusnya selesai — tidak ada guru yang menunggunya.
--
-- Hanya bab_id yang ditulis; bab_id_text menyusul sendiri lewat trigger
-- psat_bank_soal_cermin_bab.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260905000002_pindahkan_soal_bab_yatim_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Pemetaan, ditulis sekali dan dipakai ulang oleh gerbang
-- =============================================================================
CREATE TEMP TABLE _peta (guru_id uuid, ujian_id uuid, bab_lama text, bab_baru uuid, harap int) ON COMMIT DROP;
INSERT INTO _peta VALUES
  ('1bccbb8c-3e67-4051-8e73-def2bad10ab2','70de5dba-30fb-420b-858f-50de1677dd21','Food and Drink','7e96bcd9-341e-481e-9b96-4c4ecbbadf40',24),
  ('988247fb-4595-486a-b2cc-2a1587ae8ff9','282b182b-9786-4c50-8c80-e54f38a258c7','Bab 6','43553add-b1e1-49f9-afee-22093efc9861',35),
  ('988247fb-4595-486a-b2cc-2a1587ae8ff9','282b182b-9786-4c50-8c80-e54f38a258c7','Bab 8','90c186ea-b6e7-4519-a564-242386448ae9',35);

-- =============================================================================
-- 2. Cadangan permanen — supaya rollback bisa mengembalikan NILAI ASLI
-- =============================================================================
-- 11 dari 24 soal Isnaini punya bab_id NULL. Rollback yang memetakan balik
-- lewat nama akan mengisi NULL itu dengan sebuah uuid — mirip, tapi bukan
-- keadaan semula. Karena itu potretnya disimpan, bukan direkonstruksi.
CREATE TABLE IF NOT EXISTS psat.backup_bab_yatim_20260905 (
  soal_id uuid PRIMARY KEY,
  bab_id_lama uuid,
  bab_id_text_lama text,
  dicatat_pada timestamptz NOT NULL DEFAULT now()
);

INSERT INTO psat.backup_bab_yatim_20260905 (soal_id, bab_id_lama, bab_id_text_lama)
SELECT b.id, b.bab_id, b.bab_id_text
FROM psat.bank_soal b
JOIN _peta p ON p.guru_id = b.guru_id AND p.ujian_id = b.ujian_id
            AND lower(btrim(b.bab_id_text)) = lower(btrim(p.bab_lama))
ON CONFLICT (soal_id) DO NOTHING;

DO $pra$
DECLARE v_cadangan int; v_harap int;
BEGIN
  SELECT count(*) INTO v_cadangan FROM psat.backup_bab_yatim_20260905;
  SELECT sum(harap) INTO v_harap FROM _peta;
  IF v_cadangan <> v_harap THEN
    RAISE EXCEPTION 'Cadangan % baris, diharapkan % — keadaan bergeser sejak berkas ditulis, periksa dulu', v_cadangan, v_harap;
  END IF;
END
$pra$;

-- =============================================================================
-- 3. Pindahkan
-- =============================================================================
UPDATE psat.bank_soal b
   SET bab_id = p.bab_baru
  FROM _peta p
 WHERE p.guru_id = b.guru_id
   AND p.ujian_id = b.ujian_id
   AND lower(btrim(b.bab_id_text)) = lower(btrim(p.bab_lama));

-- =============================================================================
-- 4. Gerbang
-- =============================================================================
DO $gate$
DECLARE
  v_yatim_aktif int; v_salah_nama int; v_tersentuh int; v_r record;
BEGIN
  -- (a) tiap kelompok mendarat utuh di bab tujuan
  FOR v_r IN SELECT * FROM _peta LOOP
    SELECT count(*) INTO v_tersentuh
      FROM psat.bank_soal b
     WHERE b.guru_id = v_r.guru_id AND b.ujian_id = v_r.ujian_id AND b.bab_id = v_r.bab_baru;
    IF v_tersentuh < v_r.harap THEN
      RAISE EXCEPTION 'Bab tujuan % hanya berisi % soal, diharapkan minimal %', v_r.bab_baru, v_tersentuh, v_r.harap;
    END IF;
  END LOOP;

  -- (b) cermin nama ikut terbarui — trigger benar-benar bekerja
  SELECT count(*) INTO v_salah_nama
    FROM psat.bank_soal b
    JOIN psat.backup_bab_yatim_20260905 c ON c.soal_id = b.id
    JOIN public.bab_pelajaran bp ON bp.id = b.bab_id
   WHERE lower(btrim(b.bab_id_text)) IS DISTINCT FROM lower(btrim(bp.nama_bab));
  IF v_salah_nama <> 0 THEN
    RAISE EXCEPTION '% soal namanya tidak mencerminkan babnya', v_salah_nama;
  END IF;

  -- (c) inti perbaikannya: tidak ada lagi soal siklus aktif yang babnya di luar
  --     matriks penulisnya. Ini yang membuat soal terlihat lagi.
  SELECT count(*) INTO v_yatim_aktif
    FROM psat.bank_soal b
    JOIN public.ujian u ON u.id = b.ujian_id
    JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
   WHERE NOT EXISTS (
     SELECT 1 FROM psat.psat_matrix_input m
      WHERE m.ujian_id = b.ujian_id AND m.profile_id = b.guru_id
        AND lower(btrim(m.bab_id_text)) = lower(btrim(b.bab_id_text)));
  IF v_yatim_aktif <> 0 THEN
    RAISE EXCEPTION 'Masih ada % soal yatim di siklus aktif', v_yatim_aktif;
  END IF;

  -- (d) tidak ada yang lain ikut bergeser
  SELECT count(*) INTO v_tersentuh
    FROM psat.bank_soal b
    LEFT JOIN psat.backup_bab_yatim_20260905 c ON c.soal_id = b.id
   WHERE c.soal_id IS NULL
     AND b.bab_id IN (SELECT bab_baru FROM _peta)
     AND b.updated_at > now() - interval '1 minute';
  IF v_tersentuh <> 0 THEN
    RAISE EXCEPTION '% soal di luar daftar ikut tersentuh', v_tersentuh;
  END IF;

  -- (e) MENDARAT DI BAB YANG BENAR, bukan sekadar di suatu bab.
  -- Gerbang (a) hanya menghitung, jadi pemetaan yang TERTUKAR akan lolos
  -- begitu saja: "Bab 6" dan "Bab 8" sama-sama 35 soal. Yang membedakan
  -- keduanya adalah sebarannya, dan itu pula dasar pemetaan berkas ini —
  -- maka itu yang harus diassersi. Sel yang belum ditulis gurunya (Isnaini
  -- baru 24 dari 35) tidak ikut dibandingkan; yang sudah ditulis harus sama
  -- persis dengan target bab tujuannya.
  FOR v_r IN SELECT * FROM _peta LOOP
    SELECT count(*) INTO v_tersentuh
      FROM (
        SELECT b.tipe, b.tingkat_kesulitan, count(*) AS ada
          FROM psat.bank_soal b
          JOIN psat.backup_bab_yatim_20260905 c ON c.soal_id = b.id
         WHERE b.bab_id = v_r.bab_baru
         GROUP BY 1, 2
      ) s
      JOIN psat.psat_matrix_input m
        ON m.profile_id = v_r.guru_id AND m.ujian_id = v_r.ujian_id AND m.bab_id = v_r.bab_baru
     WHERE (m.data ->> (s.tipe || '_' || s.tingkat_kesulitan || '_bank'))::int IS DISTINCT FROM s.ada::int;
    IF v_tersentuh <> 0 THEN
      RAISE EXCEPTION 'Bab tujuan % tidak cocok sebarannya di % sel — pemetaan kemungkinan tertukar', v_r.bab_baru, v_tersentuh;
    END IF;
  END LOOP;

  RAISE NOTICE 'Gerbang lolos: 94 soal pindah, sebaran cocok dengan target matriks, nol yatim tersisa di siklus aktif.';
END
$gate$;

COMMIT;
