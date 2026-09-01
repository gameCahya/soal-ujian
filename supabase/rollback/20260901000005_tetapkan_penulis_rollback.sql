-- Rollback: 20260901000005_tetapkan_penulis_sekalian_izinnya.sql
--
-- ⚠️ Jalankan rollback 20260901000006 (trigger) LEBIH DULU bila ikut dibatalkan.
--
-- Mengembalikan get_calon_penulis ke bentuk 4 kolom dan melepas kedua RPC.
-- Sesudah ini halaman Patokan versi baru akan GAGAL memanggil tetapkan_penulis —
-- kembalikan juga commit kodenya (soal-ujian bf233cb), atau penunjukan tidak
-- bisa dilakukan sama sekali dari layar.
--
-- Izin yang sudah menyala TIDAK dicabut: mencabutnya mematikan tugas penulis
-- yang sedang bekerja.

BEGIN;

DROP FUNCTION IF EXISTS psat.tetapkan_penulis(uuid, uuid);
DROP FUNCTION IF EXISTS psat.hapus_penulis(uuid);

-- Tipe kembalian menyusut, jadi harus DROP dulu.
DROP FUNCTION IF EXISTS psat.get_calon_penulis(uuid);

CREATE OR REPLACE FUNCTION psat.get_calon_penulis(p_ujian_id UUID)
RETURNS TABLE (profile_id UUID, nama TEXT, sudah_isi BOOLEAN, ditunjuk BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $calon$
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  )
  SELECT DISTINCT
    gm.guru_id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = gm.guru_id),
    EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pen
             WHERE pen.ujian_id = p_ujian_id AND pen.profile_id = gm.guru_id)
  FROM a
  JOIN public.guru_mengajar gm
    ON gm.mapel_id = a.mapel_id
   AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
  JOIN public.profiles pr ON pr.id = gm.guru_id
  ORDER BY pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
