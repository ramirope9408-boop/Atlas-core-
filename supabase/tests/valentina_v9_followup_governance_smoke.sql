-- VALENTINA V9 follow-up governance regression smoke
do $$
begin
  if public.atlas_is_non_action_acknowledgement_v1('Dale quedo atento') is not true then
    raise exception 'V9_ACK_GUARD_FAILED_DALE_QUEDO_ATENTO';
  end if;

  if public.atlas_is_non_action_acknowledgement_v1('Listo estoy pendiente') is not true then
    raise exception 'V9_ACK_GUARD_FAILED_LISTO_PENDIENTE';
  end if;

  if public.atlas_is_non_action_acknowledgement_v1('Dale, quítame la albóndiga') is not false then
    raise exception 'V9_ACK_GUARD_FALSE_POSITIVE_MODIFICATION';
  end if;

  if public.atlas_is_non_action_acknowledgement_v1('Sí, acepto la cotización') is not false then
    raise exception 'V9_ACK_GUARD_FALSE_POSITIVE_ACCEPTANCE';
  end if;
end
$$;

select jsonb_build_object(
  'ok',true,
  'code','VALENTINA_V9_FOLLOWUP_GOVERNANCE_SMOKE_PASS',
  'pure_ack_blocked',true,
  'explicit_modification_preserved',true,
  'explicit_acceptance_preserved',true
) as result;
