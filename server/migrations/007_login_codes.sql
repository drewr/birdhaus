-- Emailed sign-in codes (docs/design/login-page.md). Only an HMAC of the code
-- is stored; a new code supersedes older ones for the same address.
create table login_codes (
  id bigserial primary key,
  email text not null,
  code_hash text not null,
  purpose text not null check (purpose in ('login', 'signup')),
  attempts int not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index login_codes_email_created on login_codes (email, created_at desc);
