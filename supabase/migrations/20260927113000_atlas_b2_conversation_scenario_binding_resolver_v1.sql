-- ATLAS B2 conversation scenario binding resolver V1
-- Date: 2026-09-27
-- Resolves generic scenario placeholders against the approved canonical
-- company version without embedding FingerFood-specific assumptions.
-- Service-role only because canonical values may include confidential data.

begin;

do $$
begin
  if to_regclass(
       'public.atlas_conversation_test_scenario_instances'
     ) is null
     or to_regclass(
       'public.atlas_canonical_data_versions'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception
      'Conversation scenario resolver requires scenario materialization and canonical data core';
  end if;
end;
$$;

create or replace function
public.atlas_canonical_record_display_label_v1(
  p_record jsonb
)
returns text
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_value jsonb;
  v_label text;
begin
  v_value := p_record->'value';

  if jsonb_typeof(v_value) = 'object' then
    v_label := coalesce(
      nullif(btrim(v_value->>'display_name'), ''),
      nullif(btrim(v_value->>'name'), ''),
      nullif(btrim(v_value->>'title'), ''),
      nullif(btrim(v_value->>'label'), ''),
      nullif(btrim(v_value->>'product_name'), ''),
      nullif(btrim(v_value->>'service_name'), '')
    );
  elsif jsonb_typeof(v_value) = 'string' then
    v_label := nullif(btrim(v_value #>> '{}'), '');
  end if;

  return coalesce(
    v_label,
    nullif(btrim(p_record->>'record_key'), ''),
    'CANONICAL_ENTITY'
  );
end;
$$;

revoke all on function
public.atlas_canonical_record_display_label_v1(jsonb)
from public, anon, authenticated;
grant execute on function
public.atlas_canonical_record_display_label_v1(jsonb)
to service_role;

create or replace function
public.atlas_pick_unsupported_attribute_v1(
  p_record jsonb
)
returns text
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_value jsonb := p_record->'value';
  v_candidates text[] := array[
    'popularity',
    'ranking',
    'customer_preference',
    'demand_score',
    'best_seller_rank'
  ]::text[];
  v_candidate text;
begin
  foreach v_candidate in array v_candidates loop
    if jsonb_typeof(v_value) <> 'object'
       or not (v_value ? v_candidate) then
      return v_candidate;
    end if;
  end loop;

  return 'UNSUPPORTED_DERIVED_ATTRIBUTE';
end;
$$;

revoke all on function
public.atlas_pick_unsupported_attribute_v1(jsonb)
from public, anon, authenticated;
grant execute on function
public.atlas_pick_unsupported_attribute_v1(jsonb)
to service_role;

create or replace function
public.atlas_resolve_conversation_scenario_bindings_v1(
  p_scenario_instance_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_instance
    public.atlas_conversation_test_scenario_instances%rowtype;
  v_canonical
    public.atlas_canonical_data_versions%rowtype;
  v_records jsonb;
  v_product_records jsonb := '[]'::jsonb;
  v_policy_records jsonb := '[]'::jsonb;
  v_payment_records jsonb := '[]'::jsonb;
  v_template_records jsonb := '[]'::jsonb;
  v_media_records jsonb := '[]'::jsonb;
  v_faq_records jsonb := '[]'::jsonb;
  v_primary jsonb;
  v_secondary jsonb;
  v_bindings jsonb := '{}'::jsonb;
  v_requirements jsonb := '{}'::jsonb;
  v_ready boolean := true;
  v_blockers jsonb := '[]'::jsonb;
  v_binding_sha256 text;
begin
  if p_scenario_instance_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'SCENARIO_INSTANCE_ID_REQUIRED',
      'ready', false
    );
  end if;

  select instance.*
  into v_instance
  from public.atlas_conversation_test_scenario_instances as instance
  where instance.id = p_scenario_instance_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_INSTANCE_NOT_FOUND',
      'ready', false
    );
  end if;

  if v_instance.applicability_status <> 'APPLICABLE' then
    return jsonb_build_object(
      'ok', true,
      'code', 'CONVERSATION_SCENARIO_NOT_APPLICABLE',
      'ready', false,
      'scenario_instance_id', v_instance.id,
      'scenario_code', v_instance.scenario_code
    );
  end if;

  select canonical.*
  into v_canonical
  from public.atlas_canonical_data_versions as canonical
  where canonical.id = v_instance.canonical_data_version_id
    and canonical.installation_id = v_instance.installation_id
    and canonical.empresa_id = v_instance.empresa_id
    and canonical.version_status = 'APPROVED'
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'BOUND_CANONICAL_VERSION_NOT_FOUND',
      'ready', false
    );
  end if;

  if v_canonical.canonical_sha256 <>
       public.atlas_normalization_sha256(
         v_canonical.canonical_payload::text
       ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'BOUND_CANONICAL_VERSION_HASH_MISMATCH',
      'ready', false
    );
  end if;

  v_records := v_canonical.canonical_payload->'records';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_product_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'PRODUCTS_SERVICES';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_policy_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'COMMERCIAL_POLICIES';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_payment_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'PAYMENT_METHODS_TERMS';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_template_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'QUOTES_AND_TEMPLATES';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_media_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'MEDIA_TECHNICAL_DOCUMENTS';

  select coalesce(jsonb_agg(record.value order by record.ordinality), '[]'::jsonb)
  into v_faq_records
  from jsonb_array_elements(v_records)
    with ordinality as record(value, ordinality)
  where record.value->>'inventory_code' = 'FAQ_SERVICE_LIMITS';

  if jsonb_array_length(v_product_records) > 0 then
    v_primary := v_product_records->0;
  end if;

  if jsonb_array_length(v_product_records) > 1 then
    v_secondary := v_product_records->1;
  else
    v_secondary := v_primary;
  end if;

  case v_instance.scenario_code
    when 'DIRECT_CANONICAL_LOOKUP' then
      if v_primary is null and jsonb_array_length(v_faq_records) = 0 then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'CANONICAL_LOOKUP_SOURCE_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'canonical_entity',
            case when v_primary is null
              then null
              else public.atlas_canonical_record_display_label_v1(v_primary)
            end,
          'canonical_record_key',
            case when v_primary is null then null
              else v_primary->>'record_key' end,
          'fallback_faq_available',
            jsonb_array_length(v_faq_records) > 0
        );
      end if;

    when 'UNSUPPORTED_ATTRIBUTE_REJECTION' then
      if v_primary is null then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'PRODUCT_OR_SERVICE_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'canonical_entity',
            public.atlas_canonical_record_display_label_v1(v_primary),
          'canonical_record_key', v_primary->>'record_key',
          'unsupported_attribute',
            public.atlas_pick_unsupported_attribute_v1(v_primary)
        );
      end if;

    when 'AMBIGUOUS_COMMERCIAL_REQUEST' then
      if v_primary is null then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'PRODUCT_OR_SERVICE_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'canonical_entity',
            public.atlas_canonical_record_display_label_v1(v_primary),
          'canonical_record_key', v_primary->>'record_key',
          'ambiguity_dimension', 'QUANTITY_OR_VARIANT_OR_DATE'
        );
      end if;

    when 'ACKNOWLEDGEMENT_NO_RETRIGGER' then
      v_bindings := jsonb_build_object(
        'acknowledgement_semantic',
          'NON_ACTION_CONTINUATION',
        'locale_resolution',
          'USE_INSTALLED_AGENT_LANGUAGE_PROFILE'
      );

    when 'SELF_CORRECTION_FINAL_INTENT' then
      if v_primary is null then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'PRODUCT_OR_SERVICE_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'initial_entity',
            public.atlas_canonical_record_display_label_v1(v_primary),
          'initial_record_key', v_primary->>'record_key',
          'corrected_entity',
            public.atlas_canonical_record_display_label_v1(v_secondary),
          'corrected_record_key', v_secondary->>'record_key',
          'locale_resolution',
            'USE_INSTALLED_AGENT_LANGUAGE_PROFILE'
        );
      end if;

    when 'POST_MODIFICATION_ACK_NO_LOOP' then
      v_bindings := jsonb_build_object(
        'state_precondition',
          'SUCCESSFUL_MODIFICATION_ALREADY_APPLIED',
        'acknowledgement_semantic',
          'NON_ACTION_CONTINUATION',
        'locale_resolution',
          'USE_INSTALLED_AGENT_LANGUAGE_PROFILE'
      );

    when 'EXPLICIT_ACCEPTANCE_REQUIRED' then
      if jsonb_array_length(v_policy_records) = 0 then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'COMMERCIAL_POLICY_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'state_precondition',
            'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
          'acceptance_semantic',
            'EXPLICIT_ACCEPTANCE',
          'locale_resolution',
            'USE_INSTALLED_AGENT_LANGUAGE_PROFILE'
        );
      end if;

    when 'NON_ACCEPTANCE_ACK_BLOCKED' then
      v_bindings := jsonb_build_object(
        'state_precondition',
          'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
        'acknowledgement_semantic',
          'NON_ACCEPTANCE_CONTINUATION',
        'locale_resolution',
          'USE_INSTALLED_AGENT_LANGUAGE_PROFILE'
      );

    when 'MODIFICATION_OVERRIDES_STALE_ACCEPTANCE' then
      if v_primary is null then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'PRODUCT_OR_SERVICE_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'state_precondition',
            'CURRENT_VISIBLE_COMMERCIAL_OBJECT',
          'canonical_entity',
            public.atlas_canonical_record_display_label_v1(v_primary),
          'canonical_record_key', v_primary->>'record_key',
          'intent_semantic',
            'CURRENT_MODIFICATION_OVERRIDES_STALE_ACCEPTANCE'
        );
      end if;

    when 'PAYMENT_BEFORE_ACCEPTANCE_BLOCKED' then
      if jsonb_array_length(v_payment_records) = 0 then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'PAYMENT_POLICY_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'state_precondition',
            'NO_VALID_ACCEPTANCE_FOR_CURRENT_OBJECT',
          'expected_action',
            'PAYMENT_ACTION_BLOCKED'
        );
      end if;

    when 'VISUAL_FAMILY_REFERENCE' then
      if v_primary is null
         or jsonb_array_length(v_media_records) = 0 then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'CANONICAL_MEDIA_BINDING_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'canonical_entity',
            public.atlas_canonical_record_display_label_v1(v_primary),
          'canonical_record_key', v_primary->>'record_key',
          'media_record_count',
            jsonb_array_length(v_media_records),
          'resolver_priority',
            'CURRENT_MESSAGE_BEFORE_STALE_MEMORY'
        );
      end if;

    when 'DOCUMENT_CURRENT_VERSION_BINDING' then
      if jsonb_array_length(v_template_records) = 0 then
        v_ready := false;
        v_blockers := v_blockers || jsonb_build_array(
          jsonb_build_object(
            'code', 'DOCUMENT_TEMPLATE_CANONICAL_RECORD_REQUIRED'
          )
        );
      else
        v_bindings := jsonb_build_object(
          'state_precondition',
            'CURRENT_CANONICAL_COMMERCIAL_OBJECT_AFTER_MODIFICATION',
          'template_record_count',
            jsonb_array_length(v_template_records),
          'expected_binding',
            'LATEST_CURRENT_OBJECT_VERSION'
        );
      end if;

    else
      v_ready := false;
      v_blockers := v_blockers || jsonb_build_array(
        jsonb_build_object(
          'code', 'SCENARIO_BINDING_RESOLVER_NOT_IMPLEMENTED'
        )
      );
  end case;

  v_requirements := jsonb_build_object(
    'canonical_data_version_id', v_canonical.id,
    'canonical_sha256', v_canonical.canonical_sha256,
    'inventory_counts', jsonb_build_object(
      'products_services', jsonb_array_length(v_product_records),
      'commercial_policies', jsonb_array_length(v_policy_records),
      'payment_terms', jsonb_array_length(v_payment_records),
      'quote_templates', jsonb_array_length(v_template_records),
      'media', jsonb_array_length(v_media_records),
      'faq', jsonb_array_length(v_faq_records)
    )
  );

  v_binding_sha256 :=
    public.atlas_normalization_sha256(
      jsonb_build_object(
        'scenario_instance_id', v_instance.id,
        'scenario_code', v_instance.scenario_code,
        'canonical_data_version_id', v_canonical.id,
        'bindings', v_bindings,
        'requirements', v_requirements
      )::text
    );

  return jsonb_build_object(
    'ok', true,
    'code', case
      when v_ready then 'SCENARIO_BINDINGS_RESOLVED'
      else 'SCENARIO_BINDINGS_INCOMPLETE'
    end,
    'ready', v_ready,
    'scenario_instance_id', v_instance.id,
    'scenario_code', v_instance.scenario_code,
    'installation_id', v_instance.installation_id,
    'empresa_id', v_instance.empresa_id,
    'canonical_data_version_id', v_canonical.id,
    'prompt_template', v_instance.prompt_template,
    'bindings', v_bindings,
    'requirements', v_requirements,
    'blockers', v_blockers,
    'binding_sha256', v_binding_sha256,
    'raw_canonical_values_exposed', false,
    'next_action', case
      when v_ready then 'RENDER_AND_EXECUTE_SCENARIO'
      else 'REMEDIATE_CANONICAL_INPUT_OR_BINDING'
    end
  );
end;
$$;

revoke all on function
public.atlas_resolve_conversation_scenario_bindings_v1(uuid)
from public, anon, authenticated;

grant execute on function
public.atlas_resolve_conversation_scenario_bindings_v1(uuid)
to service_role;

commit;
