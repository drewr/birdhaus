-- One row per paid pre-order, written by the Stripe webhook. The PaymentIntent
-- ID is the key, so a redelivered event is a no-op.
create table orders (
  id text primary key,
  batch text not null,
  quantity integer not null check (quantity > 0),
  amount integer not null,
  currency text not null,
  email text,
  shipping jsonb,
  status text not null default 'paid' check (status in ('paid', 'refunded')),
  created_at timestamptz not null,
  recorded_at timestamptz not null default now()
);
create index orders_batch on orders (batch, status);
