-- ATLAS / VALENTINA V9 external quote schema recovery V3
-- Pending-intent, payment-policy, and document-sequence dependencies.

begin;

create table if not exists public.atlas_conversation_pending_intents (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  conversation_id uuid not null,
  intent_type text not null,
  status text not null default 'OPEN',
  source_message_id uuid not null,
  quote_builder_id uuid,
  quote_version integer,
  payload jsonb not null default '{}'::jsonb,
  resolution_message_id uuid,
  resolved_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint atlas_conversation_pending_intents_status_check
    check(status in ('OPEN','RESOLVED','SUPERSEDED','EXPIRED','CANCELLED')),
  constraint atlas_conversation_pending_intents_scope_key
    unique(empresa_id,conversation_id,source_message_id,intent_type)
);

create table if not exists public.atlas_payment_policies (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  default_deposit_percent numeric not null default 50,
  minimum_deposit_percent numeric not null default 20,
  maximum_deposit_percent numeric not null default 100,
  currency text not null default 'COP',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint atlas_payment_policies_default_check check(default_deposit_percent between 0 and 100),
  constraint atlas_payment_policies_minimum_check check(minimum_deposit_percent between 0 and 100),
  constraint atlas_payment_policies_maximum_check check(maximum_deposit_percent between 0 and 100),
  constraint atlas_payment_policies_range_check check(minimum_deposit_percent <= default_deposit_percent and default_deposit_percent <= maximum_deposit_percent)
);

create table if not exists public.atlas_document_sequences (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null,
  document_type text not null,
  document_year integer not null,
  last_number bigint not null default 0,
  prefix text not null default 'COT',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint atlas_document_sequences_number_chk check(last_number >= 0),
  constraint atlas_document_sequences_unique unique(empresa_id,document_type,document_year)
);

alter table public.atlas_conversation_pending_intents enable row level security;
alter table public.atlas_payment_policies enable row level security;
alter table public.atlas_document_sequences enable row level security;

commit;
