-- ROLLBACK untuk 20260905000002_pindahkan_soal_bab_yatim.sql
--
-- Mengembalikan bab_id (dan bab_id_text) 94 soal ke NILAI ASLI dari tabel
-- cadangan psat.backup_bab_yatim_20260905 — termasuk 11 baris yang memang
-- bab_id-nya NULL sebelum perbaikan.
--
-- ⚠️ Sesudah ini soal-soal itu HILANG LAGI dari halaman Soal penulisnya, persis
-- seperti keluhan 5 Sep 2026. Jalankan hanya kalau pemetaannya ternyata salah.
--
-- Trigger cermin hanya menulis bab_id_text saat bab_id NOT NULL, jadi untuk
-- baris yang kembali ke NULL, bab_id_text dipulihkan tangan dari cadangan.

BEGIN;

UPDATE psat.bank_soal b
   SET bab_id      = c.bab_id_lama,
       bab_id_text = c.bab_id_text_lama
  FROM psat.backup_bab_yatim_20260905 c
 WHERE c.soal_id = b.id;

DO $gate$
DECLARE v_beda int;
BEGIN
  SELECT count(*) INTO v_beda
    FROM psat.bank_soal b
    JOIN psat.backup_bab_yatim_20260905 c ON c.soal_id = b.id
   WHERE b.bab_id IS DISTINCT FROM c.bab_id_lama
      OR b.bab_id_text IS DISTINCT FROM c.bab_id_text_lama;
  IF v_beda <> 0 THEN
    RAISE EXCEPTION '% baris tidak kembali ke nilai asli', v_beda;
  END IF;
  RAISE NOTICE 'Rollback lolos: semua baris kembali ke potret sebelum perbaikan.';
END
$gate$;

-- Tabel cadangan sengaja TIDAK dihapus: ia satu-satunya catatan keadaan
-- sebelum perbaikan. Hapus manual kalau sudah yakin tidak dibutuhkan.

COMMIT;
