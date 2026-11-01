# Birdhaus Store

A single-product storefront for the $40 Bluebird House. Pages are server-rendered by PureScript with HTMX; a small PureScript/JavaScript client mounts Stripe Elements. The Express server creates a fixed-price Stripe PaymentIntent so the amount is never accepted from the browser.

## Run locally

1. Install Node.js and npm, and Nix: the PureScript build and every script in this repository run through `nix-shell` (see the `.hs` files).
2. Install the dependencies with `npm install`.
3. Copy `.env.example` to `.env` and add your Stripe test keys.
4. Run `npm run dev`. This compiles PureScript first, then starts the Vite frontend and API server; open the Vite URL shown in the terminal.

Use `npm run build` to compile the PureScript module and produce the production frontend in `dist/`. Run `npm start` to serve that build and the API from one process.

The server requires `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY`. `VITE_STRIPE_PUBLISHABLE_KEY` is also accepted by the server as an alternative publishable-key variable. Never put the secret key in a `VITE_` variable or browser code.

Without `PGHOST` the store still runs, but orders and the waitlist are not recorded. To exercise them locally, point the `PG*` variables at a throwaway Postgres and forward Stripe events with `stripe listen --forward-to localhost:8080/api/stripe-webhook`, setting `STRIPE_WEBHOOK_SECRET` to the secret it prints.

Spago's macOS cache is redirected to `.cache/spago-home/Library/Caches/spago-nodejs`, which is ignored by Git. Halogen and the rest of the PureScript dependencies are resolved through Spago.

## Brand assets

The pencil sketches in `brand/` are the source. `./scripts/brand-assets.hs` levels the scanned paper to pure white and regenerates everything in `public/`: the wide `logo.png`, `mark-512.png`, `apple-touch-icon.png`, `favicon.ico` and PNG favicons, and the `og-image.png` link preview. It also writes `brand/logo-large.png` (2400px wide) and `brand/mark-large.png` (2048px square), upscaled from the sketches and each under 512 KB; they are not served by the site. Vite copies `public/` into `dist/`. To brand Stripe's receipt emails, upload `public/mark-512.png` as the icon and `public/logo.png` as the logo in Dashboard → Settings → Branding.

## Order confirmation

After payment Stripe redirects to `/order?payment_intent=…&payment_intent_client_secret=…`. The server looks the PaymentIntent up in Stripe and renders it only when the client secret matches, so order details are visible only to the buyer. The page shows the order number, date, items, total, pick-up time (or shipping address for older orders) and receipt email, and has separate states for processing, declined and unavailable orders. Stripe sends receipt emails only in live mode, and only if receipts are enabled in the Dashboard.

## Deploy to Datum Cloud

`run.hs` builds the image, pushes it to GHCR, and deploys it as a unikernel workload behind a domain. It is a self-contained Haskell script (turtle, run through `nix-shell`), so the only prerequisites are Nix, `datumctl` on your `PATH`, a logged-in `datumctl` session and an authenticated `gh`.

```
./run.hs --project <project> --pull-secret <secret>
```

### Versions and releases

Every deploy has a version, which is also its image tag and is reported by `/api/health` with the commit. `run.hs` derives it from git: a commit tagged `vX.Y.Z` is `vX.Y.Z`; any other commit is the next patch plus the number of commits since the last release, `vX.Y.(Z+1)-dev.N`, with `.dirty` added when the working tree has uncommitted changes. `--version` overrides it, and a release version is refused unless `HEAD` carries that tag.

A deploy finishes only when the domain serves the new version with its migrations applied (`/api/health` says `"migrations": "ok"`); the server applies them at startup. `run.hs` gives up after ten minutes.

### From GitHub Actions

`.github/workflows/deploy.yml` runs `run.hs` on GitHub's runners:

- Every push to `main` deploys `dev.birdhaus.store` as `vX.Y.Z-dev.N`.
- Publishing a GitHub release deploys its tag to `birdhaus.store`. The tag must be `vX.Y.Z` and on `main`; prereleases are not deployed. For example, `gh release create v1.0.0 --target main --generate-notes`.
- To roll back, re-run the deploy workflow of an earlier release.

One-time setup:

1. In the Datum Cloud portal, create a service account with rights to deploy in the project, download its credentials JSON, and save it as the repository secret `DATUM_CREDENTIALS`.
2. Create the environments `development` and `production` (Settings → Environments). Limit `production` to tags matching `v*` so only a release can deploy there.
3. In the `birdhaus-store` package settings on GHCR, under "Manage Actions access", give this repository write access so `GITHUB_TOKEN` can push the image.

The workflow pins `datumctl` by release and checksum and the `compute` plugin by version; bump them in the workflow's `env`.

- `--pull-secret` names an existing image-pull secret in the project holding a GHCR token that can read the image.
- The Stripe keys come from a secret in the project (default `birdhaus-stripe`, override with `--stripe-secret`), exposed to the workload as environment variables. Create it from test keys, never from `.env.production`.
- The database and webhook settings come from a second secret (default `birdhaus-store-db`, override with `--db-secret`), created once by `./scripts/store-db-secret.hs --project <project>`.
- The pre-order batch is set with `--batch` (default `xmas-2026`), `--cap` (default `20`, the Christmas 2026 batch), `--closes` (default `2026-12-01`) and `--ship-by` (default `2026-12-15`).
- Other options (`--location`, `--workload`, `--image-name`, `--domain`, `--version`, `--session`) have defaults; run `./run.hs --help`.
- Image builds use `datumctl compute build`, which uses the container engine's BuildKit (Docker, OrbStack, Colima, …) and honors `DOCKER_HOST`/`DOCKER_CONTEXT`; set `BUILDKIT_HOST` to use a different BuildKit.
- Every run with a new version replaces the running instances one at a time.

Production caching: hashed files under `/assets` are immutable for a year; `index.html` is served from memory with a content-hash ETag and `no-cache`. Reproducible image builds pin file mtimes, so Express's default size+mtime ETags cannot tell builds apart.

## AWS account setup

`ops/aws-account.hs` creates, migrates and tears down every Birdhaus AWS resource: the Postgres backup bucket and its IAM user, and `ops/watch/` alerting. Run it from the repository root with an admin AWS profile for the target account. The `drewr-admin` profile has S3/Lambda/DynamoDB/Scheduler/SES but no IAM, so bucket/IAM setup, `destroy` and a full watcher deploy need `drewr-root` (root) or another IAM admin; `ops/watch/deploy.hs code` handles checks-only watcher changes.

```
export AWS_PROFILE=<admin-profile>
./ops/aws-account.hs setup --project <project> --alert-to <email>
./ops/aws-account.hs copy-data --from-profile <old-profile> --project <project>
./ops/aws-account.hs switch --project <project>
./ops/aws-account.hs destroy --confirm <account-id> --project <project>
```

- `setup` is idempotent. It creates the bucket, its shared policy, the deployment's IAM user and Datum Secret (unless the Secret already exists, as it does during a move), birdhaus-watch, and `dns/ses.yaml` with the DKIM records. Apply that file with `datumctl apply -f dns/ses.yaml --project <project>` and click the SES verification email; DNS changes need approval.
- `copy-data` copies `birdhaus-db/` from the old account's bucket. It switches the source's WAL and waits for the archive to drain, refuses to merge into a non-empty prefix, and verifies object counts and bytes. Pause writers (Umami) first: writes after the WAL switch are not copied. The source instance is found with `--workload` (default `birdhaus-pg`); use `--session` or an active `datumctl` session for the project.
- `switch` points Postgres at this account. It refuses unless the new bucket holds a base backup, recreates the `birdhaus-db-aws` and `birdhaus-db-watch` Secrets, restarts the workload, waits for recovery and prints row counts.
- `destroy` removes birdhaus-watch, the deployment's IAM user and the bucket. It refuses if the `birdhaus-db-aws` Secret still points at the account, and `--confirm` must be the account ID.

`dns/ses.yaml` is generated, so regenerating it never touches the Stripe records in `dns/cname.yaml`.

## Pre-orders

The store sells in batches. Each pre-order is charged at checkout and promises a ship-by date; when the batch's cap is reached or its closing date passes, the page swaps checkout for a waitlist (email, quantity, optional ZIP, no payment).

- **Records:** Stripe's `payment_intent.succeeded` webhook (`POST /api/stripe-webhook`, signature-verified) writes each order to the `orders` table in the `birdhaus` database; `charge.refunded` marks it refunded, which frees its units. Redelivered events are no-ops. If the database is down the webhook returns 500 and Stripe retries for up to three days.
- **Cap:** `POST /api/create-payment-intent` refuses an order that would exceed the cap. It is a soft cap: simultaneous checkouts can overshoot by a few units. If the database is unreachable, checkout stays open.
- **Page:** `GET /api/batch` tells the page whether the batch is open, the ship-by date, and the units left once fewer than 20% remain.
- **Schema:** numbered SQL files in `server/migrations/`, applied at startup under an advisory lock.
- **Analytics:** Umami events `checkout-start`, `preorder-paid`, `waitlist-join` and `sold-out-view`.
- **Demand report:** `./scripts/demand.hs --project <project> --cap <n>` prints paid units by week and day, refunds, the waitlist, and the 7-day sell rate with a projected sell-out date.

To raise the cap or move a date, redeploy with new `run.hs` options.

## Accounts

Sign-in is optional at https://login.birdhaus.store: Google, or an email account that a magic link activates and that uses a passkey (a password remains available). Guest checkout stays the default, and nothing about buying requires an account. A signed-in customer gets order history, and past guest orders with the same verified email are linked on first sign-in. Analytics identify the visitor by Rauthy's internal ID, never the email. If the identity service is down, sign-in fails but checkout and the Stripe webhook keep working.

Setup and operations are in [`auth/README.md`](auth/README.md); the design and open work are in [`docs/design/accounts.md`](docs/design/accounts.md). Microsoft and Amazon sign-in are phase 2.

## Stripe

Stripe test mode is enabled by supplying test keys. Before launch, add live keys in the deployment environment and configure Stripe's payment methods in the Dashboard. Checkout is two steps: `/checkout` chooses delivery (local pick-up at an admin-defined slot; shipping is greyed out until USPS pricing is added) and `/checkout/pay` takes payment. It charges $40 USD per house and collects an email; tax is not added yet.

Store admins (members of the Rauthy group `birdhaus-admins`) see an Admin link: `/admin` lists recent orders and `/admin/pickup` manages pick-up locations, time slots and the pick-up schedule. To grant access, create the group in Rauthy, add users to it, and add `groups` to the Allowed Scopes of each store client; members then sign out and back in. Orders are recorded from verified webhooks, not the browser return page (see Pre-orders).

## Analytics

Visitor analytics are self-hosted Umami at https://stats.birdhaus.store; see [`umami/README.md`](umami/README.md). Signed-in visitors are identified with `umami.identify` (Rauthy's internal ID, not an email), and the store records `login`, `signup` and `logout` plus `loggedIn` on the checkout events.

## Operator alerts

`ops/watch/` is a small heartbeat and probe monitor in AWS that emails the operator when Postgres stops archiving or backing up, or when the store, checkout, auth or Umami stop answering. See [`ops/watch/README.md`](ops/watch/README.md).

## Design docs

- [A reproducible AWS account, and moving off the sandbox](docs/design/aws-account.md) (built): one script to set up, migrate and tear down every Birdhaus AWS resource.
- [S3-backed PostgreSQL on Datum Compute](docs/design/postgres-s3.md): persistence for orders, analytics and accounts. Deployed; operations in [`postgres/README.md`](postgres/README.md).
- [Accounts and sign-in with Google and email](docs/design/accounts.md) (built): a self-hosted Rauthy identity service in the `birdhaus` Network, wired into the store and Umami analytics.
