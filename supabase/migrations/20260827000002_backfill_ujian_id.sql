-- =============================================================================
-- PSAT: backfill ujian_id untuk data siklus 2025/2026
-- =============================================================================
-- Memetakan 1.523 soal, 66 baris matrix, dan 20 baris patokan ke 22 ujian
-- "PSAT <MAPEL> LEVEL <7|8> 2025/2026" yang sudah ada di LMS, supaya riwayat
-- siklus Juni 2026 tetap utuh setelah model berubah.
--
-- Sudah disimulasikan terhadap data produksi (read-only) sebelum ditulis:
--   22/22 ujian terpetakan, 1.523/1.523 soal cocok, 66/66 matrix cocok,
--   0 duplikat (profile, ujian, bab), 0 sel dengan keluar > bank.
--
-- Sumber kelas guru adalah psat.profiles_all, BUKAN psat.profiles.
-- psat.profiles adalah view yang menyaring lewat auth.uid()/auth.role(); migrasi
-- berjalan sebagai postgres tanpa JWT, jadi view itu mengembalikan nol baris.
-- Selain itu ke-22 penulis soal ada di psat.profiles_legacy, bukan public.profiles
-- — profiles_all menyatukan keduanya.
--
-- Jalankan SETELAH 20260827000001_ujian_scope.sql. Idempoten: aman diulang.
-- Terapkan ke database salinan lebih dulu.
-- =============================================================================

BEGIN;

-- =============================================================================
-- Peta (mapel psat × level) → ujian
-- =============================================================================
-- Level diambil dari nama ujian ("... LEVEL 8 ..."), yang terisi di semua 22
-- baris. psat.level_ujian() dipakai sebagai cadangan bila suatu saat ada ujian
-- PSAT tanpa pola itu di namanya.

CREATE TEMP TABLE _peta_ujian ON COMMIT DROP AS
SELECT
  ma.psat_mapel_id                                    AS psat_mapel_id,
  COALESCE(
    substring(u.nama FROM 'LEVEL[[:space:]]*([0-9])'),
    psat.level_ujian(u.id)
  )                                                   AS level,
  u.id                                                AS ujian_id,
  u.nama                                              AS ujian_nama
FROM public.ujian u
JOIN public.event_ujian ev ON ev.id = u.event_id
                          AND ev.tahun_ajaran = '2025/2026'
                          AND ev.semester = 2
JOIN psat.mapel_alias ma ON ma.public_mapel_id = u.mata_pelajaran_id
WHERE u.nama LIKE 'PSAT%';

-- Peta harus tunggal per (mapel, level), kalau tidak backfill jadi ambigu.
DO $$
DECLARE
  n_peta   INTEGER;
  n_kunci  INTEGER;
  n_kosong INTEGER;
BEGIN
  SELECT COUNT(*) INTO n_peta FROM _peta_ujian;
  SELECT COUNT(*) INTO n_kunci FROM (
    SELECT psat_mapel_id, level FROM _peta_ujian GROUP BY 1, 2
  ) t;
  SELECT COUNT(*) INTO n_kosong FROM _peta_ujian WHERE level IS NULL;

  IF n_kosong > 0 THEN
    RAISE EXCEPTION 'Backfill batal: % ujian PSAT tanpa level yang bisa diturunkan', n_kosong;
  END IF;
  IF n_peta <> n_kunci THEN
    RAISE EXCEPTION 'Backfill batal: peta (mapel, level) tidak tunggal — % baris untuk % kunci', n_peta, n_kunci;
  END IF;
  RAISE NOTICE 'Peta ujian siap: % ujian PSAT 2025/2026', n_peta;
END $$;

-- =============================================================================
-- 1. bank_soal.ujian_id
-- =============================================================================
-- Level soal diturunkan dari kelas penulisnya — satu-satunya penanda kelas yang
-- ada di model lama. Ini persis cacat yang perbaikan ini tutup, jadi backfill
-- membekukannya sekali di sini supaya tidak ikut berubah kalau guru pindah kelas.

UPDATE psat.bank_soal bs
SET ujian_id = p.ujian_id
FROM _peta_ujian p, psat.profiles_all pr
WHERE bs.ujian_id IS NULL
  AND pr.id = bs.guru_id
  AND p.psat_mapel_id = bs.mata_pelajaran_id
  AND p.level = substring(pr.kelas FROM '^[[:space:]]*([0-9])');

-- =============================================================================
-- 2. psat_matrix_input.ujian_id
-- =============================================================================

UPDATE psat.psat_matrix_input mi
SET ujian_id = p.ujian_id
FROM _peta_ujian p, psat.profiles_all pr
WHERE mi.ujian_id IS NULL
  AND pr.id = mi.profile_id
  AND p.psat_mapel_id = mi.mapel_id
  AND p.level = substring(pr.kelas FROM '^[[:space:]]*([0-9])');

-- =============================================================================
-- 3. psat_patokan_soal (CSV per mapel) → psat_patokan_ujian (baris per sel)
-- =============================================================================
-- Empat string ber-koma yang harus sejajar indeksnya diurai memakai urutan yang
-- sama seperti penulisnya: tipe di lingkar luar, kesulitan di lingkar dalam
-- (lihat handleSavePatokan di src/app/dashboard/patokan/page.tsx).
-- Patokan berlaku per mapel, jadi satu baris CSV menghasilkan dua ujian
-- (level 7 dan 8) dengan angka yang sama — memang begitu aturannya selama ini.

WITH src AS (
  SELECT
    ps.mapel_id,
    string_to_array(ps.tipe, ',')              AS tipes,
    string_to_array(ps.tingkat_kesulitan, ',') AS kesulitans,
    string_to_array(ps.keluar, ',')            AS keluars,
    string_to_array(COALESCE(ps.bank, ''), ',') AS banks
  FROM psat.psat_patokan_soal ps
),
sel AS (
  SELECT
    s.mapel_id,
    btrim(t.tipe)                                                     AS tipe,
    btrim(k.kes)                                                      AS tingkat_kesulitan,
    (t.ti - 1) * COALESCE(array_length(s.kesulitans, 1), 0) + k.ki    AS idx,
    s.keluars,
    s.banks
  FROM src s
  CROSS JOIN LATERAL unnest(s.tipes)      WITH ORDINALITY AS t(tipe, ti)
  CROSS JOIN LATERAL unnest(s.kesulitans) WITH ORDINALITY AS k(kes, ki)
)
INSERT INTO psat.psat_patokan_ujian (ujian_id, tipe, tingkat_kesulitan, jumlah_keluar, jumlah_bank)
SELECT
  p.ujian_id,
  sel.tipe,
  sel.tingkat_kesulitan,
  COALESCE(NULLIF(btrim(sel.keluars[sel.idx]), '')::INTEGER, 0),
  COALESCE(NULLIF(btrim(sel.banks[sel.idx]),   '')::INTEGER, 0)
FROM sel
JOIN _peta_ujian p ON p.psat_mapel_id = sel.mapel_id
WHERE sel.tipe IN ('pilgan', 'ceklist', 'isian_singkat', 'essay')
  AND sel.tingkat_kesulitan IN ('mudah', 'sedang', 'sulit')
ON CONFLICT (ujian_id, tipe, tingkat_kesulitan) DO NOTHING;

-- =============================================================================
-- 4. Assertion — batalkan seluruh transaksi kalau ada yang tertinggal
-- =============================================================================

DO $$
DECLARE
  soal_null   INTEGER;
  matrix_null INTEGER;
  ujian_tanpa_target INTEGER;
BEGIN
  SELECT COUNT(*) INTO soal_null   FROM psat.bank_soal        WHERE ujian_id IS NULL;
  SELECT COUNT(*) INTO matrix_null FROM psat.psat_matrix_input WHERE ujian_id IS NULL;

  IF soal_null > 0 THEN
    RAISE EXCEPTION 'Backfill batal: % soal masih tanpa ujian_id', soal_null;
  END IF;
  IF matrix_null > 0 THEN
    RAISE EXCEPTION 'Backfill batal: % baris matrix masih tanpa ujian_id', matrix_null;
  END IF;

  -- Ujian yang dipakai matrix tapi tidak punya target sama sekali menandakan
  -- patokan mapel-nya kosong. Bukan alasan membatalkan, tapi harus terlihat.
  SELECT COUNT(*) INTO ujian_tanpa_target
  FROM (SELECT DISTINCT ujian_id FROM psat.psat_matrix_input WHERE ujian_id IS NOT NULL) m
  WHERE NOT EXISTS (
    SELECT 1 FROM psat.psat_patokan_ujian pu WHERE pu.ujian_id = m.ujian_id
  );
  IF ujian_tanpa_target > 0 THEN
    RAISE WARNING 'Ada % ujian dengan matrix tapi tanpa baris target — periksa patokan mapelnya', ujian_tanpa_target;
  END IF;

  RAISE NOTICE 'Backfill selesai: semua soal & matrix punya ujian_id';
END $$;

-- psat_patokan_soal sengaja TIDAK di-DROP: dibiarkan sebagai arsip siklus lama.

COMMIT;
