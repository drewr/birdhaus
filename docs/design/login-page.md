# Plan: Store-hosted sign-in, no Rauthy screens

## Context

Customers found Rauthy's hosted login confusing. The first pass added a store
`/login` page that handed off to Rauthy's pages (`idp_hint`, `login_hint`, its
registration form). The owner wants more: **site users never interact with
Rauthy**. Rauthy stays the account directory and Google broker underneath, and
passkeys tied to `login.birdhaus.store` are fine to leave behind.

The owner also decided that **checkout and the waitlist require an account**.
That replaces the old rule that guest checkout must always work.

## Sign-in methods

- **Google** (log in and sign up are the same): `/api/auth/login?provider=google`
  sends the browser through Rauthy with `idp_hint`, so Rauthy's page only passes
  the customer on to Google and back; there is nothing to choose or type there.
- **Email, passwordless.** The customer types an email (and a name, to sign
  up); the store emails a 6-digit code; they type it on the store. No passwords.
  Rauthy is used only through its admin API, with an API key:
  - `GET /auth/v1/users/email/{email}`: does the account exist (and its id,
    name, groups, `email_verified`);
  - `POST /auth/v1/users`: create the account on sign-up (no email is sent by
    this path, checked in `create_from_new`);
  - `PATCH /auth/v1/users/{id}` with `{"put":[{"key":"email_verified","value":true}]}`
    once the code proves the address.

  Email accounts created through Rauthy's old pages keep working: their
  passkeys simply aren't offered, and a code logs them in.

## Store pieces

- `server/rauthy.js` (new): the admin API client, internal URL, header
  `Authorization: API-Key <key>` from `RAUTHY_API_KEY`.
- `server/mail.js` (new): `nodemailer` over SES SMTP, from the existing
  `birdhaus-ses` Secret (`SMTP_URL`, `SMTP_PORT`, `SMTP_USERNAME`,
  `SMTP_PASSWORD`, `SMTP_FROM`), which `run.hs --mail-secret` adds to the
  workload. The email is short text with a plain HTML copy (the name, the
  code set apart, a footer link, no images); the code is not in the subject.
- `server/migrations/007_login_codes.sql`: `login_codes(email, code_hash,
  purpose, expires_at, attempts, used_at, created_at)`. Codes are 6 random
  digits, stored as an HMAC (SESSION_SECRET), valid 10 minutes, 5 tries, and at
  most 5 sent per email per hour. A new code supersedes older ones.
- `server/auth.js`: one `startSession(response, account)` shared by the OIDC
  callback and code login (same cookie, the admin flag from Rauthy groups, the
  same guest-order linking). Sign-out clears the store session; it only visits
  Rauthy's end-session endpoint when the Google session's ID token can be
  passed silently, so no Rauthy sign-out page is ever shown.
- Routes:
  - `GET /login`: log in (Google, or email) and create an account (Google, or
    name and email). Signed-in visitors see who they are, Continue and Sign out.
  - `POST /login/email`, `POST /signup/email`: send a code, remember the email,
    purpose, name and `next` in a short-lived signed cookie, 303 to
    `/login/code`. Unknown email on log in, or a known one on sign-up, says so
    and offers the other path.
  - `GET /login/code`, `POST /login/code`: enter the code; on success create
    or verify the account and start the session, then go to `next`.
  - `POST /login/resend`.
- Gate: `/checkout`, `/checkout/delivery`, `/checkout/pay`,
  `/api/create-payment-intent` and the `/api/delivery/*` checks require a
  session (pages redirect to `/login?next=…`, APIs return 401). The cart stays
  open. With accounts unconfigured, checkout says sign-in is unavailable.
- Everything keeps failing safe: without the database or mail, email sign-in
  says it's unavailable and Google still works.

## Setup (once)

- Rauthy Admin UI → **API Keys**: a key per store (prod, dev) with Users:
  read, create, update. `./scripts/store-rauthy-key.hs` stores it as the
  `birdhaus-store-rauthy` / `birdhaus-store-dev-rauthy` Secret; `run.hs
  --rauthy-secret` mounts it.
- The registration Client URI step from the first pass is no longer needed.

## Docs

AGENTS.md: replace the guest-checkout rule; describe the code login, the API
key and mail Secrets. auth/README.md: API keys; Rauthy's own pages are no
longer linked from the store.

## Verification

- `npm run build` with 0 warnings; screenshots of `/login`, the code page and
  its error states at 1280 and 375 px.
- Locally with a throwaway Postgres and a fake mail transport (log the code):
  sign up, log in, wrong code ×5 lockout, expired code, resend limit, unknown
  email, existing email on sign-up, `next` honoured, checkout redirect when
  signed out, 401 from the payment API.
- On dev with the real API key and SES: a real code email, account created in
  Rauthy with `email_verified`, admin flag from the `birdhaus-admins` group,
  Google log in, sign-out without any Rauthy page.
