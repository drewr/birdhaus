-- Local delivery within a radius of a home base, for a flat per-order fee, in
-- slots the store defines (docs/design/local-delivery.md). Managed on
-- /admin/delivery; off until an admin enables it.
create table delivery_settings (
  id integer primary key check (id = 1),
  enabled boolean not null default false,
  fee_cents integer not null default 0 check (fee_cents >= 0),
  radius_miles numeric not null default 10 check (radius_miles > 0),
  base_address text,
  base_lat double precision,
  base_lon double precision,
  updated_at timestamptz not null default now()
);
insert into delivery_settings (id) values (1);

create table delivery_slots (
  id serial primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  active boolean not null default true
);
create index delivery_slots_starts_at on delivery_slots (starts_at);

-- The address and phone land in orders.shipping from the PaymentIntent.
-- address_check records how the radius was verified: exact (geocoded street),
-- zip (centroid fallback), mismatch (paid address differs from the verified
-- one) or none (never verified).
alter table orders drop constraint orders_fulfillment_check;
alter table orders add constraint orders_fulfillment_check check (fulfillment in ('ship', 'pickup', 'delivery'));
alter table orders add column fee_amount integer not null default 0;
alter table orders add column delivery_slot_id integer;
alter table orders add column delivery_label text;
alter table orders add column address_check text;
