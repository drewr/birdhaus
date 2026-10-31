-- Joining the waitlist now requires an account, so each row carries the Rauthy
-- subject. Null for rows made before sign-up was required (or guest-only deploys).
alter table waitlist add column account_sub text;
create index waitlist_account_sub on waitlist (account_sub) where account_sub is not null;
