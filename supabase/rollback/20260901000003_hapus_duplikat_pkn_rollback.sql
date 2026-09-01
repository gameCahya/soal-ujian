-- Rollback: 20260901000003_hapus_duplikat_pkn.sql
--
-- Mengembalikan baris "PKn" beserta seluruh turunannya, PERSIS seperti keadaan
-- produksi sebelum dihapus (1 Sep 2026) — termasuk id aslinya, supaya rujukan
-- lama yang mungkin tersimpan di luar basis data tetap cocok.
--
-- Nilai-nilai di bawah disalin dari produksi sebelum penghapusan, bukan
-- diturunkan dari Civics. Bedanya satu baris: bobot essay/mudah PKn adalah 0.00
-- sedangkan Civics 0.50. Kalau rollback ini menyalin dari Civics begitu saja,
-- keadaannya TIDAK kembali seperti semula — karena itu ditulis eksplisit.

BEGIN;

INSERT INTO psat.mata_pelajaran (id, nama, kode, deskripsi)
VALUES ('fbcd3c81-b2b3-4719-ad71-00fcdce71b40', 'PKn', NULL, NULL)
ON CONFLICT (id) DO NOTHING;

-- Bobot: 11 baris sama dengan Civics, satu (essay/mudah) sengaja 0.00
INSERT INTO psat.bobot_config (mapel_id, tipe, kesulitan, bobot)
SELECT 'fbcd3c81-b2b3-4719-ad71-00fcdce71b40', b.tipe, b.kesulitan,
       CASE WHEN b.tipe = 'essay' AND b.kesulitan = 'mudah' THEN 0.00 ELSE b.bobot END
FROM psat.bobot_config b
WHERE b.mapel_id = (SELECT id FROM psat.mata_pelajaran WHERE nama = 'Civics')
ON CONFLICT (mapel_id, tipe, kesulitan) DO NOTHING;

INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id)
VALUES ('885a13af-4687-40fe-92bc-d86545cf5385',
        'fbcd3c81-b2b3-4719-ad71-00fcdce71b40')
ON CONFLICT (validator_id, mapel_id) DO NOTHING;

INSERT INTO psat.psat_patokan_soal
  (id, profile_id, mapel_id, tipe, tingkat_kesulitan, keluar, bank)
VALUES (
  'a2409ae3-df60-488c-b6d9-5787d20e1630',
  '7d879630-aaa9-4224-8199-400ac01f9a1e',
  'fbcd3c81-b2b3-4719-ad71-00fcdce71b40',
  'pilgan,ceklist,isian_singkat,essay',
  'mudah,sedang,sulit',
  '5,9,6,4,3,3,0,10,0,0,3,2',
  '9,12,8,6,6,6,0,18,0,0,3,2')
ON CONFLICT (id) DO NOTHING;

DO $gate$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran WHERE nama = 'PKn') THEN
    RAISE EXCEPTION 'PKn tidak kembali';
  END IF;
  IF (SELECT count(*) FROM psat.bobot_config
      WHERE mapel_id = 'fbcd3c81-b2b3-4719-ad71-00fcdce71b40') <> 12 THEN
    RAISE EXCEPTION 'Bobot PKn tidak lengkap';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
