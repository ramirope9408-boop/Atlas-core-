-- Migration: atlas_internal_tool_executor_v1
-- Creates RPC public.atlas_internal_execute_tool(p_decision_id uuid) RETURNS jsonb
-- IMPORTANT: Do NOT run this migration automatically without review.

CREATE OR REPLACE FUNCTION public.atlas_internal_execute_tool(p_decision_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_decision RECORD;
  v_tool RECORD;
  v_validation_status text;
  v_audit_id uuid;
  v_result jsonb;
  v_now timestamptz := now();
BEGIN
  -- 1) Auth check (first)
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('execution_status','DENIED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','AUTH_REQUIRED');
  END IF;

  -- 2) Load decision
  SELECT * INTO v_decision FROM public.atlas_internal_agent_decisions WHERE id = p_decision_id LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','DECISION_NOT_FOUND');
  END IF;

  -- 3) Ensure decision belongs to caller
  IF v_decision.user_id IS NULL OR v_decision.user_id::text <> auth.uid()::text THEN
    RETURN jsonb_build_object('execution_status','DENIED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','OWNER_MISMATCH');
  END IF;

  -- 4) empresa access
  IF NOT public.atlas_internal_has_empresa_access(v_decision.empresa_id) THEN
    RETURN jsonb_build_object('execution_status','DENIED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','NO_EMPRESA_ACCESS');
  END IF;

  -- 5) basic decision checks
  IF v_decision.tool_required IS NOT TRUE THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','TOOL_NOT_REQUIRED');
  END IF;
  IF v_decision.selected_tool_code IS NULL THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','NO_TOOL_SELECTED');
  END IF;
  IF v_decision.permission_granted IS NOT TRUE THEN
    RETURN jsonb_build_object('execution_status','DENIED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','PERMISSION_NOT_GRANTED');
  END IF;
  IF v_decision.clarification_required IS TRUE THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','CLARIFICATION_REQUIRED');
  END IF;

  -- 6) validation_status from decision_metadata
  v_validation_status := (v_decision.decision_metadata->> 'validation_status');
  IF v_validation_status IS NULL OR v_validation_status <> 'VALID' THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','INVALID_VALIDATION_STATUS');
  END IF;

  -- 7) load tool from catalog
  SELECT * INTO v_tool FROM public.atlas_internal_tool_catalog WHERE tool_code = v_decision.selected_tool_code LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','UNSUPPORTED_TOOL_CODE');
  END IF;

  -- 8) tool must be active
  IF v_tool.active IS NOT TRUE THEN
    RETURN jsonb_build_object('execution_status','NOT_IMPLEMENTED','decision_id',p_decision_id,'safe_to_continue',false,'tool_code',v_tool.tool_code);
  END IF;

  -- 9) tool must be read_only for V1
  IF v_tool.read_only IS NOT TRUE THEN
    RETURN jsonb_build_object('execution_status','NOT_IMPLEMENTED','decision_id',p_decision_id,'safe_to_continue',false,'tool_code',v_tool.tool_code);
  END IF;

  -- 10) permission re-check for tool if required
  IF v_tool.required_permission IS NOT NULL THEN
    IF NOT public.atlas_internal_has_permission(v_decision.empresa_id, v_tool.required_permission) THEN
      RETURN jsonb_build_object('execution_status','DENIED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','PERMISSION_REVOKED');
    END IF;
  END IF;

  -- 11) Insert audit request row (use DEFAULT id)
  INSERT INTO public.atlas_agent_tool_requests(
    empresa_id, conversation_id, source_message_id, ai_message_id, agent_code, tool_code, status, input_payload, requested_at
  ) VALUES (
    v_decision.empresa_id, v_decision.conversation_id, v_decision.source_message_id, NULL, v_decision.agent_code, v_tool.tool_code, 'PENDING', jsonb_build_object('decision_id', p_decision_id, 'intent_code', v_decision.intent_code, 'runtime_version', 'INTERNAL_TOOL_EXECUTOR_V1'), now()
  ) RETURNING id INTO v_audit_id;

  -- 12) Update audit to IN_PROGRESS
  UPDATE public.atlas_agent_tool_requests SET status = 'IN_PROGRESS', started_at = now() WHERE id = v_audit_id;

  -- 13) Execute canonical RPC per tool_code
  BEGIN
    IF v_tool.tool_code = 'ATLAS_EXECUTIVE_BRIEF' THEN
      v_result := public.atlas_internal_executive_brief(v_decision.empresa_id, 30, 30);
    ELSIF v_tool.tool_code = 'ATLAS_EVENTS_READ' THEN
      v_result := public.atlas_internal_events_read(v_decision.empresa_id, current_date, current_date + 30);
    ELSIF v_tool.tool_code = 'ATLAS_QUOTES_READ' THEN
      v_result := public.atlas_internal_quotes_read(v_decision.empresa_id, 25);
    ELSIF v_tool.tool_code = 'ATLAS_CRM_SUMMARY' THEN
      v_result := public.atlas_internal_crm_summary(v_decision.empresa_id, 30);
    ELSIF v_tool.tool_code = 'ATLAS_SALES_SUMMARY' THEN
      v_result := public.atlas_internal_sales_summary(v_decision.empresa_id, 30);
    ELSE
      -- Known but not implemented tools
      IF v_tool.tool_code IN ('ATLAS_CREATOR_ANALYTICS','ATLAS_FINANCE_SUMMARY','ATLAS_OPERATIONS_MONITOR','ATLAS_QUOTE_CREATE_INTERNAL') THEN
        UPDATE public.atlas_agent_tool_requests SET status = 'FAILED', error_code = 'NOT_IMPLEMENTED', error_message = 'Tool not implemented in executor V1', completed_at = now() WHERE id = v_audit_id;
        RETURN jsonb_build_object('execution_status','NOT_IMPLEMENTED','decision_id',p_decision_id,'tool_code',v_tool.tool_code,'safe_to_continue',false);
      END IF;
      -- Unknown tool_code
      UPDATE public.atlas_agent_tool_requests SET status = 'FAILED', error_code = 'UNSUPPORTED_TOOL_CODE', error_message = 'Unsupported tool code', completed_at = now() WHERE id = v_audit_id;
      RETURN jsonb_build_object('execution_status','INVALID_DECISION','decision_id',p_decision_id,'safe_to_continue',false,'error_code','UNSUPPORTED_TOOL_CODE');
    END IF;

    -- 14) On success update audit row
    UPDATE public.atlas_agent_tool_requests SET status = 'COMPLETED', result_payload = v_result, completed_at = now() WHERE id = v_audit_id;

    RETURN jsonb_build_object(
      'execution_status','EXECUTED',
      'decision_id', p_decision_id,
      'empresa_id', v_decision.empresa_id,
      'conversation_id', v_decision.conversation_id,
      'intent_code', v_decision.intent_code,
      'tool_code', v_tool.tool_code,
      'read_only', true,
      'executed_at', now(),
      'result', v_result,
      'safe_to_continue', true
    );

  EXCEPTION WHEN OTHERS THEN
    -- On error, mark audit FAILED and return safe failure (do NOT store raw SQL errors)
    UPDATE public.atlas_agent_tool_requests SET status = 'FAILED', error_code = 'CANONICAL_TOOL_EXECUTION_FAILED', error_message = 'Canonical internal tool execution failed', completed_at = now() WHERE id = v_audit_id;
    RETURN jsonb_build_object('execution_status','FAILED','decision_id',p_decision_id,'safe_to_continue',false,'error_code','CANONICAL_TOOL_EXECUTION_FAILED');
  END;

END;
$function$;

-- Grants: allow authenticated and service_role to execute, function still requires auth.uid()
GRANT EXECUTE ON FUNCTION public.atlas_internal_execute_tool(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.atlas_internal_execute_tool(uuid) TO service_role;
