-- Unit prices admins set at /admin/inventory (docs/design/inventory.md). A
-- product without a row sells at its built-in price in server/price.js. Stripe
-- won't charge less than 50 cents.
create table prices (
  product text primary key,
  cents integer not null check (cents >= 50),
  updated_at timestamptz not null default now(),
  updated_by text
);

-- Every price change, shown with the stock changes on the inventory page.
create table price_changes (
  id bigserial primary key,
  product text not null,
  before integer not null,
  after integer not null,
  actor text,
  at timestamptz not null default now()
);
create index price_changes_product on price_changes (product, at desc);
