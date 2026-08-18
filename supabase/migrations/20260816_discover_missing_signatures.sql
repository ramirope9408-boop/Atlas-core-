-- Discovery: Missing RPC Signatures for INTERNAL_FINAL_RESPONSE V1
-- READ-ONLY discovery queries only
-- Execute in Supabase SQL editor to get exact signatures

-- 1) atlas_get_ai_persona function signature
SELECT
  n.nspname AS schema,
  p.proname AS function_name,
  oidvectortypes(p.proargtypes) AS arg_types,
  p.proargnames AS arg_names,
  p.prorettype::regtype AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname = 'atlas_get_ai_persona' AND n.nspname = 'public';

-- 2) atlas_internal_build_context function signature
SELECT
  n.nspname AS schema,
  p.proname AS function_name,
  oidvectortypes(p.proargtypes) AS arg_types,
  p.proargnames AS arg_names,
  p.prorettype::regtype AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname = 'atlas_internal_build_context' AND n.nspname = 'public';

-- 3) atlas_internal_messages table schema
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_internal_messages'
ORDER BY ordinal_position;

-- 4) Relationship tables - check which exist
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public' AND table_name ~ '^atlas_.*relationship'
ORDER BY table_name;

-- 5) If relationship tables exist, get their schemas
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name ~ '^atlas_.*relationship'
ORDER BY table_name, ordinal_position;

-- 6) Check atlas_ai_personas schema
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_ai_personas'
ORDER BY ordinal_position;

-- 7) Verify atlas_internal_tool_catalog has read_only field and enum values
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_internal_tool_catalog'
ORDER BY ordinal_position;

-- 8) Confirm atlas_agent_tool_requests input_payload->>'decision_id' retrievable
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'atlas_agent_tool_requests'
ORDER BY ordinal_position;
