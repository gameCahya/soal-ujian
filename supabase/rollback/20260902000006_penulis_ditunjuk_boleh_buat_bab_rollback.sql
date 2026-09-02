-- Rollback: 20260902000006_penulis_ditunjuk_boleh_buat_bab.sql
--
-- ⚠️ BACA DULU. Mundur dari sini MENGUNCI KEMBALI 12 dari 39 penulis yang
-- ditunjuk: mereka akan kembali melihat tugas menulis yang tidak bisa mereka
-- mulai, dengan dropdown bab kosong dan tombol buat-bab yang menolak. Tidak ada
-- galat di layar mana pun yang menjelaskan sebabnya.
--
-- Hanya masuk akal bila migrasi 20260902000001 (penunjukan boleh jatuh ke guru
-- mana pun) juga dimundurkan. Selama penunjukan masih bebas, penjaga lama ini
-- memang tidak konsisten dengan dirinya sendiri.
--
-- Yang dikembalikan: definisi persis sebelum 20260902000006, yaitu keluaran
-- 20260901000001_bab_bertingkat.sql.

BEGIN;

CREATE OR REPLACE FUNCTION psat.buat_bab_ujian(p_ujian_id UUID, p_nama_bab TEXT)
RETURNS TABLE (bab_id UUID, nama_bab TEXT, urutan INTEGER, sudah_ada BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE
  v_aktor  uuid := auth.uid();
  v_role   text;
  v_nama   text := btrim(COALESCE(p_nama_bab, ''));
  v_mapel  uuid;
  v_level  text;
  v_ada    record;
  v_baru   record;
BEGIN
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  IF v_nama = '' THEN
    RAISE EXCEPTION 'Nama bab tidak boleh kosong.' USING HINT = 'nama-kosong';
  END IF;
  IF length(v_nama) > 120 THEN
    RAISE EXCEPTION 'Nama bab terlalu panjang (maksimal 120 karakter).' USING HINT = 'nama-panjang';
  END IF;

  SELECT u.mata_pelajaran_id INTO v_mapel FROM public.ujian u WHERE u.id = p_ujian_id;
  IF v_mapel IS NULL THEN
    RAISE EXCEPTION 'Ujian tidak ditemukan atau belum punya mata pelajaran.'
      USING HINT = 'ujian-tanpa-mapel';
  END IF;

  v_role  := COALESCE(psat.current_user_role()::text, '');
  v_level := public.tingkat_ujian(p_ujian_id);

  IF v_role <> 'admin' AND NOT EXISTS (
    SELECT 1 FROM public.guru_mengajar gm
    WHERE gm.guru_id = v_aktor
      AND gm.mapel_id = v_mapel
      AND (v_level IS NULL
           OR substring(gm.kelas FROM '^[[:space:]]*([0-9])') = v_level)
  ) THEN
    RAISE EXCEPTION 'Anda tidak mengampu mata pelajaran ujian ini.'
      USING HINT = 'bukan-pengampu';
  END IF;

  SELECT v.bab_id, v.nama_bab, v.urutan INTO v_ada
  FROM public.bab_terlihat_ujian(p_ujian_id) v
  WHERE lower(btrim(v.nama_bab)) = lower(v_nama)
  ORDER BY v.prioritas, v.bab_id
  LIMIT 1;

  IF v_ada.bab_id IS NOT NULL THEN
    bab_id := v_ada.bab_id; nama_bab := v_ada.nama_bab;
    urutan := v_ada.urutan; sudah_ada := true;
    RETURN NEXT;
    RETURN;
  END IF;

  INSERT INTO public.bab_pelajaran (mata_pelajaran_id, ujian_id, tingkat, nama_bab, urutan)
  VALUES (
    v_mapel, NULL, v_level, v_nama,
    COALESCE((SELECT max(bp.urutan) + 1 FROM public.bab_pelajaran bp
               WHERE bp.mata_pelajaran_id = v_mapel
                 AND bp.tingkat IS NOT DISTINCT FROM v_level), 1)
  )
  RETURNING id, public.bab_pelajaran.nama_bab, public.bab_pelajaran.urutan INTO v_baru;

  bab_id := v_baru.id; nama_bab := v_baru.nama_bab;
  urutan := v_baru.urutan; sudah_ada := false;
  RETURN NEXT;
END
$function$;

REVOKE ALL ON FUNCTION psat.buat_bab_ujian(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.buat_bab_ujian(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
