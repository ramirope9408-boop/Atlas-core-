begin;

create or replace function public.atlas_resolve_conversation_visuals_v1(
  p_empresa_id uuid,
  p_conversation_id uuid,
  p_product_ids uuid[] default null,
  p_scope text default 'EXPLICIT'
)
returns jsonb
language plpgsql
stable
set search_path to 'public','storage','pg_temp'
as $function$
declare
  v_scope text:=upper(coalesce(p_scope,'EXPLICIT'));
  v_quote jsonb;
  v_qb uuid;
  v_ids uuid[];
  v_items jsonb;
begin
  if v_scope not in ('EXPLICIT','ACTIVE_QUOTE') then
    raise exception 'VISUAL_SCOPE_INVALID';
  end if;

  if v_scope='ACTIVE_QUOTE' then
    v_quote:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
    if coalesce((v_quote->>'found')::boolean,false) is not true then
      return jsonb_build_object('ready',false,'code','ACTIVE_QUOTE_NOT_FOUND','items','[]'::jsonb);
    end if;
    v_qb:=(v_quote->>'quote_builder_id')::uuid;
    select array_agg(distinct li.producto_id order by li.producto_id)
      into v_ids
    from public.atlas_quote_line_items li
    where li.empresa_id=p_empresa_id and li.quote_builder_id=v_qb;
  else
    v_ids:=coalesce(p_product_ids,array[]::uuid[]);
  end if;

  if coalesce(array_length(v_ids,1),0)=0 then
    return jsonb_build_object('ready',false,'code','VISUAL_PRODUCT_IDS_REQUIRED','items','[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'product_id',p.id,
      'sku',p.sku,
      'canonical_name',p.nombre,
      'image_available',(o.id is not null),
      'public_url',case when o.id is not null then
        'https://lcdfuuptfogmjmfueeem.supabase.co/storage/v1/object/public/'
        ||o.bucket_id||'/'||o.name else null end,
      'bucket',o.bucket_id,
      'path',o.name
    ) order by p.nombre
  ),'[]'::jsonb)
  into v_items
  from public.productos p
  left join lateral (
    select so.id,so.bucket_id,so.name
    from storage.objects so
    where so.bucket_id='atlas-public'
      and so.name like p_empresa_id::text||'/productos/'||p.sku||'/%'
      and coalesce(so.metadata->>'mimetype','') like 'image/%'
    order by so.created_at desc
    limit 1
  ) o on true
  where p.empresa_id=p_empresa_id
    and p.id=any(v_ids)
    and p.activo=true
    and p.estado='published'
    and p.deleted_at is null;

  return jsonb_build_object(
    'ready',jsonb_array_length(v_items)>0,
    'code','CANONICAL_VISUALS_RESOLVED_V1',
    'scope',v_scope,
    'items',v_items
  );
end;
$function$;

commit;