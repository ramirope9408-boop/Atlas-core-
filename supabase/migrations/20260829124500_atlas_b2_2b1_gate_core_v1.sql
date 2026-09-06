-- ATLAS B2.2B.1
-- Nucleo de gates G01-G04 y bitacora de aprobaciones.
-- Corte: 2026-08-29
--
-- Prerrequisitos:
--   20260828190000_atlas_b2_2a_installation_core_v1.sql
--   20260828193000_atlas_b2_2a_platform_authority_rpcs_v1.sql
--
-- Alcance deliberado:
-- - cataloga G01-G04 y sus 34 criterios canonicos;
-- - crea una instancia de cada gate por expediente;
-- - prepara la bitacora append-only de decisiones;
-- - mantiene toda escritura de cliente cerrada;
-- - no habilita aun decisiones ni transiciones sujetas a aprobacion.

begin;

do $$
begin
  if to_regclass('public.atlas_installations') is null
     or to_regclass('public.atlas_installation_states') is null
     or to_regclass('public.atlas_platform_memberships') is null then
    raise exception 'B2.2B.1 requiere B2.2A instalado y certificado';
  end if;

  if not exists (
    select 1
    from pg_proc as p
    join pg_namespace as n
      on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'atlas_platform_has_permission'
  ) then
    raise exception 'B2.2B.1 requiere public.atlas_platform_has_permission(text)';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values
  (
    'INSTALLATION_GATE_DECIDE',
    'Emitir decisiones internas autorizadas sobre gates de instalacion.'
  )
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_GATE_DECIDE'),
  ('ATLAS_LEGAL_REVIEWER', 'INSTALLATION_GATE_DECIDE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_GATE_DECIDE')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_installation_gate_definitions (
  gate_code text primary key,
  display_name text not null,
  description text not null,
  phase_order integer not null,
  review_state_code text not null,
  approved_target_state_code text not null,
  required_platform_role_code text,
  requires_platform_approval boolean not null default true,
  requires_client_approval boolean not null default false,
  criteria jsonb not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_gate_definitions_code_check
    check (gate_code ~ '^G0[1-4]$'),
  constraint atlas_installation_gate_definitions_phase_order_check
    check (phase_order > 0),
  constraint atlas_installation_gate_definitions_review_state_fkey
    foreign key (review_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_gate_definitions_target_state_fkey
    foreign key (approved_target_state_code)
    references public.atlas_installation_states(state_code)
    on delete restrict,
  constraint atlas_installation_gate_definitions_platform_role_fkey
    foreign key (required_platform_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_installation_gate_definitions_authority_check
    check (requires_platform_approval or requires_client_approval),
  constraint atlas_installation_gate_definitions_criteria_array_check
    check (
      jsonb_typeof(criteria) = 'array'
      and jsonb_array_length(criteria) > 0
    )
);

insert into public.atlas_installation_gate_definitions (
  gate_code,
  display_name,
  description,
  phase_order,
  review_state_code,
  approved_target_state_code,
  required_platform_role_code,
  requires_platform_approval,
  requires_client_approval,
  criteria,
  active
)
values
  (
    'G01',
    'Juridica e identidad',
    'Valida identidad, representacion, contratacion, autorizaciones y condicion financiera inicial.',
    10,
    'LEGAL_REVIEW',
    'LEGAL_APPROVED',
    'ATLAS_LEGAL_REVIEWER',
    true,
    false,
    jsonb_build_array(
      jsonb_build_object('code', 'COMPANY_IDENTITY_VERIFIED', 'description', 'Identidad de la empresa y representante verificada.', 'required', true),
      jsonb_build_object('code', 'CLIENT_OWNER_AUTHORIZED', 'description', 'OWNER designado y autorizado.', 'required', true),
      jsonb_build_object('code', 'SERVICE_ORDER_APPROVED', 'description', 'Propuesta u orden de servicio aprobada.', 'required', true),
      jsonb_build_object('code', 'MAIN_CONTRACT_SIGNED', 'description', 'Contrato principal firmado.', 'required', true),
      jsonb_build_object('code', 'REQUIRED_ANNEXES_PRESENT', 'description', 'Anexos requeridos presentes segun alcance.', 'required', true),
      jsonb_build_object('code', 'DATA_AND_CHANNEL_AUTHORIZATIONS', 'description', 'Autorizaciones de tratamiento y canales registradas.', 'required', true),
      jsonb_build_object('code', 'THIRD_PARTIES_IDENTIFIED', 'description', 'Proveedores y cuentas de terceros identificados.', 'required', true),
      jsonb_build_object('code', 'INITIAL_FINANCIAL_STATUS_VALID', 'description', 'Pago inicial o autorizacion financiera validada.', 'required', true),
      jsonb_build_object('code', 'LEGAL_RISKS_RESOLVED', 'description', 'Riesgos juridicos especiales observados o aprobados.', 'required', true)
    ),
    true
  ),
  (
    'G02',
    'Datos y conocimiento',
    'Valida inventarios, normalizacion, conocimiento, reglas y aprobacion del cliente.',
    20,
    'CLIENT_REVIEW',
    'DATA_APPROVED',
    null,
    false,
    true,
    jsonb_build_array(
      jsonb_build_object('code', 'REQUIRED_DATA_INVENTORIED', 'description', 'Datos obligatorios y condicionados inventariados.', 'required', true),
      jsonb_build_object('code', 'CATALOGS_AND_POLICIES_NORMALIZED', 'description', 'Catalogos, precios, politicas y vigencias normalizados.', 'required', true),
      jsonb_build_object('code', 'KNOWLEDGE_BASE_PREPARED', 'description', 'Base de conocimiento preparada.', 'required', true),
      jsonb_build_object('code', 'PERSONALITY_DEFINED', 'description', 'Personalidad y regionalidad definidas.', 'required', true),
      jsonb_build_object('code', 'COMMERCIAL_RULES_APPROVED', 'description', 'Reglas comerciales y prohibiciones aprobadas.', 'required', true),
      jsonb_build_object('code', 'DATA_CLASSIFICATION_ASSIGNED', 'description', 'Clasificacion de datos y retencion asignadas.', 'required', true),
      jsonb_build_object('code', 'CLIENT_REVIEW_COMPLETED', 'description', 'Revision del cliente concluida.', 'required', true),
      jsonb_build_object('code', 'CANONICAL_VERSIONS_APPROVED', 'description', 'Versiones canonicas aprobadas.', 'required', true)
    ),
    true
  ),
  (
    'G03',
    'Tecnica y seguridad',
    'Valida aprovisionamiento, aislamiento, integraciones, flujos y recuperacion.',
    30,
    'TESTING',
    'FINAL_APPROVAL',
    'ATLAS_SECURITY_REVIEWER',
    true,
    false,
    jsonb_build_array(
      jsonb_build_object('code', 'TENANT_PROVISIONED', 'description', 'Tenant aprovisionado.', 'required', true),
      jsonb_build_object('code', 'RLS_AND_ISOLATION_VALIDATED', 'description', 'RLS y aislamiento validados.', 'required', true),
      jsonb_build_object('code', 'OWNER_ROLES_PERMISSIONS_TESTED', 'description', 'OWNER, roles y permisos probados.', 'required', true),
      jsonb_build_object('code', 'STORAGE_CLASSIFICATION_VALIDATED', 'description', 'Storage y URLs conformes a clasificacion.', 'required', true),
      jsonb_build_object('code', 'INTEGRATIONS_SECURELY_CONNECTED', 'description', 'Integraciones conectadas con credenciales seguras.', 'required', true),
      jsonb_build_object('code', 'CERTIFIED_FLOWS_INSTALLED', 'description', 'Flujos certificados instalados.', 'required', true),
      jsonb_build_object('code', 'CHANNELS_TESTED', 'description', 'Canales entrantes y salientes probados.', 'required', true),
      jsonb_build_object('code', 'AUDIT_AND_IDEMPOTENCY_OPERATIONAL', 'description', 'Auditoria e idempotencia operativas.', 'required', true),
      jsonb_build_object('code', 'ERROR_AND_RECOVERY_TESTS_APPROVED', 'description', 'Pruebas de permisos, errores y recuperacion aprobadas.', 'required', true)
    ),
    true
  ),
  (
    'G04',
    'Certificacion y aceptacion',
    'Exige certificacion tecnica, aceptacion del cliente y autorizacion final de Atlas.',
    40,
    'FINAL_APPROVAL',
    'ACTIVE',
    'ATLAS_OWNER',
    true,
    true,
    jsonb_build_array(
      jsonb_build_object('code', 'FUNCTIONAL_CASES_APPROVED', 'description', 'Casos funcionales aprobados.', 'required', true),
      jsonb_build_object('code', 'SECURITY_TESTS_APPROVED', 'description', 'Pruebas de seguridad e aislamiento aprobadas.', 'required', true),
      jsonb_build_object('code', 'ZERO_CRITICAL_DEFECTS', 'description', 'Defectos criticos en cero.', 'required', true),
      jsonb_build_object('code', 'EXCEPTIONS_ACCEPTED', 'description', 'Excepciones documentadas y aceptadas.', 'required', true),
      jsonb_build_object('code', 'TRAINING_COMPLETED', 'description', 'Capacitacion y entrega realizadas.', 'required', true),
      jsonb_build_object('code', 'ACCEPTANCE_RECORDED', 'description', 'Acta firmada o aprobacion verificable registrada.', 'required', true),
      jsonb_build_object('code', 'INSTALLATION_CERTIFICATE_ISSUED', 'description', 'Certificado de instalacion emitido.', 'required', true),
      jsonb_build_object('code', 'ACTIVE_STATE_AUTHORIZED', 'description', 'Estado ACTIVE autorizado.', 'required', true)
    ),
    true
  )
on conflict (gate_code) do update
set
  display_name = excluded.display_name,
  description = excluded.description,
  phase_order = excluded.phase_order,
  review_state_code = excluded.review_state_code,
  approved_target_state_code = excluded.approved_target_state_code,
  required_platform_role_code = excluded.required_platform_role_code,
  requires_platform_approval = excluded.requires_platform_approval,
  requires_client_approval = excluded.requires_client_approval,
  criteria = excluded.criteria,
  active = excluded.active,
  updated_at = now();

create table if not exists public.atlas_installation_gates (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid,
  gate_code text not null,
  status text not null default 'PENDING',
  gate_version bigint not null default 1,
  requires_platform_approval boolean not null,
  requires_client_approval boolean not null,
  platform_approved boolean not null default false,
  client_approved boolean not null default false,
  criteria_snapshot jsonb not null,
  opened_at timestamptz,
  approved_at timestamptz,
  last_decided_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_installation_gates_installation_gate_key
    unique (installation_id, gate_code),
  constraint atlas_installation_gates_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_gates_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_gates_gate_fkey
    foreign key (gate_code)
    references public.atlas_installation_gate_definitions(gate_code)
    on delete restrict,
  constraint atlas_installation_gates_status_check
    check (status in ('PENDING', 'IN_REVIEW', 'APPROVED', 'REJECTED', 'BLOCKED')),
  constraint atlas_installation_gates_version_check
    check (gate_version >= 1),
  constraint atlas_installation_gates_authority_check
    check (requires_platform_approval or requires_client_approval),
  constraint atlas_installation_gates_criteria_array_check
    check (
      jsonb_typeof(criteria_snapshot) = 'array'
      and jsonb_array_length(criteria_snapshot) > 0
    ),
  constraint atlas_installation_gates_metadata_object_check
    check (jsonb_typeof(metadata) = 'object'),
  constraint atlas_installation_gates_approved_state_check
    check (
      status <> 'APPROVED'
      or (
        (not requires_platform_approval or platform_approved)
        and (not requires_client_approval or client_approved)
        and approved_at is not null
      )
    )
);

create table if not exists public.atlas_installation_approvals (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid,
  gate_id uuid not null,
  gate_code text not null,
  authority_type text not null,
  decision text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  reason text,
  evidence jsonb not null,
  request_id uuid not null,
  gate_version bigint not null,
  created_at timestamptz not null default now(),

  constraint atlas_installation_approvals_request_key
    unique (installation_id, request_id),
  constraint atlas_installation_approvals_gate_version_authority_key
    unique (gate_id, gate_version, authority_type),
  constraint atlas_installation_approvals_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_approvals_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_approvals_gate_id_fkey
    foreign key (gate_id)
    references public.atlas_installation_gates(id)
    on delete restrict,
  constraint atlas_installation_approvals_gate_code_fkey
    foreign key (gate_code)
    references public.atlas_installation_gate_definitions(gate_code)
    on delete restrict,
  constraint atlas_installation_approvals_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_approvals_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_installation_approvals_authority_check
    check (authority_type in ('PLATFORM', 'CLIENT')),
  constraint atlas_installation_approvals_decision_check
    check (decision in ('APPROVED', 'REJECTED')),
  constraint atlas_installation_approvals_version_check
    check (gate_version >= 2),
  constraint atlas_installation_approvals_reason_check
    check (decision <> 'REJECTED' or nullif(btrim(reason), '') is not null),
  constraint atlas_installation_approvals_evidence_object_check
    check (jsonb_typeof(evidence) = 'object')
);

create index if not exists idx_atlas_installation_gates_installation_status
  on public.atlas_installation_gates (installation_id, status, gate_code);

create index if not exists idx_atlas_installation_gates_empresa
  on public.atlas_installation_gates (empresa_id, status, updated_at desc);

create index if not exists idx_atlas_installation_approvals_timeline
  on public.atlas_installation_approvals (
    installation_id,
    gate_code,
    created_at desc
  );

create or replace function public.atlas_initialize_installation_gates()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.atlas_installation_gates (
    installation_id,
    empresa_id,
    gate_code,
    status,
    gate_version,
    requires_platform_approval,
    requires_client_approval,
    criteria_snapshot,
    metadata
  )
  select
    new.id,
    new.empresa_id,
    d.gate_code,
    'PENDING',
    1,
    d.requires_platform_approval,
    d.requires_client_approval,
    d.criteria,
    jsonb_build_object(
      'definition_snapshot_at', now(),
      'definition_phase_order', d.phase_order
    )
  from public.atlas_installation_gate_definitions as d
  where d.active = true
  on conflict (installation_id, gate_code) do nothing;

  return new;
end;
$$;

revoke all on function public.atlas_initialize_installation_gates()
  from public, anon, authenticated;
grant execute on function public.atlas_initialize_installation_gates()
  to service_role;

drop trigger if exists trg_atlas_installations_initialize_gates
  on public.atlas_installations;
create trigger trg_atlas_installations_initialize_gates
after insert on public.atlas_installations
for each row execute function public.atlas_initialize_installation_gates();

insert into public.atlas_installation_gates (
  installation_id,
  empresa_id,
  gate_code,
  status,
  gate_version,
  requires_platform_approval,
  requires_client_approval,
  criteria_snapshot,
  metadata
)
select
  i.id,
  i.empresa_id,
  d.gate_code,
  'PENDING',
  1,
  d.requires_platform_approval,
  d.requires_client_approval,
  d.criteria,
  jsonb_build_object(
    'definition_snapshot_at', now(),
    'definition_phase_order', d.phase_order,
    'backfilled', true
  )
from public.atlas_installations as i
cross join public.atlas_installation_gate_definitions as d
where d.active = true
on conflict (installation_id, gate_code) do nothing;

create or replace function public.atlas_block_installation_approval_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_APPROVALS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_installation_approval_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_installation_approval_mutation()
  to service_role;

drop trigger if exists trg_atlas_installation_approvals_append_only
  on public.atlas_installation_approvals;
create trigger trg_atlas_installation_approvals_append_only
before update or delete on public.atlas_installation_approvals
for each row execute function public.atlas_block_installation_approval_mutation();

drop trigger if exists trg_atlas_installation_gate_definitions_updated_at
  on public.atlas_installation_gate_definitions;
create trigger trg_atlas_installation_gate_definitions_updated_at
before update on public.atlas_installation_gate_definitions
for each row execute function public.atlas_set_updated_at();

drop trigger if exists trg_atlas_installation_gates_updated_at
  on public.atlas_installation_gates;
create trigger trg_atlas_installation_gates_updated_at
before update on public.atlas_installation_gates
for each row execute function public.atlas_set_updated_at();

create or replace function public.atlas_can_read_installation(
  p_installation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.atlas_platform_has_permission('INSTALLATION_READ')
    or exists (
      select 1
      from public.atlas_installations as i
      join public.atlas_internal_memberships as im
        on im.empresa_id = i.empresa_id
      where i.id = p_installation_id
        and im.user_id = auth.uid()
        and im.status = 'ACTIVE'
    );
$$;

revoke all on function public.atlas_can_read_installation(uuid)
  from public, anon;
grant execute on function public.atlas_can_read_installation(uuid)
  to authenticated, service_role;

alter table public.atlas_installation_gate_definitions enable row level security;
alter table public.atlas_installation_gates enable row level security;
alter table public.atlas_installation_approvals enable row level security;

revoke all on table public.atlas_installation_gate_definitions
  from anon, authenticated;
revoke all on table public.atlas_installation_gates
  from anon, authenticated;
revoke all on table public.atlas_installation_approvals
  from anon, authenticated;

grant select on table public.atlas_installation_gate_definitions
  to authenticated;
grant select on table public.atlas_installation_gates
  to authenticated;
grant select on table public.atlas_installation_approvals
  to authenticated;

grant all on table public.atlas_installation_gate_definitions
  to service_role;
grant all on table public.atlas_installation_gates
  to service_role;
grant all on table public.atlas_installation_approvals
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_gate_definitions'
      and policyname = 'atlas_installation_gate_definitions_read'
  ) then
    execute $policy$
      create policy atlas_installation_gate_definitions_read
        on public.atlas_installation_gate_definitions
        for select
        to authenticated
        using (active = true)
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_gates'
      and policyname = 'atlas_installation_gates_read'
  ) then
    execute $policy$
      create policy atlas_installation_gates_read
        on public.atlas_installation_gates
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_approvals'
      and policyname = 'atlas_installation_approvals_read'
  ) then
    execute $policy$
      create policy atlas_installation_approvals_read
        on public.atlas_installation_approvals
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_installation_gate_definitions is
  'B2: definiciones canonicas y versionables de gates G01-G04.';

comment on table public.atlas_installation_gates is
  'B2: estado materializado de cada gate dentro de un expediente.';

comment on table public.atlas_installation_approvals is
  'B2: decisiones append-only de autoridades Atlas o cliente sobre gates.';

comment on function public.atlas_can_read_installation(uuid) is
  'B2: frontera de lectura para personal Atlas autorizado o miembros activos del tenant.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2B1_GATE_CORE_INSTALLED',
  'gate_definitions', (
    select count(*)
    from public.atlas_installation_gate_definitions
    where active = true
  ),
  'canonical_criteria', (
    select sum(jsonb_array_length(criteria))
    from public.atlas_installation_gate_definitions
    where active = true
  ),
  'installation_gates', (
    select count(*)
    from public.atlas_installation_gates
  ),
  'approval_records', (
    select count(*)
    from public.atlas_installation_approvals
  ),
  'gate_decide_permission_roles', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code = 'INSTALLATION_GATE_DECIDE'
      and role_code in (
        'ATLAS_OWNER',
        'ATLAS_LEGAL_REVIEWER',
        'ATLAS_SECURITY_REVIEWER'
      )
  ),
  'direct_authenticated_write', false,
  'decisions_enabled', false,
  'next_block', 'B2.2B.2_GATE_DECISION_AND_TRANSITION_ENFORCEMENT'
) as result;
