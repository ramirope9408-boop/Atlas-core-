-- ATLAS B2.2G.3C.3A
-- Hardening de la frontera terminal PLATFORM_CONTROL.
-- Corte: 2026-09-02
--
-- Refuerza defensa en profundidad: ningun salto directo a un estado terminal
-- puede ocurrir si la ruta no esta configurada como PLATFORM_CONTROL y ligada
-- a una decision humana APPROVED valida.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_platform_control_decisions'
     ) is null
     or to_regprocedure(
       'public.atlas_decide_installation_provisioning_rollback(uuid,text,text,jsonb,uuid,bigint,bigint,jsonb)'
     ) is null
     or not exists (
       select 1
       from information_schema.columns
       where table_schema = 'public'
         and table_name = 'atlas_installations'
         and column_name =
           'last_platform_control_decision_id'
     ) then
    raise exception
      'B2.2G.3C.3A requiere B2.2G.3C.3 instalado';
  end if;
end;
$$;

create or replace function
public.atlas_block_unapproved_platform_control()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_approval_scope text;
  v_target_is_terminal boolean := false;
  v_decision
    public.atlas_installation_platform_control_decisions%rowtype;
begin
  if old.current_state_code is not distinct from
       new.current_state_code then
    if old.last_platform_control_decision_id is distinct from
         new.last_platform_control_decision_id then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_DECISION_BINDING_FORBIDDEN';
    end if;

    return new;
  end if;

  select transition.approval_scope
  into v_approval_scope
  from public.atlas_installation_state_transitions as transition
  where transition.from_state_code = old.current_state_code
    and transition.to_state_code = new.current_state_code
    and transition.active = true
  limit 1;

  select state_record.is_terminal
  into v_target_is_terminal
  from public.atlas_installation_states as state_record
  where state_record.state_code = new.current_state_code
    and state_record.active = true;

  if coalesce(v_target_is_terminal, false)
     and v_approval_scope is distinct from 'PLATFORM_CONTROL' then
    raise exception using
      errcode = '42501',
      message =
        'INSTALLATION_TERMINAL_TRANSITION_NOT_CONFIGURED';
  end if;

  if v_approval_scope = 'PLATFORM_CONTROL' then
    if new.last_platform_control_decision_id is null
       or new.last_platform_control_decision_id is not distinct from
         old.last_platform_control_decision_id then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_AUTHORIZATION_REQUIRED';
    end if;

    select decision_record.*
    into v_decision
    from public.atlas_installation_platform_control_decisions
      as decision_record
    where decision_record.id =
      new.last_platform_control_decision_id;

    if not found
       or v_decision.decision <> 'APPROVED'
       or v_decision.installation_id <> old.id
       or v_decision.empresa_id is distinct from old.empresa_id
       or v_decision.from_state_code <> old.current_state_code
       or v_decision.target_state_code <>
         new.current_state_code
       or v_decision.expected_installation_version <>
         old.version
       or v_decision.resulting_installation_version <>
         new.version then
      raise exception using
        errcode = '42501',
        message =
          'INSTALLATION_PLATFORM_CONTROL_AUTHORIZATION_INVALID';
    end if;
  elsif old.last_platform_control_decision_id is distinct from
        new.last_platform_control_decision_id then
    raise exception using
      errcode = '42501',
      message =
        'INSTALLATION_PLATFORM_CONTROL_DECISION_BINDING_FORBIDDEN';
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_block_unapproved_platform_control()
from public, anon, authenticated;
grant execute on function
public.atlas_block_unapproved_platform_control()
to service_role;

drop trigger if exists
  trg_atlas_installations_platform_control_guard
on public.atlas_installations;
create trigger trg_atlas_installations_platform_control_guard
before update of current_state_code,
  last_platform_control_decision_id
on public.atlas_installations
for each row execute function
public.atlas_block_unapproved_platform_control();

comment on function
public.atlas_block_unapproved_platform_control() is
  'B2: bloquea rutas terminales no configuradas y exige decision humana APPROVED ligada por identidad y version.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2G3C3A_TERMINAL_GUARD_HARDENED',
  'next_action',
    'CERTIFY_G3C3_HUMAN_APPROVAL_AND_TERMINAL_GUARDS',
  'unconfigured_terminal_routes_blocked', true,
  'bound_human_decision_required', true,
  'decision_version_binding_enabled', true,
  'direct_authenticated_write', false,
  'platform_control_decision_records', (
    select count(*)
    from public.atlas_installation_platform_control_decisions
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id =
      'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  )
) as result;
