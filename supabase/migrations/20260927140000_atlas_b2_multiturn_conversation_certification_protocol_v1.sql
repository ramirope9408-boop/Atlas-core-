-- ATLAS B2 multi-turn conversation certification protocol V1
-- Date: 2026-09-27
-- Adds explicit scenario steps so stateful behaviors are tested against
-- real conversational preconditions instead of inferred from a single message.

begin;

do $$
begin
  if to_regclass('public.atlas_conversation_test_scenario_definitions') is null
     or to_regclass('public.atlas_conversation_test_scenario_instances') is null
     or to_regprocedure(
       'public.atlas_resolve_conversation_scenario_bindings_v1(uuid)'
     ) is null then
    raise exception
      'Multi-turn certification requires scenario registry, instances and binding resolver';
  end if;

  if to_regclass('public.atlas_conversation_test_scenario_step_definitions') is not null then
    raise exception
      'Conversation scenario step definitions already exist; reconcile before install';
  end if;
end;
$$;

create table public.atlas_conversation_test_scenario_step_definitions (
  scenario_code text not null,
  step_order integer not null,
  step_code text not null,
  actor_role text not null,
  step_type text not null,
  message_template text,
  expected_state_semantic text,
  required_for_assertion boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  primary key (scenario_code, step_order),
  unique (scenario_code, step_code),

  constraint atlas_conversation_step_definition_scenario_fkey
    foreign key (scenario_code)
    references public.atlas_conversation_test_scenario_definitions(scenario_code)
    on delete restrict,

  constraint atlas_conversation_step_definition_order_check
    check (step_order between 1 and 1000),

  constraint atlas_conversation_step_definition_code_check
    check (
      step_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(step_code) between 3 and 120
    ),

  constraint atlas_conversation_step_definition_actor_check
    check (actor_role in ('CUSTOMER','SYSTEM_ASSERTION')),

  constraint atlas_conversation_step_definition_type_check
    check (step_type in ('MESSAGE','ASSERT_STATE')),

  constraint atlas_conversation_step_definition_message_check
    check (
      (step_type = 'MESSAGE' and message_template is not null)
      or (step_type = 'ASSERT_STATE' and expected_state_semantic is not null)
    ),

  constraint atlas_conversation_step_definition_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_conversation_test_scenario_step_definitions(
  scenario_code, step_order, step_code, actor_role, step_type,
  message_template, expected_state_semantic, required_for_assertion
) values
  ('DIRECT_CANONICAL_LOOKUP', 10, 'ASK_CANONICAL_ENTITY', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_CANONICAL_QUESTION}}', null, true),

  ('UNSUPPORTED_ATTRIBUTE_REJECTION', 10, 'ASK_UNSUPPORTED_ATTRIBUTE', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_UNSUPPORTED_ATTRIBUTE_QUESTION}}', null, true),

  ('AMBIGUOUS_COMMERCIAL_REQUEST', 10, 'SEND_AMBIGUOUS_REQUEST', 'CUSTOMER', 'MESSAGE',
   '{{AMBIGUOUS_COMMERCIAL_REQUEST}}', null, true),

  ('ACKNOWLEDGEMENT_NO_RETRIGGER', 10, 'CREATE_PRIOR_ACTION_CONTEXT', 'CUSTOMER', 'MESSAGE',
   '{{CANONICAL_ENTITY_QUESTION}}', null, false),
  ('ACKNOWLEDGEMENT_NO_RETRIGGER', 20, 'SEND_ACKNOWLEDGEMENT', 'CUSTOMER', 'MESSAGE',
   '{{ACKNOWLEDGEMENT_PHRASE}}', null, true),

  ('SELF_CORRECTION_FINAL_INTENT', 10, 'SEND_SELF_CORRECTION', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_SELF_CORRECTION}}', null, true),

  ('POST_MODIFICATION_ACK_NO_LOOP', 10, 'CREATE_COMMERCIAL_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('POST_MODIFICATION_ACK_NO_LOOP', 20, 'APPLY_MODIFICATION', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_MODIFICATION_REQUEST}}', null, false),
  ('POST_MODIFICATION_ACK_NO_LOOP', 30, 'SEND_POST_MODIFICATION_ACK', 'CUSTOMER', 'MESSAGE',
   '{{ACKNOWLEDGEMENT_PHRASE}}', null, true),

  ('EXPLICIT_ACCEPTANCE_REQUIRED', 10, 'CREATE_VISIBLE_COMMERCIAL_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('EXPLICIT_ACCEPTANCE_REQUIRED', 20, 'SEND_EXPLICIT_ACCEPTANCE', 'CUSTOMER', 'MESSAGE',
   '{{ACCEPTANCE_PHRASE}}', null, true),

  ('NON_ACCEPTANCE_ACK_BLOCKED', 10, 'CREATE_VISIBLE_COMMERCIAL_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('NON_ACCEPTANCE_ACK_BLOCKED', 20, 'SEND_NON_ACCEPTANCE_ACK', 'CUSTOMER', 'MESSAGE',
   '{{ACKNOWLEDGEMENT_PHRASE}}', null, true),

  ('MODIFICATION_OVERRIDES_STALE_ACCEPTANCE', 10, 'CREATE_VISIBLE_COMMERCIAL_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('MODIFICATION_OVERRIDES_STALE_ACCEPTANCE', 20, 'SEND_CURRENT_MODIFICATION', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_MODIFICATION_REQUEST}}', null, true),

  ('PAYMENT_BEFORE_ACCEPTANCE_BLOCKED', 10, 'CREATE_VISIBLE_COMMERCIAL_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('PAYMENT_BEFORE_ACCEPTANCE_BLOCKED', 20, 'REQUEST_PAYMENT_WITHOUT_ACCEPTANCE', 'CUSTOMER', 'MESSAGE',
   '{{PAYMENT_REQUEST}}', null, true),

  ('VISUAL_FAMILY_REFERENCE', 10, 'REQUEST_VISUAL_REFERENCE', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_VISUAL_REQUEST}}', null, true),

  ('DOCUMENT_CURRENT_VERSION_BINDING', 10, 'CREATE_DOCUMENT_SOURCE_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_COMMERCIAL_REQUEST}}', null, false),
  ('DOCUMENT_CURRENT_VERSION_BINDING', 20, 'MODIFY_DOCUMENT_SOURCE_OBJECT', 'CUSTOMER', 'MESSAGE',
   '{{LOCALE_MODIFICATION_REQUEST}}', null, false),
  ('DOCUMENT_CURRENT_VERSION_BINDING', 30, 'REQUEST_CURRENT_DOCUMENT', 'CUSTOMER', 'MESSAGE',
   '{{DOCUMENT_REQUEST}}', null, true);

create index idx_atlas_conversation_step_definitions_scenario
  on public.atlas_conversation_test_scenario_step_definitions(
    scenario_code, step_order
  );

create or replace function
public.atlas_get_conversation_scenario_steps_for_operator_v1(
  p_scenario_instance_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_instance public.atlas_conversation_test_scenario_instances%rowtype;
  v_resolution jsonb;
  v_bindings jsonb;
  v_locale text;
  v_steps jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='AUTHENTICATION_REQUIRED';
  end if;

  if not public.atlas_platform_has_permission('INSTALLATION_TEST_EXECUTE') then
    raise exception using errcode='42501', message='INSTALLATION_TEST_EXECUTE_FORBIDDEN';
  end if;

  select instance.*
  into v_instance
  from public.atlas_conversation_test_scenario_instances as instance
  where instance.id = p_scenario_instance_id;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_SCENARIO_INSTANCE_NOT_FOUND'
    );
  end if;

  v_resolution := public.atlas_resolve_conversation_scenario_bindings_v1(
    p_scenario_instance_id
  );

  if not coalesce((v_resolution->>'ready')::boolean, false) then
    return v_resolution || jsonb_build_object(
      'code', 'SCENARIO_STEPS_BLOCKED_BY_BINDINGS',
      'ready', false
    );
  end if;

  v_bindings := v_resolution->'bindings';

  v_locale := public.atlas_detect_certification_locale_v1(
    v_instance.canonical_data_version_id
  );

  if v_locale is null then
    return jsonb_build_object(
      'ok', true,
      'code', 'CERTIFICATION_LOCALE_UNSUPPORTED_OR_MISSING',
      'ready', false,
      'scenario_instance_id', v_instance.id,
      'scenario_code', v_instance.scenario_code,
      'next_action', 'REMEDIATE_AGENT_LOCALE_CONFIGURATION'
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'step_order', step.step_order,
        'step_code', step.step_code,
        'actor_role', step.actor_role,
        'step_type', step.step_type,
        'rendered_message', case
          when step.message_template is null then null
          else replace(
            replace(
              replace(
                replace(
                  replace(
                    replace(
                      replace(
                        replace(
                          replace(
                            replace(
                              replace(
                                replace(
                                  replace(
                                    replace(
                                      replace(
                                        replace(
                                          replace(
                                            step.message_template,
                                            '{{LOCALE_COMMERCIAL_REQUEST}}',
                                            coalesce(public.atlas_certification_phrase_v1(v_locale,'COMMERCIAL_REQUEST'),'')
                                          ),
                                          '{{LOCALE_MODIFICATION_REQUEST}}',
                                          coalesce(public.atlas_certification_phrase_v1(v_locale,'MODIFICATION_REQUEST'),'')
                                        ),
                                        '{{LOCALE_SELF_CORRECTION}}',
                                        coalesce(public.atlas_certification_phrase_v1(v_locale,'SELF_CORRECTION'),'')
                                      ),
                                      '{{LOCALE_CANONICAL_QUESTION}}',
                                      coalesce(public.atlas_certification_phrase_v1(v_locale,'CANONICAL_QUESTION'),'')
                                    ),
                                    '{{LOCALE_UNSUPPORTED_ATTRIBUTE_QUESTION}}',
                                    coalesce(public.atlas_certification_phrase_v1(v_locale,'UNSUPPORTED_ATTRIBUTE_QUESTION'),'')
                                  ),
                                  '{{LOCALE_VISUAL_REQUEST}}',
                                  coalesce(public.atlas_certification_phrase_v1(v_locale,'VISUAL_REQUEST'),'')
                                ),
                                '{{PAYMENT_REQUEST}}',
                                coalesce(public.atlas_certification_phrase_v1(v_locale,'PAYMENT_REQUEST'),'')
                              ),
                              '{{DOCUMENT_REQUEST}}',
                              coalesce(public.atlas_certification_phrase_v1(v_locale,'DOCUMENT_REQUEST'),'')
                            ),
                            '{{CANONICAL_ENTITY}}',
                            coalesce(v_bindings->>'canonical_entity','CANONICAL_ENTITY')
                          ),
                          '{{CANONICAL_ENTITY_OR_FAMILY}}',
                          coalesce(v_bindings->>'canonical_entity','CANONICAL_ENTITY')
                        ),
                        '{{CANONICAL_ENTITY_QUESTION}}',
                        coalesce(v_bindings->>'canonical_entity','CANONICAL_ENTITY')
                      ),
                      '{{UNSUPPORTED_ATTRIBUTE}}',
                      coalesce(v_bindings->>'unsupported_attribute','UNSUPPORTED_ATTRIBUTE')
                    ),
                    '{{INITIAL_REQUEST}}',
                    coalesce(v_bindings->>'initial_entity', v_bindings->>'canonical_entity', 'INITIAL_REQUEST')
                  ),
                  '{{CORRECTED_REQUEST}}',
                  coalesce(v_bindings->>'corrected_entity', v_bindings->>'canonical_entity', 'CORRECTED_REQUEST')
                ),
                '{{CURRENT_MODIFICATION_REQUEST}}',
                'MODIFICATION_OF_CURRENT_VISIBLE_OBJECT'
              ),
              '{{ACKNOWLEDGEMENT_PHRASE}}',
              coalesce(public.atlas_certification_phrase_v1(v_locale,'ACKNOWLEDGEMENT'),'')
            ),
            '{{ACCEPTANCE_PHRASE}}',
            coalesce(public.atlas_certification_phrase_v1(v_locale,'EXPLICIT_ACCEPTANCE'),'')
          )
        end,
        'expected_state_semantic', step.expected_state_semantic,
        'required_for_assertion', step.required_for_assertion
      )
      order by step.step_order
    ),
    '[]'::jsonb
  )
  into v_steps
  from public.atlas_conversation_test_scenario_step_definitions as step
  where step.scenario_code = v_instance.scenario_code;

  return jsonb_build_object(
    'ok', true,
    'code', 'CONVERSATION_SCENARIO_STEPS_READY',
    'ready', jsonb_array_length(v_steps) > 0,
    'scenario_instance_id', v_instance.id,
    'scenario_code', v_instance.scenario_code,
    'steps', v_steps,
    'step_count', jsonb_array_length(v_steps),
    'locale', v_locale,
    'binding_sha256', v_resolution->>'binding_sha256',
    'next_action', 'EXECUTE_SCENARIO_STEPS_IN_ORDER'
  );
end;
$$;

revoke all on table
public.atlas_conversation_test_scenario_step_definitions
from public, anon, authenticated;

revoke all on function
public.atlas_get_conversation_scenario_steps_for_operator_v1(uuid)
from public, anon;

grant select on table
public.atlas_conversation_test_scenario_step_definitions
to service_role;

grant execute on function
public.atlas_get_conversation_scenario_steps_for_operator_v1(uuid)
to authenticated, service_role;

commit;