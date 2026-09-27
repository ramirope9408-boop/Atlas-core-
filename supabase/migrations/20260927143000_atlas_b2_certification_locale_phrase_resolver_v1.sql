-- ATLAS B2 certification locale phrase resolver V1
-- Date: 2026-09-27
-- Resolves synthetic conversation phrases from installed canonical locale.
-- Supported phrase families are intentionally small and deterministic.

begin;

do $$
begin
  if to_regclass('public.atlas_canonical_data_versions') is null then
    raise exception 'Locale phrase resolver requires canonical data core';
  end if;
end;
$$;

create or replace function public.atlas_detect_certification_locale_v1(
  p_canonical_data_version_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_canonical public.atlas_canonical_data_versions%rowtype;
  v_locale text;
begin
  select canonical.*
  into v_canonical
  from public.atlas_canonical_data_versions as canonical
  where canonical.id = p_canonical_data_version_id
    and canonical.version_status = 'APPROVED';

  if not found then
    return null;
  end if;

  select coalesce(
    nullif(btrim(record.value->'value'->>'locale'), ''),
    nullif(btrim(record.value->'value'->>'language_locale'), ''),
    nullif(btrim(record.value->'value'->>'language'), ''),
    nullif(btrim(record.value->'value'->>'language_code'), '')
  )
  into v_locale
  from jsonb_array_elements(v_canonical.canonical_payload->'records') as record(value)
  where record.value->>'inventory_code' = 'AGENT_PERSONALITY_PROFILE'
  limit 1;

  if v_locale is null then
    select coalesce(
      nullif(btrim(record.value->'value'->>'locale'), ''),
      nullif(btrim(record.value->'value'->>'language'), ''),
      nullif(btrim(record.value->'value'->>'country'), '')
    )
    into v_locale
    from jsonb_array_elements(v_canonical.canonical_payload->'records') as record(value)
    where record.value->>'inventory_code' = 'LOCATION_AND_LOCALE'
    limit 1;
  end if;

  if v_locale is null then
    return null;
  end if;

  v_locale := lower(v_locale);

  if v_locale like 'es%' or v_locale in ('spanish','espanol','español','co','colombia') then
    return 'es';
  elsif v_locale like 'en%' or v_locale = 'english' then
    return 'en';
  end if;

  return null;
end;
$$;

create or replace function public.atlas_certification_phrase_v1(
  p_locale text,
  p_phrase_code text
)
returns text
language sql
immutable
strict
security definer
set search_path = public, pg_temp
as $$
  select case
    when p_locale = 'es' and p_phrase_code = 'ACKNOWLEDGEMENT' then 'Listo, quedo atento.'
    when p_locale = 'es' and p_phrase_code = 'EXPLICIT_ACCEPTANCE' then 'Sí, acepto la propuesta actual.'
    when p_locale = 'es' and p_phrase_code = 'PAYMENT_REQUEST' then 'Quiero continuar con el pago.'
    when p_locale = 'es' and p_phrase_code = 'DOCUMENT_REQUEST' then 'Genera el documento de la versión actual.'
    when p_locale = 'es' and p_phrase_code = 'CANONICAL_QUESTION' then 'Cuéntame sobre {{CANONICAL_ENTITY}}.'
    when p_locale = 'es' and p_phrase_code = 'UNSUPPORTED_ATTRIBUTE_QUESTION' then '¿Cuál es el {{UNSUPPORTED_ATTRIBUTE}} de {{CANONICAL_ENTITY}}?'
    when p_locale = 'es' and p_phrase_code = 'VISUAL_REQUEST' then 'Muéstrame una imagen de {{CANONICAL_ENTITY_OR_FAMILY}}.'
    when p_locale = 'en' and p_phrase_code = 'ACKNOWLEDGEMENT' then 'Okay, I will wait for it.'
    when p_locale = 'en' and p_phrase_code = 'EXPLICIT_ACCEPTANCE' then 'Yes, I accept the current proposal.'
    when p_locale = 'en' and p_phrase_code = 'PAYMENT_REQUEST' then 'I want to continue with payment.'
    when p_locale = 'en' and p_phrase_code = 'DOCUMENT_REQUEST' then 'Generate the document for the current version.'
    when p_locale = 'en' and p_phrase_code = 'CANONICAL_QUESTION' then 'Tell me about {{CANONICAL_ENTITY}}.'
    when p_locale = 'en' and p_phrase_code = 'UNSUPPORTED_ATTRIBUTE_QUESTION' then 'What is the {{UNSUPPORTED_ATTRIBUTE}} of {{CANONICAL_ENTITY}}?'
    when p_locale = 'en' and p_phrase_code = 'VISUAL_REQUEST' then 'Show me an image of {{CANONICAL_ENTITY_OR_FAMILY}}.'
    else null
  end
$$;

revoke all on function public.atlas_detect_certification_locale_v1(uuid)
from public, anon, authenticated;
revoke all on function public.atlas_certification_phrase_v1(text,text)
from public, anon, authenticated;

grant execute on function public.atlas_detect_certification_locale_v1(uuid)
to service_role;
grant execute on function public.atlas_certification_phrase_v1(text,text)
to service_role;

commit;