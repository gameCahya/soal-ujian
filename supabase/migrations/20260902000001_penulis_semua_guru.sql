-- Migration: penulis matriks boleh SIAPA SAJA guru, dicari lewat pencarian
-- Prasyarat: 20260901000005 dan 20260901000006 sudah diapply.
--
-- MASALAH
-- Dropdown "Penulis matriks" hanya memuat guru yang mengampu mapel+tingkat ujian
-- itu menurut public.guru_mengajar. Kalau data ampu belum lengkap — dan untuk
-- event ini banyak yang belum — guru yang sebenarnya ditugasi menulis TIDAK ADA
-- di daftar, dan tidak ada jalan lain menunjuknya dari layar mana pun.
--
-- PERBAIKAN
-- Daftar dibuka ke SELURUH guru aktif, dicari lewat nama/email/username. Tapi
-- membuka daftar saja menghasilkan penunjukan yang tampak berhasil lalu mati:
--
--   psat.get_tugas_menulis() menyaring dengan  JOIN ampu  — irisan guru_mengajar.
--   Guru yang ditunjuk tapi tidak mengampu tidak akan pernah melihat tugasnya,
--   dan tidak ada galat di mana pun. Itulah sebabnya penjaga `bukan-calon` di
--   tetapkan_penulis dulu dipasang.
--
-- Jadi penjaga itu tidak cukup dilepas; sumber larangannya yang harus pindah:
-- PENUNJUKAN EKSPLISIT sekarang memberi tugas dengan sendirinya, tidak lagi
-- bergantung pada guru_mengajar. Perilaku tanpa penunjukan tidak berubah sama
-- sekali (semua guru mapel+tingkat itu tetap melihatnya).
--
-- Empat perubahan, satu transaksi — kalau salah satu tertinggal, hasilnya persis
-- penunjukan-yang-mati di atas:
--   1. get_calon_penulis()  + kolom `mengampu`, dan penulis yang sudah ditunjuk
--                             ikut dikembalikan walau ia tidak mengampu (kalau
--                             tidak, layar menampilkan "belum ditunjuk" padahal
--                             sudah)
--   2. cari_calon_penulis() BARU — pencarian lintas seluruh guru aktif, admin saja
--   3. tetapkan_penulis()   penjaga `bukan-calon` dilepas; `mengampu` dilaporkan
--                           balik supaya layar bisa memperingatkan
--   4. get_tugas_menulis()  penunjukan mengalahkan guru_mengajar
--
-- ROLLBACK: supabase/rollback/20260902000001_penulis_semua_guru_rollback.sql

BEGIN;

-- =============================================================================
-- 1. get_calon_penulis(): tambah `mengampu`, dan jangan sembunyikan yang ditunjuk
-- =============================================================================
-- Sesudah daftar dibuka, penulis yang ditunjuk bisa saja bukan pengampu. Fungsi
-- lama membangun barisnya DARI guru_mengajar, jadi orang itu hilang dari hasil
-- dan halaman Patokan menampilkan "— belum ditunjuk —" untuk ujian yang justru
-- sudah punya penulis. Baris penunjukan ditambahkan lewat UNION ALL.
--
-- Tipe kembalian berubah (kolom ke-8), jadi CREATE OR REPLACE tidak cukup.
-- Aman di dalam transaksi: pemanggilnya dibuat ulang sesudah ini.
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

COMMENT ON FUNCTION psat.get_calon_penulis(UUID) IS
  'Guru pengampu mapel+tingkat satu ujian, DITAMBAH penulis yang sudah ditunjuk walau ia bukan pengampu (mengampu = false). Dipakai halaman Patokan untuk isi awal dropdown dan peringatan matriks ganda.';

-- =============================================================================
-- 2. cari_calon_penulis(): pencarian lintas seluruh guru aktif
-- =============================================================================
-- Kenapa fungsi terpisah, bukan parameter di get_calon_penulis: keduanya
-- menjawab pertanyaan berbeda. get_calon_penulis menjawab "siapa yang PANTAS
-- untuk ujian ini" (dipakai memuat 33+ ujian sekaligus saat halaman dibuka);
-- yang ini menjawab "siapa saja yang bernama begini" dan hanya menyala saat
-- admin mengetik. Menggabungkannya berarti setiap muat halaman menyapu ~200
-- profil tanpa perlu.
--
-- plpgsql, bukan sql, supaya penolakan non-admin muncul sebagai GALAT. Versi
-- sql hanya bisa mengembalikan nol baris, dan nol baris di layar terbaca
-- "tidak ada guru bernama itu" — kegagalan senyap yang sudah berkali-kali
-- menyesatkan di project ini.
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

COMMENT ON FUNCTION psat.cari_calon_penulis(uuid, text, int) IS
  'Cari guru aktif mana pun (nama/email/username) untuk ditunjuk jadi penulis matriks satu ujian. Pengampu mapel+tingkat ujian itu diurutkan lebih dulu dan ditandai mengampu = true. Admin saja.';

-- =============================================================================
-- 3. tetapkan_penulis(): penjaga `bukan-calon` dilepas
-- =============================================================================
-- Badan disalin dari 20260901000005 baris 107-188 dengan DUA perubahan:
-- penjaga `bukan-calon` diganti perhitungan `v_mengampu`, dan nilai itu ikut
-- dikembalikan. Penjaga status/role SENGAJA dipertahankan — keduanya benar-benar
-- membuat penunjukan mati (current_user_role() NULL), dan itu tidak bisa
-- diperbaiki oleh penunjukan eksplisit.
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
  v_aktor    uuid := auth.uid();
  v_role     text;
  v_nama     text;
  v_status   text;
  v_prole    text;
  v_flag     boolean;
  v_nyala    boolean := false;
  v_mengampu boolean := false;
BEGIN
  IF v_aktor IS NULL THEN
    RAISE EXCEPTION 'Tidak terautentikasi.' USING HINT = 'tidak-login';
  END IF;

  -- COALESCE wajib: current_user_role() NULL untuk siapa pun tanpa baris aktif
  -- di public.profiles, dan `NULL <> 'admin'` bernilai NULL sehingga penjaganya
  -- tidak menyala. Sudah pernah terjadi di fungsi lain; jangan dilepas.
  v_role := COALESCE(psat.current_user_role()::text, '');
  IF v_role <> 'admin' THEN
    RAISE EXCEPTION 'Hanya admin yang boleh menunjuk penulis matriks.'
      USING HINT = 'bukan-admin';
  END IF;

  SELECT pr.nama, pr.status::text, pr.role::text, pr.is_penulis_soal
    INTO v_nama, v_status, v_prole, v_flag
  FROM public.profiles pr WHERE pr.id = p_profile_id;

  -- NOT FOUND, bukan `v_nama IS NULL`: nama boleh kosong pada profil yang ada.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profil tidak ditemukan.' USING HINT = 'profil-tidak-ada';
  END IF;

  -- status <> 'aktif' membuat current_user_role() NULL — penulis yang ditunjuk
  -- tidak akan melihat tugasnya. Ditolak di muka supaya kegagalannya terlihat
  -- SEKARANG, bukan sebagai laporan "gurunya bilang tidak ada tugas" minggu depan.
  IF v_status IS DISTINCT FROM 'aktif' THEN
    RAISE EXCEPTION 'Akun % berstatus "%" — aktifkan dulu, kalau tidak ia tidak akan melihat tugasnya.',
      COALESCE(v_nama, p_profile_id::text), COALESCE(v_status, 'tidak diketahui')
      USING HINT = 'akun-tidak-aktif';
  END IF;

  IF v_prole IS DISTINCT FROM 'guru' THEN
    RAISE EXCEPTION 'Akun % bukan berperan guru.' , COALESCE(v_nama, p_profile_id::text)
      USING HINT = 'bukan-guru';
  END IF;

  -- Dulu ini penjaga yang MENOLAK (`bukan-calon`). Sekarang cuma keterangan:
  -- get_tugas_menulis() menghormati penunjukan eksplisit, jadi guru yang tidak
  -- mengampu pun benar-benar menerima tugasnya. Nilainya dikembalikan supaya
  -- layar bisa mengatakan apa adanya, bukan menyembunyikannya.
  SELECT EXISTS (
    SELECT 1
    FROM psat.get_ujian_aktif() a
    JOIN public.guru_mengajar gm
      ON gm.mapel_id = a.mapel_id
     AND substring(gm.kelas FROM '^[[:space:]]*([0-9])') = a.level
    WHERE a.ujian_id = p_ujian_id AND gm.guru_id = p_profile_id
  ) INTO v_mengampu;

  -- Inti perbaikan 20260901000005: izin menulis dinyalakan bersamaan dengan
  -- penunjukan. Trigger 20260901000006 menjamin hal yang sama untuk jalur lain.
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
    'izin_baru_dinyalakan', v_nyala,
    'mengampu', v_mengampu
  );
END
$function$;

REVOKE ALL ON FUNCTION psat.tetapkan_penulis(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.tetapkan_penulis(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION psat.tetapkan_penulis(uuid, uuid) IS
  'Menunjuk penulis matriks satu ujian DAN menyalakan is_penulis_soal-nya dalam satu transaksi. Guru mana pun yang aktif boleh ditunjuk; `mengampu` dalam hasil menandai apakah ia memang mengajar mapel+tingkat itu menurut guru_mengajar.';

-- =============================================================================
-- 4. get_tugas_menulis(): penunjukan mengalahkan guru_mengajar
-- =============================================================================
-- Ini bagian yang membuat pembukaan daftar di atas bermakna. Badan disalin dari
-- 20260831000001 baris 419-477; SATU perubahan: JOIN ampu → LEFT JOIN, dan
-- syaratnya ditulis ulang jadi dua cabang yang saling lepas.
--
--   cabang 1  aku ditunjuk untuk ujian ini          → dapat tugas, ampu tak dilihat
--   cabang 2  belum ada penunjukan DAN aku mengampu → perilaku lama, persis
--
-- Tidak ada yang kehilangan tugas karena perubahan ini: kedua cabang lama
-- termuat utuh di dalamnya. `ampu` sudah DISTINCT (mapel_id, level) dan
-- di-join pada kedua kolom, jadi LEFT JOIN mencocokkan paling banyak satu
-- baris — tidak ada penggandaan.
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
  LEFT JOIN ampu am ON am.mapel_id = a.mapel_id AND am.level = a.level
  WHERE EXISTS (
          SELECT 1 FROM psat.psat_ujian_penulis pen
          WHERE pen.ujian_id = a.ujian_id AND pen.profile_id = auth.uid()
        )
     OR (
          am.mapel_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM psat.psat_ujian_penulis pen WHERE pen.ujian_id = a.ujian_id
          )
        )
  ORDER BY a.mapel_nama, a.level;
$$;

GRANT EXECUTE ON FUNCTION psat.get_tugas_menulis() TO authenticated;

COMMENT ON FUNCTION psat.get_tugas_menulis() IS
  'Ujian yang jadi tugas menulis pemanggil: yang ia ditunjuk untuknya (apa pun isi guru_mengajar), atau — bila belum ada penunjukan — yang mapel+tingkatnya ia ampu.';

-- =============================================================================
-- 5. Gerbang assersi
-- =============================================================================
-- Keempat perubahan harus utuh. Kalau salah satu tertinggal hasilnya adalah
-- penunjukan yang tampak berhasil lalu mati tanpa galat — persis keadaan yang
-- migrasi ini hapus.
DO $gate$
DECLARE
  n int;
BEGIN
  IF to_regprocedure('psat.cari_calon_penulis(uuid,text,integer)') IS NULL THEN
    RAISE EXCEPTION 'cari_calon_penulis tidak terbentuk';
  END IF;

  SELECT array_length(p.proallargtypes, 1) INTO n
  FROM pg_proc p WHERE p.oid = to_regprocedure('psat.get_calon_penulis(uuid)');
  -- 1 argumen masuk + 8 kolom keluar
  IF n IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION 'get_calon_penulis harus punya kolom mengampu (dapat % entri argumen)', n;
  END IF;

  IF pg_get_functiondef(to_regprocedure('psat.tetapkan_penulis(uuid,uuid)'))
       LIKE '%bukan-calon%' THEN
    RAISE EXCEPTION 'tetapkan_penulis masih menolak guru non-pengampu';
  END IF;

  IF pg_get_functiondef(to_regprocedure('psat.tetapkan_penulis(uuid,uuid)'))
       NOT LIKE '%is_penulis_soal = true%' THEN
    RAISE EXCEPTION 'tetapkan_penulis tidak lagi menyalakan is_penulis_soal';
  END IF;

  -- Tanpa ini penunjukan tetap mati walau ketiga perubahan lain sudah masuk.
  IF pg_get_functiondef(to_regprocedure('psat.get_tugas_menulis()'))
       NOT LIKE '%LEFT JOIN ampu%' THEN
    RAISE EXCEPTION 'get_tugas_menulis masih mewajibkan guru_mengajar';
  END IF;

  RAISE NOTICE 'OK: penulis boleh siapa saja guru aktif, dan penunjukan memberi tugas dengan sendirinya';
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
