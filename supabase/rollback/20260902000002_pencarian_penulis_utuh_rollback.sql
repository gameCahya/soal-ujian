-- ROLLBACK untuk 20260902000002_pencarian_penulis_utuh.sql
--
-- Mengembalikan get_calon_penulis dan cari_calon_penulis ke bentuk
-- 20260902000001: tanpa kolom `status`, batas 30, dan guru tidak aktif kembali
-- disembunyikan dari hasil pencarian.
--
-- ⚠️ Sesudah mundur, mengetik dua huruf yang lazim akan memotong hasil lagi
-- (diukur di produksi: "ma" 72 cocok → 30 terkirim) tanpa tanda apa pun di
-- layar. Itu keluhan yang justru memicu migrasi maju ini.

BEGIN;

DROP FUNCTION IF EXISTS psat.get_calon_penulis(uuid);

CREATE OR REPLACE FUNCTION psat.get_calon_penulis(p_ujian_id UUID)
RETURNS TABLE (
  profile_id UUID,
  nama       TEXT,
  sudah_isi  BOOLEAN,
  ditunjuk   BOOLEAN,
  sekolah    TEXT,
  jml_kelas  BIGINT,
  siap       BOOLEAN,
  mengampu   BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $calon$
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  ),
  ampu AS (
    SELECT gm.guru_id, count(*) AS jml
    FROM a
    JOIN public.guru_mengajar gm
      ON gm.mapel_id = a.mapel_id
     AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
    GROUP BY gm.guru_id
  ),
  pen AS (
    SELECT p.profile_id FROM psat.psat_ujian_penulis p WHERE p.ujian_id = p_ujian_id
  ),
  kandidat AS (
    SELECT am.guru_id AS id, am.jml, true AS ampu_ya FROM ampu am
    UNION ALL
    -- Yang ditunjuk tapi tidak mengampu. NOT EXISTS mencegah baris ganda,
    -- jadi UNION ALL cukup dan tidak perlu deduplikasi.
    SELECT pn.profile_id, 0::bigint, false FROM pen pn
    WHERE NOT EXISTS (SELECT 1 FROM ampu am WHERE am.guru_id = pn.profile_id)
  )
  SELECT
    k.id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = k.id),
    EXISTS (SELECT 1 FROM pen pn WHERE pn.profile_id = k.id),
    sk.nama,
    k.jml,
    (pr.is_penulis_soal AND pr.status = 'aktif'),
    k.ampu_ya
  FROM kandidat k
  JOIN public.profiles pr ON pr.id = k.id
  LEFT JOIN public.sekolah sk ON sk.id = pr.sekolah_id
  ORDER BY k.ampu_ya DESC, pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

DROP FUNCTION IF EXISTS psat.cari_calon_penulis(uuid, text, int);

CREATE OR REPLACE FUNCTION psat.cari_calon_penulis(
  p_ujian_id UUID,
  p_q        TEXT DEFAULT NULL,
  p_limit    INT  DEFAULT 30
)
RETURNS TABLE (
  profile_id UUID,
  nama       TEXT,
  sudah_isi  BOOLEAN,
  ditunjuk   BOOLEAN,
  sekolah    TEXT,
  jml_kelas  BIGINT,
  siap       BOOLEAN,
  mengampu   BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $cari$
DECLARE
  v_pola  text;
  v_batas int := greatest(1, least(COALESCE(p_limit, 30), 100));
BEGIN
  -- COALESCE wajib: current_user_role() NULL untuk siapa pun tanpa baris aktif
  -- di public.profiles, dan `NULL <> 'admin'` bernilai NULL sehingga penjaganya
  -- tidak menyala sama sekali.
  IF COALESCE(psat.current_user_role()::text, '') <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh mencari calon penulis.'
      USING HINT = 'bukan-admin';
  END IF;

  -- Karakter jokernya di-escape. Tanpa ini, admin mengetik "%" mendapat seluruh
  -- 200 guru dan "_" cocok dengan huruf apa pun — hasil pencarian yang membingungkan.
  v_pola := '%' || replace(replace(replace(
              btrim(COALESCE(p_q, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%';

  RETURN QUERY
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  ),
  ampu AS (
    SELECT gm.guru_id, count(*) AS jml
    FROM a
    JOIN public.guru_mengajar gm
      ON gm.mapel_id = a.mapel_id
     AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
    GROUP BY gm.guru_id
  )
  SELECT
    pr.id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = pr.id),
    EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pn
             WHERE pn.ujian_id = p_ujian_id AND pn.profile_id = pr.id),
    sk.nama,
    COALESCE(am.jml, 0::bigint),
    (pr.is_penulis_soal AND pr.status = 'aktif'),
    (am.guru_id IS NOT NULL)
  FROM public.profiles pr
  LEFT JOIN ampu am               ON am.guru_id = pr.id
  LEFT JOIN public.sekolah sk     ON sk.id = pr.sekolah_id
  -- status='aktif' bukan sekadar rapi: tetapkan_penulis MENOLAK akun tidak aktif,
  -- jadi menampilkannya berarti menawarkan pilihan yang pasti gagal.
  WHERE pr.role = 'guru'
    AND pr.status = 'aktif'
    AND (pr.nama ILIKE v_pola
      OR pr.email ILIKE v_pola
      OR COALESCE(pr.username, '') ILIKE v_pola)
  -- Pengampu didahulukan: saat admin mengetik nama yang dipakai beberapa guru,
  -- yang memang mengajar mapel ini yang muncul lebih dulu.
  ORDER BY (am.guru_id IS NOT NULL) DESC, pr.nama NULLS LAST
  LIMIT v_batas;
END
$cari$;

REVOKE ALL ON FUNCTION psat.cari_calon_penulis(uuid, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.cari_calon_penulis(uuid, text, int) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
