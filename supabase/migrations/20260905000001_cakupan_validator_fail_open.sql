-- Migration: cakupan mapel kosong berarti SEMUA mapel, bukan nol
--
-- MASALAHNYA, TERUKUR DI PRODUKSI 5 SEP 2026
-- psat.psat_validator_mapel nol baris, dan satu-satunya validator
-- (Ahmad Sulaeman) karenanya melihat antrean kosong padahal ada 420 soal
-- menunggu di 6 mapel. Ini kedua kalinya cakupan yang kosong melumpuhkan
-- validasi tanpa gejala: pertama karena 13 penugasan menunjuk akun @psat.com
-- warisan (20260904000002), kedua karena pembersihan itu menyisakan tabel
-- kosong dan tidak ada yang mengisinya kembali.
--
-- ARAH GAGALNYA DIBALIK
-- Sebelum : validator tanpa cakupan → 0 mapel   (lupa mencentang = lumpuh)
-- Sesudah : validator tanpa cakupan → SEMUA     (lupa mencentang = kebanjiran)
-- Cakupan tetap menggigit begitu diisi, jadi pembagian kerja per mapel tidak
-- hilang — yang hilang cuma mode gagal senyapnya.
--
-- KENAPA AMAN DIBUKA
-- psat.bank_soal tidak punya kolom validated_by: tidak ada perhitungan honor
-- atau audit per validator yang bergantung pada cakupan ini. Cakupan adalah
-- catatan penugasan dan daftar tujuan notifikasi WA, bukan batas keamanan.
-- Pintu keamanannya tetap sama: hanya peran admin/validator yang boleh masuk.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260905000001_cakupan_validator_fail_open_rollback.sql

BEGIN;

-- =============================================================================
-- 1. Fungsi antrean: satu klausa baru, sisanya utuh dari 20260904000003
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.get_antrean_validasi()
RETURNS TABLE(ujian_id uuid, ujian_nama text, mapel_id uuid, mapel_nama text,
              level text, tahun_ajaran text, semester integer,
              submitted bigint, needs_revision bigint, approved bigint)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $function$
  WITH aktor AS (
    SELECT psat.current_user_role() AS peran, auth.uid() AS uid
  )
  SELECT
    u.id,
    u.nama,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ev.tahun_ajaran,
    ev.semester,
    count(*) FILTER (WHERE b.status = 'submitted'),
    count(*) FILTER (WHERE b.status = 'needs_revision'),
    count(*) FILTER (WHERE b.status = 'approved')
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  JOIN psat.bank_soal b      ON b.ujian_id = u.id
                            AND b.status IN ('submitted', 'needs_revision', 'approved')
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  CROSS JOIN aktor a
  -- Fungsi ini SECURITY DEFINER, jadi ia harus menjaga pintunya sendiri.
  WHERE a.peran IN ('admin'::psat.user_role, 'validator'::psat.user_role)
    AND (
      a.peran = 'admin'::psat.user_role
      -- Validator tanpa satu pun cakupan: pegang semua mapel.
      OR NOT EXISTS (SELECT 1 FROM psat.psat_validator_mapel v
                     WHERE v.validator_id = a.uid)
      OR EXISTS (SELECT 1 FROM psat.psat_validator_mapel v
                 WHERE v.validator_id = a.uid AND v.mapel_id = ma.psat_mapel_id)
    )
  GROUP BY u.id, u.nama, ma.psat_mapel_id, mp.nama, ev.tahun_ajaran, ev.semester
  ORDER BY mp.nama, psat.level_ujian(u.id);
$function$;

COMMENT ON FUNCTION psat.get_antrean_validasi() IS
  'Antrean validasi per (ujian, status) untuk event aktif. Admin melihat semua; validator melihat mapel yang ditugaskan, dan SEMUA mapel bila belum ada penugasan sama sekali (fail-open, 20260905000001).';

-- =============================================================================
-- 2. Gerbang — diuji dengan MEMANGGIL fungsinya sebagai tiga peran berbeda
-- =============================================================================
DO $gate$
DECLARE
  -- Ahmad Sulaeman: satu-satunya is_soal_validator, dan hari ini nol cakupan.
  v_validator uuid := '1e0aa7a2-3f5f-4db9-b40d-8f23cbddce19';
  v_admin     uuid := '00000000-0000-0000-0000-000000000001';
  v_guru      uuid;
  v_admin_lihat int; v_tanpa_cakupan int; v_dengan_cakupan int; v_guru_lihat int;
  v_mapel     uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM psat.psat_validator_mapel WHERE validator_id = v_validator) THEN
    RAISE EXCEPTION 'Validator uji sudah punya cakupan — gerbang ini menguji keadaan KOSONG, hentikan dan periksa dulu.';
  END IF;

  -- Penulis soal biasa: peran 'guru', harus tetap nol. Fail-open TIDAK boleh
  -- bocor ke luar validator — tanpa uji ini, "semua orang melihat semua" pun
  -- akan lolos.
  SELECT p.id INTO v_guru FROM public.profiles p
   WHERE p.role = 'guru' AND p.is_penulis_soal AND NOT p.is_soal_validator
     AND p.status = 'aktif' LIMIT 1;
  IF v_guru IS NULL THEN
    RAISE EXCEPTION 'Tidak ada penulis soal untuk dipakai kontrol negatif';
  END IF;

  -- (a) ADMIN — patokan "semua"
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_admin_lihat FROM psat.get_antrean_validasi();
  IF v_admin_lihat = 0 THEN
    RAISE EXCEPTION 'Admin melihat 0 baris — tidak ada antrean untuk diuji, gerbang ini akan lolos dengan tangan kosong.';
  END IF;

  -- (b) VALIDATOR tanpa cakupan — harus sama dengan admin
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_validator, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_tanpa_cakupan FROM psat.get_antrean_validasi();
  IF v_tanpa_cakupan <> v_admin_lihat THEN
    RAISE EXCEPTION 'Validator tanpa cakupan melihat % baris, admin %', v_tanpa_cakupan, v_admin_lihat;
  END IF;

  -- (c) VALIDATOR dengan satu cakupan — harus MENYUSUT.
  -- Kalau tidak, artinya kita tidak membuat "kosong = semua", melainkan
  -- membuang penyaringnya sama sekali. Disisipkan lalu dibatalkan lewat
  -- subtransaksi; nilai variabel plpgsql selamat dari pembatalan itu.
  SELECT ma.psat_mapel_id INTO v_mapel
    FROM public.ujian u
    JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
    JOIN psat.bank_soal b ON b.ujian_id = u.id AND b.status = 'submitted'
    JOIN psat.mapel_alias ma ON ma.public_mapel_id = u.mata_pelajaran_id
   LIMIT 1;
  IF v_mapel IS NULL THEN
    RAISE EXCEPTION 'Tidak ada mapel berantrean untuk menguji penyaring';
  END IF;

  BEGIN
    INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id) VALUES (v_validator, v_mapel);
    SELECT count(*) INTO v_dengan_cakupan FROM psat.get_antrean_validasi();
    RAISE EXCEPTION 'batalkan-uji-cakupan';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'batalkan-uji-cakupan' THEN RAISE; END IF;
  END;

  IF v_dengan_cakupan >= v_tanpa_cakupan THEN
    RAISE EXCEPTION 'Cakupan tidak lagi menyaring: dengan 1 mapel % baris, tanpa cakupan %',
                    v_dengan_cakupan, v_tanpa_cakupan;
  END IF;

  -- (d) KONTROL NEGATIF — penulis soal tetap nol
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_guru, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_guru_lihat FROM psat.get_antrean_validasi();
  IF v_guru_lihat <> 0 THEN
    RAISE EXCEPTION 'Penulis soal ikut melihat antrean (% baris) — pintu peran bocor', v_guru_lihat;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  RAISE NOTICE 'Gerbang lolos: admin %, validator tanpa cakupan % (sama), dengan 1 cakupan % (menyusut), penulis 0.',
               v_admin_lihat, v_tanpa_cakupan, v_dengan_cakupan;
END
$gate$;

COMMIT;
