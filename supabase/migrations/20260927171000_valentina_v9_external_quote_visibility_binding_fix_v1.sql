-- VALENTINA V9 external quote visibility binding hardening
-- Fixes a real branch-discovered contract mismatch:
-- materialization stores WHATSAPP:<conversation>:<source_message>,
-- while the visibility resolver previously accepted only WHATSAPP:<conversation>.
-- The quote builder now also carries canonical conversation binding metadata.

CREATE OR REPLACE FUNCTION public.atlas_quote_builder_materialize_external_v1(p_quote_builder_id uuid, p_empresa_id uuid, p_catalogo_id uuid, p_conversation_id uuid, p_source_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_quote public.atlas_quote_builders%rowtype;
  v_validation jsonb;
  v_cotizacion_id uuid;
  v_existing_id uuid;
  v_product_count integer := 0;
begin
  perform public.atlas_require_empresa_active(p_empresa_id);

  select *
  into v_quote
  from public.atlas_quote_builders qb
  where qb.id = p_quote_builder_id
    and qb.empresa_id = p_empresa_id
  for update;

  if not found then
    raise exception 'ATLAS_EXTERNAL_QUOTE_BUILDER_NOT_FOUND'
      using errcode = '22023';
  end if;

  v_validation := public.atlas_validate_quote_builder(
    p_quote_builder_id,
    p_empresa_id
  );

  if coalesce((v_validation ->> 'ready_for_quote')::boolean, false) is not true then
    raise exception 'ATLAS_EXTERNAL_QUOTE_BUILDER_NOT_READY'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.catalogos c
    where c.id = p_catalogo_id
      and c.empresa_id = p_empresa_id
      and c.deleted_at is null
      and c.estado = 'published'
      and (c.vigente_desde is null or c.vigente_desde <= current_date)
      and (c.vigente_hasta is null or c.vigente_hasta >= current_date)
  ) then
    raise exception 'ATLAS_EXTERNAL_QUOTE_CATALOG_NOT_AVAILABLE'
      using errcode = '22023';
  end if;

  select c.id
  into v_existing_id
  from public.cotizaciones c
  where c.empresa_id = p_empresa_id
    and c.quote_builder_id = p_quote_builder_id
    and c.deleted_at is null
  limit 1;

  if v_existing_id is not null then
    return jsonb_build_object(
      'materialization_status', 'EXISTING_MATERIALIZATION',
      'quote_builder_id', p_quote_builder_id,
      'cotizacion_id', v_existing_id,
      'idempotent_replay', true
    );
  end if;

  insert into public.cotizaciones (
    empresa_id,
    numero,
    estado,
    moneda,
    cliente_nombre,
    cliente_email,
    cliente_telefono,
    direccion_cliente,
    notas,
    referencia_externa,
    fecha_emision,
    fecha_validez,
    subtotal,
    impuestos,
    total,
    catalogo_id,
    medio_pago_id,
    created_by,
    updated_by,
    quote_builder_id
  ) values (
    p_empresa_id,
    v_quote.document_display_id,
    'draft',
    coalesce(v_quote.currency, 'COP'),
    v_quote.client_name,
    v_quote.client_email,
    v_quote.client_phone,
    jsonb_build_object(
      'event_location', v_quote.event_location
    ),
    concat_ws(
      E'\n',
      case when v_quote.people_count is not null
        then 'Personas: ' || v_quote.people_count::text end,
      case when v_quote.event_date is not null
        then 'Fecha evento: ' || v_quote.event_date::text end,
      case when v_quote.event_location is not null
        then 'Lugar: ' || v_quote.event_location end,
      case when nullif(v_quote.metadata ->> 'event_time', '') is not null
        then 'Hora: ' || (v_quote.metadata ->> 'event_time') end,
      case when v_quote.deposit_amount is not null
        then 'Anticipo: ' || v_quote.deposit_amount::text end,
      case when v_quote.balance_amount is not null
        then 'Saldo: ' || v_quote.balance_amount::text || ' - pago el dia del evento' end
    ),
    'WHATSAPP:' || p_conversation_id::text || ':' || p_source_message_id::text,
    coalesce(v_quote.document_issued_at::date, current_date),
    v_quote.document_valid_until,
    v_quote.total,
    0,
    v_quote.total,
    p_catalogo_id,
    null,
    null,
    null,
    p_quote_builder_id
  )
  returning id into v_cotizacion_id;

  insert into public.cotizacion_items (
    empresa_id,
    cotizacion_id,
    producto_id,
    variante_id,
    descripcion,
    cantidad,
    unidad_medida,
    precio_unitario,
    descuento_porcentaje,
    impuestos,
    line_total,
    atributos_snapshot,
    orden,
    line_type,
    quote_line_item_id,
    quote_service_item_id
  )
  select
    p_empresa_id,
    v_cotizacion_id,
    li.producto_id,
    null,
    p.nombre,
    li.cantidad,
    coalesce(nullif(p.unidad_medida, ''), 'unidad'),
    li.precio_unitario,
    case
      when li.precio_unitario > 0
      then round((coalesce(li.descuento_unitario, 0) / li.precio_unitario) * 100, 2)
      else 0
    end,
    0,
    li.line_total,
    jsonb_build_object(
      'source', 'ATLAS_QUOTE_BUILDER_EXTERNAL_WHATSAPP_V1',
      'source_line_item_id', li.id,
      'precio_unitario_final', li.precio_unitario_final,
      'descuento_unitario', li.descuento_unitario,
      'conversation_id', p_conversation_id,
      'source_message_id', p_source_message_id,
      'metadata', li.metadata
    ),
    row_number() over (order by li.created_at, li.id)::integer,
    'PRODUCTO',
    li.id,
    null
  from public.atlas_quote_line_items li
  join public.productos p
    on p.id = li.producto_id
   and p.empresa_id = li.empresa_id
  where li.quote_builder_id = p_quote_builder_id
    and li.empresa_id = p_empresa_id
  order by li.created_at, li.id;

  get diagnostics v_product_count = row_count;

  return jsonb_build_object(
    'materialization_status', 'CREATED',
    'quote_builder_id', p_quote_builder_id,
    'cotizacion_id', v_cotizacion_id,
    'product_count', v_product_count,
    'line_count', v_product_count,
    'total', v_quote.total,
    'currency', coalesce(v_quote.currency, 'COP'),
    'idempotent_replay', false
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.atlas_resolve_customer_visible_quote_context_v1(p_empresa_id uuid, p_conversation_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
with q as (
 select qb.*
 from public.atlas_quote_builders qb
 left join public.cotizaciones c on c.quote_builder_id=qb.id
 where qb.empresa_id=p_empresa_id
   and qb.document_issued_at is not null
   and (qb.metadata->>'conversation_id'=p_conversation_id::text
        or c.referencia_externa='WHATSAPP:'||p_conversation_id::text
        or c.referencia_externa like 'WHATSAPP:'||p_conversation_id::text||':%')
 order by qb.document_issued_at desc,qb.created_at desc
 limit 1
)
select case when exists(select 1 from q) then
 (select jsonb_build_object(
  'found',true,'quote_builder_id',id,'document_display_id',document_display_id,
  'quote_version',quote_version,'root_quote_builder_id',root_quote_builder_id,
  'supersedes_quote_builder_id',supersedes_quote_builder_id,'document_issued_at',document_issued_at,
  'status',status,'people_count',people_count,'event_date',event_date,'event_location',event_location,
  'total',total,'deposit_amount',deposit_amount,'balance_amount',balance_amount,
  'conversation_id',p_conversation_id,'truth_basis','LAST_ISSUED_TO_CUSTOMER'
 ) from q)
 else jsonb_build_object('found',false,'conversation_id',p_conversation_id,'truth_basis','NO_ISSUED_QUOTE') end
$function$;
