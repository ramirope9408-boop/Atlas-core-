-- VALENTINA V9
-- Hardens exception-product resolution for natural references such as
-- "la mesa mexicana" when the canonical active-quote name is "Estación mexicana".
-- Resolution remains active-quote-bound and requires a unique token-overlap match.

begin;

create or replace function public.atlas_extract_pending_quote_modification_patch_v1(
  p_empresa_id uuid,
  p_quote_builder_id uuid,
  p_proposal_text text
)
returns jsonb
language plpgsql
stable
set search_path to 'public','pg_temp'
as $function$
declare
  v_norm text;
  v_qty numeric;
  v_match text[];
  v_except_text text;
  v_except_norm text;
  v_except jsonb;
  v_except_pid uuid;
  v_products jsonb:='[]'::jsonb;
  v_fallback_count integer:=0;
begin
  if p_empresa_id is null or p_quote_builder_id is null then
    return jsonb_build_object('resolved',false,'reason','SCOPE_REQUIRED');
  end if;

  v_norm:=public.atlas_normalize_quote_query_v1(coalesce(p_proposal_text,''));
  v_match:=regexp_match(v_norm,'([0-9]+)( |$).*unidades?( |$)');

  if v_match is null then
    return jsonb_build_object('resolved',false,'reason','QUANTITY_NOT_DETERMINISTIC');
  end if;

  v_qty:=(v_match[1])::numeric;
  if v_qty<=0 then
    return jsonb_build_object('resolved',false,'reason','QUANTITY_INVALID');
  end if;

  if not (
    v_norm like '%cada opcion%'
    or v_norm like '%cada cosa%'
    or v_norm like '%los demas%'
    or v_norm like '%lo demas%'
    or v_norm like '%todo lo demas%'
  ) then
    return jsonb_build_object('resolved',false,'reason','SET_ALL_SCOPE_NOT_DETERMINISTIC');
  end if;

  if v_norm like '%ademas de %' then
    v_except_text:=split_part(v_norm,'ademas de ',2);
  elsif v_norm like '%excepto %' then
    v_except_text:=split_part(v_norm,'excepto ',2);
  elsif v_norm like '%menos %' then
    v_except_text:=split_part(v_norm,'menos ',2);
  elsif v_norm like '%salvo %' then
    v_except_text:=split_part(v_norm,'salvo ',2);
  end if;

  if nullif(btrim(v_except_text),'') is not null then
    -- Trim common confirmation tails so they do not contaminate product matching.
    v_except_text:=regexp_replace(
      v_except_text,
      '( es correcto| correcto| verdad| cierto| confirmas| por favor).*$',
      '',
      'g'
    );

    v_except:=public.atlas_resolve_active_quote_product_mention_v1(
      p_empresa_id,p_quote_builder_id,v_except_text
    );

    if coalesce((v_except->>'count')::int,0)=1 then
      v_except_pid=(v_except#>>'{matches,0,product_id}')::uuid;

    elsif coalesce((v_except->>'count')::int,0)>1 then
      return jsonb_build_object(
        'resolved',false,'reason','EXCEPTION_PRODUCT_AMBIGUOUS','matches',v_except->'matches'
      );

    else
      v_except_norm:=public.atlas_normalize_quote_query_v1(v_except_text);

      -- Unique active-quote token overlap fallback. Common stopwords are ignored.
      with exception_tokens as (
        select token
        from regexp_split_to_table(v_except_norm,'[[:space:]]+') token
        where length(token)>=4
          and token not in ('para','cada','cosa','opcion','opciones','ademas','excepto','menos','salvo','mesa')
      ),
      candidates as (
        select li.producto_id,
               p.nombre,
               count(distinct et.token) as token_hits
        from public.atlas_quote_line_items li
        join public.productos p
          on p.id=li.producto_id and p.empresa_id=li.empresa_id
        join exception_tokens et
          on public.atlas_normalize_quote_query_v1(p.nombre)
             like '%'||et.token||'%'
        where li.empresa_id=p_empresa_id
          and li.quote_builder_id=p_quote_builder_id
        group by li.producto_id,p.nombre
      ),
      best as (
        select * from candidates
        where token_hits=(select max(token_hits) from candidates)
      )
      select count(*),min(producto_id)
        into v_fallback_count,v_except_pid
      from best;

      if v_fallback_count>1 then
        return jsonb_build_object(
          'resolved',false,
          'reason','EXCEPTION_PRODUCT_TOKEN_MATCH_AMBIGUOUS',
          'exception_text',v_except_text
        );
      elsif v_fallback_count=0 then
        v_except_pid:=null;
      end if;
    end if;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'op','SET',
        'product_id',li.producto_id,
        'quantity',v_qty
      )
      order by li.created_at,li.id
    ),
    '[]'::jsonb
  )
  into v_products
  from public.atlas_quote_line_items li
  where li.empresa_id=p_empresa_id
    and li.quote_builder_id=p_quote_builder_id
    and (v_except_pid is null or li.producto_id<>v_except_pid);

  if jsonb_array_length(v_products)=0 then
    return jsonb_build_object('resolved',false,'reason','NO_PRODUCTS_TO_PATCH');
  end if;

  return jsonb_build_object(
    'resolved',true,
    'patch',jsonb_build_object('products',v_products),
    'quantity',v_qty,
    'exception_product_id',v_except_pid,
    'contract','PENDING_CONFIRMATION_PATCH_V2'
  );
end;
$function$;

commit;
