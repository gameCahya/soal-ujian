-- Migration: pencarian penulis berhenti memotong & menyembunyikan
-- Prasyarat: 20260902000001 sudah diapply.
--
-- MASALAH — dua kehilangan senyap, keduanya terlihat sama di layar
-- ("nama itu tidak ada"), padahal sebabnya berbeda:
--
--   1. LIMIT 30. Diukur di produksi: 200 guru, 186 aktif. Ketik "ma" → 72 cocok,
--      30 terkirim. "an" → 66 cocok, 30 terkirim. "ri" → 64 cocok, 30 terkirim.
--      Karena urutannya menurut nama, yang terpotong selalu separuh akhir abjad.
--   2. AND pr.status = 'aktif'. 14 guru berstatus 'nonaktif' atau 'pindah' hilang
--      sama sekali dari hasil.
--
-- PERBAIKAN
--   1. Batas dinaikkan ke 200 (tutup 500). Untuk populasi 200 guru itu berarti
--      TIDAK ADA pemotongan sama sekali; batasnya tinggal jaring pengaman.
--   2. Guru tidak aktif DIKEMBALIKAN, dengan kolom `status` supaya layar bisa
--      mengatakan sebabnya. Menyembunyikannya adalah jawaban yang salah untuk
--      pertanyaan yang benar: tetapkan_penulis memang menolak akun tidak aktif,
--      tapi penolakannya menjelaskan diri ("aktifkan dulu"), sedangkan absennya
--      dari daftar tidak menjelaskan apa pun.
--
-- get_calon_penulis ikut mendapat `status` supaya kedua daftar sebentuk — satu
-- tipe TypeScript melayani keduanya. Ia memang sudah memuat guru tidak aktif
-- (sumbernya guru_mengajar tanpa saringan status); yang berubah cuma status itu
-- jadi terlihat.
--
-- ROLLBACK: supabase/rollback/20260902000002_pencarian_penulis_utuh_rollback.sql

BEGIN;

-- =============================================================================
-- 1. get_calon_penulis(): + kolom status
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
  siap       BOOLEAN,
  mengampu   BOOLEAN,
  status     TEXT
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
    k.ampu_ya,
    pr.status::text
  FROM kandidat k
  JOIN public.profiles pr ON pr.id = k.id
  LEFT JOIN public.sekolah sk ON sk.id = pr.sekolah_id
  ORDER BY k.ampu_ya DESC, pr.nama;
$calon$;

GRANT EXECUTE ON FUNCTION psat.get_calon_penulis(UUID) TO authenticated;

COMMENT ON FUNCTION psat.get_calon_penulis(UUID) IS
  'Guru pengampu mapel+tingkat satu ujian, DITAMBAH penulis yang sudah ditunjuk walau ia bukan pengampu (mengampu = false). Kolom status menjelaskan kenapa sebagian tidak siap ditunjuk.';

-- =============================================================================
-- 2. cari_calon_penulis(): jangan potong, jangan sembunyikan
-- =============================================================================
-- Tipe kembalian berubah (kolom status), jadi DROP dulu.
DROP FUNCTION IF EXISTS psat.cari_calon_penulis(uuid, text, int);

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
    sk.nama,
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

COMMENT ON FUNCTION psat.cari_calon_penulis(uuid, text, int) IS
  'Cari guru mana pun (nama/email/username) untuk ditunjuk jadi penulis matriks. Termasuk guru tidak aktif, ditandai lewat kolom status — menyembunyikannya membuat "kok tidak ketemu" tak punya jawaban di layar. Admin saja.';

-- =============================================================================
-- 3. Gerbang assersi
-- =============================================================================
DO $gate$
DECLARE
  n int;
  d text;
BEGIN
  -- 1 argumen masuk + 9 kolom keluar
  SELECT array_length(p.proallargtypes, 1) INTO n
  FROM pg_proc p WHERE p.oid = to_regprocedure('psat.get_calon_penulis(uuid)');
  IF n IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'get_calon_penulis harus punya kolom status (dapat % entri argumen)', n;
  END IF;

  -- 3 argumen masuk + 9 kolom keluar
  SELECT array_length(p.proallargtypes, 1) INTO n
  FROM pg_proc p WHERE p.oid = to_regprocedure('psat.cari_calon_penulis(uuid,text,integer)');
  IF n IS DISTINCT FROM 12 THEN
    RAISE EXCEPTION 'cari_calon_penulis harus punya kolom status (dapat % entri argumen)', n;
  END IF;

  d := pg_get_functiondef(to_regprocedure('psat.cari_calon_penulis(uuid,text,integer)'));

  -- Inti keluhan "kok belum semua guru": batas lama memotong 72 hasil jadi 30.
  IF d NOT LIKE '%COALESCE(p_limit, 200)%' THEN
    RAISE EXCEPTION 'cari_calon_penulis masih memakai batas lama';
  END IF;

  -- Saringan status harus benar-benar hilang dari klausa WHERE-nya.
  --
  -- LIKE '%AND pr.status = ''aktif''%' TIDAK BOLEH dipakai di sini: pola itu
  -- juga cocok dengan ekspresi `siap` — (pr.is_penulis_soal AND pr.status =
  -- 'aktif') — yang memang harus tetap ada. Jadi yang dicari urutan klausanya:
  -- saringan role langsung disusul saringan status. Pelajaran dari gerbang
  -- 20260902000001 yang tersandung komentarnya sendiri.
  IF d ~ 'role = ''guru''\s*AND\s+pr\.status = ''aktif''' THEN
    RAISE EXCEPTION 'cari_calon_penulis masih menyembunyikan guru tidak aktif';
  END IF;

  RAISE NOTICE 'OK: pencarian penulis tidak lagi memotong di 30 dan tidak menyembunyikan guru tidak aktif';
END
$gate$;

COMMIT;

NOTIFY pgrst, 'reload schema';
