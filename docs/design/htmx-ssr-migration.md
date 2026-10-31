# Plan: Convert the storefront to HTMX + PureScript server-side rendering

## Context

Birdhaus is currently a Halogen single-page app (`src/Main.purs` + FFI `src/Main.js`) that fakes screens with client state. The user wants **real page URLs** (`/`, `/cart`, `/checkout`, `/order`) so it "isn't a single page application", with a **server cart (signed cookie)**, built with **HTMX** — and confirmed we **keep PureScript** (drop only Halogen + the Vite SPA bundle). This also resolves a just-found bug where the SPA cart quantity didn't accumulate.

Decisions locked with the user: cart quantity stepper uses **HTMX fragment swaps** (works as a plain form POST with JS off); post-payment confirmation lives at a **dedicated `/order` page**; HTML is rendered by **PureScript** (`ViewModel -> String`), the only irreducibly-client code (Stripe Elements + Umami) stays PureScript compiled to a small browser bundle.

## Core architecture

Make the PureScript SSR layer **pure `ViewModel -> String`**. Node does all IO (DB, Stripe, batch status, auth, money/date formatting) and passes each render function a flat record of only JS-friendly types (`String`/`Int`/`Boolean`/`Array String`) — the same convention `src/Main.purs` already uses for `Order`/`Account`/`Batch`. SSR modules import only `Prelude`, `Data.String/Array/Maybe`, and the new `Html` DSL — **never** `web-*`, `halogen`, or anything browser-coupled. This keeps the Node bundle free of `window`/DOM/`@stripe/stripe-js`.

## File structure

New PureScript — server-side (compiled, then bundled for Node):
- `src/Html.purs` — tiny HTML DSL: `el`/`text`/`attr`/`raw`, producing escaped `String` (escape `& < >` in text; `& < > "` in attrs; `raw` only for server-trusted fragments, never user input). Dependency-light, matches repo style — no new view library.
- `src/Views/Layout.purs` — `<!doctype>` shell: head (meta/OG/favicons/Architects-Daughter font/Umami script ported from `index.html` + manifest-resolved CSS/JS links), header (wordmark `mark-512.png` + "birdhaus", `Cart · N` when qty>0, account nav), `<main>`.
- `src/Views/Product.purs` — product two-column + `featureSection`/`specSection`/`trustStrip`/`faqSection` (native `<details>`), purchase block, sold-out block, waitlist embed. Port of `storefront`/`feature*`/`spec*`/`trust*`/`faq*`.
- `src/Views/Cart.purs` — cart page **and** the `#cart` fragment (line, stepper, subtotal, actions, fine-print).
- `src/Views/Checkout.purs` — checkout page with exact Stripe mount ids (`#payment-form`,`#email`,`#shipping-address`,`#payment-element`,`#payment-message`,`#submit-payment`), totals, back-to-cart.
- `src/Views/Confirmation.purs` — succeeded/processing/failed/error states, `orderSummary`, `receiptNote`, `backToStore`. Port of `paymentCompleteView`.
- `src/Views/Waitlist.purs` — the 4 states (Joined / member form / sign-up CTA / guest form) as a reusable fragment.
- `src/Server/Render.purs` — **bundle entry**; re-exports one single-record-arg fn per surface: `productPage`, `cartPage`, `cartFragment`, `checkoutPage`, `confirmationPage`, `waitlistFragment`. Only module Node imports.

New PureScript — client-side (compiled, bundled for the browser via Vite):
- `src/Client/Main.purs` — entry; runs analytics on every page, the Stripe flow when `#payment-form` exists, `preorder-paid`-once on `/order` from server-rendered `data-order-*` attrs.
- `src/Client/Stripe.purs` + `src/Client/Stripe.js` — Stripe Elements flow lifted ~verbatim from `src/Main.js` (`loadStripe`, elements, shipping+payment mount, `elements.submit()`, `shippingAddress.getValue()`, `stripe.confirmPayment({ return_url: ${origin}/order })`).
- `src/Client/Analytics.purs` + `src/Client/Analytics.js` — `track`/`identify`/`trackPaidOnce` (sessionStorage guard) + the `?auth=in`→`login` dance, lifted from `Main.js`.
- `src/client-entry.js` — Vite entry (replaces `src/client.js`): `import "htmx.org"; import "./style.css"; import { main } from "../output/Client.Main/index.js"; main();`

New Node modules:
- `server/cookies.js` — factor the module-private helpers out of `server/auth.js` (`sign`/`unsign` HMAC-SHA256 on `SESSION_SECRET`, `cookies`, `cookieOptions`, `secure`) and export them; `auth.js` imports them (keeps `SESSION_COOKIE`/TTL).
- `server/cart.js` — cookie `bh_cart` (`{qty, exp}`, 30d, httpOnly, signed via `cookies.js`): `readCart`/`writeCart`/`clearCart`, clamp 1–99. Unsigned-JSON fallback when `SESSION_SECRET` absent (safe: quantity+price re-validated at checkout).
- `server/price.js` — single authoritative `UNIT_PRICE_CENTS = 4000` + `formatUsd(cents)`; imported by create-intent **and** every view model (replaces the AGENTS.md "two places" price rule with one source).
- `server/order-format.js` — `formatOrder` logic moved server-side from `Main.js` (currency via Intl, order number = last 8 upper, date, address lines).

Removed: `src/Main.purs`, `src/Main.js`, `src/client.js`, `index.html` as a Vite entry (head moves into `Views/Layout`); spago deps `halogen`/`halogen-vdom`/`web-events` (add `strings`/`arrays`/`foldable-traversable`, regenerate `spago.lock`); the Express catch-all + in-memory `indexHtml`.

## Express routes (`server/index.js`)

Delete the SPA catch-all (`app.get(/.*/…)`) and `indexHtml`. Keep `/assets` immutable + `dist` static (no-cache). Add after static mounts:
- `GET /` → `productPage(vm)`; vm from `batchStatus(batch, await paidUnits())` (move the `<20% remaining` reveal here from `/api/batch`), `displayDate`, `accountOf`, `readCart().qty`, `authEnabled`/`signUpUrl`, `UNIT_PRICE_CENTS`. `no-cache`.
- `GET /cart` → `cartPage(vm)` (empty-cart variant if qty 0). `GET /checkout` → 303 `/cart` if empty, else `checkoutPage(vm)`. Both `no-cache`.
- `GET /order` → **`no-store`**; reuse the `/api/order` gate via extracted `lookupOrder(req)`; render `confirmationPage(vm)` with money/date pre-formatted; embed `data-order-*`.
- `POST /cart/add` (form `quantity`) → `writeCart`, 303 `/cart` (baseline, JS-off friendly).
- `POST /cart/update` → clamp, `writeCart`; if `HX-Request` return `cartFragment` (+ `hx-swap-oob` header badge) else 303 `/cart`.
- `POST /cart/clear` → `clearCart`, 303 `/`.
- `POST /waitlist` → same validation/account-gate/`db.joinWaitlist` as today's `/api/waitlist` but returns a `waitlistFragment` (Joined / error reshow / sign-up CTA) instead of JSON.

Unchanged: `/api/stripe-webhook`, `/api/auth/*`, `/api/me`, `/api/health`, `/api/create-payment-intent` (quantity now from `readCart().qty`, `amount = qty * UNIT_PRICE_CENTS`), `/api/order` kept behind shared `lookupOrder`. `/api/batch` can be dropped (stock rendered server-side). Checkout/confirmation are **full navigations**, so the client module runs on normal load — no `htmx:afterSwap` hook needed for Stripe.

## Build pipeline (`package.json`, `vite.config.js`, Dockerfile)

Keep Vite as the **client/asset bundler only** (it already gives content-hashing for the immutable-`/assets` invariant, `public/` copy, and bundles `@stripe/stripe-js` + `htmx.org`; avoids a new forbidden bash/node script). SSR is bundled separately for Node.
- `vite.config.js`: `build: { outDir:"dist", manifest:true, rollupOptions:{ input:"src/client-entry.js" } }`; drop the `/api` dev proxy.
- SSR bundle via the existing `scripts/spago-local-cache.hs` (already forwards any subcommand to spago): `spago bundle --module Server.Render --platform node --outfile server/views.js --minify` (add `--bundler-args "--format=esm"` if the default isn't ESM-with-named-exports). Lands under `server/` so `COPY server` ships it. Add `server/views.js` to `.gitignore`.
- Scripts: `build:ssr` (the bundle), `build = build:purs && build:ssr && vite build`, `dev = build:purs && concurrently "vite build --watch" "node server/index.js"` (single origin on 4242, no proxy).
- Server imports SSR dynamically: prod (`NODE_ENV=production`) → `./views.js`; dev → `../output/Server.Render/index.js` (ESM, no bundle needed to iterate).
- Asset URLs: server reads `dist/.vite/manifest.json` (at boot in prod, per-request in dev), resolves `src/client-entry.js` → `.file` (script) + `.css[0]` (stylesheet), passes both into `Layout`.
- Move `@stripe/stripe-js` to devDependencies; add `htmx.org` to devDependencies (both only bundled at build; image runs neither Vite nor these as runtime deps). Dockerfile needs no structural change (`COPY server` carries `views.js`; `COPY dist` carries hashed assets + manifest); confirm `.dockerignore` keeps `dist/.vite/manifest.json`.

## Invariants to preserve

- Server sets price (quantity from signed cart cookie, `amount = qty * UNIT_PRICE_CENTS`); never trust a browser amount.
- `/api/order` + `/order`: keep `^pi_…$`, `client_secret.startsWith(`${id}_secret_`)`, `=== intent.client_secret`, and `no-store` — all inside `lookupOrder`.
- Orders written **only** by the webhook (idempotent on PaymentIntent id, 500-on-DB-error so Stripe retries); pages/cart write nothing to `orders`.
- Fail-open: `paidUnits()` null on DB-down keeps batch open; cart is a cookie (no DB); guest checkout never gated on auth (`accountOf` only *attaches* metadata); cart works signed-out and without `SESSION_SECRET`.
- `/api/health` unchanged; `/assets` immutable, pages `no-cache`, `/order` `no-store`.

## Rollout

1. `npm run dev`, verify full flow with Stripe test keys locally.
2. Deploy to dev via `scripts/dev-store.hs` (drives `run.hs` → `birdhaus-store-dev`, `dev.birdhaus.store`, test Stripe, `birdhausdev` DB). `run.hs` already runs `npm ci && npm run build`, so `build:ssr` + manifest run automatically — no `run.hs` change.
3. Verify end-to-end on `dev.birdhaus.store` (below), then promote to prod with `./run.hs --project <project> --pull-secret <secret>` (preserve live `--cap/--closes/--ship-by`; ask first — it replaces the running instance).

## Verification

- Happy path: `/` renders product (fonts, illustration, feature/spec/trust/FAQ, `$40.00 USD each`, preorder note) → add-to-cart (works with JS and with JS **disabled** via form POST→303) → `/cart` (line, subtotal, stepper updates `#cart` + header badge via HTMX, also works as plain submit) → `/checkout` mounts Stripe elements → pay `pm_card_visa` → returns to `/order` → "Thank you for your pre-order", summary, receipt; `preorder-paid` fires once (reload doesn't double-count).
- Decline `pm_card_chargeDeclined` → failed state. Tamper `bh_cart` → checkout still prices from clamped/validated qty.
- Waitlist: signed-in (no email field) → Joined fragment; guest w/ auth → sign-up CTA; guest-only deploy → email form; bad quantity → error fragment.
- Sold-out/closed (low `BATCH_CAP` / past `BATCH_CLOSES_AT`) → sold-out variant + waitlist; create-intent 409.
- Real URLs: back/forward/refresh on `/`,`/cart`,`/checkout`,`/order`.
- Fail-open: stop Postgres → store serves, cart works, guest checkout completes, `/api/health` reports failing; restart → webhook records on Stripe retry.
- `curl -I`: `/assets/*` immutable, pages `no-cache`, `/order` `no-store`. Post-bundle: `grep -E 'window|document|@stripe' server/views.js` is empty.

## Key risks

- Browser globals in the Node bundle — prevented by the pure `ViewModel -> String` boundary; **verify** with the grep above before the dev deploy.
- `spago bundle` node/ESM format — dev imports `output/` directly so a mismatch only bites at prod-bundle; verify named exports before deploying.
- htmx vendored via `import "htmx.org"` (hashed, offline) not a CDN tag.
- `return_url` moves to `/order`; deploy in a quiet window (or temporarily also handle `/?payment=complete`) so in-flight checkouts aren't orphaned.
- DSL escaping: user text (waitlist errors, emails) via `text`, never `raw`.

## Critical files
- `server/index.js` (route restructure, cart wiring, SSR import, manifest read)
- `src/Main.purs` → port markup into `src/Views/*` + `src/Html.purs`
- `src/Main.js` → relocate Stripe/analytics into `src/Client/*`
- `server/auth.js` → factor cookie helpers into `server/cookies.js` (reused by `server/cart.js`)
- `package.json`, `vite.config.js` (build + dev); `spago.yaml`, `Dockerfile`, `.gitignore` (secondary)
