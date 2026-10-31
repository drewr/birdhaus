-- Local pick-up at times the store defines (docs/design/fulfillment.md).
-- Locations and slots are managed on /admin/pickup.
create table pickup_locations (
  id serial primary key,
  name text not null,
  details text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table pickup_slots (
  id serial primary key,
  location_id integer not null references pickup_locations (id),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  active boolean not null default true
);
create index pickup_slots_starts_at on pickup_slots (starts_at);

-- How each order is fulfilled. Orders before this were shipped. The slot is a
-- plain id with a label snapshot, so later admin edits never block the webhook.
alter table orders add column fulfillment text not null default 'ship' check (fulfillment in ('ship', 'pickup'));
alter table orders add column pickup_slot_id integer;
alter table orders add column pickup_label text;
