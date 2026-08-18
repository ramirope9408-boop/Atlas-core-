-- Smoke Tests: atlas_internal_prepare_final_response_context_v1
-- Comprehensive test matrix for context builder RPC
-- Use BEGIN; ... ROLLBACK; for each test to avoid permanent contamination

/*
TEST MATRIX:
C1  Valid decision without tool → tool_result_used=false, safe_to_generate=true
C2  Valid decision + completed tool → tool_result_used=true, result preserved, safe_to_generate=true
C3  Clarification decision → decision_state=CLARIFICATION, safe_to_generate=false
C4  Missing decision → error (DECISION_NOT_FOUND)
C5  Decision owned by another user → error (OWNER_MISMATCH)
C6  Empresa access denied (user has no permission) → error (NO_EMPRESA_ACCESS)
C7  Tool required but execution missing/pending → tool_result_used=false, safe_to_generate=false
C8  Tool execution failed → tool_result_used=false, safe_to_generate=false
C9  Tool result from wrong empresa/conversation must never be used → safety isolation
C10 Persona/relationship/prompt resolve correctly (or safely null if missing)
*/

-- ============================================
-- C1: Valid decision without tool
-- ============================================
-- Fixture for C1 test: creates minimal decision without tool
-- CORRECTED FLOW: COMMIT (not ROLLBACK) so data persists for Deno script
--
-- Expected: safe_to_generate=true, tool_result_used=false, decision_state=VALID
--
-- Test Data:
-- - OWNER user: verified from auth.users
-- - empresa_id: bf55a6aa-2e3f-4749-b2b8-135537a7c7bf (existing)
-- - conversation_id: b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de (existing)
-- - decision_id: c1000000-0000-0000-0000-000000000001 (ATLAS_C1_SMOKE_TEST)
-- - message_id: c1100000-0000-0000-0000-000000000001 (ATLAS_C1_SMOKE_TEST)
--
-- FIXTURE LIFECYCLE:
-- 1. Execute this SQL (CREATE with COMMIT)
-- 2. Run: deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts
-- 3. Execute cleanup SQL after validation

BEGIN;

-- 0) Discover valid intent_code from catalog (do NOT invent)
-- This ensures we use a real intent_code that exists
DO $$
DECLARE
  v_owner_id uuid;
  v_empresa_id constant uuid := 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf';
  v_conversation_id constant uuid := 'b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de';
  v_decision_id constant uuid := 'c1000000-0000-0000-0000-000000000001';
  v_message_id constant uuid := 'c1100000-0000-0000-0000-000000000001';
  v_intent_code text;
  v_msg_count int;
  v_dec_count int;
BEGIN

  -- 1) Verify OWNER user exists
  SELECT id INTO v_owner_id FROM auth.users 
  WHERE email LIKE '%@atlas%' OR email = 'owner@test.local'
  ORDER BY created_at DESC LIMIT 1;
  
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION '[C1-FIXTURE] OWNER user not found. Create test user first.';
  END IF;
  RAISE NOTICE '[C1-FIXTURE] OWNER found: %', v_owner_id;

  -- 2) Verify empresa exists
  PERFORM 1 FROM public.atlas_empresas WHERE id = v_empresa_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '[C1-FIXTURE] Empresa % not found.', v_empresa_id;
  END IF;
  RAISE NOTICE '[C1-FIXTURE] Empresa verified: %', v_empresa_id;

  -- 3) Verify conversation exists
  PERFORM 1 FROM public.atlas_conversations 
  WHERE id = v_conversation_id AND empresa_id = v_empresa_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '[C1-FIXTURE] Conversation % not found in empresa.', v_conversation_id;
  END IF;
  RAISE NOTICE '[C1-FIXTURE] Conversation verified: %', v_conversation_id;

  -- 4) Check if C1 fixture already exists (fail safely)
  SELECT COUNT(*) INTO v_msg_count FROM public.atlas_internal_messages WHERE id = v_message_id;
  SELECT COUNT(*) INTO v_dec_count FROM public.atlas_internal_agent_decisions WHERE id = v_decision_id;
  
  IF v_msg_count > 0 OR v_dec_count > 0 THEN
    RAISE EXCEPTION '[C1-FIXTURE] C1 fixture already exists. Run cleanup SQL first.';
  END IF;
  RAISE NOTICE '[C1-FIXTURE] C1 fixture does not exist (safe to create)';

  -- 5) Discover a valid intent_code from catalog (NOT invented)
  -- Select first available intent_code from actual catalog
  SELECT code INTO v_intent_code FROM public.atlas_internal_intent_catalog 
  WHERE active = true LIMIT 1;
  
  IF v_intent_code IS NULL THEN
    RAISE EXCEPTION '[C1-FIXTURE] No valid intent_code found in atlas_internal_intent_catalog.';
  END IF;
  RAISE NOTICE '[C1-FIXTURE] Using verified intent_code: %', v_intent_code;

  -- 6) Create source message
  INSERT INTO public.atlas_internal_messages (
    id, empresa_id, conversation_id, message_type, role, content, created_at
  )
  VALUES (
    v_message_id,
    v_empresa_id,
    v_conversation_id,
    'CONVERSATION',
    'user',
    '[ATLAS_C1_SMOKE_TEST] test message',
    now()
  );
  RAISE NOTICE '[C1-FIXTURE] Message created: %', v_message_id;

  -- 7) Create C1 decision (valid, no tool, no clarification)
  INSERT INTO public.atlas_internal_agent_decisions (
    id,
    empresa_id,
    conversation_id,
    user_id,
    agent_code,
    source_message_id,
    intent_code,
    confidence,
    tool_required,
    selected_tool_code,
    permission_required,
    permission_granted,
    clarification_required,
    clarification_reason,
    seriousness_level,
    humor_allowed,
    relationship_code,
    response_mode,
    decision_metadata,
    created_at
  )
  VALUES (
    v_decision_id,
    v_empresa_id,
    v_conversation_id,
    v_owner_id,
    'ATLAS_AGENT_STANDARD',
    v_message_id,
    v_intent_code,
    0.92,
    false,  -- tool_required = false (C1 requirement)
    NULL,   -- selected_tool_code = null (no tool)
    false,
    true,
    false,  -- clarification_required = false (C1 requirement)
    NULL,
    'NORMAL',
    true,
    NULL,
    'TEXT',
    jsonb_build_object(
      'validation_status', 'VALID',
      'runtime', 'SEMANTIC_LLM_EXECUTION_V1',
      'model', 'gpt-5.6-luna',
      'fixture_tag', 'ATLAS_C1_SMOKE_TEST'
    ),
    now()
  );
  RAISE NOTICE '[C1-FIXTURE] Decision created: %', v_decision_id;
  RAISE NOTICE '[C1-FIXTURE] ✓ C1 FIXTURE READY FOR AUTHENTICATED TEST';
  RAISE NOTICE '[C1-FIXTURE] Run: deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts';
  RAISE NOTICE '[C1-FIXTURE] After test, cleanup with: DELETE FROM atlas_internal_agent_decisions WHERE id = ''%''', v_decision_id;

END $$;

COMMIT;

-- ============================================
-- C2: Valid decision + completed tool result
-- ============================================
BEGIN;

-- Create test decision with tool_required=true, selected_tool_code='ATLAS_EXECUTIVE_BRIEF'
-- Create matching tool request with status='COMPLETED', result_payload={...}
-- Expected: safe_to_generate=true, tool_result_used=true, result preserved

-- [Test assertion: call context builder and verify output]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<REAL_DECISION_ID_WITH_COMPLETED_TOOL>'::uuid);

-- [Check: tool_result_used = true, canonical_tool_result IS NOT NULL, safe_to_generate = true]

ROLLBACK;

-- ============================================
-- C3: Clarification decision
-- ============================================
BEGIN;

-- Create test decision with clarification_required=true
-- Expected: decision_state=CLARIFICATION, safe_to_generate=false

-- [Test assertion: call context builder and verify output]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<REAL_CLARIFICATION_DECISION_ID>'::uuid);

-- [Check: decision_state = 'CLARIFICATION', safe_to_generate = false]

ROLLBACK;

-- ============================================
-- C4: Missing decision (does not exist)
-- ============================================
BEGIN;

-- Call with non-existent decision_id
-- Expected: error 'DECISION_NOT_FOUND'

-- [Test assertion]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('00000000-0000-0000-0000-000000000000'::uuid);

-- [Check: error = 'DECISION_NOT_FOUND']

ROLLBACK;

-- ============================================
-- C5: Decision owned by another user
-- ============================================
BEGIN;

-- Simulate: authenticated user != decision.user_id
-- This test requires either:
--   a) Creating a decision owned by a different user and trying to access it
--   b) Using a different auth session
-- Expected: error 'OWNER_MISMATCH'

-- Note: In automated testing, you may need to:
--   1. Create user1 and user2
--   2. User1 creates decision
--   3. User2 attempts to call context builder with user1's decision
--   Result: OWNER_MISMATCH

-- [Test assertion]
-- [Requires multi-session setup; pseudocode below]
-- SET SESSION authorization '<USER2_ID>';
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<USER1_DECISION_ID>'::uuid);

-- [Check: error = 'OWNER_MISMATCH']

ROLLBACK;

-- ============================================
-- C6: Empresa access denied (user has no permission)
-- ============================================
BEGIN;

-- Simulate: atlas_internal_has_empresa_access returns false
-- Create a decision for empresa_id that authenticated user doesn't have access to
-- Expected: error 'NO_EMPRESA_ACCESS'

-- [Test assertion]
-- [Requires RLS setup where user has no access to empresa]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<DECISION_FOR_INACCESSIBLE_EMPRESA>'::uuid);

-- [Check: error = 'NO_EMPRESA_ACCESS']

ROLLBACK;

-- ============================================
-- C7: Tool required but execution missing/pending
-- ============================================
BEGIN;

-- Create decision with tool_required=true, selected_tool_code='ATLAS_EXECUTIVE_BRIEF'
-- Do NOT create tool request (or create with status='PENDING'/'IN_PROGRESS')
-- Expected: tool_result_used=false, safe_to_generate=false, tool_status='MISSING'|'PENDING'

-- [Test assertion]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<DECISION_WITH_MISSING_TOOL_REQUEST>'::uuid);

-- [Check: tool_result_used = false, safe_to_generate = false, canonical_tool_result IS NULL]

ROLLBACK;

-- ============================================
-- C8: Tool execution failed
-- ============================================
BEGIN;

-- Create decision with tool_required=true
-- Create tool request with status='FAILED', error_code='CANONICAL_TOOL_EXECUTION_FAILED'
-- Expected: tool_result_used=false, safe_to_generate=false, error tracked

-- [Test assertion]
-- SELECT * FROM public.atlas_internal_prepare_final_response_context('<DECISION_WITH_FAILED_TOOL>'::uuid);

-- [Check: tool_result_used = false, safe_to_generate = false, canonical_tool_result IS NULL]

ROLLBACK;

-- ============================================
-- C9: Tool result from wrong empresa/conversation isolation
-- ============================================
BEGIN;

-- Create two decisions: D1 (empresa_A, conversation_A) and D2 (empresa_B, conversation_B)
-- Create tool request for D1
-- Call context builder for D2
-- MUST NOT return result from D1
-- Expected: canonical_tool_result IS NULL

-- [Test assertion]
-- [Create D1, D2 with tool requests in different empresa/conversation]
-- SELECT result FROM public.atlas_internal_prepare_final_response_context('<D2_ID>'::uuid);

-- [Check: Tool request lookup uses input_payload->>'decision_id' AND empresa_id AND conversation_id]
-- [Verify: Only tool requests from same empresa/conversation are used]

ROLLBACK;

-- ============================================
-- C10: Persona/relationship/prompt resolve correctly
-- ============================================
BEGIN;

-- Create decision with:
--   - agent_code = known agent
--   - relationship_code = known relationship
--   - decision_metadata with validation_status='VALID'
-- Expected: persona object not null, relationship object not null, prompt_contract not null

-- [Test assertion]
-- SELECT 
--   (persona IS NOT NULL) as persona_resolved,
--   (relationship IS NOT NULL) as relationship_resolved,
--   (prompt_contract IS NOT NULL) as prompt_resolved
-- FROM jsonb_to_record(
--   public.atlas_internal_prepare_final_response_context('<FULL_DECISION_ID>'::uuid)
-- ) AS x(persona jsonb, relationship jsonb, prompt_contract jsonb);

-- [Check: All three are not null (or gracefully null if tables don't exist)]

ROLLBACK;

-- ============================================
-- TEST DATA SETUP (optional reference)
-- ============================================
/*
-- To run these tests, you need to have test data set up.
-- Here's a minimal template:

-- Create test user (or use existing auth user)
-- INSERT INTO auth.users (id, email) VALUES ('<USER_ID>', '<USER_EMAIL>') ON CONFLICT DO NOTHING;

-- Create test empresa
-- INSERT INTO public.atlas_empresas (id, company_name, owner_id) 
-- VALUES ('<EMPRESA_ID>', 'Test Company', '<USER_ID>')
-- ON CONFLICT DO NOTHING;

-- Create test conversation
-- INSERT INTO public.atlas_conversations (id, empresa_id, user_id)
-- VALUES ('<CONVERSATION_ID>', '<EMPRESA_ID>', '<USER_ID>')
-- ON CONFLICT DO NOTHING;

-- Create test source message
-- INSERT INTO public.atlas_internal_messages (id, empresa_id, conversation_id, message_type, role, content)
-- VALUES ('<MESSAGE_ID>', '<EMPRESA_ID>', '<CONVERSATION_ID>', 'CONVERSATION', 'user', 'Test message')
-- ON CONFLICT DO NOTHING;

-- Create test decision without tool
-- INSERT INTO public.atlas_internal_agent_decisions (
--   id, empresa_id, conversation_id, user_id, agent_code, source_message_id,
--   intent_code, confidence, tool_required, clarification_required, 
--   permission_required, permission_granted, seriousness_level, humor_allowed,
--   response_mode, decision_metadata
-- ) VALUES (
--   '<DECISION_ID_1>',
--   '<EMPRESA_ID>',
--   '<CONVERSATION_ID>',
--   '<USER_ID>',
--   'ATLAS_AGENT_STANDARD',
--   '<MESSAGE_ID>',
--   'ANSWER_INQUIRY',
--   0.95,
--   false,
--   false,
--   false,
--   true,
--   'NORMAL',
--   true,
--   'TEXT',
--   jsonb_build_object('validation_status', 'VALID', 'runtime', 'SEMANTIC_LLM_EXECUTION_V1')
-- )
-- ON CONFLICT DO NOTHING;

-- Create test decision with tool
-- INSERT INTO public.atlas_internal_agent_decisions (...)
-- VALUES (..., tool_required=true, selected_tool_code='ATLAS_EXECUTIVE_BRIEF', ...)

-- Create test tool request for decision with tool
-- INSERT INTO public.atlas_agent_tool_requests (
--   id, empresa_id, conversation_id, source_message_id, ai_message_id, agent_code, tool_code,
--   status, input_payload, result_payload, requested_at, started_at, completed_at
-- ) VALUES (
--   '<TOOL_REQUEST_ID>',
--   '<EMPRESA_ID>',
--   '<CONVERSATION_ID>',
--   '<MESSAGE_ID>',
--   NULL,
--   'ATLAS_AGENT_STANDARD',
--   'ATLAS_EXECUTIVE_BRIEF',
--   'COMPLETED',
--   jsonb_build_object('decision_id', '<DECISION_ID_WITH_TOOL>'),
--   jsonb_build_object('highlights', {...}),
--   now() - interval '10 minutes',
--   now() - interval '9 minutes',
--   now() - interval '8 minutes'
-- )
-- ON CONFLICT DO NOTHING;

*/
