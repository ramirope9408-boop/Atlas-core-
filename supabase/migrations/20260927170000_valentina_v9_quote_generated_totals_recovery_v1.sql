-- Restore generated quote arithmetic columns exactly as production.

begin;

alter table public.atlas_quote_line_items
  drop column if exists precio_unitario_final,
  drop column if exists line_total;

alter table public.atlas_quote_line_items
  add column precio_unitario_final numeric
    generated always as (greatest(precio_unitario - descuento_unitario, 0::numeric)) stored,
  add column line_total numeric
    generated always as (cantidad * greatest(precio_unitario - descuento_unitario, 0::numeric)) stored;

alter table public.atlas_quote_service_items
  drop column if exists line_total;

alter table public.atlas_quote_service_items
  add column line_total numeric
    generated always as (cantidad * precio_unitario) stored;

commit;
