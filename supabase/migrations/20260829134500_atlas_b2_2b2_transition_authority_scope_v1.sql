-- ATLAS B2.2B.2A
-- Separacion de aprobaciones de gate y autorizaciones terminales.
-- Corte: 2026-08-29
--
-- Motivo:
-- La matriz B2.2A usaba requires_approval tanto para gates G01-G04
-- como para CANCELLED/ROLLED_BACK. B2.2B.2 necesita distinguir:
-- - GATE: aprobacion respaldada por G01-G04;
-- - PLATFORM_CONTROL: autorizacion superior terminal, aun no habilitada;
-- - NONE: transicion sin aprobacion adicional.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_state_transitions') is null
     or to_regclass('public.atlas_installations') is null
     or to_regprocedure(
       'public.atlas_decide_installation_gate(uuid,text,text,text,text,jsonb,uuid,bigint)'
     ) is null then
    raise exception 'B2.2B.2A requiere B2.2B.2 instalado';
  end if;
end;
$$;

alter table public.atlas_installation_state_transitions
  add column if not exists approval_scope text not null default 'NONE';

update public.atlas_installation_state_transitions
set approval_scope = case
  when (
    (from_state_code = 'LEGAL_REVIEW' and to_state_code = 'LEGAL_APPROVED')
    or (from_state_code = 'CLIENT_REVIEW' and to_state_code = 'DATA_APPROVED')
    or (from_state_code = 'TESTING' and to_state_code = 'FINAL_APPROVAL')
    or (from_state_code = 'FINAL_APPROVAL' and to_state_code = 'ACTIVE')
    or (from_state_code = 'OBSERVED' and to_state_code = 'ACTIVE')
  ) then 'GATE'
  when requires_approval = true then 'PLATFORM_CONTROL'
  else 'NONE'
end;

-- Desde este corte, requires_approval identifica exclusivamente gates.
-- Las autorizaciones terminales quedan expresadas por approval_scope.
update public.atlas_installation_state_transitions
set
  requires_approval = (approval_scope = 'GATE'),
  updated_at = now();

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_state_transitions'::regclass
      and conname =
        'atlas_installation_state_transitions_approval_scope_check'
  ) then
    alter table public.atlas_installation_state_transitions
      add constraint atlas_installation_state_transitions_approval_scope_check
      check (approval_scope in ('NONE', 'GATE', 'PLATFORM_CONTROL'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid =
      'public.atlas_installation_state_transitions'::regclass
      and conname =
        'atlas_installation_state_transitions_approval_consistency_check'
  ) then
    alter table public.atlas_installation_state_transitions
      add constraint atlas_installation_state_transitions_approval_consistency_check
      check (
        (approval_scope = 'GATE' and requires_approval = true)
        or (
          approval_scope in ('NONE', 'PLATFORM_CONTROL')
          and requires_approval = false
        )
      );
  end if;
end;
$$;

create or replace function public.atlas_block_unapproved_platform_control()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.current_state_code is distinct from new.current_state_code
     and exists (
       select 1
       from public.atlas_installation_state_transitions as t
       where t.from_state_code = old.current_state_code
         and t.to_state_code = new.current_state_code
         and t.approval_scope = 'PLATFORM_CONTROL'
         and t.active = true
     ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_PLATFORM_CONTROL_AUTHORIZATION_REQUIRED_B2_2C_PENDING';
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_block_unapproved_platform_control()
  from public, anon, authenticated;
grant execute on function public.atlas_block_unapproved_platform_control()
  to service_role;

drop trigger if exists trg_atlas_installations_platform_control_guard
  on public.atlas_installations;
create trigger trg_atlas_installations_platform_control_guard
before update of current_state_code on public.atlas_installations
for each row execute function public.atlas_block_unapproved_platform_control();

comment on column
  public.atlas_installation_state_transitions.approval_scope is
  'B2: NONE, GATE o PLATFORM_CONTROL; separa gates de autorizaciones terminales.';

comment on function public.atlas_block_unapproved_platform_control() is
  'B2: bloquea CANCELLED/ROLLED_BACK hasta contar con autorizacion superior especifica.';

commit;

select jsonb_build_object(
  'ok',
    (
      select count(*) = 5
      from public.atlas_installation_state_transitions
      where approval_scope = 'GATE'
        and requires_approval = true
        and active = true
    )
    and (
      select count(*) = 15
      from public.atlas_installation_state_transitions
      where approval_scope = 'PLATFORM_CONTROL'
        and requires_approval = false
        and active = true
    ),
  'code', 'B2_2B2_APPROVAL_SCOPES_RECONCILED',
  'gate_transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where approval_scope = 'GATE'
      and active = true
  ),
  'platform_control_transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where approval_scope = 'PLATFORM_CONTROL'
      and active = true
  ),
  'unprotected_transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where approval_scope = 'NONE'
      and active = true
  ),
  'total_transitions', (
    select count(*)
    from public.atlas_installation_state_transitions
    where active = true
  ),
  'platform_control_enabled', false,
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'next_action', 'CERTIFY_GATE_DECISION_ENFORCEMENT'
) as result;
