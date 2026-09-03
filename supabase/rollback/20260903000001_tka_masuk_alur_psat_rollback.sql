-- ROLLBACK untuk 20260903000001_tka_masuk_alur_psat.sql
--
-- Mengembalikan psat.get_ujian_aktif() ke definisi sebelum 3 Sep 2026: saringan
-- `tipe_ujian.soal_oleh = 'super_admin'`, tanpa memanggil fungsi milik LMS.
--
-- ⚠️ APA YANG HILANG
-- TKA lintas sekolah kembali tidak terlihat di halaman Patokan, pagunya tak bisa
-- ditetapkan, penulisnya tak bisa ditunjuk, dan gurunya tak melihat tugasnya.
-- Pagu/penulis/matriks yang TERLANJUR dibuat tidak dihapus — barisnya tetap ada,
-- hanya tidak terjangkau lagi dari layar. Kalau nanti dimajukan lagi, semuanya
-- muncul kembali utuh.
--
-- URUTAN: jalankan ini LEBIH DULU sebelum memundurkan lms-new 20260903a.
-- Terbalik = fungsi ini memanggil public.ujian_alur_psat_terpusat() yang sudah
-- dihapus, dan SELURUH alur PSAT mati — termasuk UTS.

BEGIN;

CREATE OR REPLACE FUNCTION psat.get_ujian_aktif()
RETURNS TABLE(
  ujian_id uuid, ujian_nama text, mapel_id uuid, psat_mapel_id uuid,
  mapel_nama text, level text, kelas_list text[],
  event_nama text, tahun_ajaran text, semester integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'psat', 'public'
AS $function$
  SELECT
    u.id,
    u.nama,
    u.mata_pelajaran_id,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ARRAY(
      SELECT uk.kelas FROM public.ujian_kelas uk
      WHERE uk.ujian_id = u.id ORDER BY uk.kelas
    ),
    ev.nama,
    ev.tahun_ajaran,
    ev.semester
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  JOIN public.tipe_ujian  tu ON tu.kode = u.tipe_ujian AND tu.soal_oleh = 'super_admin'
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  ORDER BY mp.nama, psat.level_ujian(u.id);
$function$;

COMMENT ON FUNCTION psat.get_ujian_aktif() IS
  'Ujian pada siklus aktif yang soalnya ditentukan super admin.';

-- Gerbang mundur: UTS/UAS wajib tetap utuh sesudah dimundurkan.
DO $gate$
DECLARE v_hilang int;
BEGIN
  SELECT count(*) INTO v_hilang
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  WHERE u.tipe_ujian IN ('UTS', 'UAS')
    AND NOT EXISTS (SELECT 1 FROM psat.get_ujian_aktif() g WHERE g.ujian_id = u.id);
  IF v_hilang > 0 THEN
    RAISE EXCEPTION 'ROLLBACK MERUSAK: % ujian UTS/UAS hilang', v_hilang;
  END IF;
END
$gate$;

COMMIT;
