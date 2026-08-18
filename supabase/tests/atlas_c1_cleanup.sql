-- C1 SMOKE TEST CLEANUP SQL
-- Execute AFTER authenticated Deno script completes successfully
-- Removes ONLY the C1 fixture data (safe deletion by exact UUID)
--
-- Fixture UUIDs:
-- - decision: c1000000-0000-0000-0000-000000000001
-- - message: c1100000-0000-0000-0000-000000000001
--
-- IMPORTANT:
-- - Only run this AFTER C1 smoke test passes
-- - Do NOT run if test is still in progress
-- - Delete order: decision first (FK), then message

BEGIN;

-- 1) Verify we're about to delete C1 fixture (safety check)
DO $$
DECLARE
  v_decision_id constant uuid := 'c1000000-0000-0000-0000-000000000001';
  v_message_id constant uuid := 'c1100000-0000-0000-0000-000000000001';
  v_dec_count int;
  v_msg_count int;
BEGIN
  SELECT COUNT(*) INTO v_dec_count FROM public.atlas_internal_agent_decisions WHERE id = v_decision_id;
  SELECT COUNT(*) INTO v_msg_count FROM public.atlas_internal_messages WHERE id = v_message_id;
  
  IF v_dec_count = 0 AND v_msg_count = 0 THEN
    RAISE NOTICE '[C1-CLEANUP] No C1 fixture data found to delete.';
    RETURN;
  END IF;
  
  RAISE NOTICE '[C1-CLEANUP] Found: % decision(s), % message(s)', v_dec_count, v_msg_count;
END $$;

-- 2) Delete decision (must come first due to FK)
DO $$
DECLARE
  v_deleted int := 0;
BEGIN
  DELETE FROM public.atlas_internal_agent_decisions
  WHERE id = 'c1000000-0000-0000-0000-000000000001'
    AND decision_metadata->>'fixture_tag' = 'ATLAS_C1_SMOKE_TEST';
  
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted > 0 THEN
    RAISE NOTICE '[C1-CLEANUP] ✓ Deleted % decision row(s)', v_deleted;
  ELSE
    RAISE WARNING '[C1-CLEANUP] Decision row not found or fixture_tag mismatch';
  END IF;
END $$;

-- 3) Delete message
DO $$
DECLARE
  v_deleted int := 0;
BEGIN
  DELETE FROM public.atlas_internal_messages
  WHERE id = 'c1100000-0000-0000-0000-000000000001'
    AND content LIKE '%ATLAS_C1_SMOKE_TEST%';
  
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  IF v_deleted > 0 THEN
    RAISE NOTICE '[C1-CLEANUP] ✓ Deleted % message row(s)', v_deleted;
  ELSE
    RAISE WARNING '[C1-CLEANUP] Message row not found or content mismatch';
  END IF;
END $$;

-- 4) Verify cleanup complete
DO $$
DECLARE
  v_decision_id constant uuid := 'c1000000-0000-0000-0000-000000000001';
  v_message_id constant uuid := 'c1100000-0000-0000-0000-000000000001';
  v_remaining int := 0;
BEGIN
  SELECT COUNT(*) INTO v_remaining FROM public.atlas_internal_agent_decisions WHERE id = v_decision_id;
  SELECT COUNT(*) + v_remaining INTO v_remaining FROM public.atlas_internal_messages WHERE id = v_message_id;
  
  IF v_remaining = 0 THEN
    RAISE NOTICE '[C1-CLEANUP] ✓ C1 FIXTURE CLEANUP COMPLETE - NO ROWS REMAIN';
  ELSE
    RAISE WARNING '[C1-CLEANUP] WARNING: % row(s) still remain', v_remaining;
  END IF;
END $$;

COMMIT;
