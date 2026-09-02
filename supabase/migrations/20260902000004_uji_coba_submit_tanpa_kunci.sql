-- Migration: uji-coba submit matriks menuntut keadaan yang baru ada sesudahnya
-- Prasyarat: 20260901000001 sudah diapply.
--
-- MASALAH — kebuntuan tertutup, tidak ada guru yang bisa submit pertama kali
-- handleSubmitAll (matrix/page.tsx:427) memanggil sinkron_konfigurasi_bab
-- dengan p_dry_run = true LEBIH DULU, baru mengunci barisnya di baris 437.
-- Tapi uji-coba itu menambahkan masalah 'matrix-belum-submit' selama masih ada
-- baris NOT is_submitted — yang pada titik itu SELALU benar, karena penguncian
-- belum terjadi. Hasilnya ok:false, klien , dan baris 437 tak pernah
-- tercapai.
--
-- Yang lolos selama ini hanyalah matriks yang sudah terkunci oleh kode LAMA
-- (yang mengunci tanpa uji-coba); submit ulang atasnya memang lulus. Guru baru
-- selalu buntu.
--
-- Diukur di produksi 2 Sep 2026 — tiga guru tersangkut, dua di antaranya justru
-- penulis yang ditunjuk, semua bab sudah terpetakan:
--   Muhammad Abdul Aziz  — PTS 1 Science LEVEL 8      (4 bab)
--   Agus Prasetyo        — PTS 1 Mathematics LEVEL 9  (2 bab)
--   Hang Sakti Abdullah  — PTS 1 English LEVEL 8      (2 bab)
--
-- Dijalankan sebagai Agus Prasetyo, apa adanya:
--   {"ok": false, "masalah": [{"kode": "matrix-belum-submit", ...}]}
-- Baris yang sama sesudah dikunci lebih dulu:
--   {"ok": true, "masalah": [], "total_soal": 35}
-- Satu-satunya masalah adalah urutannya.
--
-- PERBAIKAN
-- Penjaga itu hanya berlaku pada sinkronisasi SUNGGUHAN. Uji-coba menjawab
-- "isi matriksnya sah?" — penguncian adalah urusan pemanggil, dan pemanggil
-- melakukannya tepat sesudah uji-coba lulus. Sinkronisasi sungguhan tetap
-- menolak matriks yang belum terkunci; ia dipanggil sesudah penguncian.
--
-- Perbaikan ini SENGAJA di sisi basis data, bukan klien: build yang sedang
-- tayang langsung tertolong tanpa menunggu deploy, dan ketiga guru di atas bisa
-- submit begitu migrasi ini masuk.
--
-- Badan fungsi diambil dari pg_get_functiondef PRODUKSI, bukan disalin dari
-- berkas migrasi repo. [[project-migration-repo-vs-produksi]]
--
-- ROLLBACK: supabase/rollback/20260902000004_uji_coba_submit_rollback.sql

BEGIN;

CREATE OR REPLACE FUNCTION psat.sinkron_konfigurasi_bab(p_ujian_id uuid, p_profile_id uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'psat', 'public', 'pg_temp'
AS $function$
DECLARE
  v_aktor    uuid := auth.uid();
  v_role     text;
  v_profile  uuid;
  v_penulis  uuid;
  v_n_submit int;
  v_masalah  jsonb := '[]'::jsonb;
  v_beda     jsonb;
  v_bab_nul  jsonb;
  v_ditulis  int := 0;
  v_total    int := 0;
BEGIN
  -- ── Otorisasi ─────────────────────────────────────────────────────────────
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  -- COALESCE wajib: current_user_role() mengembalikan NULL untuk siapa pun yang
  -- tidak punya baris aktif di public.profiles — dan itu BUKAN kasus teoretis,
  -- kedua penulis matriks ICT PROGUL memang tidak ada di sana. Tanpa COALESCE,
  -- `NULL <> 'admin'` bernilai NULL, `TRUE AND NULL` bukan TRUE, dan penjaganya
  -- diam-diam tidak menyala.
  v_role    := COALESCE(psat.current_user_role()::text, '');
  v_profile := COALESCE(p_profile_id, v_aktor);

  IF v_profile <> v_aktor AND v_role <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh menyinkronkan matriks guru lain.'
      USING HINT = 'bukan-admin';
  END IF;

  -- ── Pagu wajib ada ────────────────────────────────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM psat.psat_patokan_ujian
                 WHERE ujian_id = p_ujian_id AND jumlah_keluar > 0) THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'patokan-kosong',
      'pesan', 'Super admin belum menetapkan pagu soal untuk ujian ini.');
  END IF;

  -- ── Penulis yang berhak ───────────────────────────────────────────────────
  SELECT profile_id INTO v_penulis
  FROM psat.psat_ujian_penulis WHERE ujian_id = p_ujian_id;

  SELECT count(DISTINCT profile_id) INTO v_n_submit
  FROM psat.psat_matrix_input
  WHERE ujian_id = p_ujian_id AND is_submitted;

  IF v_penulis IS NOT NULL AND v_penulis <> v_profile THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'bukan-penulis-ditunjuk',
      'pesan', 'Matriks ujian ini ditulis guru lain yang ditunjuk super admin.');
  ELSIF v_penulis IS NULL AND v_n_submit > 1 THEN
    -- Tanpa penunjukan, N guru masing-masing mengisi sebanyak pagu → N × pagu.
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'penulis-ganda',
      'pesan', format('%s guru sudah mengisi matriks ujian ini dan belum ada penulis yang ditunjuk. Super admin menunjuk satu penanggung jawab di halaman Patokan.', v_n_submit));
  END IF;

  -- ── Matriks ada dan sudah disubmit seluruhnya ─────────────────────────────
  IF NOT EXISTS (SELECT 1 FROM psat.psat_matrix_input
                 WHERE ujian_id = p_ujian_id AND profile_id = v_profile) THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'matrix-kosong',
      'pesan', 'Belum ada baris matriks untuk ujian ini.');
  ELSIF NOT p_dry_run AND EXISTS (SELECT 1 FROM psat.psat_matrix_input
                WHERE ujian_id = p_ujian_id AND profile_id = v_profile
                  AND NOT is_submitted) THEN
    -- NOT p_dry_run WAJIB. Uji-coba dipanggil SEBELUM baris dikunci
    -- (matrix/page.tsx handleSubmitAll), jadi tanpa penjaga ini ia menuntut
    -- keadaan yang justru baru dibuat SESUDAH dirinya lulus — dan tidak ada
    -- guru yang bisa submit untuk pertama kalinya. Uji-coba menjawab "isinya
    -- sah?"; penguncian urusan pemanggil. Sinkronisasi sungguhan tetap
    -- menolak matriks yang belum terkunci, dan ia memang dipanggil sesudahnya.
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'matrix-belum-submit',
      'pesan', 'Masih ada bab yang belum disubmit.');
  END IF;

  -- ── Setiap bab terpetakan ke bab LMS ──────────────────────────────────────
  SELECT jsonb_agg(bab_id_text ORDER BY bab_id_text) INTO v_bab_nul
  FROM psat.psat_matrix_input
  WHERE ujian_id = p_ujian_id AND profile_id = v_profile AND bab_id IS NULL;

  IF v_bab_nul IS NOT NULL THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'bab-belum-dipetakan',
      'pesan', 'Ada bab yang belum dipilih dari daftar bab LMS.',
      'bab',   v_bab_nul);
  END IF;

  -- ── Bab benar terlihat oleh ujian ini ─────────────────────────────────────
  -- Dulu aturannya disalin di sini (`bp.ujian_id = mi.ujian_id OR (ujian_id IS
  -- NULL AND mapel cocok)`) dan karena itu tidak ikut mengenal tingkat: matriks
  -- yang memuat bab tingkat lain akan lolos, lalu generate menemukan stok nol.
  -- Sekarang bertanya ke sumber yang sama dengan dropdown yang mengisinya.
  IF EXISTS (
    SELECT 1
    FROM psat.psat_matrix_input mi
    WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = v_profile
      AND mi.bab_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.bab_terlihat_ujian(p_ujian_id) v
        WHERE v.bab_id = mi.bab_id)
  ) THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'bab-di-luar-ujian',
      'pesan', 'Ada bab yang bukan milik ujian ini, mapelnya, atau tingkatnya.');
  END IF;

  -- ── Σ per (tipe, kesulitan) SAMA PERSIS dengan pagu ───────────────────────
  -- Validasi klien di matrix/page.tsx bisa dilewati; ini penjaganya.
  WITH sel AS (
    SELECT
      regexp_replace(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$', '')  AS tipe,
      (regexp_match(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$'))[1]   AS kesulitan,
      (regexp_match(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$'))[2]   AS bagian,
      COALESCE(NULLIF(t.v, '')::numeric, 0)::int                       AS n
    FROM psat.psat_matrix_input mi, jsonb_each_text(mi.data) AS t(k, v)
    WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = v_profile
  ),
  dibagi AS (
    SELECT tipe, kesulitan, sum(n)::int AS n
    FROM sel WHERE bagian = 'keluar' AND kesulitan IS NOT NULL
    GROUP BY 1, 2
  ),
  pagu AS (
    SELECT tipe, tingkat_kesulitan AS kesulitan, jumlah_keluar AS n
    FROM psat.psat_patokan_ujian WHERE ujian_id = p_ujian_id
  )
  SELECT jsonb_agg(jsonb_build_object(
           'tipe',      COALESCE(p.tipe, d.tipe),
           'kesulitan', COALESCE(p.kesulitan, d.kesulitan),
           'pagu',      COALESCE(p.n, 0),
           'dibagi',    COALESCE(d.n, 0))
         ORDER BY COALESCE(p.tipe, d.tipe), COALESCE(p.kesulitan, d.kesulitan))
    INTO v_beda
  FROM pagu p
  FULL JOIN dibagi d ON d.tipe = p.tipe AND d.kesulitan = p.kesulitan
  WHERE COALESCE(p.n, 0) <> COALESCE(d.n, 0);

  IF v_beda IS NOT NULL THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'jumlah-tidak-sama',
      'pesan', 'Jumlah soal per bab tidak sama dengan pagu.',
      'sel',   v_beda);
  END IF;

  -- ── Berhenti bila ada masalah, atau bila cuma uji-coba ────────────────────
  IF jsonb_array_length(v_masalah) > 0 THEN
    IF p_dry_run THEN
      RETURN jsonb_build_object('ok', false, 'ujian_id', p_ujian_id,
                                'profile_id', v_profile, 'masalah', v_masalah);
    END IF;
    RAISE EXCEPTION 'Sinkronisasi matriks ditolak: %',
      (SELECT string_agg(e->>'pesan', ' | ') FROM jsonb_array_elements(v_masalah) e)
      USING HINT = (v_masalah->0->>'kode');
  END IF;

  IF p_dry_run THEN
    SELECT COALESCE(sum((t.v)::numeric), 0)::int INTO v_total
    FROM psat.psat_matrix_input mi, jsonb_each_text(mi.data) AS t(k, v)
    WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = v_profile
      AND t.k LIKE '%\_keluar';
    RETURN jsonb_build_object('ok', true, 'dry_run', true, 'ujian_id', p_ujian_id,
                              'profile_id', v_profile, 'total_soal', v_total,
                              'masalah', '[]'::jsonb);
  END IF;

  -- ── Tulis ulang, bukan tambal ─────────────────────────────────────────────
  -- Upsert tidak bisa MENGHAPUS sel yang dinolkan guru atau bab yang dihapusnya,
  -- dan sel basi kini berarti kegagalan generate yang keras — bukan sekadar
  -- kotoran. Hapus-lalu-sisip satu-satunya bentuk yang membuat kalimat
  -- "konfigurasi LMS = grid guru" benar-benar berlaku. Aman: satu transaksi.
  DELETE FROM public.ujian_konfigurasi_bab WHERE ujian_id = p_ujian_id;

  WITH sel AS (
    SELECT
      mi.bab_id,
      psat.tipe_ke_lms(
        regexp_replace(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$', ''))   AS tipe_soal,
      (regexp_match(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$'))[1]       AS kesulitan,
      (regexp_match(t.k, '_(mudah|sedang|sulit)_(keluar|bank)$'))[2]       AS bagian,
      COALESCE(NULLIF(t.v, '')::numeric, 0)::int                           AS n
    FROM psat.psat_matrix_input mi, jsonb_each_text(mi.data) AS t(k, v)
    WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = v_profile
  )
  INSERT INTO public.ujian_konfigurasi_bab
    (ujian_id, bab_id, tipe_soal, tingkat_kesulitan, jumlah)
  SELECT p_ujian_id, bab_id, tipe_soal, kesulitan, sum(n)
  FROM sel
  WHERE bagian = 'keluar' AND kesulitan IS NOT NULL AND n > 0
  GROUP BY bab_id, tipe_soal, kesulitan
  HAVING sum(n) > 0;

  GET DIAGNOSTICS v_ditulis = ROW_COUNT;

  SELECT COALESCE(sum(jumlah), 0) INTO v_total
  FROM public.ujian_konfigurasi_bab WHERE ujian_id = p_ujian_id;

  RETURN jsonb_build_object(
    'ok', true, 'ujian_id', p_ujian_id, 'profile_id', v_profile,
    'baris_ditulis', v_ditulis, 'total_soal', v_total, 'masalah', '[]'::jsonb);
END
$function$;

GRANT EXECUTE ON FUNCTION psat.sinkron_konfigurasi_bab(uuid, uuid, boolean) TO authenticated;

-- =============================================================================
-- Gerbang: JALANKAN, jangan cuma pandangi
-- =============================================================================
-- Gerbang struktural pernah meloloskan fungsi yang gagal di setiap pemanggilan
-- (20260902000001/0002). Yang ini menyamar jadi guru yang benar-benar tersangkut
-- dan menuntut uji-cobanya berbalik jadi lulus.
DO $
DECLARE
  v_guru  uuid;
  v_ujian uuid;
  v_hasil jsonb;
BEGIN
  IF pg_get_functiondef(to_regprocedure('psat.sinkron_konfigurasi_bab(uuid,uuid,boolean)'))
       NOT LIKE '%matrix-belum-submit%' THEN
    RAISE EXCEPTION 'penjaga matrix-belum-submit hilang seluruhnya — sinkronisasi sungguhan jadi menerima matriks draf';
  END IF;

  SELECT mi.profile_id, mi.ujian_id INTO v_guru, v_ujian
  FROM psat.psat_matrix_input mi
  WHERE NOT mi.is_submitted
    AND mi.bab_id IS NOT NULL
  GROUP BY 1, 2 LIMIT 1;

  IF v_guru IS NULL THEN
    RAISE NOTICE 'tidak ada matriks belum-submit untuk diuji — gerbang perilaku dilewati';
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_guru)::text, true);
    v_hasil := psat.sinkron_konfigurasi_bab(v_ujian, NULL, true);

    IF v_hasil->'masalah' @> '[{"kode":"matrix-belum-submit"}]'::jsonb THEN
      RAISE EXCEPTION 'uji-coba MASIH menuntut baris terkunci — kebuntuannya belum hilang: %', v_hasil;
    END IF;
    RAISE NOTICE 'gerbang: uji-coba guru tersangkut = %', v_hasil;
  END IF;
END
$;

COMMIT;

NOTIFY pgrst, 'reload schema';
