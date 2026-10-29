# Birdhaus Store

A single-product storefront for the $40 Bluebird House. The frontend is a PureScript Halogen component with a JavaScript bridge for Stripe.js. The Express server creates a fixed-price Stripe PaymentIntent so the amount is never accepted from the browser.

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

After payment Stripe redirects to `/?payment=complete&payment_intent=…&payment_intent_client_secret=…`. The page calls `GET /api/order/:id?client_secret=…`, which looks the PaymentIntent up in Stripe and returns only when the client secret matches, so order details are visible only to the buyer. The page shows the order number, date, items, total, shipping address and receipt email, and has separate states for processing, declined and unavailable orders. Stripe sends receipt emails only in live mode, and only if receipts are enabled in the Dashboard.

## Deploy to Datum Cloud

`run.hs` builds the image, pushes it to GHCR, and deploys it as a unikernel workload behind a domain. It is a self-contained Haskell script (turtle, run through `nix-shell`), so the only prerequisites are Nix, `datumctl` on your `PATH`, a logged-in `datumctl` session and an authenticated `gh`.

```
./run.hs --project <project> --pull-secret <secret>
```

- `--pull-secret` names an existing image-pull secret in the project holding a GHCR token that can read the image.
- The Stripe keys come from a secret in the project (default `birdhaus-stripe`, override with `--stripe-secret`), exposed to the workload as environment variables. Create it from test keys, never from `.env.production`.
- The database and webhook settings come from a second secret (default `birdhaus-store-db`, override with `--db-secret`), created once by `./scripts/store-db-secret.hs --project <project>`.
- The pre-order batch is set with `--batch` (default `xmas-2026`), `--cap` (default `20`, the Christmas 2026 batch), `--closes` (default `2026-12-01`) and `--ship-by` (default `2026-12-15`).
- Other options (`--location`, `--workload`, `--image-name`, `--domain`, `--tag`, `--session`) have defaults; run `./run.hs --help`.
- Image builds use `datumctl compute build` against BuildKit in a colima VM, which the script starts if needed. Stop it afterwards with `colima stop`.
- Every run replaces the running instance with the new image digest; expect a few seconds of rollout.

Production caching: hashed files under `/assets` are immutable for a year; `index.html` is served from memory with a content-hash ETag and `no-cache`. Reproducible image builds pin file mtimes, so Express's default size+mtime ETags cannot tell builds apart.

## Pre-orders

The store sells in batches. Each pre-order is charged at checkout and promises a ship-by date; when the batch's cap is reached or its closing date passes, the page swaps checkout for a waitlist (email, quantity, optional ZIP, no payment).

- **Records:** Stripe's `payment_intent.succeeded` webhook (`POST /api/stripe-webhook`, signature-verified) writes each order to the `orders` table in the `birdhaus` database; `charge.refunded` marks it refunded, which frees its units. Redelivered events are no-ops. If the database is down the webhook returns 500 and Stripe retries for up to three days.
- **Cap:** `POST /api/create-payment-intent` refuses an order that would exceed the cap. It is a soft cap: simultaneous checkouts can overshoot by a few units. If the database is unreachable, checkout stays open.
- **Page:** `GET /api/batch` tells the page whether the batch is open, the ship-by date, and the units left once fewer than 20% remain.
- **Schema:** numbered SQL files in `server/migrations/`, applied at startup under an advisory lock.
- **Analytics:** Umami events `checkout-start`, `preorder-paid`, `waitlist-join` and `sold-out-view`.
- **Demand report:** `./scripts/demand.hs --project <project> --cap <n>` prints paid units by week and day, refunds, the waitlist, and the 7-day sell rate with a projected sell-out date.

To raise the cap or move a date, redeploy with new `run.hs` options.

## Stripe

Stripe test mode is enabled by supplying test keys. Before launch, add live keys in the deployment environment and configure Stripe's payment methods in the Dashboard. The current checkout charges $40 USD and collects an email and shipping address. Shipping cost and tax are not added to the amount yet. Orders are recorded from verified webhooks, not the browser return page (see Pre-orders).

## Analytics

Visitor analytics are self-hosted Umami at https://stats.birdhaus.store; see [`umami/README.md`](umami/README.md).

## Operator alerts

`ops/watch/` is a small heartbeat and probe monitor in AWS that emails the operator when Postgres stops archiving or backing up, or when the store, checkout or Umami stop answering. See [`ops/watch/README.md`](ops/watch/README.md).

## Design docs

- [A reproducible AWS account, and moving off the sandbox](docs/design/aws-account.md) (proposed): one script to set up, migrate and tear down every Birdhaus AWS resource.
- [S3-backed PostgreSQL on Datum Compute](docs/design/postgres-s3.md) : persistence for orders and analytics. Deployed; operations in [`postgres/README.md`](postgres/README.md).
