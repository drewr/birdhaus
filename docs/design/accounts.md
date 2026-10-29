# Design: accounts, sign-in with Google and email

Status: proposed (2026-10-29). Phase 1 is Google plus a passkey-first email account.

## Problem

The store learns who a customer is only at checkout, when Stripe collects an email and a shipping address. There is no account, no order history, no way to recognise a returning visitor, and analytics cannot separate known from anonymous visitors.

## Goals and non-goals

Goals:

- Optional accounts that can be created before checkout. Guest checkout stays; nothing about buying requires an account.
- Sign in with Google first, then Microsoft and Amazon through generic OIDC.
- Plain email accounts without a password: the user confirms the address once with a magic link and registers a passkey. A password remains available for users who prefer it.
- Link past guest orders to the account by verified email, so history is not lost.
- Identity-aware analytics in Umami, using an internal ID and never an email address.
- Keep selling when the identity service is down: login fails, checkout does not.

Non-goals:

- Single sign-on into the Umami dashboard. Umami self-hosted does not support OIDC (open issues #1112 and #3163); its admin login stays local.
- Roles, permissions or a customer portal beyond order history.
- Microsoft and Amazon in phase 1. They are generic OIDC registrations once the Google flow is proven.
- Replacing Stripe as the payment or receipt-email system.

## Decision: Rauthy

Rauthy 0.37.x (Apache-2.0, Rust) runs as one container and can use the existing S3-backed Postgres as its only state. It ships a brandable hosted login UI, is an OpenID Connect provider, and has templates for Google plus a generic OIDC upstream. Its account model is passkey-first: a magic link activates the account, then the user registers a passkey and can remove the password.

Alternatives considered:

- **Zitadel v4** is the most complete, but it is AGPL-3.0 and since v4 needs the separate Next.js Login V2 app deployed and upgraded alongside the core.
- **Logto** supports true per-login magic links, but our server would have to create one-time tokens and send every email itself, and Logto OSS caps social connectors at three.
- **Keycloak** is far heavier (JVM, ~1 GB) than this store needs.
- **Ory Kratos/Hydra** is headless: the login UI would be another PureScript application to build and secure.

## Architecture

```
browser ──► login.birdhaus.store  (HTTPProxy ──► workload birdhaus-auth, Rauthy :8080)
                │  OIDC code + PKCE                  └── auth DB ──► birdhaus-pg (S3-durable)
                ▼
browser ──► birdhaus.store (session cookie; guest checkout unchanged)
                │  PaymentIntent metadata.account_sub
                └──► Stripe webhook ──► orders.account_sub
browser ──► umami.identify({ id }) + login/signup/logout ──► birdhaus-umami
```

`birdhaus-auth` is a general-purpose workload on the `birdhaus` Network. It is stateless behind Postgres, so it uses `reclaimPolicy: Delete` and an image pinned by digest, like Umami. Datum programs the `login.birdhaus.store` record from the HTTPProxy, as it does for `stats.birdhaus.store`.

## Account model

- **Identity:** Rauthy owns the user. The store only holds the Rauthy `sub` and the verified email claim.
- **Registration:** open registration, confirmed by email. The magic link lands on Rauthy's hosted page, where the user sets a passkey (recommended) or a password. Rauthy's proof-of-work form is the anti-bot measure.
- **Login:** email + passkey, or email + password if the user chose one. Google is a button on the same page, and `idp_hint` lets the store deep-link straight to Google.
- **Linking:** after a login where the provider reports `email_verified`, run
  `update orders set account_sub = $1 where email = $2 and account_sub is null`.
  A customer who bought as a guest and later signs in keeps that history. The same applies to the waitlist if it gains an `account_sub` column.
- **Attribution:** when a logged-in user starts checkout, the PaymentIntent gets `metadata.account_sub`; the existing webhook writes it to the new `orders.account_sub` column. Checkout itself is unchanged.
- **Session:** the store issues its own HMAC-signed cookie (HttpOnly, Secure, SameSite=Lax) after verifying the ID token against Rauthy's JWKS. No session table: the unikernel can restart without logging everyone out, and a database outage only affects account pages.
- **Logout:** clears the cookie and calls Rauthy's RP-initiated logout.

## Rauthy configuration

- **Public URL and proxy:** `PUB_URL=login.birdhaus.store` (Rauthy rejects a scheme here), `LISTEN_SCHEME=http`, `PORT_HTTP=8080`, `PROXY_MODE=true`, `TRUSTED_PROXIES` set to the edge's source range once observed in the spike. With proxy mode on, Rauthy derives the public `https` scheme. TLS terminates at the Datum edge, as it does for the store and Umami.
- **Database:** `HIQLITE=false`, `PG_HOST=db.birdhaus.store`, `PG_DB_NAME=auth`, `PG_USER=auth`, `PG_TLS=disable`, with the password from the `birdhaus-db-db` Secret. The `auth` database and role are declared in the Postgres workload's `DATABASES` list, so every boot reconciles them.
- **WebAuthn:** `RP_ID=login.birdhaus.store`, `RP_ORIGIN=https://login.birdhaus.store`, `RP_NAME=Birdhaus`.
- **Encryption:** at least one `ENC_KEYS` entry and `ENC_KEY_ACTIVE` in the `birdhaus-auth` Secret. These encrypt client secrets and cookies in the database; losing them means re-creating clients and upstream providers.
- **Admin:** bootstrap the first admin with `BOOTSTRAP_ADMIN_EMAIL` and `BOOTSTRAP_ADMIN_PASSWORD_PLAIN` from the Secret, then force MFA on the Admin UI.
- **Email:** Mailgun SMTP (`SMTP_URL`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`); the domain already has Mailgun SPF, DKIM, DMARC and MX. Magic links and account mail come from `login@birdhaus.store`.
- **Registration:** `OPEN_USER_REG=true`.
- **Google:** a Web application OAuth client with redirect `https://login.birdhaus.store/auth/v1/providers/callback`; the client ID and secret are entered in Rauthy's Providers page and stored encrypted in Postgres.

## Components

New:

- `auth/deploy.hs`: creates the `birdhaus-auth` Secret on first run (database password from `birdhaus-db-db`, encryption keys, admin bootstrap, SMTP), deploys the workload, NetworkService and HTTPProxy, and prints the remaining manual steps. Modelled on `umami/deploy.hs`.
- `auth/README.md`: operations, the Google console steps, SMTP secret, backup/restore and admin recovery.
- `server/auth.js`: login redirect with PKCE and state, callback with code exchange and JWKS verification, session cookie, `/api/me`, logout, and the verified-email backfill.
- `scripts/store-auth-secret.hs`: creates `birdhaus-store-auth` (issuer, client ID/secret, cookie key) with `datumctl create`.
- `server/migrations/003_account_attribution.sql`: `orders.account_sub` and its index.
- `docs/design/accounts.md` (this file).

Changed:

- `postgres/deploy.hs`: default `--databases "birdhaus umami auth"`.
- `run.hs`: `--auth-secret` (default `birdhaus-store-auth`) added to the workload's `envFrom`.
- `server/index.js`: mounts the auth routes, attaches `metadata.account_sub` to PaymentIntents.
- `src/Main.purs` and `src/Main.js`: header sign-in/account control, `/api/me` state, account view with order history, `umami.identify` and `login`/`signup`/`logout` events, and `loggedIn` on the existing checkout events.
- `ops/watch/checks.json`: probe Rauthy's health endpoint, so a dead identity service alerts.
- `README.md`, `AGENTS.md`, `postgres/README.md`: point at the new component.

## Rollout

1. Add the `auth` password to `birdhaus-db-db`, recreate the Secret with all keys, and redeploy `birdhaus-pg` with the new `DATABASES`. The stop is graceful and the restore is seconds; no committed write is lost.
2. Create the `birdhaus-auth` Secret and deploy the workload; verify the login page and the health probe. This is the spike for proxy headers, IPv6 binding, Postgres mode and SMTP.
3. Manual, once: Google OAuth client, Rauthy admin bootstrap, force MFA, Google provider, the `birdhaus-store` OIDC client (PKCE S256, redirect `https://birdhaus.store/api/auth/callback`), branding.
4. Store release: migration, auth routes, UI, analytics. Local test against a `LOCAL_TEST=true` Rauthy container; then `run.hs`, which replaces the production store instance.
5. Add the watch check and update the docs.

## Verification

- Google round-trips to `birdhaus.store` and `/api/me` returns the account; a passkey registration survives a logout.
- A magic link from Mailgun activates a new account (DKIM pass).
- A previous guest order with the same verified email appears in the account after login.
- Umami shows identified sessions and `login`/`signup` events; `checkout-start` splits by `loggedIn`.
- With `birdhaus-auth` stopped: login fails, guest checkout and the webhook still work, and the watch probe reports the auth service down.
- A Rauthy restart (no local disk) comes back from Postgres with users and clients intact.

## Risks

- **Rauthy is a small project.** The upstream-provider docs cover GitHub only; Google and generic OIDC exist in the admin UI but need a hands-on check. Fallback is Zitadel v4.
- **Passkey loss.** A passkey-only user who loses every device needs an admin reset. Offer the password option and document the recovery path.
- **Proxy trust.** With edge-terminated TLS, Rauthy must trust the edge's forwarded headers; a wrong `TRUSTED_PROXIES` either blocks requests or lets clients spoof their address. The spike pins the range, and `SESSION_VALIDATE_IP` is left on so a bad setup shows up in the Admin UI.
- **SMTP dependency.** Email login needs Mailgun; Google login and the store do not.
- **Auth outage** blocks sign-in but not sales; the store's auth calls must time out quickly and never gate checkout.
- **Umami SSO is not possible** on self-hosted Umami; the dashboard login stays separate.
