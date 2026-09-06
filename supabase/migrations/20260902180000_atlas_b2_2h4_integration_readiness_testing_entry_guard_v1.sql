-- ATLAS B2.2H.4
-- Alistamiento objetivo de integraciones y guard de entrada a TESTING.
-- Corte: 2026-09-02
--
-- El manifest define el alcance contratado. La proyeccion compara ese alcance
-- con inventario, configuracion, ultima validacion y evidencia vigente.
-- Este bloque no crea integraciones ni transiciona la instalacion piloto.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_installation_integration_validation_results'
     ) is null
     or to_regclass('public.atlas_installation_manifests') is null
     or to_regclass('public.atlas_installation_files') is null
     or to_regclass('storage.objects') is null
     or to_regprocedure(
       'public.atlas_manifest_payload_is_valid(jsonb)'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_integration_check_results_are_valid(text,jsonb,text)'
     ) is null
     or to_regprocedure(
       'public.atlas_get_installation_certificate_readiness(uuid)'
     ) is null then
    raise exception 'B2.2H.4 requiere B2.2H.3 instalado y certificado';
  end if;
end;
$$;

create or replace function
public.atlas_manifest_integrations_are_valid(
  p_integrations jsonb
)
returns boolean
language plpgsql
stable
strict
security definer
set search_path = public, pg_temp
as $$
begin
  if jsonb_typeof(p_integrations) <> 'array'
     or public.atlas_jsonb_has_forbidden_secret_key(
       p_integrations
     ) then
    return false;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_integrations) as item(value)
    where jsonb_typeof(item.value) <> 'object'
       or not (item.value ?& array[
         'integration_code', 'adapter_code', 'display_name',
         'required', 'environment', 'ownership_type',
         'required_capabilities'
       ])
       or coalesce(item.value->>'integration_code', '') !~
         '^[A-Z][A-Z0-9_]*$'
       or length(item.value->>'integration_code')
         not between 3 and 100
       or coalesce(item.value->>'adapter_code', '') !~
         '^[A-Z][A-Z0-9_]*$'
       or length(btrim(item.value->>'display_name'))
         not between 3 and 160
       or item.value->>'display_name' ~ '[[:cntrl:]]'
       or jsonb_typeof(item.value->'required') <> 'boolean'
       or item.value->>'environment' not in (
         'PRODUCTION', 'SANDBOX', 'TEST'
       )
       or item.value->>'ownership_type' not in (
         'CLIENT_OWNED', 'ATLAS_MANAGED', 'SHARED_RESPONSIBILITY'
       )
       or jsonb_typeof(
         item.value->'required_capabilities'
       ) <> 'array'
       or jsonb_array_length(
         item.value->'required_capabilities'
       ) < 1
       or exists (
         select 1
         from jsonb_array_elements(
           item.value->'required_capabilities'
         ) as capability(value)
         where jsonb_typeof(capability.value) <> 'string'
            or (capability.value #>> '{}') !~
              '^[A-Z][A-Z0-9_]*$'
       )
       or not exists (
         select 1
         from public.atlas_integration_adapter_definitions as adapter
         where adapter.adapter_code = item.value->>'adapter_code'
           and adapter.active
           and (
             select coalesce(
               array_agg(capability.value #>> '{}'),
               array[]::text[]
             )
             from jsonb_array_elements(
               item.value->'required_capabilities'
             ) as capability(value)
           ) <@ adapter.capabilities
           and (item.value->>'ownership_type') =
             any(adapter.ownership_modes)
       )
  ) then
    return false;
  end if;

  if exists (
    select item.value->>'integration_code'
    from jsonb_array_elements(p_integrations) as item(value)
    group by item.value->>'integration_code'
    having count(*) > 1
  ) then
    return false;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_integrations) as item(value)
    cross join lateral jsonb_array_elements(
      item.value->'required_capabilities'
    ) as capability(value)
    group by
      item.value->>'integration_code',
      capability.value #>> '{}'
    having count(*) > 1
  ) then
    return false;
  end if;

  return true;
exception
  when others then
    return false;
end;
$$;

revoke all on function
public.atlas_manifest_integrations_are_valid(jsonb)
from public, anon, authenticated;
grant execute on function
public.atlas_manifest_integrations_are_valid(jsonb)
to service_role;

create or replace function
public.atlas_compute_installation_integration_readiness(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_installation public.atlas_installations%rowtype;
  v_manifest public.atlas_installation_manifests%rowtype;
  v_manifest_integrations jsonb := '[]'::jsonb;
  v_manifest_valid boolean := false;
  v_total_declared bigint := 0;
  v_required_count bigint := 0;
  v_registered_count bigint := 0;
  v_registered_required_count bigint := 0;
  v_validated_registered_count bigint := 0;
  v_validated_required_count bigint := 0;
  v_out_of_scope_count bigint := 0;
  v_stale_validation_count bigint := 0;
  v_invalid_configuration_count bigint := 0;
  v_blockers jsonb := '[]'::jsonb;
  v_evidence_projection jsonb := '[]'::jsonb;
  v_evidence_root_sha256 text;
  v_ready boolean := false;
begin
  if p_installation_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_ID_REQUIRED',
      'ready', false,
      'blockers', jsonb_build_array('INSTALLATION_ID_REQUIRED')
    );
  end if;

  select installation.*
  into v_installation
  from public.atlas_installations as installation
  where installation.id = p_installation_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'INSTALLATION_NOT_FOUND',
      'installation_id', p_installation_id,
      'ready', false,
      'blockers', jsonb_build_array('INSTALLATION_NOT_FOUND')
    );
  end if;

  select manifest.*
  into v_manifest
  from public.atlas_installation_manifests as manifest
  where manifest.installation_id = v_installation.id
    and manifest.empresa_id = v_installation.empresa_id
    and manifest.manifest_status in ('VALIDATED', 'APPROVED')
  order by
    manifest.package_version desc,
    manifest.created_at desc,
    manifest.id desc
  limit 1;

  if not found then
    v_blockers := v_blockers ||
      jsonb_build_array('CURRENT_VALIDATED_MANIFEST_NOT_FOUND');
  else
    v_manifest_integrations := coalesce(
      v_manifest.manifest_payload->'integrations',
      'null'::jsonb
    );

    v_manifest_valid :=
      public.atlas_manifest_payload_is_valid(
        v_manifest.manifest_payload
      )
      and public.atlas_manifest_integrations_are_valid(
        v_manifest_integrations
      )
      and not exists (
        select 1
        from public.atlas_installation_manifests as newer_manifest
        where newer_manifest.installation_id = v_manifest.installation_id
          and newer_manifest.package_id = v_manifest.package_id
          and newer_manifest.package_version > v_manifest.package_version
      )
      and exists (
        select 1
        from public.atlas_installation_files as source_file
        join storage.objects as storage_object
          on storage_object.bucket_id = source_file.storage_bucket
         and storage_object.name = source_file.storage_object_path
         and storage_object.archived_at is null
         and storage_object.is_delete_marker = false
        where source_file.id = v_manifest.source_file_id
          and source_file.installation_id = v_installation.id
          and source_file.empresa_id = v_installation.empresa_id
          and source_file.validation_status = 'ACCEPTED'
          and source_file.sha256 = v_manifest.manifest_sha256
      );

    if not v_manifest_valid then
      v_blockers := v_blockers ||
        jsonb_build_array('MANIFEST_INTEGRATION_CONTRACT_INVALID');
    end if;
  end if;

  if v_manifest_valid then
    select
      count(*),
      count(*) filter (
        where (item.value->>'required')::boolean
      )
    into v_total_declared, v_required_count
    from jsonb_array_elements(v_manifest_integrations) as item(value);

    if v_required_count = 0 then
      v_blockers := v_blockers ||
        jsonb_build_array('NO_REQUIRED_INTEGRATIONS_DECLARED');
    end if;

    select count(*)
    into v_registered_count
    from public.atlas_installation_integrations as integration
    where integration.installation_id = v_installation.id
      and integration.empresa_id = v_installation.empresa_id;

    select count(*)
    into v_registered_required_count
    from jsonb_array_elements(v_manifest_integrations) as item(value)
    where (item.value->>'required')::boolean
      and exists (
        select 1
        from public.atlas_installation_integrations as integration
        where integration.installation_id = v_installation.id
          and integration.empresa_id = v_installation.empresa_id
          and integration.integration_code =
            item.value->>'integration_code'
          and integration.adapter_code = item.value->>'adapter_code'
          and integration.environment = item.value->>'environment'
          and integration.ownership_type =
            item.value->>'ownership_type'
          and integration.required_capabilities <@ (
            select array_agg(capability.value #>> '{}')
            from jsonb_array_elements(
              item.value->'required_capabilities'
            ) as capability(value)
          )
          and (
            select array_agg(capability.value #>> '{}')
            from jsonb_array_elements(
              item.value->'required_capabilities'
            ) as capability(value)
          ) <@ integration.required_capabilities
      );

    if v_registered_required_count <> v_required_count then
      v_blockers := v_blockers ||
        jsonb_build_array('REQUIRED_INTEGRATIONS_MISSING');
    end if;

    select count(*)
    into v_out_of_scope_count
    from public.atlas_installation_integrations as integration
    where integration.installation_id = v_installation.id
      and not exists (
        select 1
        from jsonb_array_elements(v_manifest_integrations) as item(value)
        where item.value->>'integration_code' =
            integration.integration_code
          and item.value->>'adapter_code' = integration.adapter_code
      );

    if v_out_of_scope_count > 0 then
      v_blockers := v_blockers ||
        jsonb_build_array('OUT_OF_SCOPE_INTEGRATIONS_PRESENT');
    end if;

    select count(*)
    into v_invalid_configuration_count
    from public.atlas_installation_integrations as integration
    where integration.installation_id = v_installation.id
      and (
        integration.credential_reference is null
        or not public.atlas_integration_reference_is_safe(
          integration.credential_reference
        )
        or integration.credential_reference_sha256 <>
          public.atlas_normalization_sha256(
            integration.credential_reference
          )
        or integration.non_secret_configuration = '{}'::jsonb
        or integration.configuration_sha256 <>
          public.atlas_normalization_sha256(
            integration.non_secret_configuration::text
          )
      );

    if v_invalid_configuration_count > 0 then
      v_blockers := v_blockers ||
        jsonb_build_array('INTEGRATION_CONFIGURATION_INTEGRITY_INVALID');
    end if;

    select count(*)
    into v_validated_required_count
    from jsonb_array_elements(v_manifest_integrations) as item(value)
    where (item.value->>'required')::boolean
      and exists (
        select 1
        from public.atlas_installation_integrations as integration
        join lateral (
          select result.*
          from public.atlas_installation_integration_validation_results
            as result
          where result.integration_id = integration.id
          order by
            result.validation_attempt desc,
            result.created_at desc,
            result.id desc
          limit 1
        ) as latest_result on true
        where integration.installation_id = v_installation.id
          and integration.empresa_id = v_installation.empresa_id
          and integration.integration_code =
            item.value->>'integration_code'
          and integration.adapter_code = item.value->>'adapter_code'
          and integration.lifecycle_status = 'VALIDATED'
          and integration.last_health_status = 'HEALTHY'
          and integration.validated_at is not null
          and latest_result.outcome = 'PASSED'
          and latest_result.health_status = 'HEALTHY'
          and latest_result.resulting_integration_state_version =
            integration.state_version
          and latest_result.check_results_sha256 =
            public.atlas_normalization_sha256(
              latest_result.check_results::text
            )
          and public.atlas_integration_check_results_are_valid(
            integration.adapter_code,
            latest_result.check_results,
            latest_result.outcome
          )
          and integration.credential_reference_sha256 =
            public.atlas_normalization_sha256(
              integration.credential_reference
            )
          and integration.configuration_sha256 =
            public.atlas_normalization_sha256(
              integration.non_secret_configuration::text
            )
      );

    if v_validated_required_count <> v_required_count then
      v_blockers := v_blockers ||
        jsonb_build_array('REQUIRED_INTEGRATIONS_NOT_VALIDATED');
    end if;

    select count(*)
    into v_validated_registered_count
    from public.atlas_installation_integrations as integration
    join lateral (
      select result.*
      from public.atlas_installation_integration_validation_results
        as result
      where result.integration_id = integration.id
      order by
        result.validation_attempt desc,
        result.created_at desc,
        result.id desc
      limit 1
    ) as latest_result on true
    where integration.installation_id = v_installation.id
      and integration.empresa_id = v_installation.empresa_id
      and integration.lifecycle_status = 'VALIDATED'
      and integration.last_health_status = 'HEALTHY'
      and integration.validated_at is not null
      and latest_result.outcome = 'PASSED'
      and latest_result.health_status = 'HEALTHY'
      and latest_result.resulting_integration_state_version =
        integration.state_version
      and latest_result.check_results_sha256 =
        public.atlas_normalization_sha256(
          latest_result.check_results::text
        )
      and public.atlas_integration_check_results_are_valid(
        integration.adapter_code,
        latest_result.check_results,
        latest_result.outcome
      )
      and integration.credential_reference_sha256 =
        public.atlas_normalization_sha256(
          integration.credential_reference
        )
      and integration.configuration_sha256 =
        public.atlas_normalization_sha256(
          integration.non_secret_configuration::text
        );

    if v_validated_registered_count <> v_registered_count then
      v_blockers := v_blockers ||
        jsonb_build_array('REGISTERED_INTEGRATIONS_NOT_VALIDATED');
    end if;

    select count(*)
    into v_stale_validation_count
    from public.atlas_installation_integrations as integration
    where integration.installation_id = v_installation.id
      and exists (
        select 1
        from jsonb_array_elements(v_manifest_integrations) as item(value)
        where (item.value->>'required')::boolean
          and item.value->>'integration_code' =
            integration.integration_code
          and item.value->>'adapter_code' = integration.adapter_code
      )
      and not exists (
        select 1
        from public.atlas_installation_integration_validation_results
          as result
        where result.integration_id = integration.id
          and result.resulting_integration_state_version =
            integration.state_version
          and result.outcome = 'PASSED'
          and result.health_status = 'HEALTHY'
          and result.validation_attempt = (
            select max(latest.validation_attempt)
            from public.atlas_installation_integration_validation_results
              as latest
            where latest.integration_id = integration.id
          )
      );

    if v_stale_validation_count > 0 then
      v_blockers := v_blockers ||
        jsonb_build_array('INTEGRATION_VALIDATION_STALE_OR_MISSING');
    end if;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'integration_code', integration.integration_code,
          'adapter_code', integration.adapter_code,
          'integration_state_version', integration.state_version,
          'configuration_sha256', integration.configuration_sha256,
          'credential_reference_sha256',
            integration.credential_reference_sha256,
          'validation_attempt', result.validation_attempt,
          'check_results_sha256', result.check_results_sha256,
          'evidence_sha256', result.evidence_sha256
        )
        order by integration.integration_code
      ),
      '[]'::jsonb
    )
    into v_evidence_projection
    from public.atlas_installation_integrations as integration
    join lateral (
      select latest.*
      from public.atlas_installation_integration_validation_results
        as latest
      where latest.integration_id = integration.id
      order by latest.validation_attempt desc
      limit 1
    ) as result on true
    where integration.installation_id = v_installation.id;
  end if;

  v_evidence_root_sha256 := public.atlas_normalization_sha256(
    jsonb_build_object(
      'contract_version', 'B2_INTEGRATION_READINESS_V1',
      'installation_id', v_installation.id,
      'installation_version', v_installation.version,
      'manifest_id', v_manifest.id,
      'manifest_sha256', v_manifest.manifest_sha256,
      'integration_evidence', v_evidence_projection
    )::text
  );

  v_ready :=
    v_manifest_valid
    and v_required_count > 0
    and v_registered_count >= v_required_count
    and v_registered_required_count = v_required_count
    and v_validated_registered_count = v_registered_count
    and v_validated_required_count = v_required_count
    and v_out_of_scope_count = 0
    and v_stale_validation_count = 0
    and v_invalid_configuration_count = 0
    and jsonb_array_length(v_blockers) = 0;

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'INTEGRATION_READINESS_COMPLETE'
      else 'INTEGRATION_READINESS_INCOMPLETE'
    end,
    'contract_version', 'B2_INTEGRATION_READINESS_V1',
    'installation_id', v_installation.id,
    'empresa_id', v_installation.empresa_id,
    'installation_state', v_installation.current_state_code,
    'installation_version', v_installation.version,
    'manifest_id', v_manifest.id,
    'manifest_sha256', v_manifest.manifest_sha256,
    'manifest_integrations_valid', v_manifest_valid,
    'total_manifest_integrations', v_total_declared,
    'required_integrations', v_required_count,
    'registered_integrations', v_registered_count,
    'registered_required_integrations',
      v_registered_required_count,
    'validated_registered_integrations',
      v_validated_registered_count,
    'validated_required_integrations',
      v_validated_required_count,
    'out_of_scope_integrations', v_out_of_scope_count,
    'stale_validations', v_stale_validation_count,
    'invalid_configurations', v_invalid_configuration_count,
    'evidence_root_sha256', v_evidence_root_sha256,
    'ready', v_ready,
    'blockers', v_blockers,
    'credential_values_exposed', false,
    'raw_provider_payloads_exposed', false,
    'next_action', case
      when v_ready then 'START_TESTING'
      else 'COMPLETE_OR_REMEDIATE_INTEGRATIONS'
    end
  );
end;
$$;

revoke all on function
public.atlas_compute_installation_integration_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_compute_installation_integration_readiness(uuid)
to service_role;

create or replace function
public.atlas_get_installation_integration_readiness(
  p_installation_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_user_id uuid := auth.uid();
begin
  if v_actor_user_id is null then
    raise exception using
      errcode = '42501', message = 'AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission(
    'INSTALLATION_INTEGRATION_READ'
  ) then
    raise exception using
      errcode = '42501',
      message = 'INSTALLATION_INTEGRATION_READ_FORBIDDEN';
  end if;

  if p_installation_id is null then
    raise exception using
      errcode = '22023', message = 'INSTALLATION_ID_REQUIRED';
  end if;

  return public.atlas_compute_installation_integration_readiness(
    p_installation_id
  );
end;
$$;

revoke all on function
public.atlas_get_installation_integration_readiness(uuid)
from public, anon, authenticated;
grant execute on function
public.atlas_get_installation_integration_readiness(uuid)
to authenticated, service_role;

create or replace function
public.atlas_enforce_integration_testing_entry_readiness()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_readiness jsonb;
begin
  if old.current_state_code = 'INTEGRATION_SETUP'
     and new.current_state_code = 'TESTING' then
    v_readiness :=
      public.atlas_compute_installation_integration_readiness(old.id);

    if not coalesce((v_readiness->>'ready')::boolean, false) then
      raise exception using
        errcode = '42501',
        message = 'INTEGRATION_READINESS_STALE_OR_INCOMPLETE',
        detail = v_readiness::text;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function
public.atlas_enforce_integration_testing_entry_readiness()
from public, anon, authenticated;
grant execute on function
public.atlas_enforce_integration_testing_entry_readiness()
to service_role;

drop trigger if exists trg_atlas_integration_testing_entry_readiness
on public.atlas_installations;
create trigger trg_atlas_integration_testing_entry_readiness
before update of current_state_code
on public.atlas_installations
for each row execute function
public.atlas_enforce_integration_testing_entry_readiness();

comment on function
public.atlas_manifest_integrations_are_valid(jsonb) is
  'B2: valida el alcance de integraciones declarado por el manifest.';
comment on function
public.atlas_compute_installation_integration_readiness(uuid) is
  'B2: deriva readiness desde manifest, inventario, hashes y evidencia vigente.';
comment on function
public.atlas_get_installation_integration_readiness(uuid) is
  'B2: frontera interna de lectura para readiness de integraciones.';
comment on function
public.atlas_enforce_integration_testing_entry_readiness() is
  'B2: impide START_TESTING sin integraciones requeridas verificadas.';

commit;

select jsonb_build_object(
  'ok', true,
  'code',
    'B2_2H4_INTEGRATION_READINESS_TESTING_ENTRY_GUARD_INSTALLED',
  'next_action', 'CERTIFY_H4_READINESS_AND_TRANSITION_GUARD',
  'readiness_rpcs', 1,
  'readiness_helpers', 2,
  'testing_entry_guards', 1,
  'manifest_scope_binding_enabled', true,
  'missing_required_integrations_blocked', true,
  'out_of_scope_integrations_blocked', true,
  'stale_validation_blocked', true,
  'configuration_hash_revalidation_enabled', true,
  'credential_reference_hash_revalidation_enabled', true,
  'evidence_root_sha256_enabled', true,
  'credential_values_exposed', false,
  'raw_provider_payloads_exposed', false,
  'active_auto_transition_enabled', false,
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
  ),
  'direct_authenticated_write', false
) as result;
