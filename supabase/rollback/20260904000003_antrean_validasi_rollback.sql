-- ROLLBACK untuk 20260904000003_antrean_validasi.sql
--
-- ⚠️ Mundurkan KODE lebih dulu (validasi/page.tsx kembali menghitung sendiri),
-- kalau tidak halaman validasi gagal total karena memanggil RPC yang tak ada.
--
-- Yang kembali kalau ini dijalankan: klien menarik seluruh baris bank_soal lagi
-- dan menembus plafon PostgREST 1000 (1.873 baris per 4 Sep 2026), sehingga
-- ujian yang soalnya sudah dikirim bisa lenyap dari antrean; dan antrean
-- kembali mencampur 22 ujian tahun 2025/2026.

BEGIN;
DROP FUNCTION IF EXISTS psat.get_antrean_validasi();
COMMIT;
