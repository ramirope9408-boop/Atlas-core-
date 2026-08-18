// C1 SMOKE TEST GUIDE
// atlas_internal_prepare_final_response_context V1
// Valid Decision Without Tool

/*
==================================================
C1 EXECUTION ENVIRONMENT: DENO + AUTHENTICATED JWT
==================================================

PROBLEM: The RPC has SECURITY DEFINER and requires auth.uid()
  public.atlas_internal_prepare_final_response_context(p_decision_id uuid)

SUPABASE SQL EDITOR LIMITATION:
  ✗ SQL Editor runs as service_role (NOT authenticated user)
  ✗ auth.uid() returns NULL in SQL Editor
  ✗ RPC will immediately fail with error='AUTH_REQUIRED'
  ✗ CANNOT be used to test the RPC's actual authorization logic

SOLUTION:
  ✓ Create fixture data in SQL Editor (runs as service_role)
  ✓ Call RPC from authenticated Deno script (has user JWT context)
  ✓ Deno client preserves auth.uid() via Bearer token
  ✓ Can validate full authorization chain (auth + ownership + empresa access)

AUTHENTICATION FLOW:
  1. Deno script signs in OWNER via email/password
  2. Receives JWT access_token from Supabase Auth
  3. Calls RPC via /rest/v1/rpc endpoint with Bearer token
  4. Supabase JWT middleware extracts auth.uid() from token
  5. RPC receives authenticated user context
  6. Authorization checks proceed normally

*/

/*
==================================================
C1 FIXTURE REQUIRED: YES
==================================================

Fixture SQL Location:
  supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql
  Section: "C1: Valid decision without tool"

What Fixture Creates:
  1. Verifies OWNER user exists (queries auth.users)
  2. Verifies empresa exists (bf55a6aa-2e3f-4749-b2b8-135537a7c7bf)
  3. Verifies conversation exists (b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de)
  4. Creates source message (c1100000-0000-0000-0000-000000000001)
  5. Creates decision (c1000000-0000-0000-0000-000000000001) with:
     - user_id = OWNER_ID
     - empresa_id = bf55a6aa-2e3f-4749-b2b8-135537a7c7bf
     - conversation_id = b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de
     - agent_code = ATLAS_AGENT_STANDARD
     - intent_code = ANSWER_INQUIRY
     - confidence = 0.92
     - tool_required = false (C1 requirement)
     - selected_tool_code = NULL (no tool)
     - permission_required = false
     - permission_granted = true
     - clarification_required = false (C1 requirement)
     - seriousness_level = NORMAL
     - humor_allowed = true
     - response_mode = TEXT
     - decision_metadata.validation_status = VALID (C1 requirement)

Fixture Data Safety:
  ✓ Wrapped in BEGIN; ... ROLLBACK; (no permanent data contamination)
  ✓ Uses existing test empresa/conversation (not created)
  ✓ Creates message + decision only (both removed on ROLLBACK)
  ✓ Safe to run multiple times

*/

/*
==================================================
FIXTURE SQL EXECUTION
==================================================

Step 1: Open Supabase SQL Editor in your project

Step 2: Copy and run the C1 fixture from:
  supabase/tests/atlas_internal_prepare_final_response_context_v1_smoke.sql
  (Section: "C1: Valid decision without tool")

Expected Output:
  [C1] Fixture created. Decision ID: c1000000-0000-0000-0000-000000000001
  [C1] OWNER ID: <uuid of OWNER user>
  [C1] Now run authenticated C1 test: deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts

Note: If fixture fails, check:
  - Does OWNER user exist? (Check auth.users table)
  - Does empresa bf55a6aa-2e3f-4749-b2b8-135537a7c7bf exist?
  - Does conversation b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de exist?

*/

/*
==================================================
AUTHENTICATED C1 COMMAND
==================================================

Tool: Deno (must be installed: https://deno.land)

Command:
  cd /path/to/Atlas
  export SUPABASE_URL="https://<project-id>.supabase.co"
  export SUPABASE_ANON_KEY="<your-anon-key>"
  export OWNER_EMAIL="<owner-email>"
  export OWNER_PASSWORD="<owner-password>"
  deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts

Script Location:
  scripts/smoke-c1-context-builder.ts

What Script Does:
  1. Reads env vars (SUPABASE_URL, SUPABASE_ANON_KEY, OWNER_EMAIL, OWNER_PASSWORD)
  2. Signs in OWNER via /auth/v1/token endpoint
  3. Receives JWT access_token
  4. Calls atlas_internal_prepare_final_response_context RPC with:
     - p_decision_id = c1000000-0000-0000-0000-000000000001 (from fixture)
     - Authorization: Bearer <access_token>
  5. Validates response against C1 expectations
  6. Prints results

Authentication Context:
  ✓ auth.uid() = OWNER's user ID
  ✓ All authorization checks pass (ownership, empresa access verified)
  ✓ RPC returns full context (not error)

*/

/*
==================================================
EXPECTED C1 RESULT
==================================================

RPC Returns (success case):

{
  "context_version": "INTERNAL_FINAL_RESPONSE_CONTEXT_V1",
  "empresa_id": "bf55a6aa-2e3f-4749-b2b8-135537a7c7bf",
  "conversation_id": "b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de",
  "decision_id": "c1000000-0000-0000-0000-000000000001",
  "user_id": "<OWNER_ID>",
  "agent_code": "ATLAS_AGENT_STANDARD",
  "decision_state": "VALID",
  "safe_to_generate": true,  ← C1 expectation: true
  
  "validated_decision": {
    "id": "c1000000-0000-0000-0000-000000000001",
    "intent_code": "ANSWER_INQUIRY",
    "confidence": 0.92,
    "tool_required": false,  ← C1 requirement
    "selected_tool_code": null,  ← C1 requirement
    "permission_required": false,
    "permission_granted": true,
    "clarification_required": false,  ← C1 requirement
    "clarification_reason": null,
    "seriousness_level": "NORMAL",
    "humor_allowed": true,
    "relationship_code": null,
    "response_mode": "TEXT",
    "decision_metadata": {
      "validation_status": "VALID",  ← C1 requirement
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
  
  "memory": {...},  ← May be null if context RPC unavailable
  "persona": {...},  ← May be null if RPC unavailable
  "relationship": null,  ← No relationship_code in C1 decision
  
  "prompt_contract": {
    "system_prompt": "...",
    "contract_code": "INTERNAL_FINAL_RESPONSE",
    "version": "V1",
    "resolution": "GLOBAL" or "COMPANY" or "AGENT",
    ...
  },
  
  "canonical_tool_execution": null,  ← tool_required=false → null
  "canonical_tool_result": null,  ← C1 expectation: null
  "tool_result_used": false,  ← C1 expectation: false
  
  "created_at": "2026-08-16T..."
}

C1 Validation Checks (in script):
  ✓ context_version = INTERNAL_FINAL_RESPONSE_CONTEXT_V1
  ✓ empresa_id = bf55a6aa-2e3f-4749-b2b8-135537a7c7bf
  ✓ conversation_id = b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de
  ✓ decision_id = c1000000-0000-0000-0000-000000000001
  ✓ decision_state = VALID
  ✓ safe_to_generate = true
  ✓ tool_result_used = false
  ✓ canonical_tool_result = null

All checks must pass for C1 to be considered PASSED.

*/

/*
==================================================
CLEANUP
==================================================

Automatic (within test):
  - Fixture SQL wrapped in BEGIN; ... ROLLBACK;
  - Decision and message are removed on ROLLBACK
  - No permanent data contamination

Manual (if needed):
  DELETE FROM public.atlas_internal_agent_decisions
  WHERE id = 'c1000000-0000-0000-0000-000000000001';

  DELETE FROM public.atlas_internal_messages
  WHERE id = 'c1100000-0000-0000-0000-000000000001';

*/

/*
==================================================
BLOCKERS
==================================================

No blockers for C1 execution.

Prerequisites (must exist):
  ✓ OWNER user (exists in production)
  ✓ empresa bf55a6aa-2e3f-4749-b2b8-135537a7c7bf (exists in production)
  ✓ conversation b947bf0c-dfe6-4b59-9df6-7abfa1bbc6de (exists in production)
  ✓ atlas_internal_prepare_final_response_context RPC deployed

If any prerequisite is missing, C1 fixture will error with clear message.

*/

/*
==================================================
EXECUTION CHECKLIST
==================================================

[  ] 1. Verify Deno installed: deno --version
[  ] 2. Verify SUPABASE_URL, SUPABASE_ANON_KEY available
[  ] 3. Verify OWNER email/password available
[  ] 4. Run C1 fixture in SQL Editor (copy/paste from smoke test file)
[  ] 5. Note decision_id from fixture output: c1000000-0000-0000-0000-000000000001
[  ] 6. Export env vars (SUPABASE_URL, SUPABASE_ANON_KEY, OWNER_EMAIL, OWNER_PASSWORD)
[  ] 7. Run: deno run --allow-env --allow-net scripts/smoke-c1-context-builder.ts
[  ] 8. Verify all checks pass (decision_state=VALID, safe_to_generate=true, etc.)
[  ] 9. Cleanup: ROLLBACK fixture transaction (automatic if in SQL block)

*/
