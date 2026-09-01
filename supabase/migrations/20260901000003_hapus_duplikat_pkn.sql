-- Migration: hapus "PKn" — duplikat Civics di psat.mata_pelajaran
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
-- Prasyarat: 20260901000002 sudah diapply.
--
-- LATAR
-- Setelah 20260901000002 setiap mapel LMS punya padanan PSAT, tapi PSAT masih
-- menyimpan baris yang tak punya padanan LMS. Salah satunya "PKn", yang
-- dikonfirmasi pemilik produk (1 Sep 2026) memang mata pelajaran yang sama
-- dengan "Civics".
--
-- BUKTI ITU DUPLIKAT, BUKAN MAPEL TERSENDIRI (diukur di produksi 1 Sep 2026):
--   psat.bank_soal            PKn 0    | Civics 140
--   psat.psat_guru_data       PKn 0    | —
--   psat.psat_matrix_input    PKn 0    | —
--   psat.psat_validator_mapel PKn 1    | Civics 1  → validator_id SAMA persis
--   psat.psat_patokan_soal    PKn 1    | Civics 1  → keluar/bank IDENTIK,
--                                        profile_id sama, dibuat berselang 2 detik
--   psat.bobot_config         PKn 12   | Civics 12 → 11 dari 12 baris identik
--
-- ⚠️ SATU BARIS BOBOT BERBEDA dan itu memang dibuang: essay/mudah bernilai 0.00
--    di PKn, 0.50 di Civics. Yang hidup adalah Civics — 140 soal menempel padanya
--    dan semua ujian menunjuk ke sana, sedangkan PKn nol soal dan tidak dirujuk
--    ujian mana pun. Jadi 0.00 itu nilai basi di salinan yang tidak terpakai,
--    bukan konfigurasi yang hilang. Dicatat di sini supaya tidak jadi kejutan
--    kalau nanti ada yang menelusuri.
--
-- YANG MASIH TERSISA SESUDAH INI (sengaja tidak disentuh)
--   psat "Indonesia" (0 soal) dan psat "Social" (0 soal) — bayangan yang id-nya
--   JUSTRU sama dengan id mapel LMS "Indonesia"/"Social", sementara aliasnya
--   sengaja diarahkan ke "Bahasa Indonesia"/"IPS" oleh 20260827000001. Karena
--   id-nya bertabrakan lintas schema, menghapusnya bisa mematahkan kode mana pun
--   yang mencari psat.mata_pelajaran memakai id mapel LMS. Butuh penelusuran
--   tersendiri; belum diputuskan.
--
-- ROLLBACK: supabase/rollback/20260901000003_hapus_duplikat_pkn_rollback.sql

BEGIN;

DO $kerja$
DECLARE
  v_pkn    uuid;
  v_civics uuid;
  n        int;
BEGIN
  SELECT id INTO v_pkn    FROM psat.mata_pelajaran WHERE nama = 'PKn';
  SELECT id INTO v_civics FROM psat.mata_pelajaran WHERE nama = 'Civics';

  IF v_pkn IS NULL THEN
    RAISE NOTICE 'PKn sudah tidak ada — tidak ada yang dikerjakan.';
    RETURN;
  END IF;
  IF v_civics IS NULL THEN
    RAISE EXCEPTION 'Civics tidak ditemukan; membatalkan agar PKn tidak dihapus tanpa penggantinya.';
  END IF;

  -- ── Penjaga: PKn harus benar-benar kosong ────────────────────────────────
  -- Kalau sejak audit ada guru yang mulai memakainya, menghapus berarti
  -- membuang soal orang. Lebih baik migrasi ini gagal keras.
  SELECT count(*) INTO n FROM psat.bank_soal WHERE mata_pelajaran_id = v_pkn;
  IF n > 0 THEN
    RAISE EXCEPTION 'PKn punya % soal — bukan lagi duplikat kosong. Gabungkan manual dulu.', n;
  END IF;

  SELECT count(*) INTO n FROM psat.psat_matrix_input WHERE mapel_id = v_pkn;
  IF n > 0 THEN
    RAISE EXCEPTION 'PKn dipakai % baris matriks guru.', n;
  END IF;

  SELECT count(*) INTO n FROM psat.psat_guru_data WHERE mapel_id = v_pkn;
  IF n > 0 THEN
    RAISE EXCEPTION 'PKn dipakai % baris penugasan guru.', n;
  END IF;

  SELECT count(*) INTO n FROM psat.mapel_alias WHERE psat_mapel_id = v_pkn;
  IF n > 0 THEN
    RAISE EXCEPTION 'PKn dirujuk % baris mapel_alias — ada mapel LMS yang mengambil soal dari sini.', n;
  END IF;

  -- ── Penjaga: tidak ada validator yang kehilangan tugasnya ────────────────
  -- Baris validator PKn dihapus, bukan dipindah, karena UNIQUE (validator_id,
  -- mapel_id) akan menolak pemindahan ke Civics bila orangnya sudah terdaftar
  -- di sana. Yang harus dipastikan: SETIAP validator PKn memang sudah jadi
  -- validator Civics, sehingga penghapusan tidak mencabut akses siapa pun.
  SELECT count(*) INTO n
  FROM psat.psat_validator_mapel v
  WHERE v.mapel_id = v_pkn
    AND NOT EXISTS (SELECT 1 FROM psat.psat_validator_mapel w
                    WHERE w.mapel_id = v_civics AND w.validator_id = v.validator_id);
  IF n > 0 THEN
    RAISE EXCEPTION
      '% validator PKn belum terdaftar di Civics — menghapus PKn akan mencabut tugas mereka. Daftarkan ke Civics dulu.', n;
  END IF;

  -- ── Hapus ────────────────────────────────────────────────────────────────
  DELETE FROM psat.psat_validator_mapel WHERE mapel_id = v_pkn;
  DELETE FROM psat.bobot_config         WHERE mapel_id = v_pkn;
  DELETE FROM psat.psat_patokan_soal    WHERE mapel_id = v_pkn;
  DELETE FROM psat.mata_pelajaran       WHERE id = v_pkn;

  RAISE NOTICE 'PKn dihapus; Civics tetap utuh.';
END
$kerja$;

-- =============================================================================
-- Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE n int; b int; s int;
BEGIN
  SELECT count(*) INTO n FROM psat.mata_pelajaran WHERE nama = 'PKn';
  IF n <> 0 THEN RAISE EXCEPTION 'PKn masih ada'; END IF;

  -- Civics harus tidak tersentuh sama sekali
  SELECT count(*) INTO s FROM psat.bank_soal
  WHERE mata_pelajaran_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Civics');
  IF s < 140 THEN RAISE EXCEPTION 'Soal Civics turun jadi % (harusnya >= 140)', s; END IF;

  SELECT count(*) INTO b FROM psat.bobot_config
  WHERE mapel_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Civics');
  IF b <> 12 THEN RAISE EXCEPTION 'Bobot Civics jadi % baris (harusnya 12)', b; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM psat.psat_validator_mapel
    WHERE mapel_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Civics'))
  THEN RAISE EXCEPTION 'Validator Civics ikut terhapus'; END IF;

  -- Setiap mapel LMS tetap punya alias (jaminan 20260901000002 tidak rusak)
  SELECT count(*) INTO n FROM public.mata_pelajaran mp
  LEFT JOIN psat.mapel_alias a ON a.public_mapel_id = mp.id
  WHERE a.public_mapel_id IS NULL;
  IF n > 0 THEN RAISE EXCEPTION '% mapel LMS kehilangan alias', n; END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- 1. Mapel PSAT tanpa padanan LMS tinggal Indonesia & Social:
--      SELECT sm.nama FROM psat.mata_pelajaran sm
--      WHERE NOT EXISTS (SELECT 1 FROM psat.mapel_alias a WHERE a.psat_mapel_id = sm.id)
--      ORDER BY sm.nama;
--
-- 2. Civics utuh:
--      SELECT count(*) FROM psat.bank_soal
--      WHERE mata_pelajaran_id = (SELECT id FROM psat.mata_pelajaran WHERE nama='Civics');
