# Birdhaus Store

A single-product storefront for the $40 Bluebird House. The frontend is a PureScript Halogen component with a JavaScript bridge for Stripe.js. The Express server creates a fixed-price Stripe PaymentIntent so the amount is never accepted from the browser.

## Run locally

1. Install Node.js and npm, and Nix: the PureScript build and every script in this repository run through `nix-shell` (see the `.hs` files).
2. Install the dependencies with `npm install`.
3. Copy `.env.example` to `.env` and add your Stripe test keys.
4. Run `npm run dev`. This compiles PureScript first, then starts the Vite frontend and API server; open the Vite URL shown in the terminal.

Use `npm run build` to compile the PureScript module and produce the production frontend in `dist/`. Run `npm start` to serve that build and the API from one process.

The server requires `STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY`. `VITE_STRIPE_PUBLISHABLE_KEY` is also accepted by the server as an alternative publishable-key variable. Never put the secret key in a `VITE_` variable or browser code.

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
- Other options (`--location`, `--workload`, `--image-name`, `--domain`, `--tag`, `--session`) have defaults; run `./run.hs --help`.
- Image builds use `datumctl compute build` against BuildKit in a colima VM, which the script starts if needed. Stop it afterwards with `colima stop`.
- Every run replaces the running instance with the new image digest; expect a few seconds of rollout.

Production caching: hashed files under `/assets` are immutable for a year; `index.html` is served from memory with a content-hash ETag and `no-cache`. Reproducible image builds pin file mtimes, so Express's default size+mtime ETags cannot tell builds apart.

## Stripe

Stripe test mode is enabled by supplying test keys. Before launch, add live keys in the deployment environment and configure Stripe's payment methods in the Dashboard. The current checkout charges $40 USD and collects an email and shipping address. Shipping cost and tax are not added to the amount yet. A production fulfillment process should rely on verified Stripe webhooks (such as `payment_intent.succeeded`) rather than the browser return page.

## Design docs

- [S3-backed PostgreSQL on Datum Compute](docs/design/postgres-s3.md) (proposed): persistence for orders and analytics.
