-- Rollback: Telegram link
--
-- Menghapus tabel tautan Telegram. SEMUA tautan akun PSAT <-> chat Telegram
-- hilang; guru harus menautkan ulang. Tidak menyentuh tabel lain.

BEGIN;

DROP TABLE IF EXISTS psat.telegram_link_code;
DROP TABLE IF EXISTS psat.telegram_link;

COMMIT;
