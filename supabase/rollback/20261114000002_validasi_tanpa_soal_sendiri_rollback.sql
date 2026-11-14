-- Rollback: validasi tanpa soal sendiri
--
-- Mengembalikan get_antrean_validasi() ke definisi 20260905000001 dan
-- menghapus trigger penjaga.

BEGIN;

DROP TRIGGER IF EXISTS psat_bank_soal_tolak_validasi_sendiri ON psat.bank_soal;
DROP FUNCTION IF EXISTS psat.cegah_validasi_soal_sendiri();

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
    AND (
      a.peran = 'admin'::psat.user_role
      OR NOT EXISTS (SELECT 1 FROM psat.psat_validator_mapel v
                     WHERE v.validator_id = a.uid)
      OR EXISTS (SELECT 1 FROM psat.psat_validator_mapel v
                 WHERE v.validator_id = a.uid AND v.mapel_id = ma.psat_mapel_id)
    )
  GROUP BY u.id, u.nama, ma.psat_mapel_id, mp.nama, ev.tahun_ajaran, ev.semester
  ORDER BY mp.nama, psat.level_ujian(u.id);
$function$;

COMMIT;
