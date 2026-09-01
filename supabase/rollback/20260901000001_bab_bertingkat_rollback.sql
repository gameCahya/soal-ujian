-- Rollback: 20260901000001_bab_bertingkat.sql
--
-- Jalankan INI LEBIH DULU, baru rollback LMS (20260901b). Urutannya penting:
-- berkas ini mengembalikan badan asli psat.level_ujian() dan melepas semua
-- rujukan ke public.bab_terlihat_ujian(), sehingga rollback LMS boleh menghapus
-- kedua fungsi itu tanpa meninggalkan pemanggil yang menggantung.
--
-- Mengembalikan ketiga fungsi ke definisi 20260827000001 / 20260831000002 /
-- 20260831000001 — yakni aturan bab TANPA tingkat.

BEGIN;

-- 1. level_ujian kembali memparse sendiri
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

-- 2. get_bab_ujian kembali menyalin aturannya sendiri
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

COMMIT;

-- 3. buat_bab_ujian dan sinkron_konfigurasi_bab
--    Keduanya panjang dan tidak berubah selain blok pencarian bab. Cara paling
--    aman memulihkannya adalah menjalankan ulang berkas aslinya, bukan menyalin
--    badannya lagi ke sini dan berisiko menyimpang:
--      supabase/migrations/20260831000002_buat_bab_dari_psat.sql
--      supabase/migrations/20260831000001_penulis_bab_dan_jembatan_konfigurasi.sql
--
--    ⚠️ 20260831000001 juga membuat tabel dan indeks. Menjalankannya ulang aman
--       (semuanya IF NOT EXISTS / CREATE OR REPLACE), tapi periksa lagi kalau
--       berkas itu sempat disunting sejak diapply.

NOTIFY pgrst, 'reload schema';
