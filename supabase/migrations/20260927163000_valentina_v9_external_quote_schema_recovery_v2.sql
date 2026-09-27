-- ATLAS / VALENTINA V9 external quote schema recovery V2
-- Additional runtime dependencies discovered by recursive branch validation.

begin;

create table if not exists public.catalogos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  industria_id uuid,
  nombre text not null,
  slug text,
  descripcion text,
  estado text not null default 'draft',
  vigente_desde date,
  vigente_hasta date,
  config jsonb,
  version integer not null default 1,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint catalogos_empresa_slug_uniq unique(empresa_id,slug),
  constraint catalogos_estado_check check(estado in ('draft','published','archived'))
);

create table if not exists public.catalogo_productos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  catalogo_id uuid not null references public.catalogos(id) on delete restrict,
  producto_padre_id uuid not null references public.productos(id) on delete restrict,
  orden integer not null default 0,
  visible boolean not null default true,
  moneda text,
  precio_override numeric,
  impuestos_incluidos boolean not null default false,
  atributos_override jsonb not null default '{}'::jsonb,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint catalogo_productos_catalogo_producto_uniq unique(catalogo_id,producto_padre_id)
);

create table if not exists public.atlas_quote_service_items (
  id uuid primary key default gen_random_uuid(),
  quote_builder_id uuid not null references public.atlas_quote_builders(id) on delete cascade,
  empresa_id uuid not null,
  service_type text not null,
  descripcion text not null,
  cantidad numeric not null default 1,
  precio_unitario numeric not null,
  line_total numeric,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unidad_medida text not null default 'servicio',
  constraint atlas_quote_service_items_price_chk check(precio_unitario >= 0),
  constraint atlas_quote_service_items_qty_chk check(cantidad > 0),
  constraint atlas_quote_service_items_type_chk check(service_type in ('TRANSPORTE','DECORACION','MESEROS','MOBILIARIO','OTRO'))
);

create table if not exists public.atlas_agent_tool_requests (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  conversation_id uuid,
  source_message_id uuid,
  ai_message_id uuid,
  agent_code text not null,
  tool_code text not null,
  status text not null default 'PENDING',
  input_payload jsonb not null default '{}'::jsonb,
  result_payload jsonb,
  requested_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_code text,
  error_message text,
  constraint atlas_agent_tool_requests_status_check
    check(status in ('PENDING','IN_PROGRESS','COMPLETED','FAILED','CANCELLED'))
);

create table if not exists public.cotizacion_items (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  cotizacion_id uuid not null references public.cotizaciones(id) on delete restrict,
  producto_id uuid references public.productos(id) on delete restrict,
  variante_id uuid,
  descripcion text not null,
  cantidad numeric not null default 1,
  unidad_medida text,
  precio_unitario numeric not null default 0,
  descuento_porcentaje numeric not null default 0,
  impuestos numeric not null default 0,
  line_total numeric not null default 0,
  atributos_snapshot jsonb,
  orden integer not null default 0,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  variante_key text,
  line_type text,
  quote_line_item_id uuid references public.atlas_quote_line_items(id) on delete restrict,
  quote_service_item_id uuid references public.atlas_quote_service_items(id) on delete restrict,
  constraint cotizacion_items_cotizacion_orden_uniq unique(cotizacion_id,orden),
  constraint cotizacion_items_line_type_check check(line_type is null or line_type in ('PRODUCTO','SERVICIO')),
  constraint cotizacion_items_governed_source_check check(
    (quote_line_item_id is null and quote_service_item_id is null)
    or (line_type='PRODUCTO' and producto_id is not null and quote_line_item_id is not null and quote_service_item_id is null)
    or (line_type='SERVICIO' and producto_id is null and variante_id is null and quote_line_item_id is null and quote_service_item_id is not null)
  )
);

create index if not exists catalogos_empresa_id_idx on public.catalogos(empresa_id);
create index if not exists catalogos_estado_idx on public.catalogos(empresa_id,estado);
create index if not exists catalogo_productos_catalogo_idx on public.catalogo_productos(catalogo_id);
create index if not exists catalogo_productos_empresa_idx on public.catalogo_productos(empresa_id);
create index if not exists cotizacion_items_cotizacion_idx on public.cotizacion_items(cotizacion_id);

alter table public.catalogos enable row level security;
alter table public.catalogo_productos enable row level security;
alter table public.atlas_quote_service_items enable row level security;
alter table public.atlas_agent_tool_requests enable row level security;
alter table public.cotizacion_items enable row level security;

commit;
