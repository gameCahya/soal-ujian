-- Rollback: 20260901000002_lengkapi_mapel_alias.sql
--
-- Melepas alias yang dibuat migrasi itu, mengembalikan dua nama PSAT, dan
-- menghapus mapel PSAT yang lahir dari migrasi itu.
--
-- ⚠️ MENOLAK berjalan bila mapel yang akan dihapus sudah dipakai. Begitu ada
--    soal, matriks, atau bobot yang menempel padanya, menghapusnya berarti
--    kehilangan data — dan bagi guru yang sudah menulis soal Javanese di PSAT,
--    kehilangan itu tidak terlihat sampai raportnya kosong.

BEGIN;

DO $cek$
DECLARE n int; nm text;
BEGIN
  SELECT count(*), COALESCE(string_agg(sm.nama, ', '), '') INTO n, nm
  FROM psat.mata_pelajaran sm
  WHERE sm.deskripsi = 'Dibuat otomatis agar setiap mapel LMS punya padanan PSAT'
    AND (EXISTS (SELECT 1 FROM psat.bank_soal x        WHERE x.mata_pelajaran_id = sm.id)
      OR EXISTS (SELECT 1 FROM psat.psat_matrix_input x WHERE x.mapel_id = sm.id)
      OR EXISTS (SELECT 1 FROM psat.bobot_config x      WHERE x.mapel_id = sm.id)
      OR EXISTS (SELECT 1 FROM psat.psat_guru_data x    WHERE x.mapel_id = sm.id)
      OR EXISTS (SELECT 1 FROM psat.psat_validator_mapel x WHERE x.mapel_id = sm.id));

  IF n > 0 THEN
    RAISE EXCEPTION
      'Rollback dibatalkan: % mapel PSAT buatan migrasi ini sudah dipakai (%). Menghapusnya akan membuang soal/matriks/bobot yang menempel padanya.',
      n, nm;
  END IF;
END
$cek$;

-- 1. Alias yang ditambahkan migrasi itu (dikenali dari catatannya).
--    Dua sinonim tulisan tangan punya catatan berbeda, jadi tidak ikut terhapus.
DELETE FROM psat.mapel_alias
WHERE catatan LIKE 'nama sama di kedua schema:%';

-- 2. Mapel PSAT yang lahir dari migrasi itu (hari ini: Javanese).
DELETE FROM psat.mata_pelajaran
WHERE deskripsi = 'Dibuat otomatis agar setiap mapel LMS punya padanan PSAT';

-- 3. Nama kembali seperti semula.
UPDATE psat.mata_pelajaran SET nama = 'Math Cambridge'
WHERE nama = 'Mathematics Cambridge'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'Math Cambridge');

UPDATE psat.mata_pelajaran SET nama = 'IPA Cambridge'
WHERE nama = 'Science Cambridge'
  AND NOT EXISTS (SELECT 1 FROM psat.mata_pelajaran x WHERE x.nama = 'IPA Cambridge');

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Sesudah rollback, 4 mapel LMS kembali tanpa sumber PSAT dan impor untuk
-- keempatnya akan gagal lagi:
--   SELECT mp.nama FROM public.mata_pelajaran mp
--   LEFT JOIN psat.mapel_alias a ON a.public_mapel_id = mp.id
--   WHERE a.public_mapel_id IS NULL;
