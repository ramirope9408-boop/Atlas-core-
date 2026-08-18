-- Discovery script for ATLAS INTERNAL_TOOL_EXECUTOR V1
-- Run this on the target database (Supabase SQL editor) to list availability and signatures

-- 1) Check existence of required tables
SELECT
  to_regclass('public.atlas_internal_tool_catalog') AS atlas_internal_tool_catalog_exists,
  to_regclass('public.atlas_internal_agent_decisions') AS atlas_internal_agent_decisions_exists;

-- 2) List columns for decisions and tool_catalog for manual review
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('atlas_internal_agent_decisions','atlas_internal_tool_catalog')
ORDER BY table_name, ordinal_position;

-- 3) List functions of interest and show readable argument types and return type
SELECT
  n.nspname AS schema,
  p.proname AS function_name,
  oidvectortypes(p.proargtypes) AS arg_types,
  p.proargnames AS arg_names,
  pg_get_functiondef(p.oid) AS definition,
  p.prorettype::regtype AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE p.proname IN (
  'atlas_internal_has_empresa_access',
  'atlas_internal_has_permission',
  'atlas_internal_executive_brief',
  'atlas_internal_events_read',
  'atlas_internal_quotes_read',
  'atlas_internal_crm_summary',
  'atlas_internal_sales_summary',
  'atlas_internal_register_message'
)
ORDER BY p.proname;

-- 4) Check for helper tables used for auditing (optional)
SELECT to_regclass('public.atlas_agent_tool_requests') AS atlas_agent_tool_requests_exists,
       to_regclass('public.atlas_request_agent_tool') AS atlas_request_agent_tool_exists;

-- 5) Check roles/grants for 'authenticated' and 'service_role' to ensure RPC grants can be applied
SELECT rolname, rolsuper, rolcanlogin FROM pg_roles WHERE rolname IN ('authenticated','service_role');

-- End discovery script. Save results and include signatures in the migration authoring step.
