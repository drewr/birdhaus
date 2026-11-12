# Plan: Replace Rauthy with Zitadel

## Context

Status: planned, not started (2026-11-12).

The owner is unhappy with Rauthy, mainly because user and admin management is awkward, and wants Zitadel's features (its Console, project roles, audit trail, API-first setup). All of Rauthy's setup today is manual Admin UI work that isn't in the repo: the Google provider, both store clients, the `birdhaus-admins` group and the API keys. Customers never see the identity service's pages. The store runs its own `/login`, sends Google sign-in through the IdP with a hint, and runs email sign-in itself (6-digit codes), using the IdP only as an account directory through its admin API. That design stays; only the IdP behind it changes.

**Decided:** import every Rauthy account and keep order links. Zitadel lets us set the user ID on creation, so the plan is to **reuse each Rauthy user ID as the Zitadel user ID**. Then `orders.account_sub`, `restock_requests.account_sub`, Stripe PaymentIntent metadata and Umami identities all stay valid, and so do existing session cookies.

Target: Zitadel v4.20.2 (current stable; skip 4.18.0), Postgres only, pinned by digest.

## Phase 0: local spike (read-only for prod; must pass before anything else)
Run `pkgs.zitadel` from the pinned nixpkgs, plus a throwaway Postgres, and point the local store at it. The spike settles what the docs leave open:
1. A Rauthy-style ID (24 alphanumeric characters) is accepted as `userId` on `POST /v2/users/new`.
2. A human user with a verified email and no password ends up `ACTIVE`, not `INITIAL`.
3. With project role assertion on, the ID token carries `urn:zitadel:iam:org:project:roles`.
4. Calls to the internal URL work when they carry `x-zitadel-instance-host` / `x-zitadel-public-host`. Zitadel routes by host, so a bare `auth.datum.internal` gets "Instance not found".
5. `end_session` with `id_token_hint` redirects without showing a page. This is the built-in V1 login, with `LOGINV2_REQUIRED=false`, so no separate login container.
6. A PAT for a machine user with `ORG_USER_MANAGER` can read users and their authorizations.

If item 1 fails, fall back to new IDs plus a remap: one SQL migration updates `account_sub` by email, and the new IDs are accepted as breaking old Stripe metadata and Umami links. That fallback is a plan change, so check with the owner first.

## Phase 1: deploy Zitadel beside Rauthy
- **`auth/deploy.hs`:** rewrite it for Zitadel, in the same shape as today (Secret created once with `datumctl create`, general-purpose Workload, NetworkService, HTTPProxy).
  - Workload `birdhaus-zitadel`, hostname **`id.birdhaus.store`**, port 8080, network `birdhaus`.
  - Args: `start-from-setup --masterkeyFromEnv --tlsMode external`.
    - Setup, not init: Postgres's `reconcile()` (`postgres/entrypoint.sh`) already creates the role and database, owned by the role.
  - Secret env:
    - `ZITADEL_MASTERKEY`: 32 characters, generated. It can never be changed or lost; the README says so.
    - `ZITADEL_EXTERNALDOMAIN`, `EXTERNALPORT=443`, `EXTERNALSECURE=true`.
    - `ZITADEL_DATABASE_POSTGRES_*`: host `db`, database and user `zitadel`, `sslmode` disable.
    - `ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=false`.
    - `FIRSTINSTANCE`: the org "Birdhaus" and the Console admin from `--admin-email`, with a generated password.
    - The SMTP settings from `birdhaus-ses`.
  - Rauthy's deploy moves to git history; it keeps running untouched until Phase 5.
- **Postgres:** add `zitadel` to `postgres/deploy.hs`'s default `--databases`, plus the key in `birdhaus-db-db`.
  - Redeploying Postgres restarts it, so ask first.
- **Private DNS:** `dns/private.yaml` gets an `id` CNAME to `birdhaus-zitadel-default-us-east-1-0.instances.datum.internal.`, beside the `auth` one.
- **`auth/configure.hs` (new):** an idempotent Haskell/turtle script that does over the API everything Rauthy needed by hand. It authenticates with the PAT of an IAM-owner machine user, which is the one manual Console step.
  - Project "Birdhaus Store" with role **`admin`**, plus project and app role assertion so roles land in the ID token.
  - Two OIDC web apps, `store` and `store-dev`:
    - Code flow, PKCE, `client_secret_basic`.
    - Redirect URIs as today: prod, dev, localhost.
    - Post-logout URIs.
  - The Google IdP:
    - Client id and secret from env; the existing Google OAuth client gets the extra redirect `https://id.birdhaus.store/ui/login/login/externalidp/callback`.
    - Auto-creation on, auto-update on, auto-linking by email with no prompt, so a Google sign-in never stops on a Zitadel page.
  - Login policy: no self-registration, external IdPs allowed.
  - The store's machine user `birdhaus-store` with `ORG_USER_MANAGER` and a PAT.
  - Writes the Secrets by calling `scripts/store-auth-secret.hs` and the renamed key script:
    - **New names:** `birdhaus-store-oidc`, `birdhaus-store-zitadel`, and the `-dev-` versions. Cutover and rollback are then just a change of `run.hs` defaults.
    - `SESSION_SECRET` is copied from the existing auth Secret, so sessions survive.
  - Prints the Google IdP ID and the project ID for the Secret.
  - Logo and theme from `public/`, so the rare Zitadel page looks like Birdhaus.
- **`ops/watch/checks.json`:** an `id` probe on `https://id.birdhaus.store/debug/ready`. Also drop the duplicate `auth` probe.

## Phase 2: store code (one switch, no dual-IdP support)
- **`server/zitadel.js`** replaces `server/rauthy.js`. It keeps the same exports (`isConfigured`, `listUsers`, `findById`, `findByEmail`, `create`, `markVerified`) and adds `roles(sub)`.
  - Env: `ZITADEL_API_URL` (internal), `ZITADEL_PAT`, `ZITADEL_ORG_ID`, `ZITADEL_PROJECT_ID`, plus the public host for the instance headers.
  - v2 endpoints:

    | Function | Endpoint |
    |---|---|
    | `findById` | `GET /v2/users/{id}`; enabled = `state === ACTIVE` |
    | `findByEmail` | `POST /v2/users` with an email query (case-insensitive) |
    | `listUsers` | `POST /v2/users`, paging 1000 at a time (4.19.5 caps it there) |
    | `create` | `POST /v2/users/new` with `isVerified: true` and no password |
    | `markVerified` | `PATCH /v2/users/{id}` |
    | `roles` | `ListAuthorizations` filtered to the user and project |

  - The 5s timeout and "404 → null" stay as they are.
- **Names:** Zitadel requires `givenName` and `familyName`. `create` stores the typed name as `displayName`, which reads back as the name. Given is the first word; family is the rest, or the given name again when it's one word. `normalName` in `server/email-login.js` loosens to Zitadel's limits (1–200 characters).
- **`server/auth.js`:**
  - Google: drop `providerId()` and the call to Rauthy's `/auth/v1/providers/minimal`. Add the scope `urn:zitadel:iam:org:idp:id:${OIDC_GOOGLE_IDP}`, with the ID taken from the OIDC Secret.
  - Groups: read the keys of `urn:zitadel:iam:org:project:roles` in place of `groups`, and drop the `groups` scope. Internally the session still calls them `groups`, so products and visibility don't change.
  - `currentGroups()` uses `zitadel.findById` plus `zitadel.roles`. The 5-minute cache, the 503 when it's down and `updateSession` stay.
  - Discovery, token and JWKS calls to the internal URL send the instance and public host headers.
  - Keep the `id_token_hint` logout; remove `hintUsable`'s Rauthy-specific 540s window unless the spike shows Zitadel needs it.
- **Admin config:** `ADMIN_GROUP` becomes `ADMIN_ROLE` (default `admin`), in `server/auth.js`, `server/products.js` and `run.hs` (`--admin-role`).
- **`run.hs`:**
  - `--rauthy-secret/-R` becomes `--zitadel-secret/-Z` (default `birdhaus-store-zitadel`), and the `-A` default becomes `birdhaus-store-oidc`.
  - `.github/workflows/deploy.yml` passes the `-dev-` names.
  - `scripts/dev-store.hs` follows suit.
- **Scripts:** `scripts/store-rauthy-key.hs` becomes `scripts/store-zitadel-key.hs` (PAT plus org and project IDs). `scripts/store-auth-secret.hs` gets `--google-idp`, a default issuer of `https://id.birdhaus.store`, and `--session-secret-from <secret>`.
- **Comments:** update the ones that name Rauthy in `src/Server/Render.purs`, `src/Server/Admin.purs`, `src/Client/Main.js` and `server/mail.js`. Applied migrations stay untouched.

## Phase 3: import accounts, switch dev
- **`auth/import-rauthy.hs` (new):** idempotent, with `--dry-run`. It reads every Rauthy user through Rauthy's admin API with the existing key, then for each one:
  - Creates the user in Zitadel with `userId` = the Rauthy ID, plus email, verified flag and name.
  - Copies the Google link (Rauthy's upstream subject → `idpLinks` on the Google IdP).
  - Grants `admin` to `birdhaus-admins` members.
  - Deactivates users that are disabled in Rauthy.
  - Skips users that already exist.
  - Prints counts of created, skipped and failed users.
  - Passwords and passkeys from Rauthy's old pages aren't carried over; customers sign in with Google or an email code anyway.
- **Switch dev:** dev deploys from main on push, so the Phase 2 merge switches it. Test on `dev.birdhaus.store`:
  - Google sign-in, both new and imported, with no Zitadel page.
  - Email sign-up and log-in.
  - An admin reaching `/admin` and a non-admin getting a 404.
  - Revoking `admin` in the Console takes effect within 5 minutes.
  - `/admin/users` lists everyone.
  - Sign-out.
  - An existing session survives the switch.

## Phase 4: prod cutover (ask first)
1. Re-run `import-rauthy.hs` right before the release, to catch sign-ups since the last run.
2. Publish the release; prod's `run.hs` defaults now point at the new Secrets.
3. Check `/api/health`, a Google sign-in, an email sign-in and the admin pages.
4. Re-run the import once more, to catch the gap.

**Rollback:** release the previous tag. Rauthy and its Secrets are still running.

## Phase 5: retire Rauthy (after about a week, ask first)
- Delete the `birdhaus-auth` workload and its Secrets, the `auth` CNAME, the `birdhaus-store(-dev)-auth` and `-rauthy` Secrets, and the Google redirect URI for Rauthy.
- Drop the `auth` database: remove it from `--databases`, then drop it by hand, keeping a final backup.
- Docs:
  - Rewrite `auth/README.md` (deploy, configure, masterkey, Console, upgrade, operate).
  - `docs/design/accounts.md` gets a dated decision note: Zitadel replaced Rauthy, and why.
  - Update `docs/design/login-page.md`, `fulfillment.md`, `storefront-pages.md`, `postgres-s3.md`, `README.md`, `AGENTS.md`, `postgres/README.md`, `dns/README.md` and `ops/watch/README.md`.
  - Fix `scripts/ses-smtp.hs`'s comment.

## Not in scope (possible follow-ups)
- Granting or revoking admin from `/admin/users`.
- Passkeys.
- Single sign-on into Umami through Zitadel.
- Running Zitadel highly available.

## Verification
- **Phase 0:** all six spike items pass locally, with a short note of the results.
- **Each code change:** `npm run build` with no warnings; the built server run locally against local Zitadel and Postgres for sign-up, log-in, the admin gate and `/admin/users`.
- **The import:** a `--dry-run` against prod Rauthy shows expected counts. After the real run, spot-check that 3 accounts (one Google, one email, one admin) have the same ID in Zitadel, and that each one's orders still show on `/admin/users`.
- **Dev:** the Phase 3 checklist.
- **Prod:** the Phase 4 checks, `ops/watch` green for `id`, and `/api/health` unchanged.
