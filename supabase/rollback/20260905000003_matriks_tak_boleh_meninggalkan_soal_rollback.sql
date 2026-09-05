-- ROLLBACK untuk 20260905000003_matriks_tak_boleh_meninggalkan_soal.sql
--
-- ⚠️ Sesudah ini baris matriks boleh lagi ditinggalkan soalnya: memindahkan
-- bab tidak membawa soal, dan menghapus bab berisi soal tidak ditolak. Itu
-- persis keadaan yang membuat 94 soal lenyap dari layar penulisnya, 5 Sep 2026.

BEGIN;

DROP TRIGGER IF EXISTS trg_matriks_pindah_bawa_soal   ON psat.psat_matrix_input;
DROP TRIGGER IF EXISTS trg_matriks_tolak_hapus_berisi ON psat.psat_matrix_input;

DROP FUNCTION IF EXISTS psat.matriks_pindah_bawa_soal();
DROP FUNCTION IF EXISTS psat.matriks_tolak_hapus_berisi();

COMMIT;
