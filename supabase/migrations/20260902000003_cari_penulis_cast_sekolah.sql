-- Migration: cari_calon_penulis gagal di runtime — sk.nama varchar vs TEXT
-- Prasyarat: 20260902000002 sudah diapply.
--
-- MASALAH
--   ERROR 42804: structure of query does not match function result type
--   DETAIL:  Returned type character varying(255) does not match expected type
--            text in column 5.
--
-- public.sekolah.nama bertipe varchar(255); seluruh kolom lain yang dipakai
-- fungsi ini bertipe text. RETURNS TABLE menyatakan kolom 5 (`sekolah`) TEXT.
--
-- Kenapa hanya pencarian yang mati, padahal get_calon_penulis memakai ekspresi
-- yang sama: LANGUAGE sql melakukan assignment cast di keluarannya, sedangkan
-- RETURN QUERY di plpgsql menuntut tipe yang persis sama. Dua fungsi, ekspresi
-- kembar, satu jalan satu tidak.
--
-- KENAPA LOLOS DUA MIGRASI
-- Gerbang assersi 20260902000001 dan ...0002 memeriksa STRUKTUR (fungsi ada,
-- jumlah kolom, pola di pg_get_functiondef) dan tidak pernah MEMANGGIL
-- fungsinya. Uji perilaku 000001 pun hanya menguji jalur penolakan non-admin,
-- yang menyala di baris pertama — jauh sebelum RETURN QUERY. Jadi jalur
-- suksesnya belum pernah dieksekusi sekali pun sejak dibuat.
--
-- Karena itu migrasi ini menambahkan gerbang yang MENJALANKAN fungsinya dengan
-- penyamaran peran admin dan memeriksa jumlah barisnya. Gerbang itu akan gagal
-- pada definisi hari ini (galat tipe) maupun pada batas lama (tepat 30 baris) —
-- itu yang menjadikannya pengukuran, bukan formalitas.
-- Lihat [[feedback-buktikan-uji-benar-jalan]].
--
-- ROLLBACK: tidak disediakan. Mundur dari sini berarti mengembalikan fungsi
-- yang GAGAL di setiap pemanggilan; supabase/rollback/20260902000002_*.sql
-- sudah cukup kalau memang mau kembali ke keadaan sebelum kedua migrasi ini.

BEGIN;

CREATE OR REPLACE FUNCTION psat.cari_calon_penulis(
  p_ujian_id UUID,
  p_q        TEXT DEFAULT NULL,
  -- 200 = seluruh populasi guru saat ini. Bukan angka bulat asal: dengan 186
  -- guru aktif, batas 30 memotong hampir tiap ketikan dua huruf.
  p_limit    INT  DEFAULT 200
)
RETURNS TABLE (
  profile_id UUID,
  nama       TEXT,
  sudah_isi  BOOLEAN,
  ditunjuk   BOOLEAN,
  sekolah    TEXT,
  jml_kelas  BIGINT,
  siap       BOOLEAN,
  mengampu   BOOLEAN,
  status     TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'psat', 'public', 'pg_temp'
AS $cari$
DECLARE
  v_pola  text;
  v_batas int := greatest(1, least(COALESCE(p_limit, 200), 500));
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
    -- ::text WAJIB. public.sekolah.nama varchar(255); RETURN QUERY menuntut
    -- tipe persis, tidak seperti LANGUAGE sql yang mengecast sendiri.
    sk.nama::text,
    COALESCE(am.jml, 0::bigint),
    (pr.is_penulis_soal AND pr.status = 'aktif'),
    (am.guru_id IS NOT NULL),
    pr.status::text
  FROM public.profiles pr
  LEFT JOIN ampu am           ON am.guru_id = pr.id
  LEFT JOIN public.sekolah sk ON sk.id = pr.sekolah_id
  -- Saringan status SENGAJA dilepas. 14 guru 'nonaktif'/'pindah' dulu lenyap
  -- tanpa keterangan; sekarang mereka muncul dan layar menyebut sebabnya.
  -- tetapkan_penulis tetap menolak mereka — dengan pesan yang menjelaskan.
  WHERE pr.role = 'guru'
    AND (pr.nama ILIKE v_pola
      OR pr.email ILIKE v_pola
      OR COALESCE(pr.username, '') ILIKE v_pola)
  -- Pengampu dulu, lalu yang akunnya aktif, baru menurut nama. Urutan ini yang
  -- menentukan siapa yang terpotong kalau batasnya sampai kena.
  ORDER BY (am.guru_id IS NOT NULL) DESC,
           (pr.status = 'aktif') DESC,
           pr.nama NULLS LAST
  LIMIT v_batas;
END
$cari$;

REVOKE ALL ON FUNCTION psat.cari_calon_penulis(uuid, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION psat.cari_calon_penulis(uuid, text, int) TO authenticated;

-- =============================================================================
-- Gerbang: JALANKAN fungsinya, jangan cuma pandangi definisinya
-- =============================================================================
-- Penyamaran peran wajib — fungsinya menolak siapa pun yang current_user_role()
-- nya bukan 'admin', dan sebagai pemilik migrasi auth.uid() bernilai NULL.
--
-- ⚠️ URUTANNYA MENENTUKAN. Klaim JWT harus dipasang SEBELUM berpindah peran:
-- sesudah SET LOCAL ROLE authenticated, membaca public.profiles tunduk pada RLS
-- dan — karena klaimnya belum ada — subquery pencari id admin mengembalikan
-- NULL. Hasilnya `{"sub": null}`, auth.uid() NULL, dan gerbangnya menolak
-- dirinya sendiri dengan 'bukan-admin'. Sudah terjadi sekali di migrasi ini.
SELECT set_config(
  'request.jwt.claims',
  json_build_object('sub',
    (SELECT id FROM public.profiles
      WHERE role = 'admin' AND status = 'aktif' ORDER BY id LIMIT 1))::text,
  true);
SET LOCAL ROLE authenticated;

DO $asap$
DECLARE
  v_ujian uuid;
  n_ma    int;
  n_mati  int;
  n_batas int;
BEGIN
  -- Dibaca lebih dulu: 'bukan-admin' di bawah bisa berarti penyamarannya gagal,
  -- bukan fungsinya rusak. Bedakan sekarang supaya galatnya tidak menyesatkan.
  IF COALESCE(psat.current_user_role()::text, '') <> 'admin' THEN
    RAISE EXCEPTION 'penyamaran peran gagal (current_user_role = %) — gerbang tidak mengukur fungsinya',
      COALESCE(psat.current_user_role()::text, 'NULL');
  END IF;

  SELECT ujian_id INTO v_ujian FROM psat.get_ujian_aktif() LIMIT 1;
  IF v_ujian IS NULL THEN
    RAISE EXCEPTION 'tidak ada ujian aktif — gerbang tidak bisa mengukur apa pun';
  END IF;

  -- Diukur di produksi: 72 guru cocok dengan "ma". Batas lama memberi tepat 30,
  -- dan definisi bercacat cast melempar 42804 sebelum sampai ke sini.
  SELECT count(*) INTO n_ma FROM psat.cari_calon_penulis(v_ujian, 'ma', 500);
  IF n_ma <= 30 THEN
    RAISE EXCEPTION 'cari_calon_penulis("ma") = % baris — masih terpotong', n_ma;
  END IF;

  -- Guru tidak aktif harus benar-benar ikut, bukan sekadar tidak disaring di teks.
  SELECT count(*) INTO n_mati
  FROM psat.cari_calon_penulis(v_ujian, 'a', 500) c WHERE c.status <> 'aktif';
  IF n_mati = 0 THEN
    RAISE EXCEPTION 'tidak ada guru tidak-aktif di hasil — saringan status masih bekerja';
  END IF;

  -- Batasnya harus tetap mengikat kalau diminta kecil, bukan diabaikan.
  SELECT count(*) INTO n_batas FROM psat.cari_calon_penulis(v_ujian, 'a', 5);
  IF n_batas <> 5 THEN
    RAISE EXCEPTION 'p_limit tidak dihormati: minta 5, dapat %', n_batas;
  END IF;

  RAISE NOTICE 'OK: "ma"=% baris, tidak-aktif=% baris, p_limit=5 dihormati',
    n_ma, n_mati;
END
$asap$;

RESET ROLE;

COMMIT;

NOTIFY pgrst, 'reload schema';
