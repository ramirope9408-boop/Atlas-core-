-- ATLAS B2 conversational scenario registry V1
-- Date: 2026-09-27
-- Additive. Generic templates only; no FingerFood/company-specific content.

begin;

do $$
begin
  if to_regclass('public.atlas_installation_test_definitions') is null
     or to_regprocedure(
       'public.atlas_jsonb_has_forbidden_secret_key(jsonb)'
     ) is null then
    raise exception
      'Conversational scenario registry requires B2 test core';
  end if;

  if to_regclass(
       'public.atlas_conversation_test_scenario_definitions'
     ) is not null then
    raise exception
      'Conversation scenario definitions already exist; reconcile before install';
  end if;
end;
$$;

create table public.atlas_conversation_test_scenario_definitions (
  scenario_code text primary key,
  parent_test_code text not null,
  display_name text not null,
  description text not null,
  scenario_group text not null,
  requirement_mode text not null,
  applicability_rule jsonb not null,
  prompt_template text not null,
  expected_assertion_codes text[] not null,
  blocking boolean not null default true,
  sort_order integer not null,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint atlas_conversation_scenario_parent_fkey
    foreign key (parent_test_code)
    references public.atlas_installation_test_definitions(test_code)
    on delete restrict,

  constraint atlas_conversation_scenario_code_check
    check (
      scenario_code ~ '^[A-Z][A-Z0-9_]*$'
      and length(scenario_code) between 5 and 120
    ),

  constraint atlas_conversation_scenario_group_check
    check (
      scenario_group in (
        'GROUNDING',
        'AMBIGUITY',
        'CONTEXT',
        'ACTION_GATING',
        'ACCEPTANCE',
        'MODIFICATION',
        'VISUAL',
        'DOCUMENT',
        'PAYMENT'
      )
    ),

  constraint atlas_conversation_scenario_requirement_check
    check (requirement_mode in ('REQUIRED', 'CONDITIONAL')),

  constraint atlas_conversation_scenario_applicability_check
    check (
      jsonb_typeof(applicability_rule) = 'object'
      and applicability_rule <> '{}'::jsonb
      and nullif(btrim(applicability_rule->>'reason'), '') is not null
      and not public.atlas_jsonb_has_forbidden_secret_key(
        applicability_rule
      )
    ),

  constraint atlas_conversation_scenario_prompt_check
    check (
      length(btrim(prompt_template)) between 3 and 1500
      and prompt_template !~ '[[:cntrl:]]'
    ),

  constraint atlas_conversation_scenario_assertions_check
    check (
      cardinality(expected_assertion_codes) >= 1
      and array_position(expected_assertion_codes, null) is null
    ),

  constraint atlas_conversation_scenario_order_check
    check (sort_order between 1 and 1000),

  constraint atlas_conversation_scenario_metadata_check
    check (
      jsonb_typeof(metadata) = 'object'
      and not public.atlas_jsonb_has_forbidden_secret_key(metadata)
    )
);

insert into public.atlas_conversation_test_scenario_definitions (
  scenario_code,
  parent_test_code,
  display_name,
  description,
  scenario_group,
  requirement_mode,
  applicability_rule,
  prompt_template,
  expected_assertion_codes,
  blocking,
  sort_order
)
values
  (
    'DIRECT_CANONICAL_LOOKUP',
    'KNOWLEDGE_SEARCH_ACCURACY',
    'Consulta canónica directa',
    'Valida que una pregunta directa se responda solo con datos canónicos de la empresa.',
    'GROUNDING',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Toda instalación debe responder consultas canónicas directas.'
    ),
    'Consulta del cliente: "{{CANONICAL_ENTITY_QUESTION}}".',
    array['CANONICAL_SOURCE_GROUNDING']::text[],
    true, 10
  ),
  (
    'UNSUPPORTED_ATTRIBUTE_REJECTION',
    'KNOWLEDGE_SEARCH_ACCURACY',
    'Atributo no sustentado',
    'Valida que el agente no invente atributos ausentes en la fuente canónica.',
    'GROUNDING',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'El agente debe reconocer límites del conocimiento canónico.'
    ),
    'Pregunta por "{{UNSUPPORTED_ATTRIBUTE}}" de "{{CANONICAL_ENTITY}}", cuando ese atributo no existe en la fuente canónica.',
    array[
      'UNSUPPORTED_FACT_REJECTION',
      'UNSUPPORTED_ATTRIBUTE_INFERENCE_BLOCKED'
    ]::text[],
    true, 20
  ),
  (
    'AMBIGUOUS_COMMERCIAL_REQUEST',
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Solicitud comercial ambigua',
    'Valida aclaración mínima antes de ejecutar cuando faltan datos comerciales críticos.',
    'AMBIGUITY',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Una solicitud ambigua no debe producir una acción material.'
    ),
    'Solicitud incompleta: "{{AMBIGUOUS_COMMERCIAL_REQUEST}}".',
    array['AMBIGUITY_REQUIRES_CLARIFICATION']::text[],
    true, 30
  ),
  (
    'ACKNOWLEDGEMENT_NO_RETRIGGER',
    'EXTERNAL_CONVERSATION_E2E',
    'Acknowledgement sin reejecución',
    'Valida que una respuesta corta de continuidad no repita la acción anterior.',
    'CONTEXT',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Los acknowledgements no deben reactivar efectos previos.'
    ),
    'Después de una acción completada, el cliente responde "{{ACKNOWLEDGEMENT_PHRASE}}".',
    array[
      'CONVERSATION_CONTEXT_CONTINUITY',
      'ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER'
    ]::text[],
    true, 40
  ),
  (
    'SELF_CORRECTION_FINAL_INTENT',
    'EXTERNAL_CONVERSATION_E2E',
    'Autocorrección en el mismo mensaje',
    'Valida que la última corrección explícita dentro del mensaje sea la intención efectiva.',
    'MODIFICATION',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La autocorrección debe resolver la intención final sin doble ejecución.'
    ),
    'Mensaje con autocorrección: "{{INITIAL_REQUEST}}, no, mejor {{CORRECTED_REQUEST}}".',
    array[
      'SELF_CORRECTION_FINAL_INTENT_WINS',
      'CONVERSATION_CONTEXT_CONTINUITY'
    ]::text[],
    true, 50
  ),
  (
    'POST_MODIFICATION_ACK_NO_LOOP',
    'EXTERNAL_CONVERSATION_E2E',
    'Continuidad después de modificación',
    'Valida que un acknowledgement posterior a una modificación exitosa no reabra el flujo.',
    'MODIFICATION',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Las modificaciones completadas deben cerrar su intención operativa.'
    ),
    'Tras una modificación exitosa, el cliente responde "{{ACKNOWLEDGEMENT_PHRASE}}".',
    array[
      'CONTEXTUAL_MODIFICATION_NO_LOOP',
      'ACKNOWLEDGEMENT_NO_ACTION_RETRIGGER'
    ]::text[],
    true, 60
  ),
  (
    'EXPLICIT_ACCEPTANCE_REQUIRED',
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Aceptación comercial explícita',
    'Valida que la aceptación material se active solo con lenguaje y estado que realmente acepten el objeto vigente.',
    'ACCEPTANCE',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Aceptar una operación comercial no equivale a un acknowledgement genérico.'
    ),
    'Con una propuesta vigente, evaluar "{{ACCEPTANCE_PHRASE}}" contra el estado visible actual.',
    array[
      'EXPLICIT_ACCEPTANCE_GATING',
      'ACTION_INTENT_GATING'
    ]::text[],
    true, 70
  ),
  (
    'NON_ACCEPTANCE_ACK_BLOCKED',
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Acknowledgement no equivalente a aceptación',
    'Valida que una frase de continuidad no sea convertida en aceptación comercial.',
    'ACCEPTANCE',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La instalación debe distinguir conversación de consentimiento comercial.'
    ),
    'Con una propuesta vigente, el cliente responde "{{ACKNOWLEDGEMENT_PHRASE}}" sin lenguaje explícito de aceptación.',
    array[
      'EXPLICIT_ACCEPTANCE_GATING',
      'ACTION_INTENT_GATING'
    ]::text[],
    true, 80
  ),
  (
    'MODIFICATION_OVERRIDES_STALE_ACCEPTANCE',
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Modificación domina contexto anterior',
    'Valida que una corrección actual no sea interpretada como aceptación de un estado anterior.',
    'MODIFICATION',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'La intención actual debe gobernar sobre aceptación obsoleta.'
    ),
    'Con un objeto comercial vigente, el cliente solicita "{{CURRENT_MODIFICATION_REQUEST}}".',
    array[
      'MODIFICATION_OVERRIDES_STALE_ACCEPTANCE',
      'ACTION_INTENT_GATING'
    ]::text[],
    true, 90
  ),
  (
    'PAYMENT_BEFORE_ACCEPTANCE_BLOCKED',
    'COMMERCIAL_RULES_ENFORCEMENT',
    'Pago bloqueado antes de aceptación',
    'Valida que no se emita ni ejecute una acción de pago antes de una aceptación válida cuando el contrato lo exige.',
    'PAYMENT',
    'REQUIRED',
    jsonb_build_object(
      'mode', 'ALWAYS',
      'reason', 'Las acciones financieras deben respetar el gate comercial.'
    ),
    'Intentar continuar a pago sin que exista aceptación comercial válida del objeto vigente.',
    array[
      'EXPLICIT_ACCEPTANCE_GATING',
      'ACTION_INTENT_GATING'
    ]::text[],
    true, 100
  ),
  (
    'VISUAL_FAMILY_REFERENCE',
    'EXTERNAL_CONVERSATION_E2E',
    'Referencia visual de familia',
    'Valida que la referencia visual solicitada corresponda a la entidad o familia canónica vigente.',
    'VISUAL',
    'CONDITIONAL',
    jsonb_build_object(
      'mode', 'CONDITIONAL',
      'condition', 'CATALOG_MEDIA_REQUIRED',
      'reason', 'Aplica cuando la empresa instala activos visuales de catálogo.'
    ),
    'El cliente pide una imagen de "{{CANONICAL_ENTITY_OR_FAMILY}}".',
    array['CONVERSATION_CONTEXT_CONTINUITY']::text[],
    true, 110
  ),
  (
    'DOCUMENT_CURRENT_VERSION_BINDING',
    'DOCUMENT_TEMPLATE_OUTPUT',
    'Documento ligado a versión vigente',
    'Valida que el documento generado represente el estado canónico vigente y no una versión conversacional obsoleta.',
    'DOCUMENT',
    'CONDITIONAL',
    jsonb_build_object(
      'mode', 'CONDITIONAL',
      'condition', 'DOCUMENT_OUTPUT_ENABLED',
      'reason', 'Aplica cuando la instalación genera documentos para clientes.'
    ),
    'Generar el documento correspondiente al objeto comercial vigente después de una modificación confirmada.',
    array['DOCUMENT_BOUND_TO_CURRENT_CANONICAL_STATE']::text[],
    true, 120
  );

create index idx_atlas_conversation_scenarios_parent
  on public.atlas_conversation_test_scenario_definitions(
    parent_test_code,
    active,
    sort_order
  );

create or replace function public.atlas_get_conversation_test_scenarios_v1(
  p_parent_test_code text
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'scenario_code', scenario.scenario_code,
        'parent_test_code', scenario.parent_test_code,
        'display_name', scenario.display_name,
        'description', scenario.description,
        'scenario_group', scenario.scenario_group,
        'requirement_mode', scenario.requirement_mode,
        'applicability_rule', scenario.applicability_rule,
        'prompt_template', scenario.prompt_template,
        'expected_assertion_codes',
          to_jsonb(scenario.expected_assertion_codes),
        'blocking', scenario.blocking,
        'sort_order', scenario.sort_order
      )
      order by scenario.sort_order
    ),
    '[]'::jsonb
  )
  from public.atlas_conversation_test_scenario_definitions as scenario
  where scenario.active
    and (
      p_parent_test_code is null
      or scenario.parent_test_code = p_parent_test_code
    )
$$;

revoke all on table
public.atlas_conversation_test_scenario_definitions
from public, anon, authenticated;

revoke all on function
public.atlas_get_conversation_test_scenarios_v1(text)
from public, anon, authenticated;

grant select on table
public.atlas_conversation_test_scenario_definitions
to service_role;

grant execute on function
public.atlas_get_conversation_test_scenarios_v1(text)
to service_role;

commit;
