# AGENTS.md

Guidance for AI coding agents working in this repository. See `README.md` for user-facing docs.

## What this is

A single-product Stripe storefront (Bluebird House, $40). PureScript Halogen UI (`src/Main.purs`) with a JS bridge for Stripe.js and the confirmation lookup (`src/Main.js`), built by Vite, served by an Express 5 server (`server/index.js`). Deployed as a unikernel on Datum Cloud with `run.hs`.

## Commands

- `npm install`, then `npm run dev` for local development (compiles PureScript, runs Vite and the API).
- `npm run build` must pass with no PureScript warnings before you finish. `npm start` serves `dist/` plus the API on one port.
- There is no test suite. Verify UI changes by running the built server and loading the page; use Stripe test-mode PaymentIntents (card `pm_card_visa`, declined `pm_card_chargeDeclined`) for the confirmation page.
- Deploy: `./run.hs --project <project> --pull-secret <secret>`. This replaces the running production instance, so ask first.

## Conventions

- Every script is a self-contained Haskell (turtle) script with a `nix-shell` shebang, like `run.hs`: executable, with its tools named in the shebang and run from the repository root. Do not add bash or node scripts. The one exception is a script that runs inside a container image (for example the Postgres entrypoint), where Nix is not available.

- The server sets prices. Never accept an amount from the browser; the price lives in `server/index.js` and is mirrored for display in `formatTotal` in `Main.purs`. Change both together.
- `/api/order/:id` must keep requiring the matching `client_secret` and `Cache-Control: no-store`; it returns buyer PII.
- The secret key is server-side only. Never expose it through a `VITE_` variable or the client bundle.
- Keep `index.html` served from memory with `no-cache`, and hashed `/assets` immutable (see README, "Production caching").
- Add PureScript dependencies in `spago.yaml`; `spago.lock` is generated and committed.
- Match the existing style: terse comments that explain why, no dead code.

- Brand images in `public/` are generated from `brand/` by `scripts/brand-assets.hs`; edit the script or sources, not the outputs.

- DNS records we write by hand live in `dns/` and are the source of truth; apply them with `datumctl apply -f dns/ --project <project>`.

- Design docs live in `docs/design/`. Postgres on S3 is built and deployed as workload `birdhaus-pg` (deployment `birdhaus-db`) in the `birdhaus` Network (`network/`), alongside the store (see `postgres/README.md`); Umami analytics (`umami/`) is its first consumer, at https://stats.birdhaus.store, connecting through `db.birdhaus.store` (`dns/aaaa.yaml`). `datumctl compute build` makes unikernel images only, so general-purpose workloads are built with nerdctl.

## Secrets and safety

- `.env` holds Stripe **test** keys. `.env.production` holds **live** keys. Do not read, copy, or create cloud secrets from live keys unless the user explicitly says so.
- Only `.env.example` is tracked (see `.gitignore`). `workload.yaml` is written by `datumctl compute deploy`; `run.hs` is the source of truth.
- Keep personal details (emails, session names) out of committed files; pass them as `run.hs` arguments.
- Tests that create Stripe objects must refuse non-`sk_test_` keys.

## Deployment facts

- Image: `ghcr.io/<gh user>/birdhaus-store`, private; the workload pulls it with an `imagePullSecrets` entry.
- Workload `birdhaus-store` runs in `us-east-1` on the unikernel runtime and listens on 8080. `run.hs` also applies a NetworkService and HTTPProxy for the domain `birdhaus.store`.
- The `datumctl compute deploy -f` flag cannot be combined with `--http-port`, which is why networking is applied separately.
- Building needs a BuildKit daemon; the script uses colima's socket (`~/.colima/default/buildkitd.sock`).
- Fulfilment should be driven by verified Stripe webhooks, not the browser return page (not implemented yet).
