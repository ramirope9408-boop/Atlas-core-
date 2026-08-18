-- Migration: atlas_internal_prepare_final_response_context_v1
-- Creates RPC for deterministic context preparation before INTERNAL_FINAL_RESPONSE generation
-- This is a READ-ONLY preparation layer. No mutations, no OpenAI calls.

CREATE OR REPLACE FUNCTION public.atlas_internal_prepare_final_response_context(
  p_decision_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_auth_uid uuid;
  v_decision RECORD;
  v_current_message RECORD;
  v_tool_request RECORD;
  v_tool_result jsonb;
  v_tool_status text;
  v_persona jsonb;
  v_relationship jsonb;
  v_memory jsonb;
  v_prompt_contract jsonb;
  v_decision_state text;
  v_safe_to_generate boolean := false;
  v_now timestamptz := now();
BEGIN

  -- 1) AUTH CHECK FIRST
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'AUTH_REQUIRED',
      'message', 'Authentication required',
      'safe_to_continue', false
    );
  END IF;

  -- 2) LOAD DECISION
  SELECT * INTO v_decision 
  FROM public.atlas_internal_agent_decisions 
  WHERE id = p_decision_id LIMIT 1;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'error', 'DECISION_NOT_FOUND',
      'decision_id', p_decision_id,
      'safe_to_continue', false
    );
  END IF;

  -- 3) VERIFY OWNERSHIP
  IF v_decision.user_id IS NULL OR v_decision.user_id <> v_auth_uid THEN
    RETURN jsonb_build_object(
      'error', 'OWNER_MISMATCH',
      'decision_id', p_decision_id,
      'safe_to_continue', false
    );
  END IF;

  -- 4) VERIFY EMPRESA ACCESS
  IF NOT public.atlas_internal_has_empresa_access(v_decision.empresa_id) THEN
    RETURN jsonb_build_object(
      'error', 'NO_EMPRESA_ACCESS',
      'empresa_id', v_decision.empresa_id,
      'safe_to_continue', false
    );
  END IF;

  -- 5) LOAD CURRENT MESSAGE (via source_message_id)
  SELECT * INTO v_current_message
  FROM public.atlas_internal_messages
  WHERE id = v_decision.source_message_id AND empresa_id = v_decision.empresa_id LIMIT 1;
  
  -- Note: v_current_message can be NULL if not found (safe fallback below)

  -- 6) LOAD MEMORY/CONVERSATION CONTEXT
  -- Reuse existing context builder if available; fallback to null
  BEGIN
    SELECT atlas_internal_prepare_decision_context(
      v_decision.empresa_id,
      v_decision.conversation_id,
      30
    ) INTO v_memory;
  EXCEPTION WHEN OTHERS THEN
    v_memory := NULL;
  END;

  -- 7) LOAD PERSONA (server-side, no caller injection)
  -- Attempt to call atlas_get_ai_persona; if signature differs or doesn't exist, catch gracefully
  v_persona := NULL;
  BEGIN
    -- Try: atlas_get_ai_persona(empresa_id, agent_code)
    SELECT atlas_get_ai_persona(v_decision.empresa_id, v_decision.agent_code) INTO v_persona;
  EXCEPTION WHEN OTHERS THEN
    -- Function may not exist or signature may differ; safe to continue
    v_persona := NULL;
  END;

  -- 8) LOAD RELATIONSHIP (server-side, no caller injection)
  -- Resolve relationship canonically from atlas_agent_user_relationships + atlas_agent_relationship_profiles
  -- Uses: empresa_id, user_id (auth.uid()), agent_code
  -- Requires: user relationship status='ACTIVE' and profile active=true
  v_relationship := NULL;
  BEGIN
    SELECT jsonb_build_object(
      'relationship_code', rp.relationship_code,
      'display_name', rp.display_name,
      'description', rp.description,
      'warmth_level', rp.warmth_level,
      'humor_level', rp.humor_level,
      'teasing_level', rp.teasing_level,
      'regionality_level', rp.regionality_level,
      'formality_level', rp.formality_level,
      'voice_spontaneity_level', rp.voice_spontaneity_level,
      'behavior_rules', rp.behavior_rules,
      'active', rp.active,
      'custom_overrides', ur.custom_overrides
    ) INTO v_relationship
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
  EXCEPTION WHEN OTHERS THEN
    -- Tables may not exist or schema may differ; safe to continue
    v_relationship := NULL;
  END;

  -- 9) RESOLVE PROMPT CONTRACT FOR INTERNAL_FINAL_RESPONSE
  v_prompt_contract := NULL;
  BEGIN
    SELECT atlas_get_prompt_contract(
      v_decision.empresa_id,
      'INTERNAL_FINAL_RESPONSE',
      v_decision.agent_code
    ) INTO v_prompt_contract;
  EXCEPTION WHEN OTHERS THEN
    -- Prompt contract may not exist; this is an error condition
    RETURN jsonb_build_object(
      'error', 'PROMPT_CONTRACT_NOT_FOUND',
      'contract_code', 'INTERNAL_FINAL_RESPONSE',
      'safe_to_continue', false
    );
  END;

  -- 10) RESOLVE CANONICAL TOOL EXECUTION (if tool_required=true)
  v_tool_result := NULL;
  v_tool_status := NULL;

  IF v_decision.tool_required = true AND v_decision.selected_tool_code IS NOT NULL THEN
    -- Query tool requests table for decision_id in input_payload
    -- Must be: same empresa_id, same conversation_id, expected tool_code, completed with result
    SELECT id, status, result_payload, error_code, error_message
    INTO v_tool_request
    FROM public.atlas_agent_tool_requests
    WHERE empresa_id = v_decision.empresa_id
      AND conversation_id = v_decision.conversation_id
      AND tool_code = v_decision.selected_tool_code
      AND input_payload->>'decision_id' = p_decision_id::text
    ORDER BY requested_at DESC, started_at DESC
    LIMIT 1;

    IF FOUND AND v_tool_request.status = 'COMPLETED' THEN
      -- Tool execution successful; use canonical result_payload
      v_tool_result := v_tool_request.result_payload;
      v_tool_status := 'COMPLETED';
    ELSIF FOUND THEN
      -- Tool execution exists but not completed
      v_tool_status := v_tool_request.status; -- PENDING, IN_PROGRESS, FAILED, CANCELLED, etc.
      v_tool_result := NULL;
    ELSE
      -- Tool execution not found
      v_tool_status := 'MISSING';
      v_tool_result := NULL;
    END IF;
  END IF;

  -- 11) DETERMINE DECISION STATE
  -- Based on canonical decision validation state
  v_decision_state := 'INVALID';
  
  IF v_decision.clarification_required = true THEN
    v_decision_state := 'CLARIFICATION';
    v_safe_to_generate := false;
  ELSIF v_decision.permission_granted = false OR v_decision.permission_required = true THEN
    v_decision_state := 'DENIED';
    v_safe_to_generate := false;
  ELSIF v_decision.clarification_required = false 
    AND v_decision.permission_granted = true 
    AND (v_decision.decision_metadata->>'validation_status' = 'VALID') THEN
    v_decision_state := 'VALID';
    -- safe_to_generate depends on tool state
    IF v_decision.tool_required = false THEN
      v_safe_to_generate := true;
    ELSIF v_decision.tool_required = true AND v_tool_status = 'COMPLETED' THEN
      v_safe_to_generate := true;
    ELSE
      v_safe_to_generate := false;
    END IF;
  ELSE
    v_decision_state := 'INVALID';
    v_safe_to_generate := false;
  END IF;

  -- 12) RETURN STRUCTURED CONTEXT
  RETURN jsonb_build_object(
    'context_version', 'INTERNAL_FINAL_RESPONSE_CONTEXT_V1',
    'empresa_id', v_decision.empresa_id,
    'conversation_id', v_decision.conversation_id,
    'decision_id', v_decision.id,
    'user_id', v_decision.user_id,
    'agent_code', v_decision.agent_code,
    'decision_state', v_decision_state,
    'safe_to_generate', v_safe_to_generate,
    'validated_decision', jsonb_build_object(
      'id', v_decision.id,
      'intent_code', v_decision.intent_code,
      'confidence', v_decision.confidence,
      'tool_required', v_decision.tool_required,
      'selected_tool_code', v_decision.selected_tool_code,
      'permission_required', v_decision.permission_required,
      'permission_granted', v_decision.permission_granted,
      'clarification_required', v_decision.clarification_required,
      'clarification_reason', v_decision.clarification_reason,
      'seriousness_level', v_decision.seriousness_level,
      'humor_allowed', v_decision.humor_allowed,
      'relationship_code', v_decision.relationship_code,
      'response_mode', v_decision.response_mode,
      'decision_metadata', v_decision.decision_metadata,
      'created_at', v_decision.created_at
    ),
    'current_message', CASE 
      WHEN v_current_message IS NULL THEN NULL
      ELSE jsonb_build_object(
        'message_id', v_current_message.id,
        'message_type', v_current_message.message_type,
        'role', v_current_message.role,
        'content', v_current_message.content,
        'created_at', v_current_message.created_at
      )
    END,
    'memory', v_memory,
    'persona', v_persona,
    'relationship', v_relationship,
    'prompt_contract', v_prompt_contract,
    'canonical_tool_execution', CASE
      WHEN v_tool_request IS NULL THEN NULL
      ELSE jsonb_build_object(
        'tool_request_id', v_tool_request.id,
        'tool_code', v_decision.selected_tool_code,
        'status', v_tool_request.status,
        'result_available', v_tool_result IS NOT NULL
      )
    END,
    'canonical_tool_result', v_tool_result,
    'tool_result_used', (v_tool_status = 'COMPLETED'),
    'created_at', v_now
  );

END;
$function$;

-- Grants
GRANT EXECUTE ON FUNCTION public.atlas_internal_prepare_final_response_context(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.atlas_internal_prepare_final_response_context(uuid) TO service_role;
