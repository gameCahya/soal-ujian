-- =============================================================================
-- Perbaikan kunci soal validator
-- =============================================================================
-- MASALAH YANG DIPERBAIKI
--
-- 1. `kunci_soal()` mengizinkan penguncian soal berstatus apa pun — termasuk
--    `approved` — sehingga kunci bisa nyangkut di soal yang sudah selesai.
-- 2. `lepas_kunci()` tidak memberi tahu apakah ada baris yang benar-benar
--    dilepas. UI menampilkan "Kunci dilepas" walau kunci milik orang lain
--    tidak tersentuh.
-- 3. Kunci tidak pernah dibersihkan saat kedaluwarsa; baris lama tetap
--    menyimpan `locked_by` selamanya.
-- 4. EXECUTE diberikan ke PUBLIC/anon. Pemeriksaan peran di dalam fungsi
--    menolak, tetapi haknya tidak seharusnya diberikan sejak awal.
-- 5. Definisi kunci/hash tidak pernah masuk migrasi (drift produksi vs repo).
--
-- ATURAN BARU
--   * `submitted`       → validator mana pun boleh mengunci.
--   * `needs_revision`  → hanya validator yang menolaknya (`rejected_by`) atau admin.
--   * `approved`        → hanya validator yang menyetujuinya (`approved_by`) atau admin.
--   * status lain (draft) → ditolak.
--   * Kunci kedaluwarsa 10 menit; pengunci yang sama boleh memperbarui.
--   * Perubahan status oleh siapa pun melepas kunci.
--   * Guru (atau pengguna tanpa peran validator/admin) diblokir saat kunci aktif.
--
-- ROLLBACK: supabase/rollback/20261124000001_kunci_soal_perbaikan_rollback.sql

BEGIN;

-- ── 0. Kolom (idempoten; produksi sudah punya) ───────────────────────────────
ALTER TABLE psat.bank_soal
  ADD COLUMN IF NOT EXISTS locked_by   uuid,
  ADD COLUMN IF NOT EXISTS locked_at   timestamptz,
  ADD COLUMN IF NOT EXISTS content_hash text,
  ADD COLUMN IF NOT EXISTS approved_by uuid,
  ADD COLUMN IF NOT EXISTS rejected_by uuid;

COMMENT ON COLUMN psat.bank_soal.locked_by IS
  'Validator yang sedang memeriksa soal. Kunci kedaluwarsa 10 menit.';
COMMENT ON COLUMN psat.bank_soal.locked_at IS
  'Waktu kunci diambil. Kunci dianggap kedaluwarsa setelah 10 menit.';
COMMENT ON COLUMN psat.bank_soal.content_hash IS
  'MD5 isi soal; dipakai mendeteksi perubahan isi oleh guru saat validasi.';

-- ── 1. Bersihkan kunci kedaluwarsa ──────────────────────────────────────────
UPDATE psat.bank_soal
   SET locked_by = NULL, locked_at = NULL
 WHERE locked_by IS NOT NULL
   AND (locked_at IS NULL OR locked_at < now() - interval '10 minutes');

-- ── 2. Hash isi soal + trigger ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION psat.set_hash_soal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
BEGIN
  NEW.content_hash := md5(concat_ws('|',
    coalesce(NEW.pertanyaan,''),
    coalesce(NEW.tipe,''),
    coalesce(NEW.tingkat_kesulitan,''),
    coalesce(NEW.bobot::text,''),
    coalesce(NEW.bab_id_text,''),
    coalesce(NEW.pilihan::text,''),
    coalesce(NEW.pilihan_gambar::text,''),
    coalesce(NEW.jawaban_benar::text,''),
    coalesce(NEW.rubrik::text,''),
    coalesce(NEW.gambar_url,''),
    coalesce(NEW.items::text,'')));
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS psat_bank_soal_hash ON psat.bank_soal;
CREATE TRIGGER psat_bank_soal_hash
  BEFORE INSERT OR UPDATE ON psat.bank_soal
  FOR EACH ROW EXECUTE FUNCTION psat.set_hash_soal();

-- ── 3. Penjaga: kunci melepas saat status berubah, guru diblokir ────────────
CREATE OR REPLACE FUNCTION psat.cegah_ubah_soal_terkunci()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
DECLARE
  peran psat.user_role := psat.current_user_role();
BEGIN
  -- Perubahan status selalu melepas kunci, apa pun perannya. Tanpa ini, kunci
  -- bisa tertinggal di soal yang sudah approved/revisi.
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.locked_by := NULL;
    NEW.locked_at := NULL;
    RETURN NEW;
  END IF;

  -- Pengguna biasa (guru, atau profil tanpa peran PSAT) tidak boleh mengubah
  -- soal selama kunci aktif. Service role / migrasi (auth.uid() null) dikecualikan.
  IF auth.uid() IS NOT NULL
     AND coalesce(peran::text, '') NOT IN ('validator', 'admin')
     AND OLD.locked_by IS NOT NULL
     AND OLD.locked_at IS NOT NULL
     AND OLD.locked_at > now() - interval '10 minutes' THEN
    RAISE EXCEPTION 'Soal sedang divalidasi oleh validator.'
      USING ERRCODE = '42501',
            HINT = 'Tunggu validator selesai atau sekitar 10 menit sampai kunci kedaluwarsa.';
  END IF;

  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS psat_bank_soal_terkunci ON psat.bank_soal;
CREATE TRIGGER psat_bank_soal_terkunci
  BEFORE UPDATE ON psat.bank_soal
  FOR EACH ROW EXECUTE FUNCTION psat.cegah_ubah_soal_terkunci();

-- ── 4. kunci_soal: batasi status, kembalikan status ─────────────────────────
-- Tipe kembalian berubah, jadi fungsi lama harus dibuang lebih dulu.
DROP FUNCTION IF EXISTS psat.kunci_soal(uuid);

CREATE FUNCTION psat.kunci_soal(p_id uuid)
RETURNS TABLE (locked_by uuid, locked_at timestamptz, status psat.soal_status)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
DECLARE
  peran       psat.user_role := psat.current_user_role();
  v_status    psat.soal_status;
  v_approved  uuid;
  v_rejected  uuid;
BEGIN
  IF peran NOT IN ('validator', 'admin') THEN
    RAISE EXCEPTION 'Hanya validator/admin yang dapat mengunci soal.'
      USING ERRCODE = '42501';
  END IF;

  SELECT b.status, b.approved_by, b.rejected_by
    INTO v_status, v_approved, v_rejected
  FROM psat.bank_soal b
  WHERE b.id = p_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Soal tidak ditemukan.' USING ERRCODE = 'P0002';
  END IF;

  IF peran = 'validator' THEN
    IF v_status = 'submitted' THEN
      NULL; -- semua validator boleh mengunci soal yang menunggu validasi
    ELSIF v_status = 'needs_revision' AND v_rejected = auth.uid() THEN
      NULL; -- hanya penolak yang boleh membatalkan penolakannya
    ELSIF v_status = 'approved' AND v_approved = auth.uid() THEN
      NULL; -- hanya penyetuju yang boleh membatalkan approval
    ELSE
      RAISE EXCEPTION 'Soal berstatus % tidak bisa Anda kunci.', v_status
        USING ERRCODE = '42501',
              HINT = 'Hanya soal yang menunggu validasi, atau keputusan yang Anda buat sendiri.';
    END IF;
  END IF;

  UPDATE psat.bank_soal b
     SET locked_by = auth.uid(), locked_at = now()
   WHERE b.id = p_id
     AND (b.locked_by IS NULL
          OR b.locked_by = auth.uid()
          OR b.locked_at IS NULL
          OR b.locked_at < now() - interval '10 minutes');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Soal sedang dikunci validator lain.'
      USING ERRCODE = '42501',
            HINT = 'Tunggu sekitar 10 menit sampai kunci kedaluwarsa, atau minta admin melepasnya.';
  END IF;

  RETURN QUERY
  SELECT b.locked_by, b.locked_at, b.status
  FROM psat.bank_soal b WHERE b.id = p_id;
END
$fn$;

COMMENT ON FUNCTION psat.kunci_soal(uuid) IS
  'Mengunci soal untuk validasi selama 10 menit. Menolak status yang bukan hak pemanggil.';

-- ── 5. lepas_kunci: kembalikan jumlah baris yang dilepas ────────────────────
DROP FUNCTION IF EXISTS psat.lepas_kunci(uuid);

CREATE FUNCTION psat.lepas_kunci(p_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $fn$
DECLARE
  peran psat.user_role := psat.current_user_role();
  n     integer;
BEGIN
  IF peran NOT IN ('validator', 'admin') THEN
    RAISE EXCEPTION 'Hanya validator/admin yang dapat melepas kunci.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE psat.bank_soal
     SET locked_by = NULL, locked_at = NULL
   WHERE id = p_id
     AND (locked_by = auth.uid() OR peran = 'admin');

  GET DIAGNOSTICS n = row_count;
  RETURN n;
END
$fn$;

COMMENT ON FUNCTION psat.lepas_kunci(uuid) IS
  'Melepas kunci soal. Validator hanya kuncinya sendiri; admin semua. Mengembalikan jumlah baris.';

-- ── 6. Hak akses: hanya pengguna masuk ──────────────────────────────────────
REVOKE ALL ON FUNCTION psat.kunci_soal(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION psat.lepas_kunci(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION psat.kunci_soal(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION psat.lepas_kunci(uuid) TO authenticated;

-- ── 7. Index untuk pencarian kunci ──────────────────────────────────────────
CREATE INDEX IF NOT EXISTS bank_soal_lock_idx
  ON psat.bank_soal (locked_by)
  WHERE locked_by IS NOT NULL;

-- ── 8. Gerbang ──────────────────────────────────────────────────────────────
DO $gate$
DECLARE
  v_kunci int;
  v_lepas int;
BEGIN
  IF to_regprocedure('psat.kunci_soal(uuid)') IS NULL
     OR to_regprocedure('psat.lepas_kunci(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Fungsi kunci_soal/lepas_kunci tidak terbentuk';
  END IF;

  -- lepas_kunci harus mengembalikan integer
  IF (SELECT prorettype FROM pg_proc WHERE oid = to_regprocedure('psat.lepas_kunci(uuid)'))
       <> 'int4'::regtype THEN
    RAISE EXCEPTION 'lepas_kunci tidak mengembalikan integer';
  END IF;

  -- tidak boleh ada EXECUTE untuk anon
  SELECT count(*) INTO v_kunci
  FROM information_schema.routine_privileges
  WHERE routine_schema='psat' AND routine_name='kunci_soal' AND grantee='anon';
  IF v_kunci > 0 THEN
    RAISE EXCEPTION 'anon masih boleh mengeksekusi kunci_soal';
  END IF;

  SELECT count(*) INTO v_lepas
  FROM information_schema.routine_privileges
  WHERE routine_schema='psat' AND routine_name='lepas_kunci' AND grantee='anon';
  IF v_lepas > 0 THEN
    RAISE EXCEPTION 'anon masih boleh mengeksekusi lepas_kunci';
  END IF;

  RAISE NOTICE 'Gerbang lolos: kunci soal dibatasi status, lepas_kunci mengembalikan jumlah, anon dicabut.';
END
$gate$;

COMMIT;
