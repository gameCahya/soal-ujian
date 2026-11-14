-- Validator tidak boleh memvalidasi soal yang ia tulis sendiri
--
-- MASALAH
-- Sejak PSAT mengizinkan satu orang menjadi penulis sekaligus validator,
-- get_antrean_validasi() dan halaman validasi menampilkan soal milik validator
-- itu sendiri. Ia bisa meng-approve atau meminta revisi soalnya sendiri —
-- konflik kepentingan yang tidak terlihat di UI.
--
-- PERBAIKAN
-- 1. get_antrean_validasi(): untuk peran validator, kecualikan baris dengan
--    guru_id = auth.uid(). Admin tetap melihat semua.
-- 2. Trigger bank_soal: tolak perubahan status ke approved/needs_revision oleh
--    validator atas soal miliknya sendiri, supaya bukan hanya UI yang menjaga.
--
-- ROLLBACK: supabase/rollback/20261114000002_validasi_tanpa_soal_sendiri_rollback.sql

BEGIN;

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
  WHERE a.peran IN ('admin'::psat.user_role, 'validator'::psat.user_role)
    -- Validator tidak melihat soalnya sendiri; admin tetap melihat semua.
    AND (a.peran = 'admin'::psat.user_role OR b.guru_id IS DISTINCT FROM a.uid)
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
  'Antrean validasi per (ujian, status) untuk event aktif. Admin melihat semua; validator melihat mapel yang ditugaskan (semua mapel bila cakupan kosong), TANPA soal miliknya sendiri (20261114000002).';

-- ── Trigger penjaga ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION psat.cegah_validasi_soal_sendiri()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
BEGIN
  IF NEW.guru_id IS NOT NULL
     AND NEW.guru_id = auth.uid()
     AND psat.current_user_role() = 'validator'
     AND NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('approved', 'needs_revision') THEN
    RAISE EXCEPTION 'Validator tidak boleh memvalidasi soal yang ia tulis sendiri.'
      USING ERRCODE = '42501',
            HINT = 'Minta validator lain atau admin untuk memeriksa soal ini.';
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS psat_bank_soal_tolak_validasi_sendiri ON psat.bank_soal;
CREATE TRIGGER psat_bank_soal_tolak_validasi_sendiri
  BEFORE UPDATE OF status ON psat.bank_soal
  FOR EACH ROW EXECUTE FUNCTION psat.cegah_validasi_soal_sendiri();

COMMENT ON FUNCTION psat.cegah_validasi_soal_sendiri() IS
  'Menolak validator mengubah status soal miliknya sendiri ke approved/needs_revision. Admin tidak dibatasi.';

-- ── Gerbang ─────────────────────────────────────────────────────────────────
DO $gate$
BEGIN
  IF to_regprocedure('psat.cegah_validasi_soal_sendiri()') IS NULL THEN
    RAISE EXCEPTION 'cegah_validasi_soal_sendiri tidak terbentuk';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'psat.bank_soal'::regclass
      AND tgname = 'psat_bank_soal_tolak_validasi_sendiri'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'Trigger tolak validasi sendiri tidak aktif';
  END IF;

  RAISE NOTICE 'Gerbang lolos: antrean tanpa soal sendiri + trigger penjaga aktif.';
END
$gate$;

COMMIT;
