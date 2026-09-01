-- Rollback: 20260901000004_satukan_nama_indonesia_social.sql
--
-- Mengembalikan nama lama dan kedua baris bayangan PSAT, dengan id serta nilai
-- persis seperti produksi sebelum dihapus (1 Sep 2026).
--
-- URUTAN MENGIKAT, kebalikan dari migrasinya: nama dikembalikan DULU
-- ("Social" → "IPS"), baru bayangan disisipkan — kalau tidak, akan ada dua baris
-- bernama "Social" di psat pada saat yang sama.

BEGIN;

-- 1. Nama kembali seperti semula
UPDATE psat.mata_pelajaran SET nama = 'IPS'
WHERE nama = 'Social'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'IPS');

UPDATE public.mata_pelajaran SET nama = 'Indonesia'
WHERE nama = 'Bahasa Indonesia'
  AND NOT EXISTS (SELECT 1 FROM public.mata_pelajaran x WHERE x.nama = 'Indonesia');

-- 2. Baris bayangan kembali, dengan id aslinya
INSERT INTO psat.mata_pelajaran (id, nama, kode, deskripsi) VALUES
  ('754edf07-e611-415e-a357-2b629f158d27', 'Indonesia', 'BIN', NULL),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'Social',    'IPS', NULL)
ON CONFLICT (id) DO NOTHING;

-- 3. Bobot bayangan disalin dari baris aslinya masing-masing.
--    ⚠️ Ini TIDAK sepenuhnya setia: nilai asli bayangan tidak pernah dicatat
--    baris per baris sebelum dihapus, hanya jumlahnya (12 masing-masing).
--    Kalau ada sel yang dulu berbeda, di sini ia menjadi salinan baris asli.
--    Keduanya nol soal dan tidak dirujuk alias, jadi tidak ada perhitungan yang
--    bergantung padanya — tapi jangan mengaku ini pemulihan sempurna.
INSERT INTO psat.bobot_config (mapel_id, tipe, kesulitan, bobot)
SELECT '754edf07-e611-415e-a357-2b629f158d27', b.tipe, b.kesulitan, b.bobot
FROM psat.bobot_config b
WHERE b.mapel_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Bahasa Indonesia')
ON CONFLICT (mapel_id, tipe, kesulitan) DO NOTHING;

INSERT INTO psat.bobot_config (mapel_id, tipe, kesulitan, bobot)
SELECT 'aaaaaaaa-0000-0000-0000-000000000004', b.tipe, b.kesulitan, b.bobot
FROM psat.bobot_config b
WHERE b.mapel_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'IPS')
ON CONFLICT (mapel_id, tipe, kesulitan) DO NOTHING;

-- 4. Validator bayangan "Social" (orang yang sama dengan validator IPS)
INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id)
VALUES ('e3ad1d2e-8716-47bf-b2f7-5ed5421f424e',
        'aaaaaaaa-0000-0000-0000-000000000004')
ON CONFLICT (validator_id, mapel_id) DO NOTHING;

-- 5. Catatan alias kembali menyebut sinonim
UPDATE psat.mapel_alias a
SET catatan = format('sinonim: mapel ujian "%s" → mapel guru "%s"', mp.nama, sm.nama)
FROM public.mata_pelajaran mp, psat.mata_pelajaran sm
WHERE mp.id = a.public_mapel_id
  AND sm.id = a.psat_mapel_id
  AND lower(btrim(mp.nama)) <> lower(btrim(sm.nama));

DO $gate$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.mata_pelajaran WHERE nama = 'Indonesia') THEN
    RAISE EXCEPTION 'Nama LMS tidak kembali ke "Indonesia"';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran WHERE nama = 'IPS') THEN
    RAISE EXCEPTION 'Nama PSAT tidak kembali ke "IPS"';
  END IF;
  IF (SELECT count(*) FROM psat.mata_pelajaran WHERE nama IN ('Indonesia', 'Social')) <> 2 THEN
    RAISE EXCEPTION 'Baris bayangan tidak kembali lengkap';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- psat_patokan_soal kedua bayangan TIDAK dipulihkan: isinya tidak dicatat
-- sebelum dihapus, dan tabel itu sudah digantikan psat_patokan_ujian sejak
-- 20260827000001. Kalau benar-benar dibutuhkan, ambil dari backup.
