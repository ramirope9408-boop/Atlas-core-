-- VALENTINA V9 REGRESSION
-- Scenario: quote modification succeeds, then acknowledgement-only follow-up must not retrigger.
-- Requires the isolated certification fixture created for conversation
-- 90000000-0000-4000-8000-000000000001.

do $$
declare
  v_result jsonb;
  v_tool_requests bigint;
begin
  select public.atlas_execute_external_quote_request_v1(
    'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf'::uuid,
    '90000000-0000-4000-8000-000000000001'::uuid,
    '90000000-0000-4000-8000-000000000103'::uuid,
    '{}'::jsonb,
    'B2-CERT-V9-ACK-REGRESSION'
  )
  into v_result;

  if v_result->>'code' <> 'ACKNOWLEDGEMENT_NO_ACTION_V1' then
    raise exception 'V9 acknowledgement regression failed: code=%', v_result->>'code';
  end if;

  if coalesce((v_result->>'executed')::boolean,true)
     or coalesce((v_result->>'modification_triggered')::boolean,true)
     or coalesce((v_result->>'acceptance_created')::boolean,true)
     or coalesce((v_result->>'payment_triggered')::boolean,true)
     or v_result->>'next_action' <> 'NONE'
  then
    raise exception 'V9 acknowledgement regression failed: unexpected action: %', v_result;
  end if;

  select count(*)
  into v_tool_requests
  from public.atlas_agent_tool_requests
  where source_message_id='90000000-0000-4000-8000-000000000103'::uuid;

  if v_tool_requests <> 0 then
    raise exception 'V9 acknowledgement regression failed: tool request created';
  end if;
end;
$$;

select jsonb_build_object(
  'ok',true,
  'code','VALENTINA_V9_POST_MODIFICATION_ACK_NO_RETRIGGER_PASS'
) as result;
