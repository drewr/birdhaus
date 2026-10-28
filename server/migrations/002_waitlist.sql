-- Demand beyond the batch: one row per email per batch, latest quantity wins.
create table waitlist (
  batch text not null,
  email text not null,
  quantity integer not null check (quantity between 1 and 99),
  postal_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (batch, email)
);
