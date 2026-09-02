-- ROLLBACK untuk 20260902000001_penulis_semua_guru.sql
--
-- Mengembalikan keempat fungsi ke bentuk 20260901000005/20260901000006:
-- daftar calon kembali sebatas pengampu, dan penunjukan kembali bergantung pada
-- public.guru_mengajar.
--
-- ⚠️ MENOLAK MUNDUR bila sudah ada penunjukan untuk guru yang tidak mengampu.
-- Mundur dalam keadaan itu membuat penulis-penulis tersebut kehilangan tugasnya
-- dalam sekejap, tanpa galat di layar mana pun — persis kegagalan senyap yang
-- migrasi maju ini hapus. Bereskan dulu penunjukannya (tunjuk ulang pengampu,
-- atau lengkapi guru_mengajar), baru mundur.

BEGIN;

DO $jaga$
DECLARE
  n int;
  contoh text;
BEGIN
  SELECT count(*), string_agg(DISTINCT COALESCE(pr.nama, pen.profile_id::text), ', ')
    INTO n, contoh
  FROM psat.psat_ujian_penulis pen
  JOIN public.profiles pr ON pr.id = pen.profile_id
  WHERE NOT EXISTS (
    SELECT 1
    FROM psat.get_ujian_aktif() a
    JOIN public.guru_mengajar gm
      ON gm.mapel_id = a.mapel_id
     AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
    WHERE a.ujian_id = pen.ujian_id AND gm.guru_id = pen.profile_id
  );

  IF n > 0 THEN
    RAISE EXCEPTION
      'Tidak bisa mundur: % penunjukan menuju guru yang tidak mengampu (%). Mereka akan kehilangan tugasnya tanpa galat.',
      n, left(contoh, 300);
  END IF;
END
$jaga$;

-- =============================================================================
-- 1. get_tugas_menulis(): kembali mewajibkan guru_mengajar
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.get_tugas_menulis()
RETURNS TABLE (
  ujian_id         UUID,
  ujian_nama       TEXT,
  mapel_id         UUID,
  psat_mapel_id    UUID,
  mapel_nama       TEXT,
  level            TEXT,
  matrix_submitted BOOLEAN,
  total_soal       BIGINT,
  target_bank      BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  WITH aktif AS (
    SELECT * FROM psat.get_ujian_aktif()
  ),
  ampu AS (
    SELECT DISTINCT
      gm.mapel_id,
      substring(gm.kelas FROM '^[[:space:]]*([0-9])') AS level
    FROM public.guru_mengajar gm
    WHERE gm.guru_id = auth.uid()
  )
  SELECT
    a.ujian_id,
    a.ujian_nama,
    a.mapel_id,
    a.psat_mapel_id,
    a.mapel_nama,
    a.level,
    EXISTS (
      SELECT 1 FROM psat.psat_matrix_input mi
      WHERE mi.profile_id = auth.uid()
        AND mi.ujian_id = a.ujian_id
        AND mi.is_submitted
    ),
    (
      SELECT COUNT(*) FROM psat.bank_soal bs
      WHERE bs.guru_id = auth.uid() AND bs.ujian_id = a.ujian_id
    ),
    COALESCE((
      SELECT SUM(pu.jumlah_bank) FROM psat.psat_patokan_ujian pu
      WHERE pu.ujian_id = a.ujian_id
    ), 0)
  FROM aktif a
  JOIN ampu am ON am.mapel_id = a.mapel_id AND am.level = a.level
  WHERE NOT EXISTS (
          SELECT 1 FROM psat.psat_ujian_penulis pen WHERE pen.ujian_id = a.ujian_id
        )
     OR EXISTS (
          SELECT 1 FROM psat.psat_ujian_penulis pen
          WHERE pen.ujian_id = a.ujian_id AND pen.profile_id = auth.uid()
        )
  ORDER BY a.mapel_nama, a.level;
$$;

GRANT EXECUTE ON FUNCTION psat.get_tugas_menulis() TO authenticated;

-- =============================================================================
-- 2. Pencarian dihapus
-- =============================================================================
DROP FUNCTION IF EXISTS psat.cari_calon_penulis(uuid, text, int);

-- =============================================================================
-- 3. get_calon_penulis(): kembali 7 kolom
-- =============================================================================
DROP FUNCTION IF EXISTS psat.get_calon_penulis(uuid);

CREATE OR REPLACE FUNCTION psat.get_calon_penulis(p_ujian_id UUID)
RETURNS TABLE (
  profile_id UUID,
  nama       TEXT,
  sudah_isi  BOOLEAN,
  ditunjuk   BOOLEAN,
  sekolah    TEXT,
  jml_kelas  BIGINT,
  siap       BOOLEAN
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $calon$
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  )
  SELECT
    gm.guru_id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = gm.guru_id),
    EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pen
             WHERE pen.ujian_id = p_ujian_id AND pen.profile_id = gm.guru_id),
    sk.nama,
    count(*),
    (pr.is_penulis_soal AND pr.status = 'aktif')
  FROM a
  JOIN public.guru_mengajar gm
    ON gm.mapel_id = a.mapel_id
   AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
  JOIN public.profiles pr ON pr.id = gm.guru_id
  LEFT JOIN public.sekolah sk ON sk.id = pr.sekolah_id
  GROUP BY gm.guru_id, pr.nama, sk.nama, pr.is_penulis_soal, pr.status
  ORDER BY pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

-- =============================================================================
-- 4. tetapkan_penulis(): penjaga `bukan-calon` dipasang lagi
-- =============================================================================
CREATE OR REPLACE FUNCTION psat.tetapkan_penulis(
  p_ujian_id   uuid,
  p_profile_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE
  v_aktor  uuid := auth.uid();
  v_role   text;
  v_nama   text;
  v_status text;
  v_prole  text;
  v_flag   boolean;
  v_nyala  boolean := false;
BEGIN
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  v_role := COALESCE(psat.current_user_role()::text, '');
  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh menunjuk penulis matriks.'
      USING HINT = 'bukan-admin';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM psat.get_calon_penulis(p_ujian_id) c
    WHERE c.profile_id = p_profile_id
  ) THEN
    RAISE EXCEPTION 'Guru itu tidak mengampu mata pelajaran dan tingkat ujian ini.'
      USING HINT = 'bukan-calon';
  END IF;

  SELECT pr.nama, pr.status::text, pr.role::text, pr.is_penulis_soal
    INTO v_nama, v_status, v_prole, v_flag
  FROM public.profiles pr WHERE pr.id = p_profile_id;

  IF v_status IS DISTINCT FROM 'aktif' THEN
    RAISE EXCEPTION 'Akun % berstatus "%" — aktifkan dulu, kalau tidak ia tidak akan melihat tugasnya.',
      COALESCE(v_nama, p_profile_id::text), COALESCE(v_status, 'tidak diketahui')
      USING HINT = 'akun-tidak-aktif';
  END IF;

  IF v_prole IS DISTINCT FROM 'guru' THEN
    RAISE EXCEPTION 'Akun % bukan berperan guru.' , COALESCE(v_nama, p_profile_id::text)
      USING HINT = 'bukan-guru';
  END IF;

  IF NOT COALESCE(v_flag, false) THEN
    UPDATE public.profiles SET is_penulis_soal = true WHERE id = p_profile_id;
    v_nyala := true;
  END IF;

  INSERT INTO psat.psat_ujian_penulis (ujian_id, profile_id, ditetapkan_oleh)
  VALUES (p_ujian_id, p_profile_id, v_aktor)
  ON CONFLICT (ujian_id) DO UPDATE
    SET profile_id      = EXCLUDED.profile_id,
        ditetapkan_oleh = EXCLUDED.ditetapkan_oleh,
        updated_at      = now();

  RETURN jsonb_build_object(
    'ok', true,
    'ujian_id', p_ujian_id,
    'profile_id', p_profile_id,
    'nama', v_nama,
    'izin_baru_dinyalakan', v_nyala
  );
END
$function$;

REVOKE ALL ON FUNCTION psat.tetapkan_penulis(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.tetapkan_penulis(uuid, uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
