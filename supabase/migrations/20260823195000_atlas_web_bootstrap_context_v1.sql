-- ============================================================
-- ATLAS WEB B1A
-- AUTHENTICATED BOOTSTRAP CONTEXT V1
-- ============================================================

create or replace function public.atlas_web_bootstrap_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_membership_count integer := 0;
  v_companies jsonb := '[]'::jsonb;
  v_default_empresa_id uuid := null;
begin

  if v_user_id is null then
    raise exception 'ATLAS_AUTH_REQUIRED';
  end if;

  select
    count(*)::integer,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'membership_id', resolved.membership_id,
          'empresa_id', resolved.empresa_id,
          'empresa_name', resolved.empresa_name,
          'empresa_commercial_name',
            resolved.empresa_commercial_name,
          'empresa_city', resolved.empresa_city,
          'empresa_country', resolved.empresa_country,
          'empresa_timezone', resolved.empresa_timezone,
          'empresa_status', resolved.empresa_status,
          'role_code', resolved.role_code,
          'role_name', resolved.role_name,
          'role_priority', resolved.role_priority,
          'display_name', resolved.display_name,
          'permissions', resolved.permissions,
          'agents', resolved.agents
        )
        order by
          resolved.empresa_name,
          resolved.empresa_id
      ),
      '[]'::jsonb
    )
  into
    v_membership_count,
    v_companies
  from (
    select
      m.id as membership_id,
      m.empresa_id,
      e.nombre as empresa_name,
      e.nombre_comercial as empresa_commercial_name,
      e.ciudad as empresa_city,
      e.pais as empresa_country,
      e.zona_horaria as empresa_timezone,
      e.estado as empresa_status,
      m.role_code,
      r.display_name as role_name,
      r.priority as role_priority,
      m.display_name,

      coalesce(
        (
          select jsonb_agg(
            rp.permission_code
            order by rp.permission_code
          )
          from public.atlas_internal_role_permissions rp
          join public.atlas_internal_permissions p
            on p.permission_code = rp.permission_code
          where rp.role_code = m.role_code
        ),
        '[]'::jsonb
      ) as permissions,

      coalesce(
        (
          select jsonb_agg(
            jsonb_build_object(
              'agent_code', aur.agent_code,
              'relationship_code',
                aur.relationship_code,
              'status', aur.status
            )
            order by aur.agent_code
          )
          from public.atlas_agent_user_relationships aur
          where aur.empresa_id = m.empresa_id
            and aur.user_id = v_user_id
            and aur.status = 'ACTIVE'
        ),
        '[]'::jsonb
      ) as agents

    from public.atlas_internal_memberships m
    join public.atlas_internal_roles r
      on r.role_code = m.role_code
     and r.active = true
    join public.empresas e
      on e.id = m.empresa_id
     and e.estado = 'active'
    where m.user_id = v_user_id
      and m.status = 'ACTIVE'
  ) resolved;

  if v_membership_count = 1 then
    v_default_empresa_id :=
      nullif(
        v_companies -> 0 ->> 'empresa_id',
        ''
      )::uuid;
  end if;

  return jsonb_build_object(
    'bootstrap_status',
      case
        when v_membership_count = 0
          then 'NO_ACTIVE_MEMBERSHIP'
        else 'READY'
      end,
    'safe_to_continue',
      v_membership_count > 0,
    'runtime_version',
      'ATLAS_WEB_BOOTSTRAP_V1',
    'user_id',
      v_user_id,
    'company_count',
      v_membership_count,
    'requires_company_selection',
      v_membership_count > 1,
    'default_empresa_id',
      v_default_empresa_id,
    'companies',
      v_companies
  );

end;
$function$;

alter function public.atlas_web_bootstrap_context()
owner to postgres;

revoke all
on function public.atlas_web_bootstrap_context()
from public;

revoke all
on function public.atlas_web_bootstrap_context()
from anon;

grant execute
on function public.atlas_web_bootstrap_context()
to authenticated;

grant execute
on function public.atlas_web_bootstrap_context()
to service_role;

comment on function public.atlas_web_bootstrap_context()
is
'Atlas Web B1 authenticated bootstrap. Resolves active companies, roles, permissions and agents exclusively from auth.uid().';