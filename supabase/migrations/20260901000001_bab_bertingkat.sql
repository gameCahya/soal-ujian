-- Migration: sisi PSAT dari "bab mengenal tingkat"
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
--
-- ⚠️ PRASYARAT MUTLAK: lms-new/supabase/migrations/20260901b_bab_bertingkat.sql
--    HARUS sudah diapply. Berkas ini memanggil public.tingkat_ujian() dan
--    public.bab_terlihat_ujian(); tanpa keduanya migrasi ini gagal seketika
--    (gerbang di bagian 0 memeriksanya lebih dulu supaya pesannya jelas).
--
-- LATAR
-- Alur PSAT dipakai dengan 3 level per mata pelajaran. Aturan "bab mana yang
-- boleh dipakai ujian ini" sebelumnya ditulis ULANG di empat tempat:
--   psat.get_bab_ujian()            → dropdown guru
--   psat.buat_bab_ujian()           → ambil-atau-buat
--   psat.sinkron_konfigurasi_bab()  → penjaga 'bab-di-luar-ujian'
--   public.impor_soal_psat()        → pemetaan nama bab saat impor
-- Yang keempat sudah menyimpang dari tiga lainnya (memakai `limit 1` atas
-- SELURUH mapel tanpa ORDER BY), dan itulah yang membuat soal bisa menempel ke
-- bab milik ujian level lain. Migrasi ini membuat ketiga fungsi PSAT memakai
-- public.bab_terlihat_ujian() — satu-satunya penulis aturan itu sekarang.
--
-- ROLLBACK: supabase/rollback/20260901000001_bab_bertingkat_rollback.sql
-- Cara apply: pnpm db:migrate supabase/migrations/20260901000001_*.sql
--   JANGAN menjalankan seluruh folder — berkas init memanggil
--   ALTER TABLE psat.profiles ENABLE ROW LEVEL SECURITY, dan psat.profiles kini
--   berupa VIEW sehingga perintah itu pasti gagal.

BEGIN;

-- =============================================================================
-- 0. Gerbang prasyarat
-- =============================================================================
DO $pra$
BEGIN
  IF to_regprocedure('public.tingkat_ujian(uuid)') IS NULL THEN
    RAISE EXCEPTION 'public.tingkat_ujian() belum ada — apply lms-new/20260901b_bab_bertingkat.sql lebih dulu.';
  END IF;
  IF to_regprocedure('public.bab_terlihat_ujian(uuid)') IS NULL THEN
    RAISE EXCEPTION 'public.bab_terlihat_ujian() belum ada — apply lms-new/20260901b_bab_bertingkat.sql lebih dulu.';
  END IF;
END
$pra$;

-- =============================================================================
-- 1. level_ujian mendelegasi
-- =============================================================================
-- Badannya dipindah ke public.tingkat_ujian(). Nama lama dipertahankan karena
-- get_ujian_aktif(), get_tugas_menulis(), dan get_calon_penulis() memanggilnya —
-- dan karena parsing level tidak boleh punya dua versi yang bisa menyimpang.

CREATE OR REPLACE FUNCTION psat.level_ujian(p_ujian_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT public.tingkat_ujian(p_ujian_id);
$$;

GRANT EXECUTE ON FUNCTION psat.level_ujian(UUID) TO anon, authenticated;

COMMENT ON FUNCTION psat.level_ujian(UUID) IS
  'Alias historis untuk public.tingkat_ujian(). Jangan menyalin badannya ke sini lagi — satu implementasi saja.';

-- =============================================================================
-- 2. get_bab_ujian jadi pembungkus tipis
-- =============================================================================
-- Tanda tangan keluarannya sengaja TIDAK berubah (bab_id, nama_bab, urutan):
-- src/lib/ujian.ts membacanya persis begitu, jadi klien tidak perlu ikut rilis.

CREATE OR REPLACE FUNCTION psat.get_bab_ujian(p_ujian_id UUID)
RETURNS TABLE (
  bab_id   UUID,
  nama_bab TEXT,
  urutan   INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT v.bab_id, v.nama_bab, v.urutan
  FROM public.bab_terlihat_ujian(p_ujian_id) v;
$$;

GRANT EXECUTE ON FUNCTION psat.get_bab_ujian(UUID) TO authenticated;

COMMENT ON FUNCTION psat.get_bab_ujian(UUID) IS
  'Bab yang boleh dipilih guru untuk satu ujian. Pembungkus public.bab_terlihat_ujian() — aturannya ada di sana, bukan di sini.';

-- =============================================================================
-- 3. buat_bab_ujian: sadar tingkat
-- =============================================================================
-- Dua perubahan: pencarian ambil-atau-buat memakai bab_terlihat_ujian (sehingga
-- bab tingkat LAIN tidak lagi dianggap "sudah ada" dan dikembalikan begitu saja),
-- dan bab baru lahir dengan tingkat ujian tujuan.
--
-- Bab tetap dibuat TINGKAT MAPEL (ujian_id NULL) sesuai keputusan 31 Agu — jadi
-- UTS dan UAS di tingkat yang sama berbagi bab, sementara tingkat berbeda tidak.

CREATE OR REPLACE FUNCTION psat.buat_bab_ujian(
  p_ujian_id uuid,
  p_nama_bab text
)
RETURNS TABLE (bab_id uuid, nama_bab text, urutan integer, sudah_ada boolean)
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
  -- ⚠️ DEFINER melewati RLS. Pemeriksaan di bawah INILAH batas keamanannya.
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

  -- Otorisasi: pengampu mapel+tingkat ujian ini, atau admin.
  -- Sengaja TIDAK memakai filter penulis-ditunjuk: membuat bab itu tak merusak
  -- dan hasilnya dipakai bersama, jadi guru boleh menyiapkannya sebelum ada
  -- penunjukan. Yang dijaga ketat adalah menulis konfigurasi, bukan ini.
  --
  -- COALESCE wajib: current_user_role() NULL untuk siapa pun tanpa baris aktif
  -- di public.profiles, dan `NULL <> 'admin'` bernilai NULL — penjaganya tidak
  -- akan menyala. Sudah pernah terjadi; jangan dilepas.
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

  -- Ambil-atau-buat. Cakupannya kini persis apa yang DILIHAT ujian ini, bukan
  -- seluruh mapel: bab bernama sama milik tingkat lain tidak lagi dikembalikan
  -- sebagai "sudah ada". prioritas memastikan pilihannya deterministik ketika
  -- ada lebih dari satu yang cocok.
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
    v_mapel,
    NULL,                                  -- tingkat mapel: dipakai ulang lintas ujian
    v_level,
    v_nama,
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

COMMENT ON FUNCTION psat.buat_bab_ujian(uuid, text) IS
  'Ambil-atau-buat bab untuk satu ujian, di tingkat ujian itu. Bab dibuat tingkat mapel (ujian_id NULL) supaya dipakai ulang lintas ujian di tingkat yang sama. Sengaja tanpa hapus/ganti-nama: menghapus bab memicu ON DELETE SET NULL di bank_soal.bab_id dan membuat generate ditolak.';

-- =============================================================================
-- 4. sinkron_konfigurasi_bab: penjaga bab memakai sumber yang sama
-- =============================================================================
-- Badan disalin utuh dari 20260831000001 dengan SATU blok yang berubah — penjaga
-- 'bab-di-luar-ujian'. Postgres tidak bisa menambal badan fungsi, jadi seluruhnya
-- ditulis ulang; jangan tergoda menyunting bagian lain di sini.
--
-- ⚠️ Satu transaksi dengan bagian 2-3, disengaja. Kalau dropdown sudah sadar
--    tingkat sementara penjaga ini belum, ada keadaan setengah jadi di mana
--    matriks bisa memuat bab tingkat lain tanpa ditolak — lalu generate
--    menemukan stok nol tanpa penjelasan.

CREATE OR REPLACE FUNCTION psat.sinkron_konfigurasi_bab(
  p_ujian_id   uuid,
  p_profile_id uuid    DEFAULT NULL,
  p_dry_run    boolean DEFAULT false
)
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
  ELSIF EXISTS (SELECT 1 FROM psat.psat_matrix_input
                WHERE ujian_id = p_ujian_id AND profile_id = v_profile
                  AND NOT is_submitted) THEN
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

REVOKE ALL ON FUNCTION psat.sinkron_konfigurasi_bab(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.sinkron_konfigurasi_bab(uuid, uuid, boolean) TO authenticated;

-- =============================================================================
-- 5. Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE v_def text;
BEGIN
  IF to_regprocedure('psat.buat_bab_ujian(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'buat_bab_ujian tidak terbentuk';
  END IF;
  IF to_regprocedure('psat.get_bab_ujian(uuid)') IS NULL THEN
    RAISE EXCEPTION 'get_bab_ujian tidak terbentuk';
  END IF;

  -- Ketiganya HARUS benar-benar memanggil sumber bersama. Tanpa cek ini,
  -- salinan aturan yang tertinggal lolos diam-diam — persis cara masalah ini
  -- lahir pertama kali.
  FOR v_def IN
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'psat'
      AND p.proname IN ('get_bab_ujian', 'buat_bab_ujian', 'sinkron_konfigurasi_bab')
  LOOP
    IF v_def NOT LIKE '%bab_terlihat_ujian%' THEN
      RAISE EXCEPTION 'Ada fungsi psat yang masih menyalin aturan bab sendiri, bukan memanggil bab_terlihat_ujian()';
    END IF;
  END LOOP;

  IF pg_get_functiondef(to_regprocedure('psat.level_ujian(uuid)')) NOT LIKE '%tingkat_ujian%' THEN
    RAISE EXCEPTION 'level_ujian belum mendelegasi ke public.tingkat_ujian()';
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- ⚠️ Management API & service-role BYPASS RLS, dan fungsi-fungsi ini membaca
--    auth.uid(). Tanpa penyamaran peran hasilnya menyesatkan. Buktikan
--    penyamaran aktif lebih dulu (current_user harus 'authenticated'), dan
--    jalankan tiap assersi sekali lagi dalam varian yang sengaja dirusak —
--    `[]` dari Management API berarti "sukses" MAUPUN "tanpa hasil".
--
-- 1. Dropdown tidak lagi bocor lintas tingkat:
--      BEGIN;
--        -- bab tingkat 9 tidak boleh muncul untuk ujian tingkat 7
--        SELECT count(*) FROM psat.get_bab_ujian('<ujian-L7>') g
--        JOIN public.bab_pelajaran bp ON bp.id = g.bab_id
--        WHERE bp.tingkat = '9';                       -- harap 0
--        -- bab warisan tanpa tingkat TETAP terlihat
--        SELECT count(*) FROM psat.get_bab_ujian('<ujian-L7>') g
--        JOIN public.bab_pelajaran bp ON bp.id = g.bab_id
--        WHERE bp.tingkat IS NULL;                     -- harap > 0 bila ada
--      ROLLBACK;
--
-- 2. buat_bab_ujian tidak lagi mengembalikan bab tingkat lain sebagai
--    "sudah_ada" — buat "Bab 1" di ujian L7 lalu di ujian L9 mapel yang sama;
--    keduanya harus mengembalikan bab_id BERBEDA dengan sudah_ada = false.
--
-- 3. sinkron menolak bab tingkat lain: sisipkan baris psat_matrix_input dengan
--    bab_id milik tingkat berbeda → dry-run harus memuat 'bab-di-luar-ujian'.
