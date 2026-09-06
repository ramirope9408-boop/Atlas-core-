-- ATLAS B2.2C.2A
-- Reconciliacion de autoridad y contrato MIME para Storage privado.
-- Corte: 2026-08-29
--
-- Decisiones:
-- - atlas_internal_memberships es la autoridad canonica de tenant;
-- - empresa_usuarios no gobierna nuevas operaciones de Storage;
-- - toda ruta conserva {empresa_id}/... como primer segmento;
-- - atlas-private permanece privado y sin DELETE para clientes;
-- - se agregan MIME JSON/CSV compatibles sin retirar tipos existentes.

begin;

do $$
begin
  if to_regclass('public.atlas_internal_memberships') is null then
    raise exception 'B2.2C.2A requiere atlas_internal_memberships';
  end if;

  if to_regclass('storage.buckets') is null
     or to_regclass('storage.objects') is null then
    raise exception 'B2.2C.2A requiere Supabase Storage';
  end if;

  if not exists (
    select 1
    from storage.buckets
    where id = 'atlas-private'
      and public = false
  ) then
    raise exception 'B2.2C.2A requiere bucket privado atlas-private';
  end if;
end;
$$;

create or replace function public.usuario_puede_acceder_storage(
  p_path text
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_empresa_segmento text;
  v_empresa_id uuid;
begin
  if v_actor_user_id is null
     or p_path is null
     or btrim(p_path) = '' then
    return false;
  end if;

  -- Contrato canonico de ruta: {empresa_id}/...
  v_empresa_segmento := split_part(p_path, '/', 1);

  if v_empresa_segmento is null
     or v_empresa_segmento = ''
     or v_empresa_segmento !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return false;
  end if;

  v_empresa_id := v_empresa_segmento::uuid;

  return exists (
    select 1
    from public.atlas_internal_memberships as im
    where im.empresa_id = v_empresa_id
      and im.user_id = v_actor_user_id
      and im.status = 'ACTIVE'
  );
exception
  when others then
    return false;
end;
$$;

revoke all on function public.usuario_puede_acceder_storage(text)
  from public, anon;
grant execute on function public.usuario_puede_acceder_storage(text)
  to authenticated, service_role;

update storage.buckets
set
  allowed_mime_types = array(
    select distinct mime_type
    from unnest(
      coalesce(allowed_mime_types, '{}'::text[])
      || array[
        'application/json',
        'text/json',
        'application/csv',
        'text/plain'
      ]::text[]
    ) as mime_type
    order by mime_type
  ),
  updated_at = now()
where id = 'atlas-private'
  and public = false;

comment on function public.usuario_puede_acceder_storage(text) is
  'Atlas: autoriza rutas {empresa_id}/... usando atlas_internal_memberships como autoridad canonica.';

commit;

select jsonb_build_object(
  'ok',
    exists (
      select 1
      from storage.buckets as b
      where b.id = 'atlas-private'
        and b.public = false
        and b.file_size_limit = 31457280
        and 'application/json' = any(b.allowed_mime_types)
        and 'text/json' = any(b.allowed_mime_types)
        and 'application/csv' = any(b.allowed_mime_types)
        and 'text/plain' = any(b.allowed_mime_types)
    ),
  'code', 'B2_2C2A_STORAGE_AUTHORITY_RECONCILED',
  'canonical_membership_table', 'atlas_internal_memberships',
  'path_contract', '{empresa_id}/...',
  'private_bucket', (
    select not b.public
    from storage.buckets as b
    where b.id = 'atlas-private'
  ),
  'file_size_limit', (
    select b.file_size_limit
    from storage.buckets as b
    where b.id = 'atlas-private'
  ),
  'allowed_mime_type_count', (
    select cardinality(b.allowed_mime_types)
    from storage.buckets as b
    where b.id = 'atlas-private'
  ),
  'json_mime_enabled', (
    select 'application/json' = any(b.allowed_mime_types)
    from storage.buckets as b
    where b.id = 'atlas-private'
  ),
  'client_delete_policies', (
    select count(*)
    from pg_policies as p
    where p.schemaname = 'storage'
      and p.tablename = 'objects'
      and p.cmd = 'DELETE'
      and 'authenticated' = any(p.roles)
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'next_action', 'CERTIFY_STORAGE_AUTHORITY'
) as result;
