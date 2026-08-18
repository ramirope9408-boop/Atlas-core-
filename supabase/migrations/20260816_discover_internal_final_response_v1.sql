-- Discovery: INTERNAL_FINAL_RESPONSE V1 Dependencies
-- READ-ONLY discovery. Execute in Supabase SQL editor to inspect schema/contracts.
-- DO NOT modify any objects.

-- 1) Inspect atlas_ai_prompt_contracts schema and existing contracts
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_ai_prompt_contracts'
ORDER BY ordinal_position;

-- 2) List existing prompt contracts by type (search for FINAL_RESPONSE or similar)
SELECT * FROM public.atlas_ai_prompt_contracts
LIMIT 20;

-- 3) Inspect atlas_internal_register_message function signature
SELECT
  n.nspname AS schema,
  p.proname AS function_name,
  oidvectortypes(p.proargtypes) AS arg_types,
  p.proargnames AS arg_names,
  pg_get_functiondef(p.oid) AS full_definition,
  p.prorettype::regtype AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname = 'atlas_internal_register_message'
ORDER BY p.proname;

-- 4) Inspect atlas_ai_personas table (personality data)
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_ai_personas'
ORDER BY ordinal_position;

-- 5) List sample ai_personas to understand structure
SELECT * FROM public.atlas_ai_personas
LIMIT 5;

-- 6) Inspect relationship profile schema if exists
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('atlas_relationship_profiles', 'atlas_agent_relationship_profiles', 'atlas_relationship_config')
ORDER BY table_name, ordinal_position;

-- 7) Inspect atlas_internal_messages to understand message registration
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_internal_messages'
ORDER BY ordinal_position;

-- 8) Inspect atlas_agent_tool_requests to confirm result_payload path
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_agent_tool_requests'
ORDER BY ordinal_position;

-- 9) Test retrieval pattern: decision_id -> tool_request -> result_payload
-- (This is a read-only test; replace with real decision_id if available)
-- SELECT
--   d.id AS decision_id,
--   d.intent_code,
--   t.id AS tool_request_id,
--   t.status,
--   t.result_payload
-- FROM public.atlas_internal_agent_decisions d
-- LEFT JOIN public.atlas_agent_tool_requests t ON t.input_payload->>'decision_id' = d.id::text
-- WHERE d.id = '<REAL_DECISION_ID>'::uuid
-- LIMIT 1;

-- 10) Inspect audit/message logging tables
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('atlas_internal_audit_log', 'atlas_ai_message_audit', 'atlas_message_logs')
ORDER BY table_name, ordinal_position;

-- 11) List all RPC functions related to response/message/persona
SELECT
  n.nspname AS schema,
  p.proname AS function_name,
  p.prorettype::regtype AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname ~ '(response|message|persona|prompt|final)' AND n.nspname = 'public'
ORDER BY p.proname;

-- 12) Check if Edge Functions already exist for final response
-- (informational only; schema inspection via filesystem)

-- END discovery script
