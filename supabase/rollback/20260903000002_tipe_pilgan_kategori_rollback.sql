-- ROLLBACK untuk 20260903000002_tipe_pilgan_kategori.sql
--
-- ⚠️ Menolak mundur kalau tipe barunya sudah dipakai — melepas CHECK saat sudah
-- ada barisnya akan meninggalkan data yang tak bisa dimasukkan lagi, dan
-- mengembalikan tipe_ke_lms berarti impor soal kategori mendarat di nama yang
-- ditolak LMS.

BEGIN;

DO $jaga$
DECLARE v_pagu int; v_soal int;
BEGIN
  SELECT count(*) INTO v_pagu FROM psat.psat_patokan_ujian WHERE tipe = 'pilgan_kategori';
  SELECT count(*) INTO v_soal FROM psat.bank_soal        WHERE tipe = 'pilgan_kategori';
  IF v_pagu > 0 OR v_soal > 0 THEN
    RAISE EXCEPTION
      'MENOLAK MUNDUR: % baris pagu dan % soal sudah bertipe pilgan_kategori. Hapus dulu atau batalkan rencana mundur.',
      v_pagu, v_soal;
  END IF;
END
$jaga$;

ALTER TABLE psat.psat_patokan_ujian DROP CONSTRAINT IF EXISTS psat_patokan_ujian_tipe_check;
ALTER TABLE psat.psat_patokan_ujian ADD CONSTRAINT psat_patokan_ujian_tipe_check
  CHECK (tipe = ANY (ARRAY['pilgan', 'ceklist', 'isian_singkat', 'essay', 'benar_salah']));

CREATE OR REPLACE FUNCTION psat.tipe_ke_lms(p_tipe text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE p_tipe
           WHEN 'pilgan' THEN 'pilihan_ganda'
           WHEN 'essay'  THEN 'esai'
           ELSE p_tipe
         END;
$function$;

COMMIT;
