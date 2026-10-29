-- The Rauthy subject this order belongs to, copied from the PaymentIntent
-- metadata when checkout starts signed in. Null for guest orders.
alter table orders add column account_sub text;
create index orders_account_sub on orders (account_sub) where account_sub is not null;
