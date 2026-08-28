-- =============================================================================
-- PSAT: cakupan ujian & kelas
-- =============================================================================
-- Memberi PSAT dua dimensi yang selama ini hilang: siklus/ujian dan kelas.
-- Keduanya sudah dimodelkan di schema `public` (repo lms-new) lewat
-- event_ujian → ujian → ujian_kelas, jadi PSAT menumpang ke sana alih-alih
-- membuat entitas sendiri.
--
-- Pembagian kerja (keputusan): super admin menetapkan TOTAL soal per
-- tipe × kesulitan untuk satu ujian; guru yang memecahnya ke bab.
-- Karena itu target keluar DAN bank sama-sama tinggal di schema psat —
-- public.ujian_konfigurasi_bab menyimpan angka per bab, yang di alur ini
-- justru hasil keputusan guru, bukan masukannya.
--
-- Terapkan ketiga migrasi cakupan-ujian berurutan:
--   pnpm db:migrate:ujian
-- Jangan menjalankan seluruh folder migrasi: berkas init memanggil
-- ALTER TABLE psat.profiles ENABLE ROW LEVEL SECURITY, dan sejak psat.profiles
-- berupa VIEW perintah itu pasti gagal.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. Jembatan identitas mapel: psat.mata_pelajaran ↔ public.mata_pelajaran
-- =============================================================================
-- 14 dari 20 mapel PSAT memakai UUID yang sama dengan padanannya di public.
-- Namanya pun sama persis di kedua schema — tidak ada beda penamaan lintas-schema.
--
-- Yang beda ada DI DALAM psat.mata_pelajaran sendiri: ada baris ganda untuk dua
-- mapel. Ujian menunjuk baris yang satu, guru memakai baris yang lain:
--   ujian "Indonesia" (juga ada di public)  ← guru memakai "Bahasa Indonesia"
--   ujian "Social"    (juga ada di public)  ← guru memakai "IPS"
-- Tanpa pemetaan ini, soal & matrix kedua mapel itu tidak akan ketemu ujiannya.
-- Baris mapel sengaja TIDAK digabung — terlalu berisiko dan di luar cakupan.

CREATE TABLE IF NOT EXISTS psat.mapel_alias (
  public_mapel_id UUID PRIMARY KEY,
  psat_mapel_id   UUID NOT NULL REFERENCES psat.mata_pelajaran(id) ON DELETE CASCADE,
  catatan         TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE psat.mapel_alias IS
  'Peta id mata pelajaran public.mata_pelajaran → psat.mata_pelajaran. Dipakai backfill dan RPC.';

-- Baris identitas: id yang sama di kedua schema
INSERT INTO psat.mapel_alias (public_mapel_id, psat_mapel_id, catatan)
SELECT pm.id, pm.id, 'identitas (id sama di kedua schema)'
FROM public.mata_pelajaran pm
JOIN psat.mata_pelajaran sm ON sm.id = pm.id
ON CONFLICT (public_mapel_id) DO NOTHING;

-- Dua baris ganda di dalam psat: arahkan mapel milik ujian ke mapel milik guru.
-- DO UPDATE, bukan DO NOTHING, karena baris identitas di atas sudah menempati
-- kunci yang sama dan justru itu yang perlu ditimpa.
INSERT INTO psat.mapel_alias (public_mapel_id, psat_mapel_id, catatan)
SELECT pm.id, sm.id, format('sinonim: mapel ujian "%s" → mapel guru "%s"', pm.nama, sm.nama)
FROM psat.mata_pelajaran pm
JOIN psat.mata_pelajaran sm
  ON ((pm.nama = 'Indonesia' AND sm.nama = 'Bahasa Indonesia')
   OR (pm.nama = 'Social'    AND sm.nama = 'IPS'))
 AND sm.id <> pm.id
WHERE EXISTS (SELECT 1 FROM public.mata_pelajaran x WHERE x.id = pm.id)
ON CONFLICT (public_mapel_id) DO UPDATE
  SET psat_mapel_id = EXCLUDED.psat_mapel_id,
      catatan       = EXCLUDED.catatan;

-- =============================================================================
-- 2. Helper: level (tingkat) sebuah ujian
-- =============================================================================
-- ujian.kelas NULL di semua baris; level ada di ujian_kelas.kelas sebagai nama
-- rombel ("7A", "8H", "9 RUBY"). Ambil digit di AWAL string, bukan digit
-- pertama yang ditemukan di mana saja. Nama ujian ("... LEVEL 8 ...") dipakai
-- lebih dulu bila ada; kalau tidak, pakai modus digit awal rombelnya —
-- ini yang membuat satu ujian dengan rombel campur tidak menghasilkan level ganda.

CREATE OR REPLACE FUNCTION psat.level_ujian(p_ujian_id UUID)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT COALESCE(
    (
      SELECT substring(u.nama FROM 'LEVEL[[:space:]]*([0-9])')
      FROM public.ujian u
      WHERE u.id = p_ujian_id
    ),
    (
      SELECT substring(uk.kelas FROM '^[[:space:]]*([0-9])')
      FROM public.ujian_kelas uk
      WHERE uk.ujian_id = p_ujian_id
        AND substring(uk.kelas FROM '^[[:space:]]*([0-9])') IS NOT NULL
      GROUP BY substring(uk.kelas FROM '^[[:space:]]*([0-9])')
      ORDER BY COUNT(*) DESC, 1
      LIMIT 1
    )
  );
$$;

GRANT EXECUTE ON FUNCTION psat.level_ujian(UUID) TO anon, authenticated;

-- =============================================================================
-- 3. Target soal per ujian (pengganti psat_patokan_soal)
-- =============================================================================
-- psat_patokan_soal menyimpan empat string ber-koma yang harus sejajar
-- indeksnya (tipe, tingkat_kesulitan, keluar, bank). Encoding itu ditinggalkan;
-- di sini satu baris = satu sel matrix.

CREATE TABLE IF NOT EXISTS psat.psat_patokan_ujian (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ujian_id          UUID NOT NULL REFERENCES public.ujian(id) ON DELETE CASCADE,
  tipe              TEXT NOT NULL,
  tingkat_kesulitan TEXT NOT NULL,
  jumlah_keluar     INTEGER NOT NULL DEFAULT 0 CHECK (jumlah_keluar >= 0),
  jumlah_bank       INTEGER NOT NULL DEFAULT 0 CHECK (jumlah_bank >= 0),
  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (ujian_id, tipe, tingkat_kesulitan),
  CHECK (tipe IN ('pilgan', 'ceklist', 'isian_singkat', 'essay')),
  CHECK (tingkat_kesulitan IN ('mudah', 'sedang', 'sulit')),
  CHECK (jumlah_keluar <= jumlah_bank)
);

CREATE INDEX IF NOT EXISTS idx_patokan_ujian ON psat.psat_patokan_ujian(ujian_id);

DROP TRIGGER IF EXISTS trg_patokan_ujian_updated_at ON psat.psat_patokan_ujian;
CREATE TRIGGER trg_patokan_ujian_updated_at
  BEFORE UPDATE ON psat.psat_patokan_ujian
  FOR EACH ROW EXECUTE FUNCTION psat.set_updated_at();

-- created_by menunjuk auth.users, bukan psat.profiles: psat.profiles kini
-- berupa VIEW di atas public.profiles, jadi tidak bisa jadi target foreign key.

-- =============================================================================
-- 4. Kolom ujian_id pada tabel yang sudah ada
-- =============================================================================

ALTER TABLE psat.psat_matrix_input
  ADD COLUMN IF NOT EXISTS ujian_id UUID REFERENCES public.ujian(id) ON DELETE CASCADE;

ALTER TABLE psat.bank_soal
  ADD COLUMN IF NOT EXISTS ujian_id UUID REFERENCES public.ujian(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_matrix_ujian ON psat.psat_matrix_input(ujian_id);
CREATE INDEX IF NOT EXISTS idx_soal_ujian   ON psat.bank_soal(ujian_id);

-- Satu bab hanya boleh muncul sekali per (guru, ujian). Selama ujian_id masih
-- NULL constraint ini tidak menggigit (NULL dianggap berbeda di Postgres);
-- begitu backfill jalan, duplikat akan menggagalkan transaksi — memang itu
-- yang diinginkan.
DO $$ BEGIN
  ALTER TABLE psat.psat_matrix_input
    ADD CONSTRAINT psat_matrix_input_profile_ujian_bab_key
    UNIQUE (profile_id, ujian_id, bab_id_text);
EXCEPTION WHEN duplicate_table OR duplicate_object THEN NULL; END $$;

-- =============================================================================
-- 5. Grant & RLS
-- =============================================================================
-- ALTER DEFAULT PRIVILEGES di migrasi init hanya berlaku untuk role yang
-- menjalankannya; grant eksplisit di sini supaya tabel baru tetap terjangkau
-- kalau migrasi dijalankan role lain.

GRANT ALL ON psat.psat_patokan_ujian TO postgres, anon, authenticated, service_role;
GRANT ALL ON psat.mapel_alias        TO postgres, anon, authenticated, service_role;


ALTER TABLE psat.psat_patokan_ujian ENABLE ROW LEVEL SECURITY;
ALTER TABLE psat.mapel_alias        ENABLE ROW LEVEL SECURITY;

-- Target dibaca siapa pun yang sudah login (guru perlu tahu targetnya),
-- tapi hanya admin yang boleh menulis. Ini sekaligus menutup celah lama:
-- policy "patokan_own_or_staff" memberi validator akses FOR ALL ke patokan.
DROP POLICY IF EXISTS "patokan_ujian_read" ON psat.psat_patokan_ujian;
CREATE POLICY "patokan_ujian_read" ON psat.psat_patokan_ujian
  FOR SELECT USING (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS "patokan_ujian_admin_write" ON psat.psat_patokan_ujian;
CREATE POLICY "patokan_ujian_admin_write" ON psat.psat_patokan_ujian
  FOR ALL
  USING (psat.current_user_role() = 'admin')
  WITH CHECK (psat.current_user_role() = 'admin');

DROP POLICY IF EXISTS "mapel_alias_read" ON psat.mapel_alias;
CREATE POLICY "mapel_alias_read" ON psat.mapel_alias
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "mapel_alias_admin_write" ON psat.mapel_alias;
CREATE POLICY "mapel_alias_admin_write" ON psat.mapel_alias
  FOR ALL
  USING (psat.current_user_role() = 'admin')
  WITH CHECK (psat.current_user_role() = 'admin');

-- =============================================================================
-- 6. RPC baca data LMS
-- =============================================================================
-- Tabel di schema public tertutup RLS untuk anon (dicek: HTTP 200 / 0 baris),
-- dan tidak ada jaminan role `authenticated` diizinkan. Jadi PSAT tidak
-- menyentuh tabel LMS langsung dari browser — semua lewat SECURITY DEFINER
-- di schema psat, pola yang sudah dipakai di seluruh repo ini. Efek sampingnya
-- bagus: lms-new tidak perlu diubah sama sekali.

-- Ujian pada siklus aktif yang soalnya ditentukan super admin (UTS/UAS).
CREATE OR REPLACE FUNCTION psat.get_ujian_aktif()
RETURNS TABLE (
  ujian_id      UUID,
  ujian_nama    TEXT,
  mapel_id      UUID,
  psat_mapel_id UUID,
  mapel_nama    TEXT,
  level         TEXT,
  kelas_list    TEXT[],
  event_nama    TEXT,
  tahun_ajaran  TEXT,
  semester      INTEGER
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = psat, public
AS $$
  SELECT
    u.id,
    u.nama,
    u.mata_pelajaran_id,
    ma.psat_mapel_id,
    mp.nama,
    psat.level_ujian(u.id),
    ARRAY(
      SELECT uk.kelas FROM public.ujian_kelas uk
      WHERE uk.ujian_id = u.id ORDER BY uk.kelas
    ),
    ev.nama,
    ev.tahun_ajaran,
    ev.semester
  FROM public.ujian u
  JOIN public.event_ujian ev ON ev.id = u.event_id AND ev.is_active
  JOIN public.tipe_ujian  tu ON tu.kode = u.tipe_ujian AND tu.soal_oleh = 'super_admin'
  LEFT JOIN public.mata_pelajaran mp ON mp.id = u.mata_pelajaran_id
  LEFT JOIN psat.mapel_alias      ma ON ma.public_mapel_id = u.mata_pelajaran_id
  ORDER BY mp.nama, psat.level_ujian(u.id);
$$;

GRANT EXECUTE ON FUNCTION psat.get_ujian_aktif() TO authenticated;

-- Tugas menulis milik guru pemanggil: irisan guru_mengajar × ujian aktif.
-- Sengaja memakai auth.uid(), bukan parameter profile_id, supaya tidak bisa
-- dipakai mengintip penugasan orang lain.
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
  ORDER BY a.mapel_nama, a.level;
$$;

GRANT EXECUTE ON FUNCTION psat.get_tugas_menulis() TO authenticated;

-- Daftar bab dari LMS untuk satu ujian — dipakai sebagai saran nama bab
-- di halaman matrix. Nama bab di PSAT tetap teks bebas.
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
  SELECT bp.id, bp.nama_bab, bp.urutan
  FROM public.bab_pelajaran bp
  JOIN public.ujian u ON u.id = p_ujian_id
  WHERE bp.ujian_id = p_ujian_id
     OR (bp.ujian_id IS NULL AND bp.mata_pelajaran_id = u.mata_pelajaran_id)
  ORDER BY bp.urutan NULLS LAST, bp.nama_bab;
$$;

GRANT EXECUTE ON FUNCTION psat.get_bab_ujian(UUID) TO authenticated;

COMMIT;
