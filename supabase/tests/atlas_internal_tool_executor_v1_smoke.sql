-- Smoke tests for atlas_internal_execute_tool V1
-- IMPORTANT: These are templates with placeholders. Do NOT run against production without replacing placeholders.

-- Use a transaction and rollback to avoid mutating production data during tests
BEGIN;
-- T1: EXECUTIVE_STATUS / ATLAS_EXECUTIVE_BRIEF
-- Replace <DECISION_ID_T1> with a real decision id for testing
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T1>'::uuid);

-- T2: EVENTS_QUERY / ATLAS_EVENTS_READ
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T2>'::uuid);

-- T3: QUOTES_QUERY / ATLAS_QUOTES_READ
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T3>'::uuid);

-- T4: CRM_QUERY / ATLAS_CRM_SUMMARY
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T4>'::uuid);

-- T5: SALES_QUERY / ATLAS_SALES_SUMMARY
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T5>'::uuid);

-- T6: clarification_required = true -> expect INVALID_DECISION
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T6>'::uuid);

-- T7: validation_status != VALID -> expect INVALID_DECISION
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T7>'::uuid);

-- T8: current permission revoked -> expect DENIED
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T8>'::uuid);

-- T9: ATLAS_FINANCE_SUMMARY -> NOT_IMPLEMENTED
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T9>'::uuid);

-- T10: invented tool_code -> INVALID_DECISION
-- SELECT public.atlas_internal_execute_tool('<DECISION_ID_T10>'::uuid);

ROLLBACK;
