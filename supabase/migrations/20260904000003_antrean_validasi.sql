-- Migration: antrean validasi dihitung di database, bukan ditarik mentah
--
-- MASALAHNYA — SUDAH MENGGIGIT, BUKAN LATEN
-- validasi/page.tsx:161-164 menarik SELURUH soal ber-status submitted /
-- needs_revision / approved tanpa .limit(), .range(), maupun ORDER BY, lalu
-- menghitung ringkasannya di browser. Hari ini:
--     1.873 baris diminta   vs   plafon PostgREST 1.000
-- 873 baris hilang diam-diam, dan baris MANA yang selamat tidak ditentukan
-- karena tidak ada ORDER BY. Ringkasan per ujian dihitung dari sisa yang acak
-- itu, lalu ujian yang jumlahnya jadi nol dibuang filter di :175 — sehingga
-- ujian yang soalnya SUDAH dikirim guru bisa lenyap sama sekali dari antrean
-- validator. Kelas bug yang sama pernah menghilangkan 591 siswa di repo LMS.
--
-- Yang dibutuhkan layar itu cuma HITUNGAN per (ujian, status). Menghitungnya di
-- sini membuat yang menyeberang belasan baris, bukan ribuan — plafonnya tidak
-- lagi bisa tercapai berapa pun soal yang ditulis.
--
-- SEKALIAN DUA HAL YANG SELAMA INI DI KLIEN
-- 1. Saringan tahun. psat.get_ujian_psat() menggabungkan event_ujian TANPA
--    ev.is_active — berbeda dari get_ujian_aktif() yang menyaring. Akibatnya
--    antrean memuat 22 ujian / 1.523 soal tahun 2025/2026 di samping 44 ujian /
--    600 soal tahun ini, dan kartunya tidak menampilkan tahun sama sekali:
--    dua "Qur'an · Kelas 7" dari dua tahun tampak identik. get_ujian_psat()
--    sengaja TIDAK diubah — ia dipakai halaman lain yang memang lintas tahun.
-- 2. Cakupan mapel validator. Dulu disaring di browser setelah data lengkap
--    diambil; sekarang di SQL, jadi soal mapel lain tidak pernah ikut terkirim
--    ke perangkat validator sejak awal.
--
-- ⚠️ Cara apply: Management API
-- ROLLBACK: supabase/rollback/20260904000003_antrean_validasi_rollback.sql

BEGIN;

CREATE OR REPLACE FUNCTION psat.get_antrean_validasi()
RETURNS TABLE (
  ujian_id       uuid,
  ujian_nama     text,
  mapel_id       uuid,
  mapel_nama     text,
  level          text,
  tahun_ajaran   text,
  semester       integer,
  submitted      bigint,
  needs_revision bigint,
  approved       bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
  WITH aktor AS (
    SELECT psat.current_user_role() AS peran, auth.uid() AS uid
  )
  SELECT
    u.id,
    u.nama,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ev.tahun_ajaran,
    ev.semester,
    count(*) FILTER (WHERE b.status = 'submitted'),
    count(*) FILTER (WHERE b.status = 'needs_revision'),
    count(*) FILTER (WHERE b.status = 'approved')
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  JOIN psat.bank_soal b      ON b.ujian_id = u.id
                            AND b.status IN ('submitted', 'needs_revision', 'approved')
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  CROSS JOIN aktor a
  -- Fungsi ini SECURITY DEFINER, jadi ia harus menjaga pintunya sendiri.
  WHERE a.peran IN ('admin'::psat.user_role, 'validator'::psat.user_role)
    AND (
      a.peran = 'admin'::psat.user_role
      OR EXISTS (SELECT 1 FROM psat.psat_validator_mapel v
                 WHERE v.validator_id = a.uid AND v.mapel_id = ma.psat_mapel_id)
    )
  GROUP BY u.id, u.nama, ma.psat_mapel_id, mp.nama, ev.tahun_ajaran, ev.semester
  ORDER BY mp.nama, psat.level_ujian(u.id);
$fn$;

COMMENT ON FUNCTION psat.get_antrean_validasi() IS
  'Antrean validasi: hitungan per (ujian, status) untuk event AKTIF saja, sudah disaring cakupan mapel validator. Menggantikan penarikan seluruh baris bank_soal di klien yang menembus plafon PostgREST 1000.';

GRANT EXECUTE ON FUNCTION psat.get_antrean_validasi() TO authenticated;

-- =============================================================================
-- Gerbang
-- =============================================================================
DO $gate$
DECLARE
  v_admin uuid; v_val uuid; v_guru uuid; v_mapel uuid; v_lain uuid;
  n int; n_lama int; r record; v_beda int;
BEGIN
  SELECT id INTO v_admin FROM public.profiles WHERE role = 'admin' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_val   FROM public.profiles WHERE is_soal_validator LIMIT 1;
  IF v_admin IS NULL OR v_val IS NULL THEN
    RAISE EXCEPTION 'Butuh satu admin dan satu validator untuk menguji';
  END IF;

  -- ── Sebagai ADMIN ────────────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  SELECT count(*) INTO n FROM psat.get_antrean_validasi();
  IF n = 0 THEN
    RAISE EXCEPTION 'Antrean admin kosong — gerbang tidak memeriksa apa pun';
  END IF;

  -- Nol baris boleh berasal dari event yang tidak aktif. Hari ini ada 22 ujian
  -- / 1.523 soal di sana, jadi kalau saringannya mati angkanya melonjak jelas.
  SELECT count(*) INTO n_lama
  FROM psat.get_antrean_validasi() q
  JOIN public.ujian u ON u.id = q.ujian_id
  JOIN public.event_ujian ev ON ev.id = u.event_id
  WHERE NOT ev.is_active;
  IF n_lama <> 0 THEN
    RAISE EXCEPTION '% ujian dari event tidak aktif bocor ke antrean', n_lama;
  END IF;

  -- Hitungannya harus SAMA PERSIS dengan hitungan langsung. Inilah yang
  -- membedakan agregasi yang benar dari yang kebetulan tidak kosong.
  SELECT count(*) INTO v_beda
  FROM psat.get_antrean_validasi() q
  JOIN LATERAL (
    SELECT count(*) FILTER (WHERE b.status = 'submitted')      AS s,
           count(*) FILTER (WHERE b.status = 'needs_revision') AS r,
           count(*) FILTER (WHERE b.status = 'approved')       AS a
    FROM psat.bank_soal b WHERE b.ujian_id = q.ujian_id
  ) x ON true
  WHERE (q.submitted, q.needs_revision, q.approved) IS DISTINCT FROM (x.s, x.r, x.a);
  IF v_beda <> 0 THEN
    RAISE EXCEPTION '% ujian hitungannya meleset dari hitungan langsung', v_beda;
  END IF;

  -- ── Sebagai VALIDATOR ────────────────────────────────────────────────────
  -- Cakupan dibuat sementara di dalam subtransaksi yang dibatalkan: tanpa
  -- penugasan, "hasilnya kosong" tidak membuktikan saringannya bekerja.
  SELECT q.mapel_id INTO v_mapel FROM psat.get_antrean_validasi() q
  WHERE q.mapel_id IS NOT NULL LIMIT 1;
  SELECT q.mapel_id INTO v_lain FROM psat.get_antrean_validasi() q
  WHERE q.mapel_id IS NOT NULL AND q.mapel_id <> v_mapel LIMIT 1;
  IF v_lain IS NULL THEN
    RAISE EXCEPTION 'Butuh dua mapel berbeda di antrean untuk menguji cakupan';
  END IF;

  BEGIN
    INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id) VALUES (v_val, v_mapel);

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_val, 'role', 'authenticated')::text, true);

    SELECT count(*) INTO n FROM psat.get_antrean_validasi() WHERE mapel_id = v_mapel;
    IF n = 0 THEN
      RAISE EXCEPTION 'Validator tidak melihat mapel yang DITUGASKAN kepadanya';
    END IF;

    SELECT count(*) INTO n FROM psat.get_antrean_validasi() WHERE mapel_id <> v_mapel;
    IF n <> 0 THEN
      RAISE EXCEPTION 'Validator melihat % ujian mapel yang bukan cakupannya', n;
    END IF;

    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'BATALKAN' THEN RAISE; END IF;
  END;

  -- ── Guru biasa tidak boleh melihat apa pun ───────────────────────────────
  -- Gurunya sengaja DIBERI baris cakupan lebih dulu. Tanpa itu ia tertahan
  -- syarat cakupan, bukan pintu perannya — dan assersinya lolos walau pintu
  -- perannya dicopot. (Terbukti: sabotase "WHERE true" pertama kali lolos.)
  SELECT id INTO v_guru FROM public.profiles
  WHERE role = 'guru' AND is_penulis_soal AND NOT is_soal_validator LIMIT 1;
  IF v_guru IS NULL THEN
    RAISE EXCEPTION 'Butuh satu guru penulis non-validator untuk menguji pintu peran';
  END IF;

  BEGIN
    INSERT INTO psat.psat_validator_mapel (validator_id, mapel_id) VALUES (v_guru, v_mapel);

    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_guru, 'role', 'authenticated')::text, true);

    SELECT count(*) INTO n FROM psat.get_antrean_validasi();
    IF n <> 0 THEN
      RAISE EXCEPTION 'Guru penulis (walau punya baris cakupan) melihat % baris antrean', n;
    END IF;

    RAISE EXCEPTION 'BATALKAN';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'BATALKAN' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'Gerbang lolos: antrean bercakupan benar, hitungan cocok, event lama tersaring.';
END
$gate$;

COMMIT;
