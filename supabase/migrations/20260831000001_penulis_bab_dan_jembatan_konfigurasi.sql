-- =============================================================================
-- PSAT: penulis ditunjuk, identitas bab, dan jembatan ke public.ujian_konfigurasi_bab
-- =============================================================================
-- Plan: /home/bangcs/.claude/plans/buatkan-agar-bsia-seperti-atomic-neumann.md
-- Prasyarat: 20260827000001..3 sudah diapply. Di sisi LMS, 20260831a sudah
--            diapply (ujian_pakai_alur_psat + pelonggaran nama bab per ujian).
--
-- LATAR
-- Pembagian kerja yang sudah dicatat di 20260827000001 baris 9-13 belum pernah
-- disambungkan: super admin menetapkan total per tipe × kesulitan, guru memecah
-- ke bab, dan `public.ujian_konfigurasi_bab` menyimpan HASIL keputusan guru.
-- Angka itu tidak pernah menyeberang, dan generator LMS meluruhkan dimensi bab.
-- Migrasi ini membangun jembatannya.
--
-- TIGA MASALAH YANG HARUS BERES DULU
--
-- 1. Satu ujian, banyak penulis. get_tugas_menulis() menghitung penugasan dari
--    guru_mengajar sebagai DISTINCT (mapel_id, level), jadi SETIAP guru mapel
--    itu melihat ujian yang sama sebagai tugasnya. Diukur di produksi:
--    45 dari 46 kombinasi (mapel, tingkat) diajar >1 guru — median 11-12 orang,
--    tertinggi 26. Karena tiap grid divalidasi harus sama dengan pagu, menjumlah
--    N guru menghasilkan N × pagu. Sudah terjadi sekali (ujian ICT PROGUL LEVEL 7:
--    dua guru, bab sama sekali berbeda, total 37 dan 45, pagu 45).
--    → psat_ujian_penulis: super admin menunjuk satu penanggung jawab.
--
-- 2. Bab cuma teks bebas. psat_matrix_input.bab_id_text diisi lewat <input> ber-
--    datalist; nama yang tak dikenal LMS tidak bisa dipetakan ke bab_pelajaran.
--    Ganti nama pun memutus soal: handleRenameBab memperbarui matrix tapi TIDAK
--    psat.bank_soal.bab_id_text.
--    → kolom bab_id UUID sebagai identitas yang stabil.
--
-- 3. PSAT hanya kenal 4 tipe; LMS punya 5 (benar_salah).
--
-- PRA-TERBANG (diukur 31 Agu 2026, service role lewat PostgREST):
--   psat_matrix_input          : 66 baris, 22 ujian
--   ujian dengan >1 guru mengisi: 1  (91d90268… ICT PROGUL LEVEL 7)
--   public.bab_pelajaran       : 60 baris (54 terikat ujian, 6 warisan)
--
-- ⚠️ Cara apply: pnpm db:migrate supabase/migrations/20260831000001_*.sql
--    JANGAN menjalankan seluruh folder — berkas init memanggil
--    ALTER TABLE psat.profiles ENABLE ROW LEVEL SECURITY, dan psat.profiles
--    kini berupa VIEW sehingga perintah itu pasti gagal.
-- ROLLBACK: supabase/rollback/20260831000001_penulis_bab_dan_jembatan_rollback.sql
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. Tipe kelima: benar_salah
-- =============================================================================
-- Hanya SATU CHECK yang menyebut daftar tipe (psat_patokan_ujian). psat.bank_soal
-- .tipe adalah TEXT polos tanpa constraint, jadi tidak perlu disentuh.
-- Namanya dicari dinamis: constraint ini lahir tanpa nama eksplisit di
-- 20260827000001, jadi namanya hasil generate Postgres.

DO $tipe$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
  WHERE conrelid = 'psat.psat_patokan_ujian'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%pilgan%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE psat.psat_patokan_ujian DROP CONSTRAINT %I', c);
  END IF;
END
$tipe$;

ALTER TABLE psat.psat_patokan_ujian
  ADD CONSTRAINT psat_patokan_ujian_tipe_check
  CHECK (tipe IN ('pilgan', 'ceklist', 'isian_singkat', 'essay', 'benar_salah'));

-- Baris `data` lama TIDAK perlu di-backfill: INITIAL_DATA di sisi klien
-- diturunkan dari TIPE_OPTIONS dan dimuat sebagai { ...INITIAL_DATA, ...parsed },
-- sehingga kunci benar_salah_* yang belum ada terbaca 0.

-- =============================================================================
-- 2. Identitas bab yang stabil
-- =============================================================================
-- ON DELETE SET NULL, bukan RESTRICT: bab dihapus dari LMS adalah kejadian sah
-- (KelolaBabModal punya tombolnya), dan matriks yang menggantung lebih baik
-- ditolak jembatan dengan pesan jelas daripada membuat DELETE di LMS gagal
-- dengan galat FK yang tak bisa ditindaklanjuti admin LMS.

ALTER TABLE psat.psat_matrix_input
  ADD COLUMN IF NOT EXISTS bab_id UUID
  REFERENCES public.bab_pelajaran(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_matrix_bab ON psat.psat_matrix_input(bab_id);

COMMENT ON COLUMN psat.psat_matrix_input.bab_id IS
  'Bab di LMS yang dirujuk baris ini. bab_id_text dipertahankan untuk tampilan dan baris lama; jembatan ke public.ujian_konfigurasi_bab mensyaratkan kolom ini terisi.';

-- Backfill: cocokkan nama (case/spasi-insensitif) DALAM himpunan kandidat yang
-- sama persis dengan psat.get_bab_ujian(), supaya tidak ada bab dari ujian lain
-- yang ikut tersedot.
UPDATE psat.psat_matrix_input mi
SET bab_id = bp.id
FROM public.ujian u, public.bab_pelajaran bp
WHERE u.id = mi.ujian_id
  AND mi.bab_id IS NULL
  AND (bp.ujian_id = mi.ujian_id
       OR (bp.ujian_id IS NULL AND bp.mata_pelajaran_id = u.mata_pelajaran_id))
  AND lower(btrim(bp.nama_bab)) = lower(btrim(mi.bab_id_text));

DO $lapor$
DECLARE sisa int; total int;
BEGIN
  SELECT count(*) INTO total FROM psat.psat_matrix_input;
  SELECT count(*) INTO sisa  FROM psat.psat_matrix_input WHERE bab_id IS NULL;
  RAISE NOTICE 'Backfill bab_id: % dari % baris masih NULL (nama tak dikenal LMS; guru memilih ulang lewat dropdown)', sisa, total;
END
$lapor$;

-- =============================================================================
-- 3. Penulis yang ditunjuk
-- =============================================================================
-- PK di ujian_id: tepat satu penanggung jawab per ujian. Kalau suatu saat
-- co-authoring per bab benar-benar dibutuhkan, itu tabel lain dengan aturan
-- validasi lain (jumlah SELURUH guru = pagu) — bukan pelonggaran PK ini.

CREATE TABLE IF NOT EXISTS psat.psat_ujian_penulis (
  ujian_id        UUID PRIMARY KEY REFERENCES public.ujian(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  ditetapkan_oleh UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- profile_id tanpa FK, mengikuti alasan yang sama dengan created_by di
-- psat_patokan_ujian: psat.profiles kini VIEW di atas public.profiles sehingga
-- tidak bisa jadi target foreign key.

DROP TRIGGER IF EXISTS trg_ujian_penulis_updated_at ON psat.psat_ujian_penulis;
CREATE TRIGGER trg_ujian_penulis_updated_at
  BEFORE UPDATE ON psat.psat_ujian_penulis
  FOR EACH ROW EXECUTE FUNCTION psat.set_updated_at();

ALTER TABLE psat.psat_ujian_penulis ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ujian_penulis_read" ON psat.psat_ujian_penulis;
CREATE POLICY "ujian_penulis_read" ON psat.psat_ujian_penulis
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "ujian_penulis_admin_write" ON psat.psat_ujian_penulis;
CREATE POLICY "ujian_penulis_admin_write" ON psat.psat_ujian_penulis
  FOR ALL
  USING (psat.current_user_role() = 'admin')
  WITH CHECK (psat.current_user_role() = 'admin');

COMMENT ON TABLE psat.psat_ujian_penulis IS
  'Guru penanggung jawab matriks satu ujian. Tanpa baris ini, get_tugas_menulis() menampilkan ujian ke SEMUA guru mapel+level tersebut (45 dari 46 kombinasi punya >1 guru) dan jumlah grid mereka melebihi pagu.';

COMMIT;

-- =============================================================================
-- 4. Kosakata tipe: PSAT → LMS
-- =============================================================================
-- Satu sumber kebenaran. Cerminan CASE inline di
-- lms-new/supabase/migrations/20260820_impor_soal_psat.sql:248-250; berkas itu
-- sengaja tidak diubah di sini supaya impor soal tidak ikut terguncang.

BEGIN;

CREATE OR REPLACE FUNCTION psat.tipe_ke_lms(p_tipe text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT CASE p_tipe
           WHEN 'pilgan' THEN 'pilihan_ganda'
           WHEN 'essay'  THEN 'esai'
           ELSE p_tipe   -- ceklist, isian_singkat, benar_salah sama di kedua sisi
         END;
$function$;

-- =============================================================================
-- 5. Jembatan: psat_matrix_input → public.ujian_konfigurasi_bab
-- =============================================================================
-- SECURITY DEFINER karena guru tidak punya — dan tidak boleh diberi — hak tulis
-- langsung ke public.ujian_konfigurasi_bab. Satu-satunya policy tulis guru di
-- tabel itu mensyaratkan ujian.created_by = auth.uid(), yang pasti gagal untuk
-- ujian buatan admin. Fungsi ini menulis atas namanya.
--
-- ⚠️ DEFINER melewati RLS, jadi pemeriksaan di badan fungsi INILAH batas
--    keamanannya. Jangan menambah jalan keluar lebih awal sebelum blok otorisasi.
--
-- Fungsi, bukan trigger di psat_matrix_input: invarian "Σ per bab = pagu" hanya
-- bisa diperiksa saat SELURUH bab diketahui. Trigger per-baris akan menyala di
-- tengah keadaan separuh-jadi dan pasti menolak baris pertama.
--
-- Semua masalah dikumpulkan lebih dulu lalu dilaporkan sekaligus: guru butuh
-- daftar utuh apa yang harus dibetulkan, bukan satu galat per percobaan.

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

  v_role    := psat.current_user_role();
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

  -- ── Bab benar milik ujian ini (cerminan get_bab_ujian) ────────────────────
  IF EXISTS (
    SELECT 1
    FROM psat.psat_matrix_input mi
    JOIN public.ujian u          ON u.id  = mi.ujian_id
    JOIN public.bab_pelajaran bp ON bp.id = mi.bab_id
    WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = v_profile
      AND NOT (bp.ujian_id = mi.ujian_id
               OR (bp.ujian_id IS NULL AND bp.mata_pelajaran_id = u.mata_pelajaran_id))
  ) THEN
    v_masalah := v_masalah || jsonb_build_object(
      'kode',  'bab-di-luar-ujian',
      'pesan', 'Ada bab yang bukan milik ujian maupun mapel ini.');
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

COMMIT;

-- =============================================================================
-- 6. get_tugas_menulis() menghormati penulis yang ditunjuk
-- =============================================================================
-- Badan fungsi disalin dari 20260827000001 baris 253-303, dengan SATU tambahan:
-- filter penulis di bagian bawah. Sisanya sengaja tidak diubah.
--
-- Perilaku tanpa penunjukan sengaja DIPERTAHANKAN (semua guru mapel+level itu
-- melihat tugasnya). Kalau baris penunjukan langsung diwajibkan, seluruh ujian
-- yang sedang berjalan mendadak lenyap dari layar guru sebelum admin sempat
-- menunjuk siapa pun. Jembatanlah yang menolak saat >1 guru submit tanpa
-- penunjukan — menahan kerusakan di tempat yang bisa dijelaskan, bukan dengan
-- mengosongkan layar.

BEGIN;

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
-- 6b. Calon penulis satu ujian
-- =============================================================================
-- Dipakai halaman Patokan untuk mengisi dropdown penunjukan. Irisannya sama
-- dengan yang dipakai get_tugas_menulis (guru_mengajar × mapel × tingkat),
-- supaya yang bisa ditunjuk persis yang memang melihat ujian itu sebagai tugas.

CREATE OR REPLACE FUNCTION psat.get_calon_penulis(p_ujian_id UUID)
RETURNS TABLE (profile_id UUID, nama TEXT, sudah_isi BOOLEAN, ditunjuk BOOLEAN)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $calon$
  WITH a AS (
    SELECT * FROM psat.get_ujian_aktif() WHERE ujian_id = p_ujian_id
  )
  SELECT DISTINCT
    gm.guru_id,
    pr.nama,
    EXISTS (SELECT 1 FROM psat.psat_matrix_input mi
             WHERE mi.ujian_id = p_ujian_id AND mi.profile_id = gm.guru_id),
    EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pen
             WHERE pen.ujian_id = p_ujian_id AND pen.profile_id = gm.guru_id)
  FROM a
  JOIN public.guru_mengajar gm
    ON gm.mapel_id = a.mapel_id
   AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
  JOIN public.profiles pr ON pr.id = gm.guru_id
  ORDER BY pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

-- =============================================================================
-- 7. Gerbang assertion
-- =============================================================================
DO $gate$
DECLARE n int;
BEGIN
  IF to_regprocedure('psat.tipe_ke_lms(text)') IS NULL THEN
    RAISE EXCEPTION 'tipe_ke_lms tidak terbentuk';
  END IF;
  IF to_regprocedure('psat.sinkron_konfigurasi_bab(uuid,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'sinkron_konfigurasi_bab tidak terbentuk';
  END IF;
  IF to_regprocedure('psat.get_calon_penulis(uuid)') IS NULL THEN
    RAISE EXCEPTION 'get_calon_penulis tidak terbentuk';
  END IF;
  IF to_regclass('psat.psat_ujian_penulis') IS NULL THEN
    RAISE EXCEPTION 'psat_ujian_penulis tidak terbentuk';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='psat' AND table_name='psat_matrix_input'
                   AND column_name='bab_id') THEN
    RAISE EXCEPTION 'kolom bab_id tidak terbentuk';
  END IF;

  -- CHECK harus menerima benar_salah sekarang
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid='psat.psat_patokan_ujian'::regclass
                   AND conname='psat_patokan_ujian_tipe_check'
                   AND pg_get_constraintdef(oid) LIKE '%benar_salah%') THEN
    RAISE EXCEPTION 'CHECK tipe belum memuat benar_salah';
  END IF;

  SELECT count(*) INTO n FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
  WHERE c.relname = 'psat_ujian_penulis';
  IF n <> 2 THEN
    RAISE EXCEPTION 'Policy psat_ujian_penulis tidak lengkap: % dari 2', n;
  END IF;
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- =============================================================================
-- Verifikasi sesudah apply
-- =============================================================================
-- 1. benar_salah diterima (harap sukses lalu ROLLBACK):
--      BEGIN;
--      INSERT INTO psat.psat_patokan_ujian (ujian_id, tipe, tingkat_kesulitan, jumlah_keluar, jumlah_bank)
--      SELECT id, 'benar_salah', 'mudah', 1, 1 FROM public.ujian LIMIT 1;
--      ROLLBACK;
--
-- 2. Berapa baris matriks yang berhasil dipetakan ke bab LMS:
--      SELECT count(*) FILTER (WHERE bab_id IS NOT NULL) AS terpetakan,
--             count(*) AS total FROM psat.psat_matrix_input;
--
-- 3. Uji-coba jembatan TANPA menulis apa pun (harap `ok:false` + daftar masalah
--    untuk ujian ICT PROGUL karena dua guru dan belum ada penulis ditunjuk):
--      SELECT psat.sinkron_konfigurasi_bab(
--        '91d90268-bd50-44e2-9662-e2ec1786273c', NULL, true);
--
-- 4. ⚠️ Uji otorisasi WAJIB menyamar — Management API & service-role BYPASS RLS,
--    dan `psat.current_user_role()` membaca auth.uid() sehingga tanpa penyamaran
--    hasilnya menyesatkan. Buktikan penyamaran aktif lebih dulu (current_user
--    harus 'authenticated'), lalu jalankan tiap assersi DUA KALI — sekali dalam
--    varian yang sengaja dirusak — karena `[]` dari Management API berarti
--    "sukses" MAUPUN "tanpa hasil":
--      BEGIN;
--        SET LOCAL ROLE authenticated;
--        SET LOCAL request.jwt.claims = '{"sub":"<uuid-guru-B>"}';
--        SELECT current_user;                       -- harap 'authenticated'
--        SELECT psat.sinkron_konfigurasi_bab('<ujian>', NULL, true);
--        -- guru B mencoba menyinkronkan matriks guru A → harap RAISE 'bukan-admin'
--        SELECT psat.sinkron_konfigurasi_bab('<ujian>', '<uuid-guru-A>', true);
--      ROLLBACK;
--
-- 5. Setelah penulis ditunjuk, guru lain tidak lagi melihat tugasnya:
--      BEGIN;
--        INSERT INTO psat.psat_ujian_penulis (ujian_id, profile_id)
--        VALUES ('91d90268-bd50-44e2-9662-e2ec1786273c',
--                '025ce69b-29e7-4902-a70f-3dd9349dd35f');
--        SET LOCAL ROLE authenticated;
--        SET LOCAL request.jwt.claims = '{"sub":"3df3f0fa-9de1-4fd4-bf62-6803ba1d56ec"}';
--        SELECT count(*) FROM psat.get_tugas_menulis()
--         WHERE ujian_id = '91d90268-bd50-44e2-9662-e2ec1786273c';  -- harap 0
--      ROLLBACK;
