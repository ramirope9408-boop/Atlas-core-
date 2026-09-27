-- ATLAS B2 conversation scenario renderer contract V1
-- Date: 2026-09-27
-- Produces execution-ready, company-bound scenario payloads from
-- resolved bindings while keeping provider/model execution external.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_resolve_conversation_scenario_bindings_v1(uuid)'
     ) is null
     or to_regclass(
       'public.atlas_conversation_test_scenario_instances'
     ) is null
     or to_regprocedure(
       'public.atlas_normalization_sha256(text)'
     ) is null then
    raise exception
      'Conversation scenario renderer requires binding resolver and scenario instance core';
  end if;
end;
$$;

create or replace function
public.atlas_render_conversation_scenario_payload_v1(
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
  v_resolution jsonb;
  v_bindings jsonb;
  v_prompt text;
  v_rendered text;
  v_expected text[];
  v_payload jsonb;
  v_payload_sha256 text;
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

  v_resolution :=
    public.atlas_resolve_conversation_scenario_bindings_v1(
      p_scenario_instance_id
    );

  if not coalesce((v_resolution->>'ready')::boolean, false) then
    return v_resolution || jsonb_build_object(
      'code', 'SCENARIO_RENDER_BLOCKED_BY_BINDINGS',
      'ready', false
    );
  end if;

  v_bindings := v_resolution->'bindings';
  v_prompt := v_instance.prompt_template;
  v_rendered := v_prompt;

  -- Generic replacements only. These placeholders are scenario contracts,
  -- not company-specific literals.
  v_rendered := replace(
    v_rendered,
    '{{CANONICAL_ENTITY}}',
    coalesce(v_bindings->>'canonical_entity', 'CANONICAL_ENTITY')
  );
  v_rendered := replace(
    v_rendered,
    '{{CANONICAL_ENTITY_OR_FAMILY}}',
    coalesce(v_bindings->>'canonical_entity', 'CANONICAL_ENTITY')
  );
  v_rendered := replace(
    v_rendered,
    '{{UNSUPPORTED_ATTRIBUTE}}',
    coalesce(v_bindings->>'unsupported_attribute', 'UNSUPPORTED_ATTRIBUTE')
  );
  v_rendered := replace(
    v_rendered,
    '{{ACKNOWLEDGEMENT_PHRASE}}',
    'ACKNOWLEDGEMENT_IN_INSTALLED_LOCALE'
  );
  v_rendered := replace(
    v_rendered,
    '{{ACCEPTANCE_PHRASE}}',
    'EXPLICIT_ACCEPTANCE_IN_INSTALLED_LOCALE'
  );
  v_rendered := replace(
    v_rendered,
    '{{INITIAL_REQUEST}}',
    coalesce(v_bindings->>'initial_entity', 'INITIAL_CANONICAL_REQUEST')
  );
  v_rendered := replace(
    v_rendered,
    '{{CORRECTED_REQUEST}}',
    coalesce(v_bindings->>'corrected_entity', 'CORRECTED_CANONICAL_REQUEST')
  );
  v_rendered := replace(
    v_rendered,
    '{{CURRENT_MODIFICATION_REQUEST}}',
    'MODIFICATION_OF_CURRENT_VISIBLE_OBJECT'
  );
  v_rendered := replace(
    v_rendered,
    '{{AMBIGUOUS_COMMERCIAL_REQUEST}}',
    coalesce(
      v_bindings->>'canonical_entity',
      'AMBIGUOUS_CANONICAL_COMMERCIAL_REQUEST'
    )
  );
  v_rendered := replace(
    v_rendered,
    '{{CANONICAL_ENTITY_QUESTION}}',
    coalesce(
      v_bindings->>'canonical_entity',
      'CANONICAL_ENTITY_QUESTION'
    )
  );

  v_expected := v_instance.expected_assertion_codes;

  v_payload := jsonb_build_object(
    'contract_version', 'B2_CONVERSATION_SCENARIO_EXECUTION_INPUT_V1',
    'scenario_instance_id', v_instance.id,
    'scenario_plan_id', v_instance.scenario_plan_id,
    'test_plan_id', v_instance.test_plan_id,
    'installation_id', v_instance.installation_id,
    'empresa_id', v_instance.empresa_id,
    'canonical_data_version_id',
      v_instance.canonical_data_version_id,
    'scenario_code', v_instance.scenario_code,
    'rendered_prompt', v_rendered,
    'binding_sha256', v_resolution->>'binding_sha256',
    'expected_assertion_codes', to_jsonb(v_expected),
    'execution_policy', jsonb_build_object(
      'must_use_current_installed_runtime', true,
      'must_use_current_company_context', true,
      'must_not_override_company_policy', true,
      'must_not_invent_missing_business_facts', true,
      'must_capture_redacted_evidence', true,
      'must_preserve_current_conversation_state', true
    ),
    'raw_canonical_values_persisted', false
  );

  v_payload_sha256 :=
    public.atlas_normalization_sha256(v_payload::text);

  return jsonb_build_object(
    'ok', true,
    'code', 'SCENARIO_EXECUTION_PAYLOAD_READY',
    'ready', true,
    'scenario_instance_id', v_instance.id,
    'scenario_code', v_instance.scenario_code,
    'payload', v_payload,
    'payload_sha256', v_payload_sha256,
    'next_action', 'EXECUTE_AGAINST_INSTALLED_RUNTIME'
  );
end;
$$;

revoke all on function
public.atlas_render_conversation_scenario_payload_v1(uuid)
from public, anon, authenticated;

grant execute on function
public.atlas_render_conversation_scenario_payload_v1(uuid)
to service_role;

commit;
