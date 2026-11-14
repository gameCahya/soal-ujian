-- Security: psat.login_log tanpa RLS
--
-- MASALAH
-- Tabel ini dibuat di 20260503000000_init_psat_schema.sql, tetapi TIDAK pernah
-- mengaktifkan RLS. Schema psat diekspos ke PostgREST dan init memberi
-- `GRANT ALL ON ALL TABLES IN SCHEMA psat TO anon, authenticated`, sehingga
-- siapa pun yang memegang publishable key bisa membaca (dan mengubah/menghapus)
-- audit login berisi email + user agent.
--
-- PERBAIKAN
-- Aktifkan RLS, cabut seluruh akses anon/authenticated, dan biarkan service_role
-- (BYPASSRLS) satu-satunya penulis. Aplikasi menulis log lewat service role di
-- server action login (+page.server.ts), jadi login tetap tercatat tanpa
-- memberi akses tabel ke browser.
--
-- Tidak ada policy SELECT: admin yang perlu membaca log harus lewat SQL editor /
-- service role, bukan dari aplikasi pengguna.
--
-- ROLLBACK: supabase/rollback/20261114000001_login_log_rls_rollback.sql

BEGIN;

ALTER TABLE psat.login_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE psat.login_log FROM anon, authenticated;

DO $gate$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'psat.login_log'::regclass AND relrowsecurity
  ) THEN
    RAISE EXCEPTION 'RLS psat.login_log tidak aktif';
  END IF;

  IF has_table_privilege('anon', 'psat.login_log', 'SELECT')
     OR has_table_privilege('anon', 'psat.login_log', 'INSERT')
     OR has_table_privilege('authenticated', 'psat.login_log', 'SELECT')
     OR has_table_privilege('authenticated', 'psat.login_log', 'INSERT') THEN
    RAISE EXCEPTION 'Masih ada grant anon/authenticated pada psat.login_log';
  END IF;

  IF NOT has_table_privilege('service_role', 'psat.login_log', 'INSERT') THEN
    RAISE EXCEPTION 'service_role tidak bisa INSERT ke psat.login_log';
  END IF;

  RAISE NOTICE 'RLS psat.login_log aktif; anon/authenticated tanpa akses; service_role tetap bisa menulis.';
END
$gate$;

COMMIT;
