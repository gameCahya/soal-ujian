-- ROLLBACK untuk 20260831000001_penulis_bab_dan_jembatan_konfigurasi.sql
--
-- ⚠️ Cara apply: pnpm db:migrate supabase/rollback/20260831000001_*.sql
--
-- ⚠️ TIDAK mengembalikan isi public.ujian_konfigurasi_bab. Jembatan menulis
--    tabel itu dengan hapus-lalu-sisip, jadi konfigurasi yang ada SEBELUM
--    sinkronisasi pertama sudah tidak ada lagi. Kalau perlu dipulihkan, ambil
--    dari backup — bukan dari berkas ini.
--
-- Menyempitkan kembali CHECK tipe akan GAGAL bila sudah ada baris benar_salah.
-- Blok pemeriksa melaporkannya lebih dulu agar kegagalannya punya konteks.

BEGIN;

DO $cek$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM psat.psat_patokan_ujian WHERE tipe = 'benar_salah';
  IF n > 0 THEN
    RAISE EXCEPTION
      'Rollback ditolak: % baris patokan bertipe benar_salah. Hapus atau ubah dulu: DELETE FROM psat.psat_patokan_ujian WHERE tipe = ''benar_salah'';', n;
  END IF;
END
$cek$;

-- 6. get_tugas_menulis kembali tanpa filter penulis
CREATE OR REPLACE FUNCTION psat.get_tugas_menulis()
RETURNS TABLE (
  ujian_id UUID, ujian_nama TEXT, mapel_id UUID, psat_mapel_id UUID,
  mapel_nama TEXT, level TEXT, matrix_submitted BOOLEAN,
  total_soal BIGINT, target_bank BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = psat, public
AS $$
  WITH aktif AS (SELECT * FROM psat.get_ujian_aktif()),
  ampu AS (
    SELECT DISTINCT gm.mapel_id,
           substring(gm.kelas FROM '^[[:space:]]*([0-9])') AS level
    FROM public.guru_mengajar gm WHERE gm.guru_id = auth.uid()
  )
  SELECT a.ujian_id, a.ujian_nama, a.mapel_id, a.psat_mapel_id, a.mapel_nama, a.level,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
            WHERE mi.profile_id = auth.uid() AND mi.ujian_id = a.ujian_id AND mi.is_submitted),
    (SELECT COUNT(*) FROM psat.bank_soal bs
      WHERE bs.guru_id = auth.uid() AND bs.ujian_id = a.ujian_id),
    COALESCE((SELECT SUM(pu.jumlah_bank) FROM psat.psat_patokan_ujian pu
               WHERE pu.ujian_id = a.ujian_id), 0)
  FROM aktif a
  JOIN ampu am ON am.mapel_id = a.mapel_id AND am.level = a.level
  ORDER BY a.mapel_nama, a.level;
$$;

-- 5 & 4. Jembatan dan kosakata tipe
DROP FUNCTION IF EXISTS psat.get_calon_penulis(uuid);
DROP FUNCTION IF EXISTS psat.sinkron_konfigurasi_bab(uuid, uuid, boolean);
DROP FUNCTION IF EXISTS psat.tipe_ke_lms(text);

-- 3. Penulis ditunjuk
DROP TABLE IF EXISTS psat.psat_ujian_penulis;

-- 2. Identitas bab
DROP INDEX IF EXISTS psat.idx_matrix_bab;
ALTER TABLE psat.psat_matrix_input DROP COLUMN IF EXISTS bab_id;

-- 1. CHECK kembali ke 4 tipe
ALTER TABLE psat.psat_patokan_ujian
  DROP CONSTRAINT IF EXISTS psat_patokan_ujian_tipe_check;
ALTER TABLE psat.psat_patokan_ujian
  ADD CONSTRAINT psat_patokan_ujian_tipe_check
  CHECK (tipe IN ('pilgan', 'ceklist', 'isian_singkat', 'essay'));

COMMIT;

NOTIFY pgrst, 'reload schema';
