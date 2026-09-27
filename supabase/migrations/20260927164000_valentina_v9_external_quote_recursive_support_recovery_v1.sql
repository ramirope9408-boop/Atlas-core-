-- ATLAS / VALENTINA V9 recursive support-function recovery
-- Recovered read-only from production on 2026-09-27 for isolated certification.

-- atlas_check_conversation_automation_gate
CREATE OR REPLACE FUNCTION public.atlas_check_conversation_automation_gate(p_empresa_id uuid, p_conversation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_state public.atlas_conversation_control_states%rowtype;
begin
  if not exists (
    select 1
    from public.atlas_conversations c
    where c.id = p_conversation_id
      and c.empresa_id = p_empresa_id
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'CONVERSATION_NOT_FOUND',
      'automation_allowed', false
    );
  end if;

  insert into public.atlas_conversation_control_states (
    empresa_id,
    conversation_id,
    control_mode
  )
  values (
    p_empresa_id,
    p_conversation_id,
    'VALENTINA_ACTIVE'
  )
  on conflict (empresa_id, conversation_id) do nothing;

  select * into strict v_state
  from public.atlas_conversation_control_states s
  where s.empresa_id = p_empresa_id
    and s.conversation_id = p_conversation_id;

  return jsonb_strip_nulls(jsonb_build_object(
    'ok', true,
    'code', case
      when v_state.control_mode = 'VALENTINA_ACTIVE'
        then 'AUTOMATION_ALLOWED'
      else 'AUTOMATION_BLOCKED_BY_HUMAN_CONTROL'
    end,
    'automation_allowed',
      v_state.control_mode = 'VALENTINA_ACTIVE',
    'control_mode', v_state.control_mode,
    'controlled_by_user_id', v_state.controlled_by_user_id,
    'controlled_by_display_name', v_state.controlled_by_display_name,
    'version', v_state.version
  ));
end;
$function$;

-- atlas_create_quote_builder
CREATE OR REPLACE FUNCTION public.atlas_create_quote_builder(p_empresa_id uuid, p_source_message text, p_context_code text DEFAULT NULL::text, p_people_count integer DEFAULT NULL::integer, p_event_date date DEFAULT NULL::date, p_event_location text DEFAULT NULL::text, p_source_channel text DEFAULT 'TEST'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_quote_builder_id uuid;
begin

  insert into public.atlas_quote_builders (
    empresa_id,
    source_channel,
    source_message,
    context_code,
    people_count,
    event_date,
    event_location,
    status
  )
  values (
    p_empresa_id,
    p_source_channel,
    p_source_message,
    p_context_code,
    p_people_count,
    p_event_date,
    p_event_location,
    'BUILDING'
  )
  returning id
  into v_quote_builder_id;

  return v_quote_builder_id;

end;
$function$;

-- atlas_get_open_quote_clarification_v1
CREATE OR REPLACE FUNCTION public.atlas_get_open_quote_clarification_v1(p_empresa_id uuid, p_conversation_id uuid, p_active_quote_builder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_row public.atlas_conversation_pending_intents%rowtype;
begin
 select * into v_row from public.atlas_conversation_pending_intents
 where empresa_id=p_empresa_id and conversation_id=p_conversation_id
 and intent_type='QUOTE_CLARIFICATION' and status='OPEN'
 and quote_builder_id=p_active_quote_builder_id
 and (expires_at is null or expires_at>now())
 order by created_at desc limit 1;
 if not found then return jsonb_build_object('found',false); end if;
 return jsonb_build_object('found',true,'id',v_row.id,'source_message_id',v_row.source_message_id,
 'quote_builder_id',v_row.quote_builder_id,'quote_version',v_row.quote_version,'payload',v_row.payload,
 'expires_at',v_row.expires_at);
end $function$;

-- atlas_prepare_quote_document
CREATE OR REPLACE FUNCTION public.atlas_prepare_quote_document(p_quote_builder_id uuid, p_empresa_id uuid, p_valid_until date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_v2 jsonb;
begin
 v_v2:=public.atlas_prepare_quote_document_v2(p_quote_builder_id,p_empresa_id,96);
 return jsonb_build_object('quote_builder_id',p_quote_builder_id,'document',jsonb_build_object(
 'display_id',v_v2->'document'->>'display_id','issued_at',v_v2->'document'->>'issued_at',
 'valid_until',v_v2->'document'->>'valid_until_date','valid_until_at',v_v2->'document'->>'valid_until_at',
 'validity_hours',96,'validity_timezone','America/Bogota'),'compatibility_contract','ATLAS_QUOTE_DOCUMENT_V1_TO_V2_96H');
end $function$;

-- atlas_prepare_quote_document_v2
CREATE OR REPLACE FUNCTION public.atlas_prepare_quote_document_v2(p_quote_builder_id uuid, p_empresa_id uuid, p_validity_hours integer DEFAULT 96)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_quote public.atlas_quote_builders%rowtype;
  v_display_id text;
  v_issued_at timestamptz;
  v_valid_until_at timestamptz;
begin
  if p_validity_hours is null or p_validity_hours < 1 or p_validity_hours > 720 then
    raise exception 'QUOTE_VALIDITY_HOURS_INVALID';
  end if;

  select * into v_quote
  from public.atlas_quote_builders
  where id=p_quote_builder_id and empresa_id=p_empresa_id
  for update;

  if not found then
    raise exception 'Quote Builder no encontrado para la empresa';
  end if;

  if v_quote.status <> 'READY_FOR_QUOTE' then
    raise exception 'El Quote Builder debe estar READY_FOR_QUOTE antes de preparar el documento';
  end if;

  v_display_id := coalesce(
    v_quote.document_display_id,
    public.atlas_next_document_display_id(p_empresa_id,'QUOTE','COT')
  );

  v_issued_at := coalesce(v_quote.document_issued_at, clock_timestamp());

  v_valid_until_at := coalesce(
    v_quote.document_valid_until_at,
    v_issued_at + make_interval(hours => p_validity_hours)
  );

  update public.atlas_quote_builders
  set document_display_id=v_display_id,
      document_issued_at=v_issued_at,
      document_valid_until_at=v_valid_until_at,
      document_valid_until=(v_valid_until_at at time zone 'America/Bogota')::date,
      metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'quote_document_contract','V2',
        'validity_hours',p_validity_hours,
        'validity_timezone','America/Bogota'
      ),
      updated_at=now()
  where id=p_quote_builder_id and empresa_id=p_empresa_id;

  return jsonb_build_object(
    'quote_builder_id',p_quote_builder_id,
    'quote_version',v_quote.quote_version,
    'document',jsonb_build_object(
      'display_id',v_display_id,
      'issued_at',v_issued_at,
      'valid_until_at',v_valid_until_at,
      'valid_until_date',(v_valid_until_at at time zone 'America/Bogota')::date,
      'validity_hours',p_validity_hours
    )
  );
end;
$function$;

-- atlas_quote_builder_add_product
CREATE OR REPLACE FUNCTION public.atlas_quote_builder_add_product(p_quote_builder_id uuid, p_empresa_id uuid, p_producto_id uuid, p_cantidad numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_line_id uuid;
  v_precio numeric(12,2);
begin

  if p_cantidad is null
     or p_cantidad <= 0
  then
    raise exception
      'La cantidad debe ser mayor que cero';
  end if;


  select
    precio_base
  into
    v_precio
  from public.productos
  where id = p_producto_id
    and empresa_id = p_empresa_id
    and deleted_at is null
    and activo = true;


  if not found then
    raise exception
      'Producto no encontrado o no disponible para la empresa';
  end if;


  if v_precio is null then
    raise exception
      'El producto no tiene precio_base definido';
  end if;


  insert into public.atlas_quote_line_items (
    quote_builder_id,
    empresa_id,
    producto_id,
    cantidad,
    precio_unitario
  )
  values (
    p_quote_builder_id,
    p_empresa_id,
    p_producto_id,
    p_cantidad,
    v_precio
  )

  on conflict (
    quote_builder_id,
    producto_id
  )
  do update set
    cantidad =
      excluded.cantidad,

    precio_unitario =
      excluded.precio_unitario,

    updated_at =
      now()

  returning id
  into v_line_id;


  perform public.atlas_recalculate_quote_builder(
    p_quote_builder_id
  );


  return v_line_id;

end;
$function$;

-- atlas_quote_builder_materialize_external_v1
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

-- atlas_quote_builder_set_billing
CREATE OR REPLACE FUNCTION public.atlas_quote_builder_set_billing(p_quote_builder_id uuid, p_empresa_id uuid, p_requires_electronic_invoice boolean, p_billing_name text DEFAULT NULL::text, p_billing_document_type text DEFAULT NULL::text, p_billing_document_number text DEFAULT NULL::text, p_billing_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin

  if not exists (
    select 1
    from public.atlas_quote_builders q
    where q.id = p_quote_builder_id
      and q.empresa_id = p_empresa_id
  ) then
    raise exception
      'Quote Builder no encontrado para la empresa';
  end if;


  -- Si requiere factura, exigimos datos fiscales.
  if p_requires_electronic_invoice = true then

    if p_billing_name is null
       or trim(p_billing_name) = ''
    then
      raise exception
        'billing_name es obligatorio para factura electrónica';
    end if;

    if p_billing_document_type is null
       or trim(p_billing_document_type) = ''
    then
      raise exception
        'billing_document_type es obligatorio para factura electrónica';
    end if;

    if p_billing_document_number is null
       or trim(p_billing_document_number) = ''
    then
      raise exception
        'billing_document_number es obligatorio para factura electrónica';
    end if;

    if p_billing_email is null
       or trim(p_billing_email) = ''
    then
      raise exception
        'billing_email es obligatorio para factura electrónica';
    end if;

  end if;


  update public.atlas_quote_builders
  set
    requires_electronic_invoice =
      p_requires_electronic_invoice,

    billing_name =
      case
        when p_requires_electronic_invoice
        then nullif(trim(p_billing_name), '')
        else null
      end,

    billing_document_type =
      case
        when p_requires_electronic_invoice
        then nullif(trim(p_billing_document_type), '')
        else null
      end,

    billing_document_number =
      case
        when p_requires_electronic_invoice
        then nullif(trim(p_billing_document_number), '')
        else null
      end,

    billing_email =
      case
        when p_requires_electronic_invoice
        then nullif(trim(p_billing_email), '')
        else null
      end,

    updated_at = now()

  where id = p_quote_builder_id
    and empresa_id = p_empresa_id;


  return jsonb_build_object(
    'quote_builder_id',
    p_quote_builder_id,
    'requires_electronic_invoice',
    p_requires_electronic_invoice,
    'billing_name',
    case
      when p_requires_electronic_invoice
      then nullif(trim(p_billing_name), '')
      else null
    end,
    'billing_document_type',
    case
      when p_requires_electronic_invoice
      then nullif(trim(p_billing_document_type), '')
      else null
    end,
    'billing_document_number',
    case
      when p_requires_electronic_invoice
      then nullif(trim(p_billing_document_number), '')
      else null
    end,
    'billing_email',
    case
      when p_requires_electronic_invoice
      then nullif(trim(p_billing_email), '')
      else null
    end
  );

end;
$function$;

-- atlas_quote_builder_set_client
CREATE OR REPLACE FUNCTION public.atlas_quote_builder_set_client(p_quote_builder_id uuid, p_empresa_id uuid, p_client_name text, p_client_phone text, p_client_email text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin

  if p_client_name is null
     or trim(p_client_name) = ''
  then
    raise exception
      'El nombre del cliente es obligatorio';
  end if;

  if p_client_phone is null
     or trim(p_client_phone) = ''
  then
    raise exception
      'El teléfono del cliente es obligatorio';
  end if;

  if not exists (
    select 1
    from public.atlas_quote_builders q
    where q.id = p_quote_builder_id
      and q.empresa_id = p_empresa_id
  ) then
    raise exception
      'Quote Builder no encontrado para la empresa';
  end if;

  update public.atlas_quote_builders
  set
    client_name = trim(p_client_name),
    client_phone = trim(p_client_phone),
    client_email = nullif(trim(p_client_email), ''),
    updated_at = now()
  where id = p_quote_builder_id
    and empresa_id = p_empresa_id;

  return jsonb_build_object(
    'quote_builder_id',
    p_quote_builder_id,
    'client_name',
    trim(p_client_name),
    'client_phone',
    trim(p_client_phone),
    'client_email',
    nullif(trim(p_client_email), '')
  );

end;
$function$;

-- atlas_quote_builder_set_payment
CREATE OR REPLACE FUNCTION public.atlas_quote_builder_set_payment(p_quote_builder_id uuid, p_empresa_id uuid, p_mode text DEFAULT 'STANDARD_PERCENT'::text, p_override_percent numeric DEFAULT NULL::numeric, p_override_amount numeric DEFAULT NULL::numeric, p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_quote public.atlas_quote_builders%rowtype;
  v_policy public.atlas_payment_policies%rowtype;

  v_mode text;

  v_effective_percent numeric(5,2);
  v_deposit_amount numeric(14,2);
  v_balance_amount numeric(14,2);

  v_is_override boolean := false;

BEGIN

  -- ==========================================================
  -- 1. QUOTE BUILDER
  -- ==========================================================

  SELECT *
  INTO v_quote
  FROM public.atlas_quote_builders
  WHERE id = p_quote_builder_id
    AND empresa_id = p_empresa_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Quote Builder no encontrado para la empresa';
  END IF;


  -- ==========================================================
  -- 2. PAYMENT POLICY
  -- ==========================================================

  SELECT *
  INTO v_policy
  FROM public.atlas_payment_policies
  WHERE empresa_id = p_empresa_id
    AND active = true
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'No existe política de pagos activa para la empresa';
  END IF;


  -- ==========================================================
  -- 3. QUOTE TOTAL
  -- ==========================================================

  IF v_quote.total IS NULL
     OR v_quote.total <= 0
  THEN
    RAISE EXCEPTION
      'La cotización debe tener un total mayor que cero';
  END IF;


  -- ==========================================================
  -- 4. NORMALIZE MODE
  -- ==========================================================

  v_mode :=
    UPPER(
      COALESCE(
        NULLIF(TRIM(p_mode), ''),
        'STANDARD_PERCENT'
      )
    );

  IF v_mode NOT IN (
    'STANDARD_PERCENT',
    'OVERRIDE_PERCENT',
    'OVERRIDE_AMOUNT'
  ) THEN
    RAISE EXCEPTION
      'Modo de anticipo no permitido: %',
      v_mode;
  END IF;


  -- ==========================================================
  -- 5. STANDARD PAYMENT
  --
  -- FingerFood canonical standard:
  -- active payment policy default, currently 50%.
  -- ==========================================================

  IF v_mode = 'STANDARD_PERCENT' THEN

    v_effective_percent :=
      v_policy.default_deposit_percent;

    IF v_effective_percent <= 0
       OR v_effective_percent > 100
    THEN
      RAISE EXCEPTION
        'La política estándar de anticipo no es válida';
    END IF;

    v_deposit_amount :=
      ROUND(
        v_quote.total
        *
        (
          v_effective_percent
          / 100.0
        ),
        2
      );

    v_is_override := false;


  -- ==========================================================
  -- 6. SPECIAL AGREEMENT BY PERCENT
  --
  -- No commercial minimum.
  -- Any percentage > 0 and <= 100 is allowed when explicitly
  -- agreed with the client and a reason is recorded.
  -- ==========================================================

  ELSIF v_mode = 'OVERRIDE_PERCENT' THEN

    IF p_override_percent IS NULL THEN
      RAISE EXCEPTION
        'Debe indicar el porcentaje acordado';
    END IF;

    IF p_override_percent <= 0 THEN
      RAISE EXCEPTION
        'El porcentaje de anticipo debe ser mayor que cero';
    END IF;

    IF p_override_percent > 100 THEN
      RAISE EXCEPTION
        'El porcentaje de anticipo no puede superar el 100%%';
    END IF;

    IF p_override_reason IS NULL
       OR TRIM(p_override_reason) = ''
    THEN
      RAISE EXCEPTION
        'Debe registrar el motivo del acuerdo especial';
    END IF;

    v_effective_percent :=
      ROUND(
        p_override_percent,
        2
      );

    v_deposit_amount :=
      ROUND(
        v_quote.total
        *
        (
          v_effective_percent
          / 100.0
        ),
        2
      );

    v_is_override := true;


  -- ==========================================================
  -- 7. SPECIAL AGREEMENT BY AMOUNT
  --
  -- Any amount > 0 and <= total may be agreed.
  -- ==========================================================

  ELSIF v_mode = 'OVERRIDE_AMOUNT' THEN

    IF p_override_amount IS NULL THEN
      RAISE EXCEPTION
        'Debe indicar el monto acordado';
    END IF;

    IF p_override_amount <= 0 THEN
      RAISE EXCEPTION
        'El anticipo acordado debe ser mayor que cero';
    END IF;

    IF p_override_amount > v_quote.total THEN
      RAISE EXCEPTION
        'El anticipo acordado no puede superar el total de la cotización';
    END IF;

    IF p_override_reason IS NULL
       OR TRIM(p_override_reason) = ''
    THEN
      RAISE EXCEPTION
        'Debe registrar el motivo del acuerdo especial';
    END IF;

    v_deposit_amount :=
      ROUND(
        p_override_amount,
        2
      );

    v_effective_percent :=
      ROUND(
        (
          v_deposit_amount
          /
          v_quote.total
        )
        * 100,
        2
      );

    v_is_override := true;

  END IF;


  -- ==========================================================
  -- 8. BALANCE
  --
  -- Remaining balance is total - agreed deposit.
  -- Operational rule: balance is due on event day.
  -- ==========================================================

  v_balance_amount :=
    ROUND(
      v_quote.total
      -
      v_deposit_amount,
      2
    );

  IF v_balance_amount < 0 THEN
    RAISE EXCEPTION
      'El saldo calculado no puede ser negativo';
  END IF;


  -- ==========================================================
  -- 9. PERSIST
  -- ==========================================================

  UPDATE public.atlas_quote_builders
  SET
    deposit_mode =
      v_mode,

    deposit_percent =
      v_effective_percent,

    deposit_amount =
      v_deposit_amount,

    balance_amount =
      v_balance_amount,

    deposit_override =
      v_is_override,

    deposit_override_reason =
      CASE
        WHEN v_is_override
        THEN TRIM(p_override_reason)
        ELSE NULL
      END,

    updated_at =
      NOW()

  WHERE id = p_quote_builder_id
    AND empresa_id = p_empresa_id;


  -- ==========================================================
  -- 10. CANONICAL RESPONSE
  -- ==========================================================

  RETURN jsonb_build_object(

    'quote_builder_id',
      p_quote_builder_id,

    'mode',
      v_mode,

    'total',
      v_quote.total,

    'currency',
      v_quote.currency,

    'policy',
      jsonb_build_object(
        'default_percent',
          v_policy.default_deposit_percent
      ),

    'payment',
      jsonb_build_object(
        'deposit_percent',
          v_effective_percent,

        'deposit_amount',
          v_deposit_amount,

        'balance_amount',
          v_balance_amount,

        'balance_due_rule',
          'EVENT_DAY',

        'is_override',
          v_is_override,

        'override_reason',
          CASE
            WHEN v_is_override
            THEN TRIM(p_override_reason)
            ELSE NULL
          END
      )
  );

END;
$function$;

-- atlas_recalculate_quote_builder
CREATE OR REPLACE FUNCTION public.atlas_recalculate_quote_builder(p_quote_builder_id uuid)
 RETURNS TABLE(quote_builder_id uuid, subtotal_productos numeric, subtotal_servicios numeric, descuento_total numeric, total numeric)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_subtotal_productos numeric(12,2);
  v_subtotal_servicios numeric(12,2);
  v_descuento_total numeric(12,2);
  v_total numeric(12,2);

  v_quote public.atlas_quote_builders%rowtype;

  v_deposit_amount numeric(14,2);
  v_balance_amount numeric(14,2);
BEGIN

  -- ==========================================================
  -- 1. PRODUCT TOTALS
  -- ==========================================================

  SELECT
    COALESCE(
      SUM(
        cantidad * precio_unitario
      ),
      0
    ),

    COALESCE(
      SUM(
        cantidad * descuento_unitario
      ),
      0
    ),

    COALESCE(
      SUM(line_total),
      0
    )

  INTO
    v_subtotal_productos,
    v_descuento_total,
    v_total

  FROM public.atlas_quote_line_items
  WHERE atlas_quote_line_items.quote_builder_id =
    p_quote_builder_id;


  -- ==========================================================
  -- 2. SERVICE TOTALS
  -- ==========================================================

  SELECT
    COALESCE(
      SUM(line_total),
      0
    )

  INTO
    v_subtotal_servicios

  FROM public.atlas_quote_service_items
  WHERE atlas_quote_service_items.quote_builder_id =
    p_quote_builder_id;


  -- ==========================================================
  -- 3. FINAL TOTAL
  --
  -- Product line_total is already NET of unit discounts.
  -- ==========================================================

  v_total :=
    COALESCE(v_total, 0)
    +
    COALESCE(v_subtotal_servicios, 0);


  -- ==========================================================
  -- 4. LOAD CURRENT PAYMENT STATE
  -- ==========================================================

  SELECT *
  INTO v_quote
  FROM public.atlas_quote_builders
  WHERE id = p_quote_builder_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Quote Builder no encontrado';
  END IF;


  -- ==========================================================
  -- 5. RECALCULATE DERIVED PAYMENT STATE
  --
  -- STANDARD_PERCENT:
  --   preserve percent, recalculate deposit + balance.
  --
  -- OVERRIDE_PERCENT:
  --   preserve agreed percent, recalculate deposit + balance.
  --
  -- OVERRIDE_AMOUNT:
  --   preserve explicitly agreed amount, recalculate balance.
  --
  -- NO PAYMENT MODE:
  --   leave payment state untouched.
  -- ==========================================================

  IF v_quote.deposit_mode IN (
    'STANDARD_PERCENT',
    'OVERRIDE_PERCENT'
  ) THEN

    IF v_quote.deposit_percent IS NULL
       OR v_quote.deposit_percent <= 0
       OR v_quote.deposit_percent > 100
    THEN
      RAISE EXCEPTION
        'Invalid deposit_percent for payment mode %',
        v_quote.deposit_mode;
    END IF;

    v_deposit_amount :=
      ROUND(
        v_total
        *
        (
          v_quote.deposit_percent
          / 100.0
        ),
        2
      );

    v_balance_amount :=
      ROUND(
        v_total
        -
        v_deposit_amount,
        2
      );


  ELSIF v_quote.deposit_mode = 'OVERRIDE_AMOUNT' THEN

    IF v_quote.deposit_amount IS NULL
       OR v_quote.deposit_amount <= 0
    THEN
      RAISE EXCEPTION
        'Invalid deposit_amount for OVERRIDE_AMOUNT';
    END IF;

    IF v_quote.deposit_amount > v_total THEN
      RAISE EXCEPTION
        'Stored deposit amount exceeds recalculated quote total';
    END IF;

    -- Explicit amount is contractual:
    -- preserve it.
    v_deposit_amount :=
      ROUND(
        v_quote.deposit_amount,
        2
      );

    v_balance_amount :=
      ROUND(
        v_total
        -
        v_deposit_amount,
        2
      );


  ELSE

    -- Payment has not been configured yet.
    v_deposit_amount :=
      v_quote.deposit_amount;

    v_balance_amount :=
      v_quote.balance_amount;

  END IF;


  -- ==========================================================
  -- 6. PERSIST TOTALS + SYNCHRONIZED PAYMENT STATE
  -- ==========================================================

  UPDATE public.atlas_quote_builders
  SET
    subtotal_productos =
      COALESCE(
        v_subtotal_productos,
        0
      ),

    subtotal_servicios =
      COALESCE(
        v_subtotal_servicios,
        0
      ),

    descuento_total =
      COALESCE(
        v_descuento_total,
        0
      ),

    total =
      COALESCE(
        v_total,
        0
      ),

    deposit_amount =
      CASE
        WHEN deposit_mode IS NOT NULL
        THEN v_deposit_amount
        ELSE deposit_amount
      END,

    balance_amount =
      CASE
        WHEN deposit_mode IS NOT NULL
        THEN v_balance_amount
        ELSE balance_amount
      END,

    updated_at =
      NOW()

  WHERE id = p_quote_builder_id;


  -- ==========================================================
  -- 7. RETURN
  -- ==========================================================

  RETURN QUERY
  SELECT
    p_quote_builder_id,

    COALESCE(
      v_subtotal_productos,
      0
    ),

    COALESCE(
      v_subtotal_servicios,
      0
    ),

    COALESCE(
      v_descuento_total,
      0
    ),

    COALESCE(
      v_total,
      0
    );

END;
$function$;

-- atlas_require_empresa_active
CREATE OR REPLACE FUNCTION public.atlas_require_empresa_active(p_empresa_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_empresa_id IS NULL THEN
    RAISE EXCEPTION 'empresa_id must not be null' USING errcode = '22004';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empresas e
    WHERE e.id = p_empresa_id
      AND e.estado = 'active'
  ) THEN
    RAISE EXCEPTION 'empresa_id is not active or does not exist' USING errcode = '22023';
  END IF;
END;
$function$;

-- atlas_resolve_active_quote_product_mention_v1
CREATE OR REPLACE FUNCTION public.atlas_resolve_active_quote_product_mention_v1(p_empresa_id uuid, p_quote_builder_id uuid, p_source_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_norm text; v_hits jsonb; v_n int;
begin
 v_norm:=public.atlas_normalize_quote_query_v1(coalesce(p_source_text,''));
 select coalesce(jsonb_agg(jsonb_build_object('product_id',x.producto_id,'name',x.nombre,'quantity',x.cantidad) order by x.nombre),'[]'::jsonb),count(*)
 into v_hits,v_n
 from (
   select distinct li.producto_id,p.nombre,li.cantidad
   from public.atlas_quote_line_items li
   join public.productos p on p.id=li.producto_id and p.empresa_id=li.empresa_id
   where li.empresa_id=p_empresa_id and li.quote_builder_id=p_quote_builder_id
   and (
     v_norm like '%'||public.atlas_normalize_quote_query_v1(p.nombre)||'%'
     or (v_norm like '%taco%' and public.atlas_normalize_quote_query_v1(p.nombre) like 'taco%')
     or (v_norm like '%hamburgues%' and public.atlas_normalize_quote_query_v1(p.nombre) like '%hamburgues%')
     or (v_norm like '%doggi%' and public.atlas_normalize_quote_query_v1(p.nombre) like '%doggi%')
   )
 ) x;
 return jsonb_build_object('count',v_n,'matches',v_hits);
end $function$;

-- atlas_singularize_quote_query_v1
CREATE OR REPLACE FUNCTION public.atlas_singularize_quote_query_v1(p_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select trim(
    regexp_replace(
      coalesce(p_value, ''),
      '([a-z0-9]{4,})s(\s|$)',
      '\1\2',
      'g'
    )
  );
$function$;

-- atlas_validate_quote_builder
CREATE OR REPLACE FUNCTION public.atlas_validate_quote_builder(p_quote_builder_id uuid, p_empresa_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_quote public.atlas_quote_builders%rowtype;

  v_missing text[] := array[]::text[];
  v_errors text[] := array[]::text[];

  v_product_count integer := 0;
  v_service_count integer := 0;

  v_products_total numeric(12,2) := 0;
  v_services_total numeric(12,2) := 0;
  v_expected_total numeric(12,2) := 0;

  v_ready boolean := false;
  v_status text := 'BUILDING';
BEGIN

  -- ==========================================================
  -- 1. QUOTE BUILDER
  -- ==========================================================

  SELECT *
  INTO v_quote
  FROM public.atlas_quote_builders
  WHERE id = p_quote_builder_id
    AND empresa_id = p_empresa_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Quote Builder no encontrado para la empresa';
  END IF;


  -- ==========================================================
  -- 2. CLIENT
  -- ==========================================================

  IF v_quote.client_name IS NULL
     OR trim(v_quote.client_name) = ''
  THEN
    v_missing :=
      array_append(v_missing, 'client_name');
  END IF;

  IF v_quote.client_phone IS NULL
     OR trim(v_quote.client_phone) = ''
  THEN
    v_missing :=
      array_append(v_missing, 'client_phone');
  END IF;


  -- ==========================================================
  -- 3. EVENT
  -- ==========================================================

  IF v_quote.people_count IS NULL
     OR v_quote.people_count <= 0
  THEN
    v_missing :=
      array_append(v_missing, 'people_count');
  END IF;

  IF v_quote.event_date IS NULL THEN
    v_missing :=
      array_append(v_missing, 'event_date');
  END IF;

  IF v_quote.event_location IS NULL
     OR trim(v_quote.event_location) = ''
  THEN
    v_missing :=
      array_append(v_missing, 'event_location');
  END IF;


  -- ==========================================================
  -- 4. PRODUCTS
  -- ==========================================================

  SELECT
    count(*),
    coalesce(sum(line_total), 0)
  INTO
    v_product_count,
    v_products_total
  FROM public.atlas_quote_line_items
  WHERE quote_builder_id = p_quote_builder_id
    AND empresa_id = p_empresa_id;

  IF v_product_count = 0 THEN
    v_missing :=
      array_append(v_missing, 'products');
  END IF;


  IF EXISTS (
    SELECT 1
    FROM public.atlas_quote_line_items
    WHERE quote_builder_id = p_quote_builder_id
      AND empresa_id = p_empresa_id
      AND (
        cantidad IS NULL
        OR cantidad <= 0
      )
  ) THEN
    v_errors :=
      array_append(
        v_errors,
        'INVALID_PRODUCT_QUANTITY'
      );
  END IF;


  IF EXISTS (
    SELECT 1
    FROM public.atlas_quote_line_items
    WHERE quote_builder_id = p_quote_builder_id
      AND empresa_id = p_empresa_id
      AND (
        precio_unitario IS NULL
        OR precio_unitario < 0
      )
  ) THEN
    v_errors :=
      array_append(
        v_errors,
        'INVALID_PRODUCT_PRICE'
      );
  END IF;


  -- ==========================================================
  -- 5. SERVICES
  -- ==========================================================

  SELECT
    count(*),
    coalesce(sum(line_total), 0)
  INTO
    v_service_count,
    v_services_total
  FROM public.atlas_quote_service_items
  WHERE quote_builder_id = p_quote_builder_id
    AND empresa_id = p_empresa_id;


  IF EXISTS (
    SELECT 1
    FROM public.atlas_quote_service_items
    WHERE quote_builder_id = p_quote_builder_id
      AND empresa_id = p_empresa_id
      AND (
        cantidad IS NULL
        OR cantidad <= 0
      )
  ) THEN
    v_errors :=
      array_append(
        v_errors,
        'INVALID_SERVICE_QUANTITY'
      );
  END IF;


  IF EXISTS (
    SELECT 1
    FROM public.atlas_quote_service_items
    WHERE quote_builder_id = p_quote_builder_id
      AND empresa_id = p_empresa_id
      AND (
        precio_unitario IS NULL
        OR precio_unitario < 0
      )
  ) THEN
    v_errors :=
      array_append(
        v_errors,
        'INVALID_SERVICE_PRICE'
      );
  END IF;


  -- ==========================================================
  -- 6. TOTALS
  -- ==========================================================
  --
  -- IMPORTANTE:
  --
  -- atlas_quote_line_items.line_total YA incluye el descuento:
  --
  -- cantidad *
  -- GREATEST(precio_unitario - descuento_unitario, 0)
  --
  -- Por lo tanto v_products_total ya es NETO.
  --
  -- descuento_total se conserva como dato comercial/auditable,
  -- pero NO debe volver a restarse aquí.
  -- ==========================================================

  v_expected_total :=
      coalesce(v_products_total, 0)
    + coalesce(v_services_total, 0);


  IF v_expected_total < 0 THEN
    v_errors :=
      array_append(
        v_errors,
        'NEGATIVE_TOTAL'
      );
  END IF;


  IF round(coalesce(v_quote.total, 0), 2)
     <>
     round(coalesce(v_expected_total, 0), 2)
  THEN
    v_errors :=
      array_append(
        v_errors,
        'TOTAL_MISMATCH'
      );
  END IF;


  -- ==========================================================
  -- 7. READY STATE
  -- ==========================================================

  v_ready :=
       cardinality(v_missing) = 0
   AND cardinality(v_errors) = 0
   AND v_product_count > 0;


  IF v_ready THEN
    v_status := 'READY_FOR_QUOTE';
  ELSE
    v_status := 'BUILDING';
  END IF;


  -- ==========================================================
  -- 8. PERSIST STATE
  -- ==========================================================

  UPDATE public.atlas_quote_builders
  SET
    status = v_status,
    updated_at = now()
  WHERE id = p_quote_builder_id
    AND empresa_id = p_empresa_id;


  -- ==========================================================
  -- 9. CANONICAL RESPONSE
  -- ==========================================================

  RETURN jsonb_build_object(
    'quote_builder_id',
      p_quote_builder_id,

    'ready_for_quote',
      v_ready,

    'status',
      v_status,

    'missing_information',
      to_jsonb(v_missing),

    'errors',
      to_jsonb(v_errors),

    'product_count',
      v_product_count,

    'service_count',
      v_service_count,

    'subtotal_productos',
      v_products_total,

    'subtotal_servicios',
      v_services_total,

    'descuento_total',
      v_quote.descuento_total,

    'expected_total',
      v_expected_total,

    'stored_total',
      v_quote.total
  );

END;
$function$;
