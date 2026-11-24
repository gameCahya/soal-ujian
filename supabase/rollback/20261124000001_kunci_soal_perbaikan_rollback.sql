-- Rollback: kembalikan kunci_soal/lepas_kunci ke versi 21 Nov (tanpa batas status,
-- lepas_kunci void). Tidak mengembalikan hak EXECUTE ke anon — itu perbaikan
-- keamanan yang sebaiknya tetap berlaku.

BEGIN;

DROP FUNCTION IF EXISTS psat.kunci_soal(uuid);
CREATE FUNCTION psat.kunci_soal(p_id uuid)
RETURNS TABLE(locked_by uuid, locked_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $function$
declare peran psat.user_role := psat.current_user_role();
begin
  if peran not in ('validator','admin') then
    raise exception 'Hanya validator/admin yang dapat mengunci soal.' using errcode='42501';
  end if;
  update psat.bank_soal b
     set locked_by = auth.uid(), locked_at = now()
   where b.id = p_id
     and (b.locked_by is null or b.locked_by = auth.uid()
          or b.locked_at is null or b.locked_at < now() - interval '10 minutes');
  if not found then
    raise exception 'Soal sedang dikunci validator lain.' using errcode='42501';
  end if;
  return query select b.locked_by, b.locked_at from psat.bank_soal b where b.id = p_id;
end $function$;

DROP FUNCTION IF EXISTS psat.lepas_kunci(uuid);
CREATE FUNCTION psat.lepas_kunci(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'psat', 'public'
AS $function$
declare peran psat.user_role := psat.current_user_role();
begin
  update psat.bank_soal
     set locked_by = null, locked_at = null
   where id = p_id and (locked_by = auth.uid() or peran = 'admin');
end $function$;

REVOKE ALL ON FUNCTION psat.kunci_soal(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION psat.lepas_kunci(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION psat.kunci_soal(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION psat.lepas_kunci(uuid) TO authenticated;

COMMIT;
