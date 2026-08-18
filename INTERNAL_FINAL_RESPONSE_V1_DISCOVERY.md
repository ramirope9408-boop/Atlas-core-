// ATLAS INTERNAL_FINAL_RESPONSE V1 - DISCOVERY & DESIGN SUMMARY
// Created: 2026-08-16
// Status: DESIGN PHASE - REQUIRES DISCOVERY

/*
==================================================
DISCOVERY SUMMARY
==================================================

1. EXISTING COMPONENTS VERIFIED:
   ✓ SEMANTIC_LLM_EXECUTION V1 (deployed)
   ✓ INTERNAL_TOOL_EXECUTOR V1 (migration ready)
   ✓ atlas_internal_prepare_decision_context (RPC exists)
   ✓ atlas_get_prompt_contract (RPC exists)
   ✓ atlas_internal_validate_decision (RPC exists)
   ✓ atlas_internal_execute_tool (migration pending)
   ✓ atlas_agent_tool_requests (audit table exists, schema verified)
   ✓ atlas_internal_agent_decisions (schema verified)

2. COMPONENTS REQUIRING DISCOVERY SQL:
   ✗ atlas_ai_prompt_contracts (schema/contracts unknown)
   ✗ atlas_internal_register_message (signature unknown)
   ✗ atlas_ai_personas (schema/data unknown)
   ✗ Relationship profile tables (existence unknown)
   ✗ atlas_internal_messages (schema unknown)
   ✗ Audit table contracts (atlas_internal_audit_log, atlas_ai_message_audit, etc.)
   ✗ Tool result retrieval pattern (decision_id -> result_payload path unconfirmed)

3. EDGE FUNCTIONS INVENTORY:
   Existing:
   - atlas-internal-semantic-decision (Deno + TypeScript, Edge Function V1 pattern)
   
   Proposed (NOT YET CREATED):
   - atlas-internal-final-response (new, will follow same pattern)

4. LOCAL WORKSPACE STATE:
   - supabase/ folder structure present
   - migrations/ contains discovery and executor V1
   - functions/ contains only semantic decision
   - No local Edge Function code for final-response yet
   - Package structure ready for new function

==================================================
REUSABLE COMPONENTS IDENTIFIED
==================================================

1. Edge Function Pattern:
   - withSupabase({ auth: ["publishable", "secret"] }, ...)
   - User-scoped Supabase client
   - RPC-first design for data access
   - Safe error handling without leaking secrets

2. RPC Contract Pattern:
   - atlas_get_prompt_contract(empresa_id, contract_code, agent_code)
   - Resolves AGENT > COMPANY > GLOBAL
   - Versioned prompt templates
   - Can be reused for INTERNAL_FINAL_RESPONSE

3. Audit Integration:
   - atlas_agent_tool_requests pattern (audit + result tracking)
   - Versioned execution with metadata
   - Timestamps and status lifecycle

4. Context Loading:
   - atlas_internal_prepare_decision_context (decision context)
   - atlas_internal_build_context (conversation/memory context)
   - Decision metadata with validation_status

==================================================
MISSING CONTRACTS (MUST VERIFY)
==================================================

1. atlas_ai_prompt_contracts:
   - Does INTERNAL_FINAL_RESPONSE contract_code already exist?
   - What are valid contract_type values?
   - Does prompt inheritance work for final response?

2. atlas_internal_register_message:
   - Exact signature: parameters, return type
   - Required fields: message_role, message_type, content, etc.?
   - Does it return message_id or full message object?

3. Relationship Profiles:
   - Table name(s) for relationship configuration
   - How are they linked to decisions/conversations/companies?
   - What fields define personality modulation?

4. Message/Audit Logging:
   - Which tables are primary for response logging?
   - audit_log vs. message_audit - what's the contract?
   - Are responses stored in atlas_internal_messages or separate table?

==================================================
PROPOSED FINAL_RESPONSE FLOW
==================================================

Input:
  empresa_id: uuid
  conversation_id: uuid
  decision_id: uuid

Edge Function (atlas-internal-final-response):
  1. Verify auth.uid() and conversation ownership
  2. Load decision from decision_id
  3. Load full decision_context via RPC
  4. If tool_required=true:
     - Query atlas_agent_tool_requests for result_payload (by input_payload->>'decision_id')
     - Validate result exists, status=COMPLETED
  5. Load persona and relationship profile
  6. Load prompt contract for INTERNAL_FINAL_RESPONSE
  7. Build input payload for OpenAI (decision context + tool result if any)
  8. Call OpenAI Structured Output API
  9. Parse response per OUTPUT_CONTRACT
  10. Register response message via atlas_internal_register_message
  11. Audit log the response generation
  12. Return structured response JSON

==================================================
PROPOSED INPUT CONTRACT
==================================================

POST /atlas-internal-final-response

{
  "empresa_id": "uuid",
  "conversation_id": "uuid",
  "decision_id": "uuid"
}

All required (no tool result injection; fetched server-side).

==================================================
PROPOSED OUTPUT CONTRACT (to be refined)
==================================================

{
  "response_type": "FINAL" | "CLARIFICATION" | "SAFE_STOP",
  "response_mode": "TEXT" | "AUDIO" | "TEXT_PLUS_AUDIO",
  "text_response": "string | null",
  "audio_script": "string | null",
  "facts_used": [
    "result.highlights.upcoming_events",
    "result.highlights.quoted_value_in_period",
    "decision.intent_code"
  ],
  "tool_result_used": true | false,
  "humor_used": false,
  "seriousness_level": "RELAXED" | "NORMAL" | "SERIOUS" | "CRITICAL",
  "registered_message_id": "uuid | null",
  "safe_to_continue": true
}

Notes:
- facts_used: audit-friendly references, NOT chain-of-thought
- text_response: final human response (UTF-8, may include markdown)
- audio_script: for future TTS integration (v1: null)
- response_type: FINAL when fully answered, CLARIFICATION when ambiguity, SAFE_STOP for blocked

==================================================
SECURITY RISKS & MITIGATIONS
==================================================

1. Tool Result Injection:
   Risk: Client sends crafted tool result
   Mitigation: Fetch result_payload server-side via decision_id + validation

2. Persona/Relationship Spoofing:
   Risk: Client claims different persona
   Mitigation: Load persona by agent_code from decision; validate matches auth context

3. Permission Bypass:
   Risk: Return data from unauthorized decision
   Mitigation: Verify auth.uid() matches decision.user_id; use empresa_access check

4. LLM Hallucination:
   Risk: Model invents facts outside tool results
   Mitigation: System prompt constraints, Structured Output schema enforcement, audit facts_used

5. Secret Leakage:
   Risk: OpenAI response contains credentials/tokens
   Mitigation: Never pass auth tokens to LLM; sanitize facts before prompt; audit all facts

6. Response Mode Fabrication:
   Risk: Model returns unsupported audio format
   Mitigation: Strict enum validation in Structured Output schema; v1 TEXT only

==================================================
READY TO IMPLEMENT: NO
==================================================

BLOCKERS:
1. atlas_ai_prompt_contracts schema unknown
   → Execute discovery query #1-2

2. atlas_internal_register_message signature unknown
   → Execute discovery query #3

3. atlas_ai_personas schema/data unknown
   → Execute discovery query #4-5

4. Relationship profile schema unknown
   → Execute discovery query #6

5. atlas_internal_messages schema unknown
   → Execute discovery query #7

6. Tool result retrieval pattern not confirmed
   → Execute discovery query #9 with real test data

7. Audit/logging table contracts unknown
   → Execute discovery query #10

NEXT STEP:
→ Run 20260816_discover_internal_final_response_v1.sql in Supabase SQL editor
→ Paste results here
→ Update this document with verified schema/signatures
→ Then proceed to implementation

*/
