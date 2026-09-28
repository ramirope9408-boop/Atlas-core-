begin;

create or replace function public.atlas_build_conversation_ai_context_v2(
  p_conversation_id uuid,
  p_empresa_id uuid,
  p_memory_limit integer default 20
)
returns jsonb
language plpgsql
stable
set search_path to 'public','storage','pg_temp'
as $function$
declare
  v_conversation public.atlas_conversations%rowtype;
  v_persona jsonb;
  v_memory jsonb;
  v_active_quote jsonb;
  v_catalog jsonb;
  v_pending jsonb;
  v_payment jsonb;
begin
  select * into v_conversation
  from public.atlas_conversations
  where id=p_conversation_id and empresa_id=p_empresa_id;

  if not found then raise exception 'CONVERSATION_NOT_FOUND'; end if;

  v_persona:=public.atlas_get_ai_persona(p_empresa_id,v_conversation.persona_code);
  if v_persona is null then raise exception 'ACTIVE_PERSONA_NOT_FOUND'; end if;

  v_memory:=public.atlas_get_conversation_memory(
    p_conversation_id,p_empresa_id,greatest(1,least(coalesce(p_memory_limit,20),50))
  );
  v_active_quote:=public.atlas_resolve_active_quote_context_v2(p_empresa_id,p_conversation_id);
  v_pending:=public.atlas_get_open_quote_modification_confirmation_v1(
    p_empresa_id,p_conversation_id
  );
  v_payment:=public.atlas_build_dynamic_payment_payload_v1(
    p_empresa_id,p_conversation_id
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'product_id',p.id,
      'sku',p.sku,
      'name',p.nombre,
      'summary',p.descripcion_resumen,
      'price',p.precio_base,
      'unit',p.unidad_medida,
      'status',p.estado,
      'visual',jsonb_build_object(
        'available',(o.id is not null),
        'public_url',case when o.id is not null then
          'https://lcdfuuptfogmjmfueeem.supabase.co/storage/v1/object/public/'
          ||o.bucket_id||'/'||o.name else null end,
        'bucket',o.bucket_id,
        'path',o.name
      )
    ) order by p.nombre
  ),'[]'::jsonb)
  into v_catalog
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
    and p.activo=true
    and p.estado='published'
    and p.deleted_at is null;

  return jsonb_build_object(
    'context_version','ATLAS_EXTERNAL_CONVERSATION_CONTEXT_V2',
    'empresa_id',p_empresa_id,
    'conversation',jsonb_build_object(
      'id',v_conversation.id,
      'channel',v_conversation.channel,
      'customer_phone',v_conversation.customer_phone,
      'customer_name',v_conversation.customer_name,
      'customer_email',v_conversation.customer_email,
      'status',v_conversation.status,
      'current_intent',v_conversation.current_intent
    ),
    'persona',v_persona,
    'memory',v_memory,
    'active_quote',v_active_quote,
    'pending_quote_modification_confirmation',v_pending,
    'payment_state',v_payment,
    'catalog_products',v_catalog,
    'context_rules',jsonb_build_object(
      'catalog_is_canonical',true,
      'visual_references_are_canonical',true,
      'active_quote_is_canonical',true,
      'pending_confirmation_is_canonical',true,
      'payment_state_is_canonical',true,
      'memory_is_history_not_business_truth',true,
      'never_invent_product_ids',true,
      'never_invent_visual_urls',true,
      'never_reconstruct_quote_from_old_messages',true,
      'critical_actions_require_backend_validation',true
    )
  );
end;
$function$;

commit;