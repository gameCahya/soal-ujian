-- Migration: penulis yang DITUNJUK boleh membuat bab
-- Prasyarat: 20260902000001 (penulis boleh siapa saja) sudah diapply.
--
-- MASALAH
-- Rustikawati ditunjuk sebagai penulis "PTS 1 Mathematics Cambridge LEVEL 8".
-- Ujian itu muncul di daftar tugasnya, dropdown babnya KOSONG (nol bab terlihat
-- untuk ujian itu), dan menekan "Buat bab" ditolak:
--
--   Anda tidak mengampu mata pelajaran ujian ini.   (HINT = 'bukan-pengampu')
--
-- Ia memang tidak mengampunya: guru_mengajar mencatatnya di mapel "Mathematics",
-- sedangkan ujiannya bermapel "Mathematics Cambridge" — dua baris mata_pelajaran
-- yang berbeda. Jalannya buntu total: tak ada bab untuk dipilih, dan tak boleh
-- membuat satu pun.
--
-- SEBABNYA PERUBAHAN 2 SEPTEMBER
-- 20260902000001 memindahkan aturan "siapa yang boleh menulis" dari
-- tetapkan_penulis ke get_tugas_menulis: sejak itu PENUNJUKAN EKSPLISIT yang
-- memberi tugas, dan penunjukan boleh jatuh ke guru mana pun. buat_bab_ujian
-- tertinggal — ia masih satu-satunya pintu yang bertanya "apakah kamu pengampu?"
-- Akibatnya seorang guru bisa memegang tugas yang tidak bisa ia mulai.
--
-- Diukur di produksi hari ini: 39 penunjukan, **12 di antaranya** jatuh ke guru
-- yang bukan pengampu mapel+tingkat ujiannya. Kedua belasnya terkunci dengan
-- cara yang sama; baru satu yang melapor.
--
-- PERBAIKAN
-- Tambahkan cabang "ditunjuk sebagai penulis ujian ini" ke penjaganya. Cabang
-- pengampu SENGAJA dipertahankan: komentar aslinya menyatakan niat itu — bab
-- dipakai bersama dan membuatnya tidak merusak apa pun, jadi guru boleh
-- menyiapkannya SEBELUM ada penunjukan. Yang salah bukan keluasan aturan lama,
-- melainkan bahwa ia melewatkan orang yang justru paling berhak.
--
-- Baris psat_ujian_penulis hanya lahir dari tetapkan_penulis, yang admin-saja.
-- Jadi cabang baru ini berbunyi "admin menaruh kamu sebagai penanggung jawab
-- ujian ini" — lebih sempit dari sebuah peran, bukan lebih longgar.
--
-- Tidak ada pintu lain yang perlu ikut berubah: sinkron_konfigurasi_bab sudah
-- memakai psat_ujian_penulis, dan RLS psat_matrix_input serta psat.bank_soal
-- memakai profile_id/guru_id = auth.uid() — keduanya tidak pernah bertanya soal
-- ampu. buat_bab_ujian adalah satu-satunya yang tertinggal.
--
-- ROLLBACK: supabase/rollback/20260902000006_penulis_ditunjuk_boleh_buat_bab_rollback.sql
-- Cara apply: pnpm db:migrate supabase/migrations/20260902000006_*.sql

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

  -- Otorisasi: admin, ATAU penulis yang ditunjuk untuk ujian ini, ATAU pengampu
  -- mapel+tingkatnya.
  --
  -- Cabang penulis-ditunjuk ditambahkan 2 Sep 2026. Sejak 20260902000001,
  -- penunjukanlah yang memberi tugas menulis — dan penunjukan boleh jatuh ke
  -- guru mana pun, termasuk yang guru_mengajar-nya mencatat mapel bernama lain
  -- ("Mathematics" vs "Mathematics Cambridge"). Tanpa cabang ini, 12 dari 39
  -- penulis memegang tugas yang tidak bisa mereka mulai: dropdown babnya kosong
  -- dan tombol buat-bab menolak mereka.
  --
  -- Cabang pengampu tetap ada dengan sengaja: bab dipakai bersama dan membuatnya
  -- tidak merusak apa pun, jadi guru boleh menyiapkannya sebelum ada penunjukan.
  -- Yang dijaga ketat adalah menulis konfigurasi (sinkron_konfigurasi_bab), yang
  -- memang menolak siapa pun selain penulis yang ditunjuk.
  --
  -- COALESCE wajib: current_user_role() NULL untuk siapa pun tanpa baris aktif
  -- di public.profiles, dan `NULL <> 'admin'` bernilai NULL — penjaganya tidak
  -- akan menyala. Sudah pernah terjadi; jangan dilepas.
  v_role  := COALESCE(psat.current_user_role()::text, '');
  v_level := public.tingkat_ujian(p_ujian_id);

  IF v_role <> 'admin'
     AND NOT EXISTS (
       SELECT 1 FROM psat.psat_ujian_penulis pen
       WHERE pen.ujian_id = p_ujian_id AND pen.profile_id = v_aktor
     )
     AND NOT EXISTS (
       SELECT 1 FROM public.guru_mengajar gm
       WHERE gm.guru_id = v_aktor
         AND gm.mapel_id = v_mapel
         AND (v_level IS NULL
              OR substring(gm.kelas FROM '^[[:space:]]*([0-9])') = v_level)
     ) THEN
    RAISE EXCEPTION 'Anda tidak mengampu mata pelajaran ujian ini dan tidak ditunjuk sebagai penulisnya.'
      USING HINT = 'bukan-pengampu';
  END IF;

  -- Ambil-atau-buat. Cakupannya persis apa yang DILIHAT ujian ini, bukan seluruh
  -- mapel: bab bernama sama milik tingkat lain tidak dikembalikan sebagai
  -- "sudah ada". prioritas memastikan pilihannya deterministik ketika ada lebih
  -- dari satu yang cocok.
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
  'Ambil-atau-buat bab tingkat mapel dari PSAT. Boleh dipanggil admin, penulis yang ditunjuk untuk ujian itu, atau pengampu mapel+tingkatnya.';

-- =============================================================================
-- Gerbang: JALANKAN fungsinya, jangan cuma pandangi definisinya
-- =============================================================================
-- Pelajaran 20260902000003: gerbang struktural (fungsi ada, jumlah kolom, pola
-- di pg_get_functiondef) LOLOS untuk fungsi yang gagal di setiap pemanggilan.
-- Jadi gerbang ini memanggilnya sungguhan, dari kursi guru yang terkunci.
--
-- ⚠️ URUTANNYA MENENTUKAN. Klaim JWT dipasang SEBELUM berpindah peran: sesudah
-- SET LOCAL ROLE authenticated, membaca public.profiles tunduk RLS sehingga
-- subquery pencari id mengembalikan NULL, dan gerbangnya menolak dirinya
-- sendiri. Sudah terjadi sekali.
--
-- INSERT yang dihasilkan uji positif dibatalkan lewat subtransaksi bersarang
-- (BEGIN/EXCEPTION di plpgsql): perubahan basis data mundur, nilai variabel
-- tidak — persis yang dibutuhkan untuk mengukur tanpa meninggalkan jejak.

DO $siapa$
DECLARE
  v_penulis uuid;
  v_ujian   uuid;
BEGIN
  -- Kasus yang dilaporkan, dicari lagi dari data — bukan UUID yang dipatri:
  -- penulis DITUNJUK yang bukan pengampu mapel+tingkat ujiannya.
  SELECT pn.profile_id, pn.ujian_id INTO v_penulis, v_ujian
  FROM psat.psat_ujian_penulis pn
  JOIN public.ujian u ON u.id = pn.ujian_id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.guru_mengajar gm
    WHERE gm.guru_id = pn.profile_id
      AND gm.mapel_id = u.mata_pelajaran_id
      AND (public.tingkat_ujian(u.id) IS NULL
           OR substring(gm.kelas FROM '^[[:space:]]*([0-9])') = public.tingkat_ujian(u.id))
  )
  ORDER BY pn.ujian_id
  LIMIT 1;

  IF v_penulis IS NULL THEN
    RAISE EXCEPTION 'tidak ada penulis-bukan-pengampu di data — gerbang tidak bisa mengukur apa pun';
  END IF;

  PERFORM set_config('psat.uji_penulis', v_penulis::text, true);
  PERFORM set_config('psat.uji_ujian',   v_ujian::text,   true);
END
$siapa$;

SELECT set_config('request.jwt.claims',
  json_build_object('sub', current_setting('psat.uji_penulis'))::text, true);
SET LOCAL ROLE authenticated;

DO $gate$
DECLARE
  v_penulis uuid := current_setting('psat.uji_penulis')::uuid;
  v_ujian   uuid := current_setting('psat.uji_ujian')::uuid;
  v_lain    uuid;
  v_nama    text := '__gerbang_' || gen_random_uuid()::text || '__';
  r         record;
  v_positif text := 'tidak dijalankan';
  v_negatif text := 'tidak dijalankan';
BEGIN
  -- Dibaca lebih dulu: penolakan di bawah bisa berarti penyamarannya gagal,
  -- bukan fungsinya rusak. Bedakan sekarang supaya galatnya tidak menyesatkan.
  IF auth.uid() IS DISTINCT FROM v_penulis THEN
    RAISE EXCEPTION 'penyamaran peran gagal (auth.uid = %) — gerbang tidak mengukur fungsinya',
      COALESCE(auth.uid()::text, 'NULL');
  END IF;

  -- ── Positif: penulis yang ditunjuk HARUS bisa membuat bab ────────────────
  -- Inilah yang gagal sebelum migrasi ini, dengan HINT 'bukan-pengampu'.
  BEGIN
    SELECT * INTO r FROM psat.buat_bab_ujian(v_ujian, v_nama) LIMIT 1;
    v_positif := CASE
      WHEN r.bab_id IS NOT NULL AND NOT r.sudah_ada THEN 'OK'
      ELSE format('bab tidak terbuat (bab_id=%s sudah_ada=%s)', r.bab_id, r.sudah_ada)
    END;
    -- Batalkan INSERT-nya. Nilai v_positif di atas selamat: plpgsql memundurkan
    -- perubahan basis data pada subtransaksi, bukan penetapan variabel.
    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'BATALKAN' THEN
      v_positif := format('DITOLAK (%s) %s', COALESCE(NULLIF(SQLSTATE,''),'?'), SQLERRM);
    END IF;
  END;

  -- ── Negatif: orang yang sama, ujian yang bukan urusannya → tetap ditolak ──
  -- Tanpa ini, penjaga yang dilepas seluruhnya juga akan melewatkan uji positif.
  SELECT u.id INTO v_lain
  FROM public.ujian u
  WHERE u.mata_pelajaran_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM psat.psat_ujian_penulis pn
                    WHERE pn.ujian_id = u.id AND pn.profile_id = v_penulis)
    AND NOT EXISTS (
      SELECT 1 FROM public.guru_mengajar gm
      WHERE gm.guru_id = v_penulis
        AND gm.mapel_id = u.mata_pelajaran_id
        AND (public.tingkat_ujian(u.id) IS NULL
             OR substring(gm.kelas FROM '^[[:space:]]*([0-9])') = public.tingkat_ujian(u.id))
    )
  ORDER BY u.id
  LIMIT 1;

  IF v_lain IS NULL THEN
    RAISE EXCEPTION 'tidak ada ujian pembanding — kendali negatif tidak bisa dijalankan';
  END IF;

  BEGIN
    PERFORM psat.buat_bab_ujian(v_lain, v_nama);
    v_negatif := 'LOLOS PADAHAL HARUS DITOLAK';
    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'BATALKAN' THEN
      v_negatif := CASE WHEN SQLERRM LIKE '%tidak ditunjuk sebagai penulisnya%'
                        THEN 'OK (ditolak)'
                        ELSE format('ditolak dengan alasan lain: %s', SQLERRM) END;
    END IF;
  END;

  IF v_positif <> 'OK' THEN
    RAISE EXCEPTION 'uji positif gagal — penulis ditunjuk masih tidak bisa membuat bab: %', v_positif;
  END IF;
  IF v_negatif <> 'OK (ditolak)' THEN
    RAISE EXCEPTION 'kendali negatif gagal — penjaganya terlalu longgar: %', v_negatif;
  END IF;

  RAISE NOTICE 'OK: penulis ditunjuk (%) bisa membuat bab untuk ujian %, dan tetap ditolak untuk ujian %',
    v_penulis, v_ujian, v_lain;
END
$gate$;

RESET ROLE;

COMMIT;

NOTIFY pgrst, 'reload schema';
