-- Migration: atlas_internal_prepare_final_response_context_v1
--
-- Creates the deterministic canonical context builder used before
-- INTERNAL_FINAL_RESPONSE generation.
--
-- CERTIFIED RUNTIME STATE:
-- - F1 VALID WITHOUT TOOL: PASS
-- - F2 VALID + COMPLETED TOOL: PASS
--
-- READ-ONLY preparation layer.
-- No mutations.
-- No OpenAI calls.
-- No caller-provided tool result injection.

CREATE OR REPLACE FUNCTION public.atlas_internal_prepare_final_response_context(
  p_decision_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$

DECLARE

  -- ============================================================
  -- AUTH / CANONICAL RECORDS
  -- ============================================================

  v_auth_uid uuid;

  v_decision RECORD;
  v_current_message RECORD;


  -- ============================================================
  -- TOOL EXECUTION
  --
  -- IMPORTANT:
  -- Explicit scalar variables are used instead of an unassigned
  -- RECORD. This is required for valid no-tool decisions such as F1.
  -- ============================================================

  v_tool_request_id uuid := NULL;
  v_tool_status text := NULL;
  v_tool_result jsonb := NULL;
  v_tool_error_code text := NULL;
  v_tool_error_message text := NULL;


  -- ============================================================
  -- CONTEXT COMPONENTS
  -- ============================================================

  v_persona jsonb := NULL;
  v_relationship jsonb := NULL;
  v_memory jsonb := NULL;
  v_prompt_contract jsonb := NULL;


  -- ============================================================
  -- DECISION STATE
  -- ============================================================

  v_decision_state text := 'INVALID';
  v_safe_to_generate boolean := false;

  v_now timestamptz := now();

BEGIN

  -- ============================================================
  -- 1. AUTH CHECK FIRST
  -- ============================================================

  v_auth_uid := auth.uid();

  IF v_auth_uid IS NULL THEN
    RETURN jsonb_build_object(
      'error',
      'AUTH_REQUIRED',

      'message',
      'Authentication required',

      'safe_to_continue',
      false
    );
  END IF;


  -- ============================================================
  -- 2. LOAD CANONICAL DECISION
  -- ============================================================

  SELECT *
  INTO v_decision
  FROM public.atlas_internal_agent_decisions
  WHERE id = p_decision_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'error',
      'DECISION_NOT_FOUND',

      'decision_id',
      p_decision_id,

      'safe_to_continue',
      false
    );
  END IF;


  -- ============================================================
  -- 3. VERIFY DECISION OWNERSHIP
  -- ============================================================

  IF
    v_decision.user_id IS NULL
    OR v_decision.user_id <> v_auth_uid
  THEN

    RETURN jsonb_build_object(
      'error',
      'OWNER_MISMATCH',

      'decision_id',
      p_decision_id,

      'safe_to_continue',
      false
    );

  END IF;


  -- ============================================================
  -- 4. VERIFY EMPRESA ACCESS
  -- ============================================================

  IF NOT public.atlas_internal_has_empresa_access(
    v_decision.empresa_id
  )
  THEN

    RETURN jsonb_build_object(
      'error',
      'NO_EMPRESA_ACCESS',

      'empresa_id',
      v_decision.empresa_id,

      'safe_to_continue',
      false
    );

  END IF;


  -- ============================================================
  -- 5. LOAD SOURCE / CURRENT MESSAGE
  -- ============================================================

  SELECT *
  INTO v_current_message
  FROM public.atlas_internal_messages
  WHERE id = v_decision.source_message_id
    AND empresa_id = v_decision.empresa_id
  LIMIT 1;


  -- ============================================================
  -- 6. LOAD MEMORY / INTERNAL DECISION CONTEXT
  --
  -- This component is useful but must not break the final context
  -- if unavailable.
  -- ============================================================

  BEGIN

    SELECT public.atlas_internal_prepare_decision_context(
      v_decision.empresa_id,
      v_decision.conversation_id,
      30
    )
    INTO v_memory;

  EXCEPTION
    WHEN OTHERS THEN
      v_memory := NULL;
  END;


  -- ============================================================
  -- 7. LOAD PERSONA SERVER-SIDE
  -- ============================================================

  BEGIN

    SELECT public.atlas_get_ai_persona(
      v_decision.empresa_id,
      v_decision.agent_code
    )
    INTO v_persona;

  EXCEPTION
    WHEN OTHERS THEN
      v_persona := NULL;
  END;


  -- ============================================================
  -- 8. LOAD CANONICAL USER / AGENT RELATIONSHIP
  --
  -- Relationship controls style only.
  -- It never grants authority.
  -- ============================================================

  BEGIN

    SELECT jsonb_build_object(

      'relationship_code',
      rp.relationship_code,

      'display_name',
      rp.display_name,

      'description',
      rp.description,

      'warmth_level',
      rp.warmth_level,

      'humor_level',
      rp.humor_level,

      'teasing_level',
      rp.teasing_level,

      'regionality_level',
      rp.regionality_level,

      'formality_level',
      rp.formality_level,

      'voice_spontaneity_level',
      rp.voice_spontaneity_level,

      'behavior_rules',
      rp.behavior_rules,

      'active',
      rp.active,

      'custom_overrides',
      ur.custom_overrides

    )
    INTO v_relationship

    FROM public.atlas_agent_user_relationships ur

    JOIN public.atlas_agent_relationship_profiles rp
      ON ur.empresa_id = rp.empresa_id
     AND ur.relationship_code = rp.relationship_code

    WHERE ur.empresa_id = v_decision.empresa_id
      AND ur.user_id = v_auth_uid
      AND ur.agent_code = v_decision.agent_code
      AND ur.status = 'ACTIVE'
      AND rp.active = true

    LIMIT 1;

  EXCEPTION
    WHEN OTHERS THEN
      v_relationship := NULL;
  END;


  -- ============================================================
  -- 9. RESOLVE INTERNAL_FINAL_RESPONSE PROMPT CONTRACT
  -- ============================================================

  BEGIN

    SELECT public.atlas_get_prompt_contract(
      v_decision.empresa_id,
      'INTERNAL_FINAL_RESPONSE',
      v_decision.agent_code
    )
    INTO v_prompt_contract;

  EXCEPTION
    WHEN OTHERS THEN

      RETURN jsonb_build_object(
        'error',
        'PROMPT_CONTRACT_NOT_FOUND',

        'contract_code',
        'INTERNAL_FINAL_RESPONSE',

        'safe_to_continue',
        false
      );

  END;


  IF v_prompt_contract IS NULL THEN

    RETURN jsonb_build_object(
      'error',
      'PROMPT_CONTRACT_NOT_FOUND',

      'contract_code',
      'INTERNAL_FINAL_RESPONSE',

      'safe_to_continue',
      false
    );

  END IF;


  -- ============================================================
  -- 10. RESOLVE CANONICAL TOOL EXECUTION
  --
  -- Caller cannot inject tool results.
  --
  -- Tool request must match:
  -- - empresa_id
  -- - conversation_id
  -- - selected_tool_code
  -- - decision_id inside input_payload
  --
  -- Only COMPLETED execution may expose result_payload.
  -- ============================================================

  IF
    v_decision.tool_required = true
    AND v_decision.selected_tool_code IS NOT NULL
  THEN

    SELECT
      tr.id,
      tr.status,
      tr.result_payload,
      tr.error_code,
      tr.error_message

    INTO
      v_tool_request_id,
      v_tool_status,
      v_tool_result,
      v_tool_error_code,
      v_tool_error_message

    FROM public.atlas_agent_tool_requests tr

    WHERE tr.empresa_id = v_decision.empresa_id
      AND tr.conversation_id = v_decision.conversation_id
      AND tr.tool_code = v_decision.selected_tool_code
      AND tr.input_payload->>'decision_id' = p_decision_id::text

    ORDER BY
      tr.requested_at DESC,
      tr.started_at DESC

    LIMIT 1;


    IF NOT FOUND THEN

      v_tool_request_id := NULL;
      v_tool_status := 'MISSING';
      v_tool_result := NULL;
      v_tool_error_code := NULL;
      v_tool_error_message := NULL;


    ELSIF v_tool_status <> 'COMPLETED' THEN

      -- Never trust an incomplete / failed result payload.
      v_tool_result := NULL;

    END IF;


  ELSE

    -- Explicit canonical no-tool state.
    v_tool_request_id := NULL;
    v_tool_status := NULL;
    v_tool_result := NULL;
    v_tool_error_code := NULL;
    v_tool_error_message := NULL;

  END IF;


  -- ============================================================
  -- 11. DETERMINE CANONICAL DECISION STATE
  -- ============================================================

  v_decision_state := 'INVALID';
  v_safe_to_generate := false;


  -- ------------------------------------------------------------
  -- CLARIFICATION
  -- ------------------------------------------------------------

  IF v_decision.clarification_required = true THEN

    v_decision_state := 'CLARIFICATION';
    v_safe_to_generate := false;


  -- ------------------------------------------------------------
  -- DENIED
  --
  -- permission_required is TEXT, not BOOLEAN.
  --
  -- Example:
  -- INTERNAL_CHAT_USE
  -- EVENTS_READ
  -- EXECUTIVE_BRIEF
  -- etc.
  -- ------------------------------------------------------------

  ELSIF
    (
      v_decision.permission_required IS NOT NULL
      AND v_decision.permission_granted IS DISTINCT FROM true
    )
    OR v_decision.permission_granted = false
  THEN

    v_decision_state := 'DENIED';
    v_safe_to_generate := false;


  -- ------------------------------------------------------------
  -- VALID
  -- ------------------------------------------------------------

  ELSIF
    v_decision.clarification_required = false
    AND v_decision.permission_granted = true
    AND v_decision.decision_metadata->>'validation_status' = 'VALID'
  THEN

    v_decision_state := 'VALID';


    -- ----------------------------------------------------------
    -- VALID WITHOUT TOOL
    -- F1 certified path.
    -- ----------------------------------------------------------

    IF v_decision.tool_required = false THEN

      v_safe_to_generate := true;


    -- ----------------------------------------------------------
    -- VALID WITH COMPLETED CANONICAL TOOL RESULT
    -- F2 certified path.
    -- ----------------------------------------------------------

    ELSIF
      v_decision.tool_required = true
      AND v_tool_status = 'COMPLETED'
      AND v_tool_result IS NOT NULL
    THEN

      v_safe_to_generate := true;


    ELSE

      v_safe_to_generate := false;

    END IF;


  ELSE

    v_decision_state := 'INVALID';
    v_safe_to_generate := false;

  END IF;


  -- ============================================================
  -- 12. RETURN STRUCTURED CANONICAL CONTEXT
  -- ============================================================

  RETURN jsonb_build_object(

    -- ----------------------------------------------------------
    -- CONTEXT IDENTITY
    -- ----------------------------------------------------------

    'context_version',
    'INTERNAL_FINAL_RESPONSE_CONTEXT_V1',

    'empresa_id',
    v_decision.empresa_id,

    'conversation_id',
    v_decision.conversation_id,

    'decision_id',
    v_decision.id,

    'user_id',
    v_decision.user_id,

    'agent_code',
    v_decision.agent_code,


    -- ----------------------------------------------------------
    -- CANONICAL STATE
    -- ----------------------------------------------------------

    'decision_state',
    v_decision_state,

    'safe_to_generate',
    v_safe_to_generate,


    -- ----------------------------------------------------------
    -- VALIDATED DECISION
    -- ----------------------------------------------------------

    'validated_decision',
    jsonb_build_object(

      'id',
      v_decision.id,

      'intent_code',
      v_decision.intent_code,

      'confidence',
      v_decision.confidence,

      'tool_required',
      v_decision.tool_required,

      'selected_tool_code',
      v_decision.selected_tool_code,

      'permission_required',
      v_decision.permission_required,

      'permission_granted',
      v_decision.permission_granted,

      'clarification_required',
      v_decision.clarification_required,

      'clarification_reason',
      v_decision.clarification_reason,

      'seriousness_level',
      v_decision.seriousness_level,

      'humor_allowed',
      v_decision.humor_allowed,

      'relationship_code',
      v_decision.relationship_code,

      'response_mode',
      v_decision.response_mode,

      'decision_metadata',
      v_decision.decision_metadata,

      'created_at',
      v_decision.created_at
    ),


    -- ----------------------------------------------------------
    -- SOURCE MESSAGE
    --
    -- atlas_internal_messages real schema:
    -- actor_type
    -- direction
    -- message_type
    -- text_content
    --
    -- It does NOT contain role/content columns.
    -- ----------------------------------------------------------

    'current_message',

    CASE

      WHEN v_current_message.id IS NULL THEN
        NULL

      ELSE
        jsonb_build_object(

          'message_id',
          v_current_message.id,

          'message_type',
          v_current_message.message_type,

          'role',
          CASE

            WHEN v_current_message.actor_type = 'USER'
              THEN 'user'

            WHEN v_current_message.actor_type = 'AGENT'
              THEN 'assistant'

            ELSE
              'system'

          END,

          'content',
          v_current_message.text_content,

          'actor_type',
          v_current_message.actor_type,

          'direction',
          v_current_message.direction,

          'created_at',
          v_current_message.created_at
        )

    END,


    -- ----------------------------------------------------------
    -- CONVERSATIONAL / STYLE CONTEXT
    -- ----------------------------------------------------------

    'memory',
    v_memory,

    'persona',
    v_persona,

    'relationship',
    v_relationship,

    'prompt_contract',
    v_prompt_contract,


    -- ----------------------------------------------------------
    -- CANONICAL TOOL EXECUTION
    -- ----------------------------------------------------------

    'canonical_tool_execution',

    CASE

      WHEN v_tool_status IS NULL THEN
        NULL

      ELSE
        jsonb_build_object(

          'tool_request_id',
          v_tool_request_id,

          'tool_code',
          v_decision.selected_tool_code,

          'status',
          v_tool_status,

          'result_available',
          v_tool_result IS NOT NULL,

          'error_code',
          v_tool_error_code
        )

    END,


    -- ----------------------------------------------------------
    -- CANONICAL TOOL RESULT
    -- ----------------------------------------------------------

    'canonical_tool_result',
    v_tool_result,


    -- ----------------------------------------------------------
    -- TRUE ONLY FOR TRUSTED COMPLETED RESULT
    -- ----------------------------------------------------------

    'tool_result_used',
    (
      v_tool_status = 'COMPLETED'
      AND v_tool_result IS NOT NULL
    ),


    -- ----------------------------------------------------------
    -- CONTEXT CREATION TIME
    -- ----------------------------------------------------------

    'created_at',
    v_now
  );


END;
$function$;


-- ==============================================================
-- GRANTS
-- ==============================================================

GRANT EXECUTE
ON FUNCTION public.atlas_internal_prepare_final_response_context(uuid)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.atlas_internal_prepare_final_response_context(uuid)
TO service_role;