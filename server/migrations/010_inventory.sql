-- Units available per tracked product (docs/design/inventory.md), edited at
-- /admin/inventory and counted down by paid orders. It may go below zero: two
-- buyers paying for the last unit at once both keep their orders, and the admin
-- page shows the product as oversold.
create table inventory (
  product text primary key,
  available integer not null,
  updated_at timestamptz not null default now(),
  updated_by text
);

-- Every change, by an admin or an order, for when a number looks wrong.
create table inventory_changes (
  id bigserial primary key,
  product text not null,
  before integer,
  after integer not null,
  reason text not null check (reason in ('admin', 'order', 'seed')),
  order_id text,
  actor text,
  at timestamptz not null default now()
);
create index inventory_changes_product on inventory_changes (product, at desc);

-- "Notify me when available": one row per product and account email, until an
-- admin emails everyone waiting.
create table restock_requests (
  product text not null,
  email text not null,
  account_sub text,
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  primary key (product, email)
);

-- The inventory replaces the deploy's batch cap (20 for xmas-2026), so start
-- the Bluebird House where the cap left it.
insert into inventory (product, available)
select 'bluebird-house', greatest(20 - coalesce(sum(quantity), 0), 0)
from orders where batch = 'xmas-2026' and status = 'paid' and product = 'bluebird-house';
insert into inventory_changes (product, before, after, reason)
select product, null, available, 'seed' from inventory;

-- People on the old batch waitlist get the restock email too.
insert into restock_requests (product, email, account_sub, created_at)
select 'bluebird-house', email, account_sub, created_at from waitlist
on conflict do nothing;
