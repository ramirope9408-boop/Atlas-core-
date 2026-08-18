// FINAL C1 SMOKE TEST PREPARATION REPORT
// atlas_internal_prepare_final_response_context V1
// Date: 2026-08-16

==================================================
C1 EXECUTION ENVIRONMENT: DENO + AUTHENTICATED JWT
==================================================

CANNOT: Supabase SQL Editor
  ✗ SQL Editor runs as service_role (NOT authenticated)
  ✗ auth.uid() returns NULL
  ✗ RPC immediately fails: error='AUTH_REQUIRED'

CAN: Deno Script with JWT Authentication
  ✓ Deno client receives Bearer token via JWT
  ✓ Supabase middleware extracts auth.uid() from token
  ✓ RPC receives authenticated user context
  ✓ Full authorization chain executed (auth → ownership → empresa access)
  ✓ All C1 expectations validated

AUTHENTICATION FLOW:
  1. Deno signs in OWNER via email/password
  2. Receives JWT access_token from /auth/v1/token
  3. Calls RPC via /rest/v1/rpc with Authorization: Bearer <token>
  4. Supabase middleware extracts user ID from JWT
  5. RPC checks auth.uid() = OWNER_ID (passes)
  6. RPC checks decision.user_id = auth.uid() (passes)
  7. RPC checks empresa access (passes)
  8. RPC returns full context for C1

==================================================
C1 FIXTURE REQUIRED: YES
==================================================

Fixture File:
  supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql
  Section: "C1: Valid decision without tool" (lines ~14-80)

Fixture Creates (transaction-based, ROLLBACK on cleanup):
  1. Verifies OWNER user exists
  2. Verifies empresa bf55a6aa-2e3f-4749-b2b8-135537a7c7bf exists
  3. Verifies conversation b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de exists
  4. Creates source message:
     - id: c1100000-0000-0000-0000-000000000001
     - content: "C1 test message: what is our quarterly revenue?"
  5. Creates decision:
     - id: c1000000-0000-0000-0000-000000000001
     - user_id: OWNER_ID (verified from auth.users)
     - empresa_id: bf55a6aa-2e3f-4749-b2b8-135537a7c7bf
     - conversation_id: b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de
     - agent_code: ATLAS_AGENT_STANDARD
     - intent_code: ANSWER_INQUIRY
     - confidence: 0.92
     - tool_required: FALSE (C1 requirement)
     - selected_tool_code: NULL (C1 requirement)
     - clarification_required: FALSE (C1 requirement)
     - permission_granted: TRUE
     - seriousness_level: NORMAL
     - humor_allowed: TRUE
     - response_mode: TEXT
     - decision_metadata.validation_status: VALID (C1 requirement)

Fixture Safety:
  ✓ BEGIN; ... ROLLBACK; wrapper (no permanent data)
  ✓ Uses existing empresa/conversation (not created)
  ✓ Only creates test message + decision (both removed)
  ✓ Safe to run multiple times
  ✓ Safe to revert if needed

==================================================
FIXTURE SQL EXECUTION STEPS
==================================================

Step 1:
  Open Supabase project SQL Editor (console.supabase.com)

Step 2:
  Copy fixture SQL from:
  supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql
  (Section: "C1: Valid decision without tool")

Step 3:
  Paste and Execute

Expected Console Output:
  [C1] Fixture created. Decision ID: c1000000-0000-0000-0000-000000000001
  [C1] OWNER ID: <uuid>
  [C1] Now run authenticated C1 test: deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts

Fixture Errors (if any):
  [C1] OWNER user not found → Create OWNER in auth.users first
  [C1] Empresa bf55a6aa-2e3f-4749-b2b8-135537a7c7bf not found → Check empresa exists
  [C1] Conversation not found in empresa → Check conversation exists

==================================================
AUTHENTICATED C1 COMMAND
==================================================

Tool: Deno Runtime (https://deno.land)

Installation:
  Mac/Linux: curl -fsSL https://deno.land/x/install/install.sh | sh
  Windows: irm https://deno.land/x/install/install.ps1 | iex
  Verify: deno --version

Environment Setup:
  export SUPABASE_URL="https://<project-id>.supabase.co"
  export SUPABASE_ANON_KEY="<your-publishable-anon-key>"
  export OWNER_EMAIL="<owner-email>"
  export OWNER_PASSWORD="<owner-password>"

Execute C1:
  cd /path/to/Atlas
  deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts

Script Location:
  scripts/smoke-c1-context-builder.ts

What Script Does:
  [C1] Starting C1 smoke test for context builder...
  [C1] Authenticating OWNER...
  [C1] Authentication OK - user: owner@example.com
  [C1] Calling atlas_internal_prepare_final_response_context with decision_id=c1000000-0000-0000-0000-000000000001...
  [C1] RPC Response:
  {
    "context_version": "INTERNAL_FINAL_RESPONSE_CONTEXT_V1",
    "empresa_id": "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf",
    ...
  }
  [C1] Validation:
  ✓ context_version: "INTERNAL_FINAL_RESPONSE_CONTEXT_V1"
  ✓ empresa_id: "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf"
  ✓ conversation_id: "b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de"
  ✓ decision_id: "c1000000-0000-0000-0000-000000000001"
  ✓ decision_state: "VALID"
  ✓ safe_to_generate: true
  ✓ tool_result_used: false
  ✓ canonical_tool_result: null

  [C1] Checks: 8 passed, 0 failed

  [C1] C1 SMOKE TEST PASSED ✓

Exit Code: 0 (success) or 1 (failure)

==================================================
EXPECTED C1 RESULT
==================================================

Success Response:

{
  "context_version": "INTERNAL_FINAL_RESPONSE_CONTEXT_V1",
  "empresa_id": "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf",
  "conversation_id": "b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de",
  "decision_id": "c1000000-0000-0000-0000-000000000001",
  "user_id": "<OWNER_ID>",
  "agent_code": "ATLAS_AGENT_STANDARD",
  
  "decision_state": "VALID",           ← C1 validation
  "safe_to_generate": true,            ← C1 validation
  
  "validated_decision": {
    "id": "c1000000-0000-0000-0000-000000000001",
    "intent_code": "ANSWER_INQUIRY",
    "confidence": 0.92,
    "tool_required": false,            ← C1 requirement
    "selected_tool_code": null,        ← C1 requirement
    "permission_required": false,
    "permission_granted": true,
    "clarification_required": false,   ← C1 requirement
    "clarification_reason": null,
    "seriousness_level": "NORMAL",
    "humor_allowed": true,
    "relationship_code": null,
    "response_mode": "TEXT",
    "decision_metadata": {
      "validation_status": "VALID",    ← C1 requirement
      "runtime": "SEMANTIC_LLM_EXECUTION_V1",
      "model": "gpt-5.6-luna"
    },
    "created_at": "2026-08-16T..."
  },
  
  "current_message": {
    "message_id": "c1100000-0000-0000-0000-000000000001",
    "message_type": "CONVERSATION",
    "role": "user",
    "content": "C1 test message: what is our quarterly revenue?",
    "created_at": "2026-08-16T..."
  },
  
  "memory": {...},
  "persona": {...},
  "relationship": null,
  
  "prompt_contract": {
    "system_prompt": "...",
    "contract_code": "INTERNAL_FINAL_RESPONSE",
    "version": "V1",
    "resolution": "GLOBAL|COMPANY|AGENT",
    ...
  },
  
  "canonical_tool_execution": null,    ← C1 validation (no tool)
  "canonical_tool_result": null,       ← C1 validation (no result)
  "tool_result_used": false,           ← C1 validation
  
  "created_at": "2026-08-16T..."
}

C1 Validation Checks (8 assertions):
  ✓ context_version = INTERNAL_FINAL_RESPONSE_CONTEXT_V1
  ✓ empresa_id = bf55a6aa-2e3f-4749-b2b8-135537a7c7bf
  ✓ conversation_id = b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de
  ✓ decision_id = c1000000-0000-0000-0000-000000000001
  ✓ decision_state = VALID
  ✓ safe_to_generate = true
  ✓ tool_result_used = false
  ✓ canonical_tool_result = null

All 8 checks must pass for C1 to be considered PASSED.

Failure Response (if RPC fails):

{
  "error": "AUTH_REQUIRED|OWNER_MISMATCH|NO_EMPRESA_ACCESS|...",
  "message": "<safe error message>",
  "safe_to_continue": false
}

If RPC returns error object, check:
  - Is OWNER authenticated? (verify JWT token valid)
  - Is OWNER the decision owner? (decision.user_id = auth.uid())
  - Does OWNER have empresa access? (atlas_internal_has_empresa_access check)

==================================================
CLEANUP
==================================================

Automatic Cleanup (within fixture transaction):
  - Fixture wrapped in BEGIN; ... ROLLBACK;
  - Decision created (removed on ROLLBACK)
  - Message created (removed on ROLLBACK)
  - No permanent data contamination

Manual Cleanup (if needed):
  DELETE FROM public.atlas_internal_agent_decisions
  WHERE id = 'c1000000-0000-0000-0000-000000000001';

  DELETE FROM public.atlas_internal_messages
  WHERE id = 'c1100000-0000-0000-0000-000000000001';

Fixture is idempotent:
  - Safe to run multiple times (uses ON CONFLICT DO NOTHING)
  - Can revert by rolling back transaction
  - Can delete manually if needed

==================================================
BLOCKERS
==================================================

NONE.

All prerequisites exist or are verified in fixture:
  ✓ OWNER user (verified in fixture, uses auth.users query)
  ✓ empresa bf55a6aa-2e3f-4749-b2b8-135537a7c7bf (verified in fixture)
  ✓ conversation b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de (verified in fixture)
  ✓ atlas_internal_prepare_final_response_context RPC (already deployed)
  ✓ Valid intent_code ANSWER_INQUIRY (exists in catalog)
  ✓ Deno runtime (user must install)

If fixture fails:
  - Clear error message from fixture RAISE NOTICE statements
  - Fixture will not create incomplete data
  - Safe to troubleshoot and retry

==================================================
C1 SMOKE TEST SUMMARY
==================================================

Test Name: C1 - Valid Decision Without Tool

Test Scope:
  - Decision with tool_required=false
  - No tool execution
  - Valid decision state
  - Canonical context resolution

Test Execution:
  Step 1: Run fixture SQL (creates test data)
  Step 2: Run authenticated Deno script (calls RPC, validates result)

Expected Duration: ~5-10 seconds (auth + RPC call + validation)

Success Criteria:
  ✓ 8 assertions pass
  ✓ decision_state = VALID
  ✓ safe_to_generate = true
  ✓ tool_result_used = false
  ✓ RPC returns complete context (no error)

Failure Criteria:
  ✗ Any assertion fails
  ✗ RPC returns error object
  ✗ Script exits with code 1

Files Involved:
  - supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql (fixture)
  - scripts/smoke-c1-context-builder.ts (authenticated test)
  - C1_SMOKE_TEST_GUIDE.md (this guide)

Ready to Execute: YES ✓
