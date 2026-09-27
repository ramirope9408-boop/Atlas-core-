-- ATLAS B2 conversational certification hardening
-- Date: 2026-09-27
-- Scope: additive V2 assertion contract only.
-- Safety: does NOT alter the historical 18-case B2 plan, G03, states, or production data.
--
-- Rationale:
-- FingerFood testing exposed business-agnostic conversational failure modes
-- that should be certified for every future company. The historical B2 plan
-- is deliberately fixed to 18 top-level cases, so this migration strengthens
-- the assertion contract inside existing cases instead of changing their count.

begin;

do $$
begin
  if to_regprocedure(
       'public.atlas_test_assertion_contract_v1(text,text,text[],text[])'
     ) is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception
      'B2 conversational hardening requires B2.2I.2A/B2.2I.2B installed';
  end if;
end;
$$;

create or replace function public.atlas_test_assertion_contract_v2(
  p_test_code text,
  p_description text,
  p_required_evidence_kinds text[],
  p_g03_criterion_codes text[]
)
returns jsonb
language plpgsql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
declare
  v_base jsonb;
  v_extra jsonb := '[]'::jsonb;
begin
  v_base := jsonb_build_array(
    jsonb_build_object(
      'assertion_code', p_test_code || '_VERIFIED',
      'description', p_description,
      'required', true,
      'required_evidence_kinds',
        to_jsonb(p_required_evidence_kinds),
      'g03_criterion_codes',
        to_jsonb(p_g03_criterion_codes)
    )
  );

  case p_test_code
    when 'KNOWLEDGE_SEARCH_ACCURACY' then
      v_extra := jsonb_build_array(
        jsonb_build_object(
          'assertion_code', 'CANONICAL_SOURCE_GROUNDING',
          'description',
            'Responses use only company-authorized canonical knowledge for factual business claims.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'UNSUPPORTED_FACT_REJECTION',
          'description',
            'When canonical knowledge does not support a requested fact or attribute, the agent does not fabricate it.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'UNSUPPORTED_ATTRIBUTE_INFERENCE_BLOCKED',
          'description',
            'The agent does not infer popularity, taste, availability, policy, or other business attributes from unrelated fields.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        )
      );

    when 'COMMERCIAL_RULES_ENFORCEMENT' then
      v_extra := jsonb_build_array(
        jsonb_build_object(
          'assertion_code', 'AMBIGUITY_REQUIRES_CLARIFICATION',
          'description',
            'Missing or ambiguous commercial data causes a focused clarification instead of an invented assumption.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'ACTION_INTENT_GATING',
          'description',
            'Material actions execute only when the current message and active state authorize that action.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'EXPLICIT_ACCEPTANCE_GATING',
          'description',
            'Commercial acceptance is distinguished from acknowledgements, questions, interest, and modification requests.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'MODIFICATION_OVERRIDES_STALE_ACCEPTANCE',
          'description',
            'A current modification or correction supersedes stale acceptance context and is applied to the active object only.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        )
      );

    when 'EXTERNAL_CONVERSATION_E2E' then
      v_extra := jsonb_build_array(
        jsonb_build_object(
          'assertion_code', 'CONVERSATION_CONTEXT_CONTINUITY',
          'description',
            'Short follow-ups are interpreted against the current conversational state without losing the active context.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER',
          'description',
            'Acknowledgements such as yes, ok, done, waiting, or equivalent do not re-trigger a previous action by themselves.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'SELF_CORRECTION_FINAL_INTENT_WINS',
          'description',
            'When a message contains an explicit self-correction, the final corrected intent is the one executed.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        ),
        jsonb_build_object(
          'assertion_code', 'CONTEXTUAL_MODIFICATION_NO_LOOP',
          'description',
            'After a successful modification, follow-up acknowledgements do not reopen or repeat the modification flow.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        )
      );

    when 'DOCUMENT_TEMPLATE_OUTPUT' then
      v_extra := jsonb_build_array(
        jsonb_build_object(
          'assertion_code', 'DOCUMENT_BOUND_TO_CURRENT_CANONICAL_STATE',
          'description',
            'Generated documents are bound to the current canonical business object/version rather than stale conversation state.',
          'required', true,
          'required_evidence_kinds',
            to_jsonb(p_required_evidence_kinds),
          'g03_criterion_codes',
            to_jsonb(p_g03_criterion_codes)
        )
      );

    else
      v_extra := '[]'::jsonb;
  end case;

  return v_base || v_extra;
end;
$$;

revoke all on function public.atlas_test_assertion_contract_v2(
  text, text, text[], text[]
)
from public, anon, authenticated;

grant execute on function public.atlas_test_assertion_contract_v2(
  text, text, text[], text[]
)
to service_role;

comment on function public.atlas_test_assertion_contract_v2(
  text, text, text[], text[]
) is
  'B2 V2 assertion contract. Strengthens existing canonical installation tests with reusable conversational safety assertions without changing the historical 18 top-level test cases.';

commit;
