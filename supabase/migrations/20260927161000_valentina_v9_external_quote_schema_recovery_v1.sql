-- ATLAS / VALENTINA V9 external quote schema recovery
-- Isolated-branch recovery of production structures missing from the replayable migration history.
-- This migration is additive and contains no production data.

begin;

alter table public.atlas_quote_builders add column if not exists client_name text;
alter table public.atlas_quote_builders add column if not exists client_phone text;
alter table public.atlas_quote_builders add column if not exists client_email text;
alter table public.atlas_quote_builders add column if not exists requires_electronic_invoice boolean;
alter table public.atlas_quote_builders add column if not exists billing_name text;
alter table public.atlas_quote_builders add column if not exists billing_document_type text;
alter table public.atlas_quote_builders add column if not exists billing_document_number text;
alter table public.atlas_quote_builders add column if not exists billing_email text;
alter table public.atlas_quote_builders add column if not exists deposit_mode text;
alter table public.atlas_quote_builders add column if not exists deposit_percent numeric;
alter table public.atlas_quote_builders add column if not exists deposit_amount numeric;
alter table public.atlas_quote_builders add column if not exists balance_amount numeric;
alter table public.atlas_quote_builders add column if not exists deposit_override boolean not null default false;
alter table public.atlas_quote_builders add column if not exists deposit_override_reason text;
alter table public.atlas_quote_builders add column if not exists billing_provider_id uuid;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_status text not null default 'NOT_REQUESTED';
alter table public.atlas_quote_builders add column if not exists electronic_invoice_external_id text;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_number text;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_cufe text;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_pdf_url text;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_xml_url text;
alter table public.atlas_quote_builders add column if not exists electronic_invoice_error text;
alter table public.atlas_quote_builders add column if not exists document_display_id text;
alter table public.atlas_quote_builders add column if not exists document_issued_at timestamptz;
alter table public.atlas_quote_builders add column if not exists document_valid_until date;
alter table public.atlas_quote_builders add column if not exists document_valid_until_at timestamptz;
alter table public.atlas_quote_builders add column if not exists quote_version integer not null default 1;
alter table public.atlas_quote_builders add column if not exists root_quote_builder_id uuid;
alter table public.atlas_quote_builders add column if not exists supersedes_quote_builder_id uuid;
alter table public.atlas_quote_builders add column if not exists revision_reason text;

create table if not exists public.productos (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  industria_id uuid,
  categoria_id uuid,
  nombre text not null,
  slug text,
  descripcion_resumen text,
  descripcion_larga text,
  sku text,
  codigo_externo text,
  activo boolean not null default true,
  estado text not null default 'draft',
  vigente_desde date,
  vigente_hasta date,
  unidad_medida text,
  moneda text,
  precio_base numeric,
  impuestos_incluidos boolean not null default false,
  atributos_extra jsonb not null default '{}'::jsonb,
  instrucciones jsonb,
  keywords text[],
  version integer not null default 1,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint productos_estado_check check (estado in ('draft','published','archived')),
  constraint productos_empresa_slug_uniq unique (empresa_id, slug)
);

create table if not exists public.medios_pago (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  nombre text not null,
  tipo text not null default 'other',
  detalle jsonb,
  activo boolean not null default true,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint medios_pago_empresa_nombre_uniq unique (empresa_id,nombre)
);

create table if not exists public.atlas_quote_line_items (
  id uuid primary key default gen_random_uuid(),
  quote_builder_id uuid not null references public.atlas_quote_builders(id) on delete cascade,
  empresa_id uuid not null,
  producto_id uuid not null references public.productos(id),
  cantidad numeric not null,
  precio_unitario numeric not null,
  descuento_unitario numeric not null default 0,
  precio_unitario_final numeric,
  line_total numeric,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint atlas_quote_line_items_qty_chk check (cantidad > 0),
  constraint atlas_quote_line_items_price_chk check (precio_unitario >= 0),
  constraint atlas_quote_line_items_discount_chk check (descuento_unitario >= 0),
  constraint atlas_quote_line_items_unique_product unique (quote_builder_id, producto_id)
);

create table if not exists public.atlas_quote_modification_executions (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  conversation_id uuid not null,
  source_message_id uuid not null,
  source_quote_builder_id uuid not null references public.atlas_quote_builders(id),
  new_quote_builder_id uuid references public.atlas_quote_builders(id),
  status text not null default 'PROCESSING',
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint atlas_quote_modification_executions_status_check check (status in ('PROCESSING','COMPLETED')),
  constraint atlas_quote_modification_execu_empresa_id_source_message_id_key unique (empresa_id,source_message_id)
);

create table if not exists public.atlas_quote_acceptances (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  conversation_id uuid not null,
  quote_builder_id uuid not null references public.atlas_quote_builders(id),
  source_message_id uuid not null references public.atlas_conversation_messages(id),
  quote_version integer not null,
  document_display_id text not null,
  status text not null default 'ACCEPTED',
  accepted_at timestamptz not null default now(),
  superseded_at timestamptz,
  superseded_by_quote_builder_id uuid references public.atlas_quote_builders(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint atlas_quote_acceptances_source_message_id_key unique (source_message_id),
  constraint atlas_quote_acceptances_status_check check (status in ('ACCEPTED','SUPERSEDED','CANCELLED'))
);

create unique index if not exists atlas_quote_acceptances_one_current_uidx
  on public.atlas_quote_acceptances(empresa_id,conversation_id)
  where status='ACCEPTED';

create table if not exists public.cotizaciones (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas(id) on delete restrict,
  numero text,
  estado text not null default 'draft',
  moneda text,
  cliente_nombre text,
  cliente_email text,
  cliente_telefono text,
  direccion_cliente jsonb,
  notas text,
  referencia_externa text,
  fecha_emision date,
  fecha_validez date,
  subtotal numeric not null default 0,
  impuestos numeric not null default 0,
  total numeric not null default 0,
  catalogo_id uuid,
  medio_pago_id uuid references public.medios_pago(id) on delete restrict,
  created_by uuid,
  updated_by uuid,
  deleted_at timestamptz,
  deleted_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  quote_builder_id uuid references public.atlas_quote_builders(id) on delete restrict,
  constraint cotizaciones_estado_check check (estado in ('draft','sent','accepted','declined','cancelled','expired'))
);

create unique index if not exists cotizaciones_empresa_numero_uniq
  on public.cotizaciones(empresa_id,numero)
  where deleted_at is null and numero is not null;

create unique index if not exists cotizaciones_empresa_quote_builder_active_uniq
  on public.cotizaciones(empresa_id,quote_builder_id)
  where quote_builder_id is not null and deleted_at is null;

create index if not exists productos_empresa_id_idx on public.productos(empresa_id);
create index if not exists productos_estado_idx on public.productos(empresa_id,estado);
create index if not exists productos_activo_idx on public.productos(empresa_id,activo);
create index if not exists productos_keywords_gin_idx on public.productos using gin(keywords);
create index if not exists medios_pago_empresa_id_idx on public.medios_pago(empresa_id);
create index if not exists medios_pago_activo_idx on public.medios_pago(empresa_id,activo);

alter table public.productos enable row level security;
alter table public.medios_pago enable row level security;
alter table public.atlas_quote_line_items enable row level security;
alter table public.atlas_quote_modification_executions enable row level security;
alter table public.atlas_quote_acceptances enable row level security;
alter table public.cotizaciones enable row level security;

commit;
