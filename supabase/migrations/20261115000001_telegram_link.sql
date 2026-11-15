-- Telegram: tautan akun PSAT <-> chat Telegram
--
-- Dipakai bot @psatAlbiBot untuk:
--   - membuka matrix guru lewat /edit_matrix (hanya baris milik sendiri);
--   - mengirim notifikasi (revisi/approved) ke chat guru.
--
-- KEAMANAN
-- RLS aktif TANPA policy: anon/authenticated tidak punya akses sama sekali.
-- Hanya service_role (server aplikasi & bot) yang membaca/menulis.
--
-- Catatan: kode tautan disimpan terpisah (telegram_link_code) karena hanya
-- berlaku 10 menit dan sekali pakai; memisahkannya mencegah kode kedaluwarsa
-- menimpa tautan yang sudah aktif.
--
-- ROLLBACK: supabase/rollback/20261115000001_telegram_link_rollback.sql

BEGIN;

CREATE TABLE IF NOT EXISTS psat.telegram_link (
	profile_id uuid PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
	chat_id bigint NOT NULL UNIQUE,
	username text,
	linked_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS psat.telegram_link_code (
	profile_id uuid PRIMARY KEY REFERENCES public.profiles (id) ON DELETE CASCADE,
	code text NOT NULL,
	expires_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS telegram_link_code_code_idx
	ON psat.telegram_link_code (code);
CREATE INDEX IF NOT EXISTS telegram_link_code_expires_idx
	ON psat.telegram_link_code (expires_at);

ALTER TABLE psat.telegram_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE psat.telegram_link_code ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE psat.telegram_link FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE psat.telegram_link_code FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE psat.telegram_link TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE psat.telegram_link_code TO service_role;

DO $gate$
BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM pg_class
		WHERE oid = 'psat.telegram_link'::regclass AND relrowsecurity
	) THEN
		RAISE EXCEPTION 'RLS psat.telegram_link tidak aktif';
	END IF;

	IF NOT EXISTS (
		SELECT 1 FROM pg_class
		WHERE oid = 'psat.telegram_link_code'::regclass AND relrowsecurity
	) THEN
		RAISE EXCEPTION 'RLS psat.telegram_link_code tidak aktif';
	END IF;

	IF has_table_privilege('anon', 'psat.telegram_link', 'SELECT')
	   OR has_table_privilege('authenticated', 'psat.telegram_link', 'SELECT')
	   OR has_table_privilege('anon', 'psat.telegram_link_code', 'SELECT')
	   OR has_table_privilege('authenticated', 'psat.telegram_link_code', 'SELECT') THEN
		RAISE EXCEPTION 'Masih ada akses anon/authenticated ke tabel telegram';
	END IF;

	RAISE NOTICE 'Tabel telegram_link + telegram_link_code siap (RLS aktif, service_role saja).';
END
$gate$;

COMMIT;
