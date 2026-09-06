-- ATLAS B2.2C.3
-- Aceptacion, cuarentena y rechazo gobernados de archivos.
-- Corte: 2026-08-29
--
-- Prerrequisitos:
--   B2.2C.1, B2.2C.2A y B2.2C.2 instalados y certificados.
--
-- Invariantes:
-- - solo Atlas Security/Owner decide el estado final del archivo;
-- - ACCEPTED exige las siete inspecciones canonicas completas;
-- - NOT_APPLICABLE solo se admite para macros en formatos declarados;
-- - una decision negativa exige motivo, razon canonica y evidencia;
-- - las decisiones son append-only e idempotentes;
-- - SECURITY_VALIDATION no avanza a LEGAL_REVIEW sin archivos reales,
--   todos ACCEPTED.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_files') is null
     or to_regclass('public.atlas_installation_file_inspections') is null
     or to_regclass('storage.objects') is null
     or to_regprocedure(
       'public.atlas_record_installation_file_inspection(uuid,text,text,text,text,text,text,jsonb,jsonb,uuid)'
     ) is null
     or to_regprocedure(
       'public.atlas_transition_installation(uuid,text,text,uuid,bigint)'
     ) is null then
    raise exception 'B2.2C.3 requiere B2.2C.1/C.2A/C.2 certificados';
  end if;
end;
$$;

insert into public.atlas_internal_permissions (
  permission_code,
  description
)
values (
  'INSTALLATION_FILE_DECIDE',
  'Aceptar, poner en cuarentena o rechazar archivos inspeccionados.'
)
on conflict (permission_code) do update
set description = excluded.description;

insert into public.atlas_internal_role_permissions (
  role_code,
  permission_code
)
values
  ('ATLAS_OWNER', 'INSTALLATION_FILE_DECIDE'),
  ('ATLAS_SECURITY_REVIEWER', 'INSTALLATION_FILE_DECIDE')
on conflict (role_code, permission_code) do nothing;

create table if not exists public.atlas_installation_file_decisions (
  id uuid primary key default gen_random_uuid(),
  installation_id uuid not null,
  empresa_id uuid not null,
  file_id uuid not null,
  decision_code text not null,
  from_validation_status text not null,
  to_validation_status text not null,
  reason text not null,
  rejection_reason_code text,
  required_inspection_count integer not null,
  satisfied_inspection_count integer not null,
  inspection_snapshot jsonb not null,
  file_version integer not null,
  sha256 text not null,
  actor_user_id uuid not null,
  actor_role_code text not null,
  request_id uuid not null,
  evidence jsonb not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint atlas_installation_file_decisions_request_key
    unique (file_id, request_id),
  constraint atlas_installation_file_decisions_installation_fkey
    foreign key (installation_id)
    references public.atlas_installations(id)
    on delete restrict,
  constraint atlas_installation_file_decisions_empresa_fkey
    foreign key (empresa_id)
    references public.empresas(id)
    on delete restrict,
  constraint atlas_installation_file_decisions_file_fkey
    foreign key (file_id)
    references public.atlas_installation_files(id)
    on delete restrict,
  constraint atlas_installation_file_decisions_rejection_reason_fkey
    foreign key (rejection_reason_code)
    references public.atlas_installation_file_rejection_reasons(reason_code)
    on delete restrict,
  constraint atlas_installation_file_decisions_actor_user_fkey
    foreign key (actor_user_id)
    references auth.users(id)
    on delete restrict,
  constraint atlas_installation_file_decisions_actor_role_fkey
    foreign key (actor_role_code)
    references public.atlas_internal_roles(role_code)
    on delete restrict,
  constraint atlas_installation_file_decisions_code_check
    check (decision_code in ('ACCEPTED', 'QUARANTINED', 'REJECTED')),
  constraint atlas_installation_file_decisions_from_status_check
    check (
      from_validation_status in (
        'INSPECTION_PENDING',
        'QUARANTINED'
      )
    ),
  constraint atlas_installation_file_decisions_to_status_check
    check (
      to_validation_status = decision_code
      and to_validation_status in (
        'ACCEPTED',
        'QUARANTINED',
        'REJECTED'
      )
    ),
  constraint atlas_installation_file_decisions_reason_check
    check (length(btrim(reason)) >= 3),
  constraint atlas_installation_file_decisions_rejection_check
    check (
      (decision_code = 'ACCEPTED' and rejection_reason_code is null)
      or (
        decision_code in ('QUARANTINED', 'REJECTED')
        and rejection_reason_code is not null
      )
    ),
  constraint atlas_installation_file_decisions_inspection_counts_check
    check (
      required_inspection_count >= 0
      and satisfied_inspection_count >= 0
      and satisfied_inspection_count <= required_inspection_count
      and (
        decision_code <> 'ACCEPTED'
        or satisfied_inspection_count = required_inspection_count
      )
    ),
  constraint atlas_installation_file_decisions_snapshot_check
    check (jsonb_typeof(inspection_snapshot) = 'array'),
  constraint atlas_installation_file_decisions_version_check
    check (file_version >= 1),
  constraint atlas_installation_file_decisions_sha256_check
    check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint atlas_installation_file_decisions_evidence_check
    check (
      jsonb_typeof(evidence) = 'object'
      and evidence <> '{}'::jsonb
    ),
  constraint atlas_installation_file_decisions_metadata_check
    check (jsonb_typeof(metadata) = 'object')
);

create index if not exists idx_atlas_file_decisions_installation
  on public.atlas_installation_file_decisions (
    installation_id,
    decision_code,
    created_at desc
  );

create index if not exists idx_atlas_file_decisions_file
  on public.atlas_installation_file_decisions (
    file_id,
    created_at desc
  );

create or replace function public.atlas_block_installation_file_decision_mutation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception using
    errcode = '42501',
    message = 'ATLAS_INSTALLATION_FILE_DECISIONS_APPEND_ONLY';
end;
$$;

revoke all on function public.atlas_block_installation_file_decision_mutation()
  from public, anon, authenticated;
grant execute on function public.atlas_block_installation_file_decision_mutation()
  to service_role;

drop trigger if exists trg_atlas_installation_file_decisions_append_only
  on public.atlas_installation_file_decisions;
create trigger trg_atlas_installation_file_decisions_append_only
before update or delete on public.atlas_installation_file_decisions
for each row execute function public.atlas_block_installation_file_decision_mutation();

create or replace function public.atlas_decide_installation_file(
  p_file_id uuid,
  p_decision_code text,
  p_reason text,
  p_rejection_reason_code text,
  p_expected_validation_status text,
  p_request_id uuid,
  p_evidence jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
  v_actor_role_code text;
  v_decision_code text := upper(nullif(btrim(p_decision_code), ''));
  v_expected_status text := upper(
    nullif(btrim(p_expected_validation_status), '')
  );
  v_file public.atlas_installation_files%rowtype;
  v_installation public.atlas_installations%rowtype;
  v_existing public.atlas_installation_file_decisions%rowtype;
  v_created public.atlas_installation_file_decisions%rowtype;
  v_rejection_reason public.atlas_installation_file_rejection_reasons%rowtype;
  v_snapshot jsonb := '[]'::jsonb;
  v_required_count integer := 0;
  v_satisfied_count integer := 0;
  v_from_status text;
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_FILE_DECIDE'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_FILE_DECIDE_FORBIDDEN';
  end if;

  if p_file_id is null
     or p_request_id is null
     or v_decision_code is null
     or v_expected_status is null
     or nullif(btrim(p_reason), '') is null
     or p_evidence is null
     or jsonb_typeof(p_evidence) <> 'object'
     or p_evidence = '{}'::jsonb then
    raise exception using
      errcode = '22023',
      message = 'FILE_DECISION_REQUIRED_FIELDS_MISSING';
  end if;

  if v_decision_code not in ('ACCEPTED', 'QUARANTINED', 'REJECTED') then
    raise exception using
      errcode = '22023',
      message = 'FILE_DECISION_CODE_INVALID';
  end if;

  select f.*
  into v_file
  from public.atlas_installation_files as f
  where f.id = p_file_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'INSTALLATION_FILE_NOT_FOUND';
  end if;

  select d.*
  into v_existing
  from public.atlas_installation_file_decisions as d
  where d.file_id = v_file.id
    and d.request_id = p_request_id
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', true,
      'code', 'ALREADY_COMPLETED',
      'decision_id', v_existing.id,
      'file_id', v_existing.file_id,
      'decision', v_existing.decision_code,
      'validation_status', v_existing.to_validation_status,
      'required_inspections', v_existing.required_inspection_count,
      'satisfied_inspections', v_existing.satisfied_inspection_count
    );
  end if;

  select i.*
  into v_installation
  from public.atlas_installations as i
  where i.id = v_file.installation_id;

  if v_installation.current_state_code <> 'SECURITY_VALIDATION' then
    raise exception using
      errcode = '22023',
      message = 'INSTALLATION_NOT_IN_SECURITY_VALIDATION';
  end if;

  if v_file.validation_status <> v_expected_status then
    raise exception using
      errcode = '40001',
      message = 'FILE_VALIDATION_STATUS_CONFLICT';
  end if;

  v_from_status := v_file.validation_status;

  if v_file.validation_status not in (
    'INSPECTION_PENDING',
    'QUARANTINED'
  ) then
    raise exception using
      errcode = '22023',
      message = 'FILE_DECISION_NOT_ALLOWED_FROM_CURRENT_STATUS';
  end if;

  if v_decision_code = 'ACCEPTED'
     and v_file.validation_status <> 'INSPECTION_PENDING' then
    raise exception using
      errcode = '22023',
      message = 'QUARANTINED_FILE_REQUIRES_NEW_CLEAN_VERSION';
  end if;

  if v_decision_code = 'QUARANTINED'
     and v_file.validation_status = 'QUARANTINED' then
    raise exception using
      errcode = '22023',
      message = 'FILE_ALREADY_QUARANTINED';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'inspection_type', latest.inspection_type_code,
        'inspection_status', latest.inspection_status,
        'inspection_id', latest.id,
        'engine_name', latest.engine_name,
        'engine_version', latest.engine_version,
        'detected_mime_type', latest.detected_mime_type,
        'rejection_reason', latest.rejection_reason_code,
        'created_at', latest.created_at
      )
      order by latest.inspection_type_code
    ),
    '[]'::jsonb
  )
  into v_snapshot
  from (
    select distinct on (fi.inspection_type_code)
      fi.*
    from public.atlas_installation_file_inspections as fi
    where fi.file_id = v_file.id
    order by
      fi.inspection_type_code,
      fi.created_at desc,
      fi.id desc
  ) as latest;

  select
    count(*) filter (where it.required_by_default = true),
    count(*) filter (
      where it.required_by_default = true
        and (
          latest.inspection_status = 'PASSED'
          or (
            it.inspection_type_code = 'MACRO_SCAN'
            and latest.inspection_status = 'NOT_APPLICABLE'
            and exists (
              select 1
              from jsonb_array_elements_text(
                coalesce(
                  it.metadata->'not_applicable_extensions',
                  '[]'::jsonb
                )
              ) as allowed_extension(extension)
              where allowed_extension.extension = v_file.extension
            )
          )
        )
    )
  into
    v_required_count,
    v_satisfied_count
  from public.atlas_installation_file_inspection_types as it
  left join lateral (
    select fi.inspection_status
    from public.atlas_installation_file_inspections as fi
    where fi.file_id = v_file.id
      and fi.inspection_type_code = it.inspection_type_code
    order by fi.created_at desc, fi.id desc
    limit 1
  ) as latest on true
  where it.active = true;

  if v_decision_code = 'ACCEPTED' then
    if v_required_count = 0
       or v_satisfied_count <> v_required_count then
      raise exception using
        errcode = '22023',
        message = 'FILE_REQUIRED_INSPECTIONS_INCOMPLETE',
        detail = jsonb_build_object(
          'required', v_required_count,
          'satisfied', v_satisfied_count,
          'snapshot', v_snapshot
        )::text;
    end if;

    if nullif(btrim(v_file.detected_mime_type), '') is null then
      raise exception using
        errcode = '22023',
        message = 'FILE_DETECTED_MIME_REQUIRED_FOR_ACCEPTANCE';
    end if;

    if v_file.rejection_reason_code is not null then
      raise exception using
        errcode = '22023',
        message = 'FILE_WITH_REJECTION_REASON_CANNOT_BE_ACCEPTED';
    end if;

    if p_rejection_reason_code is not null then
      raise exception using
        errcode = '22023',
        message = 'ACCEPTED_FILE_CANNOT_HAVE_REJECTION_REASON';
    end if;

    if not exists (
      select 1
      from storage.objects as o
      where o.bucket_id = v_file.storage_bucket
        and o.name = v_file.storage_object_path
        and o.archived_at is null
        and o.is_delete_marker = false
    ) then
      raise exception using
        errcode = 'P0002',
        message = 'STORAGE_OBJECT_NOT_FOUND_AT_ACCEPTANCE';
    end if;
  else
    select rr.*
    into v_rejection_reason
    from public.atlas_installation_file_rejection_reasons as rr
    where rr.reason_code = upper(
      nullif(btrim(p_rejection_reason_code), '')
    )
      and rr.active = true;

    if not found then
      raise exception using
        errcode = '22023',
        message = 'FILE_NEGATIVE_DECISION_REASON_REQUIRED';
    end if;

    if v_decision_code = 'QUARANTINED'
       and v_rejection_reason.default_disposition <> 'QUARANTINED' then
      raise exception using
        errcode = '22023',
        message = 'FILE_DECISION_DISPOSITION_MISMATCH';
    end if;
  end if;

  select pm.role_code
  into v_actor_role_code
  from public.atlas_platform_memberships as pm
  join public.atlas_internal_roles as r
    on r.role_code = pm.role_code
   and r.active = true
  where pm.user_id = v_actor_user_id
    and pm.status = 'ACTIVE'
  order by r.priority asc, pm.created_at asc
  limit 1;

  insert into public.atlas_installation_file_decisions (
    installation_id,
    empresa_id,
    file_id,
    decision_code,
    from_validation_status,
    to_validation_status,
    reason,
    rejection_reason_code,
    required_inspection_count,
    satisfied_inspection_count,
    inspection_snapshot,
    file_version,
    sha256,
    actor_user_id,
    actor_role_code,
    request_id,
    evidence,
    metadata
  )
  values (
    v_file.installation_id,
    v_file.empresa_id,
    v_file.id,
    v_decision_code,
    v_file.validation_status,
    v_decision_code,
    btrim(p_reason),
    case
      when v_decision_code = 'ACCEPTED' then null
      else v_rejection_reason.reason_code
    end,
    v_required_count,
    v_satisfied_count,
    v_snapshot,
    v_file.file_version,
    v_file.sha256,
    v_actor_user_id,
    v_actor_role_code,
    p_request_id,
    p_evidence,
    jsonb_build_object(
      'expected_validation_status', v_expected_status,
      'decision_engine', 'B2_2C3_V1'
    )
  )
  returning * into v_created;

  update public.atlas_installation_files
  set
    validation_status = v_decision_code,
    rejection_reason_code = case
      when v_decision_code = 'ACCEPTED' then null
      else v_rejection_reason.reason_code
    end,
    updated_at = now()
  where id = v_file.id
  returning * into v_file;

  insert into public.atlas_installation_file_events (
    installation_id,
    empresa_id,
    file_id,
    event_code,
    from_validation_status,
    to_validation_status,
    actor_user_id,
    actor_role_code,
    reason,
    request_id,
    file_version,
    sha256,
    evidence,
    metadata
  )
  values (
    v_file.installation_id,
    v_file.empresa_id,
    v_file.id,
    'FILE_' || v_decision_code,
    v_from_status,
    v_file.validation_status,
    v_actor_user_id,
    v_actor_role_code,
    btrim(p_reason),
    p_request_id,
    v_file.file_version,
    v_file.sha256,
    jsonb_build_object(
      'decision_id', v_created.id,
      'required_inspections', v_required_count,
      'satisfied_inspections', v_satisfied_count,
      'rejection_reason', v_created.rejection_reason_code
    ),
    '{}'::jsonb
  );

  insert into public.atlas_internal_audit_log (
    empresa_id,
    user_id,
    agent_code,
    conversation_id,
    action_type,
    tool_code,
    status,
    input_summary,
    output_summary,
    error_message
  )
  values (
    v_file.empresa_id,
    v_actor_user_id,
    null,
    null,
    'INSTALLATION_FILE_DECIDED',
    'B2_SECURE_FILE_ENGINE',
    'COMPLETED',
    jsonb_build_object(
      'request_id', p_request_id,
      'file_id', v_file.id,
      'decision', v_decision_code,
      'expected_validation_status', v_expected_status
    ),
    jsonb_build_object(
      'decision_id', v_created.id,
      'validation_status', v_file.validation_status,
      'required_inspections', v_required_count,
      'satisfied_inspections', v_satisfied_count
    ),
    null
  );

  return jsonb_build_object(
    'ok', true,
    'code', 'INSTALLATION_FILE_DECIDED',
    'decision_id', v_created.id,
    'file_id', v_file.id,
    'decision', v_created.decision_code,
    'validation_status', v_file.validation_status,
    'required_inspections', v_required_count,
    'satisfied_inspections', v_satisfied_count,
    'rejection_reason', v_file.rejection_reason_code
  );
end;
$$;

revoke all on function public.atlas_decide_installation_file(
  uuid, text, text, text, text, uuid, jsonb
) from public, anon;
grant execute on function public.atlas_decide_installation_file(
  uuid, text, text, text, text, uuid, jsonb
) to authenticated, service_role;

create or replace function public.atlas_enforce_security_file_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total_files bigint;
  v_unaccepted_files bigint;
begin
  if old.current_state_code = 'SECURITY_VALIDATION'
     and new.current_state_code = 'LEGAL_REVIEW' then
    select
      count(*),
      count(*) filter (where f.validation_status <> 'ACCEPTED')
    into
      v_total_files,
      v_unaccepted_files
    from (
      select distinct on (
        source_file.logical_section,
        source_file.canonical_file_name
      )
        source_file.validation_status
      from public.atlas_installation_files as source_file
      where source_file.installation_id = old.id
      order by
        source_file.logical_section,
        source_file.canonical_file_name,
        source_file.file_version desc,
        source_file.created_at desc,
        source_file.id desc
    ) as f;

    if v_total_files = 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_FILES_REQUIRED';
    end if;

    if v_unaccepted_files > 0 then
      raise exception using
        errcode = '42501',
        message = 'SECURITY_VALIDATION_UNACCEPTED_FILES_REMAIN',
        detail = jsonb_build_object(
          'total_files', v_total_files,
          'unaccepted_files', v_unaccepted_files
        )::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.atlas_enforce_security_file_completion()
  from public, anon, authenticated;
grant execute on function public.atlas_enforce_security_file_completion()
  to service_role;

drop trigger if exists trg_atlas_installations_security_file_completion
  on public.atlas_installations;
create trigger trg_atlas_installations_security_file_completion
before update of current_state_code on public.atlas_installations
for each row execute function public.atlas_enforce_security_file_completion();

alter table public.atlas_installation_file_decisions
  enable row level security;

revoke all on table public.atlas_installation_file_decisions
  from anon, authenticated;
grant select on table public.atlas_installation_file_decisions
  to authenticated;
grant all on table public.atlas_installation_file_decisions
  to service_role;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'atlas_installation_file_decisions'
      and policyname = 'atlas_installation_file_decisions_read'
  ) then
    execute $policy$
      create policy atlas_installation_file_decisions_read
        on public.atlas_installation_file_decisions
        for select
        to authenticated
        using (public.atlas_can_read_installation(installation_id))
    $policy$;
  end if;
end;
$$;

comment on table public.atlas_installation_file_decisions is
  'B2: decisiones append-only de aceptacion, cuarentena o rechazo de archivos.';

comment on function public.atlas_decide_installation_file(
  uuid, text, text, text, text, uuid, jsonb
) is
  'B2: decide archivos con inspecciones completas, evidencia, concurrencia e idempotencia.';

comment on function public.atlas_enforce_security_file_completion() is
  'B2: impide salir de SECURITY_VALIDATION sin archivos reales y todos ACCEPTED.';

commit;

select jsonb_build_object(
  'ok', true,
  'code', 'B2_2C3_FILE_ACCEPTANCE_QUARANTINE_INSTALLED',
  'next_action', 'CERTIFY_ACCEPTANCE_AND_FORWARD_TRANSITION_GUARDS',
  'decision_permission_roles', (
    select count(*)
    from public.atlas_internal_role_permissions
    where permission_code = 'INSTALLATION_FILE_DECIDE'
  ),
  'decision_records', (
    select count(*)
    from public.atlas_installation_file_decisions
  ),
  'required_inspection_types', (
    select count(*)
    from public.atlas_installation_file_inspection_types
    where active = true
      and required_by_default = true
  ),
  'decision_rpc_enabled', (
    to_regprocedure(
      'public.atlas_decide_installation_file(uuid,text,text,text,text,uuid,jsonb)'
    ) is not null
  ),
  'security_exit_guard_enabled', (
    select count(*) = 1
    from pg_trigger as t
    join pg_class as c
      on c.oid = t.tgrelid
    where c.oid = 'public.atlas_installations'::regclass
      and t.tgname = 'trg_atlas_installations_security_file_completion'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  ),
  'registered_files', (
    select count(*)
    from public.atlas_installation_files
    where installation_id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_state', (
    select current_state_code
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'current_installation_version', (
    select version
    from public.atlas_installations
    where id = 'f816e940-c609-4172-a79f-8024a1e03f35'::uuid
  ),
  'direct_authenticated_write', false
) as result;
