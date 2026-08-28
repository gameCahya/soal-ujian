-- =============================================================================
-- PSAT: RPC publik bercakupan ujian
-- =============================================================================
-- Menggantikan trio RPC lama yang bercakupan mapel. Perubahan penting selain
-- cakupan: kelas tidak lagi diturunkan dari profil penulis, melainkan dari
-- level ujian. Guru yang pindah kelas tahun depan tidak lagi menyeret soal
-- lamanya ikut berpindah kelas.
--
-- Jalankan SETELAH 20260827000002_backfill_ujian_id.sql.
-- =============================================================================

BEGIN;

-- =============================================================================
-- Daftar siklus PSAT yang punya data — untuk pemilih siklus di halaman publik
-- =============================================================================

CREATE OR REPLACE FUNCTION psat.get_ujian_psat()
RETURNS TABLE (
  ujian_id      UUID,
  ujian_nama    TEXT,
  mapel_id      UUID,
  psat_mapel_id UUID,
  mapel_nama    TEXT,
  level         TEXT,
  event_id      UUID,
  event_nama    TEXT,
  tahun_ajaran  TEXT,
  semester      INTEGER,
  event_aktif   BOOLEAN,
  jumlah_soal   BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT
    u.id,
    u.nama,
    u.mata_pelajaran_id,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ev.id,
    ev.nama,
    ev.tahun_ajaran,
    ev.semester,
    ev.is_active,
    COUNT(bs.id)
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  LEFT JOIN psat.bank_soal        bs ON bs.ujian_id = u.id
  WHERE EXISTS (SELECT 1 FROM psat.bank_soal        b WHERE b.ujian_id = u.id)
     OR EXISTS (SELECT 1 FROM psat.psat_matrix_input m WHERE m.ujian_id = u.id)
     OR EXISTS (SELECT 1 FROM psat.psat_patokan_ujian p WHERE p.ujian_id = u.id)
  GROUP BY u.id, u.nama, u.mata_pelajaran_id, ma.psat_mapel_id, mp.nama,
           ev.id, ev.nama, ev.tahun_ajaran, ev.semester, ev.is_active
  ORDER BY ev.tahun_ajaran DESC, ev.semester DESC, mp.nama, psat.level_ujian(u.id);
$$;

GRANT EXECUTE ON FUNCTION psat.get_ujian_psat() TO anon, authenticated;

-- =============================================================================
-- Progress per guru, dicakup ujian
-- =============================================================================

DROP FUNCTION IF EXISTS psat.get_public_guru_progress();

CREATE OR REPLACE FUNCTION psat.get_public_guru_progress(p_ujian_id UUID DEFAULT NULL)
RETURNS TABLE (
  profile_id          UUID,
  guru_nama           TEXT,
  guru_kelas          TEXT,
  guru_unit_sekolah   TEXT,
  ujian_id            UUID,
  ujian_nama          TEXT,
  mapel_id            UUID,
  mapel_nama          TEXT,
  mapel_kode          TEXT,
  total               BIGINT,
  approved            BIGINT,
  submitted           BIGINT,
  draft               BIGINT,
  needs_revision      BIGINT,
  patokan_bank_total  BIGINT,
  has_matrix          BOOLEAN,
  glossary_url        TEXT,
  kisi_kisi_url       TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  WITH pasangan AS (
    -- Guru yang terlibat di sebuah ujian: punya soal, atau punya matrix
    SELECT DISTINCT bs.guru_id AS profile_id, bs.ujian_id
    FROM psat.bank_soal bs
    WHERE bs.ujian_id IS NOT NULL
      AND (p_ujian_id IS NULL OR bs.ujian_id = p_ujian_id)
    UNION
    SELECT DISTINCT mi.profile_id, mi.ujian_id
    FROM psat.psat_matrix_input mi
    WHERE mi.ujian_id IS NOT NULL
      AND (p_ujian_id IS NULL OR mi.ujian_id = p_ujian_id)
  )
  SELECT
    pg.profile_id,
    p.nama,
    -- Kelas dari level ujian, bukan dari profil penulis
    'Kelas ' || psat.level_ujian(pg.ujian_id),
    gd.unit_sekolah,
    pg.ujian_id,
    u.nama,
    ma.psat_mapel_id,
    mp.nama,
    mp.kode,
    COUNT(bs.id),
    COUNT(bs.id) FILTER (WHERE bs.status = 'approved'),
    COUNT(bs.id) FILTER (WHERE bs.status = 'submitted'),
    COUNT(bs.id) FILTER (WHERE bs.status = 'draft'),
    COUNT(bs.id) FILTER (WHERE bs.status = 'needs_revision'),
    COALESCE((
      SELECT SUM(pu.jumlah_bank) FROM psat.psat_patokan_ujian pu
      WHERE pu.ujian_id = pg.ujian_id
    ), 0),
    EXISTS (
      SELECT 1 FROM psat.psat_matrix_input mi
      WHERE mi.profile_id = pg.profile_id
        AND mi.ujian_id = pg.ujian_id
        AND mi.is_submitted
    ),
    (
      SELECT ds.file_url FROM psat.psat_dokumen_status ds
      WHERE ds.profile_id = pg.profile_id AND ds.tipe = 'glossary' LIMIT 1
    ),
    (
      SELECT ds.file_url FROM psat.psat_dokumen_status ds
      WHERE ds.profile_id = pg.profile_id AND ds.tipe = 'kisi_kisi' LIMIT 1
    )
  FROM pasangan pg
  -- profiles_all, bukan profiles: psat.profiles menyaring lewat auth.uid()/auth.role(),
  -- jadi dipanggil anon (halaman publik) ia mengembalikan nol baris meski fungsinya
  -- SECURITY DEFINER. Ini juga bug pada versi lama RPC ini.
  JOIN psat.profiles_all p ON p.id = pg.profile_id
  JOIN public.ujian  u ON u.id = pg.ujian_id
  LEFT JOIN psat.psat_guru_data gd ON gd.profile_id = pg.profile_id
  LEFT JOIN psat.mapel_alias    ma ON ma.public_mapel_id = u.mata_pelajaran_id
  LEFT JOIN psat.mata_pelajaran mp ON mp.id = ma.psat_mapel_id
  LEFT JOIN psat.bank_soal      bs ON bs.guru_id = pg.profile_id AND bs.ujian_id = pg.ujian_id
  GROUP BY pg.profile_id, p.nama, gd.unit_sekolah, pg.ujian_id, u.nama,
           ma.psat_mapel_id, mp.nama, mp.kode
  ORDER BY mp.nama, psat.level_ujian(pg.ujian_id), p.nama;
$$;

GRANT EXECUTE ON FUNCTION psat.get_public_guru_progress(UUID) TO anon, authenticated;

-- =============================================================================
-- Soal & matrix publik, dicakup ujian
-- =============================================================================

DROP FUNCTION IF EXISTS psat.get_public_soal_by_mapel(UUID);

CREATE OR REPLACE FUNCTION psat.get_public_soal_by_ujian(p_ujian_id UUID)
RETURNS TABLE (
  id                UUID,
  pertanyaan        TEXT,
  tipe              TEXT,
  tingkat_kesulitan TEXT,
  bab_id_text       TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT id, pertanyaan, tipe, tingkat_kesulitan, bab_id_text
  FROM psat.bank_soal
  WHERE ujian_id = p_ujian_id
    AND status = 'approved'
  ORDER BY bab_id_text, tipe, tingkat_kesulitan, created_at;
$$;

GRANT EXECUTE ON FUNCTION psat.get_public_soal_by_ujian(UUID) TO anon, authenticated;

DROP FUNCTION IF EXISTS psat.get_public_matrix_by_mapel(UUID);
DROP FUNCTION IF EXISTS psat.get_public_matrix_by_mapel(UUID, UUID);

CREATE OR REPLACE FUNCTION psat.get_public_matrix_by_ujian(p_ujian_id UUID, p_profile_id UUID)
RETURNS TABLE (
  bab_id_text TEXT,
  data        JSONB
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT mi.bab_id_text, mi.data
  FROM psat.psat_matrix_input mi
  WHERE mi.ujian_id = p_ujian_id
    AND mi.profile_id = p_profile_id
    AND mi.is_submitted = true
  ORDER BY mi.bab_id_text;
$$;

GRANT EXECUTE ON FUNCTION psat.get_public_matrix_by_ujian(UUID, UUID) TO anon, authenticated;

COMMIT;
