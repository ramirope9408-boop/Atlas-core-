-- ATLAS B2 conversational certification V2 - static contract test
-- Safe to run in a database where the migration has been applied.

do $$
declare
  v_assertions jsonb;
  v_codes text[];
begin
  v_assertions := public.atlas_test_assertion_contract_v2(
    'EXTERNAL_CONVERSATION_E2E',
    'Conversation E2E contract',
    array['TECHNICAL_ASSERTION','CHANNEL_RECEIPT']::text[],
    array['CERTIFIED_FLOWS_INSTALLED','CHANNELS_TESTED']::text[]
  );

  if jsonb_array_length(v_assertions) <> 5 then
    raise exception
      'Expected 5 assertions for EXTERNAL_CONVERSATION_E2E, got %',
      jsonb_array_length(v_assertions);
  end if;

  select array_agg(item->>'assertion_code' order by item->>'assertion_code')
  into v_codes
  from jsonb_array_elements(v_assertions) as x(item);

  if not (
    'CONVERSATION_CONTEXT_CONTINUITY' = any(v_codes)
    and 'ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER' = any(v_codes)
    and 'SELF_CORRECTION_FINAL_INTENT_WINS' = any(v_codes)
    and 'CONTEXTUAL_MODIFICATION_NO_LOOP' = any(v_codes)
  ) then
    raise exception 'Conversational assertion coverage incomplete';
  end if;

  v_assertions := public.atlas_test_assertion_contract_v2(
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Commercial rules contract',
    array['TECHNICAL_ASSERTION','HUMAN_APPROVAL']::text[],
    array['CERTIFIED_FLOWS_INSTALLED']::text[]
  );

  if jsonb_array_length(v_assertions) <> 5 then
    raise exception
      'Expected 5 assertions for COMMERCIAL_RULES_ENFORCEMENT, got %',
      jsonb_array_length(v_assertions);
  end if;

  if v_assertions::text ~* 'FingerFood|mini doggi|taco|Cartagena|Bancolombia|Nequi|Daviplata' then
    raise exception
      'Company-specific FingerFood content leaked into reusable B2 CORE assertions';
  end if;
end;
$$;
