-- Rollback: psat.login_log RLS
--
-- Mengembalikan keadaan sebelum 20261114000001_login_log_rls.sql.
-- PERINGATAN: setelah rollback, anon/authenticated kembali bisa membaca
-- seluruh audit login. Hanya jalankan bila benar-benar diperlukan.

BEGIN;

ALTER TABLE psat.login_log DISABLE ROW LEVEL SECURITY;
GRANT ALL ON TABLE psat.login_log TO anon, authenticated;

COMMIT;
