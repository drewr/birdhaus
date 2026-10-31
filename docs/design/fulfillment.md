# Plan: Delivery choice at checkout (local pick-up now, shipping greyed out) and a store admin portal

## Context

Checkout today has a single path: Stripe's Address Element collects a shipping address, and the price excludes shipping. The owner wants buyers to choose a delivery method. In the end that means USPS-priced shipping or free local pick-up at a time slot the store defines. The owner doesn't have a USPS API key yet, so for now:

- **Shipping is shown greyed out ("Shipping — coming soon")** and can't be selected. **No USPS code is written in this change.** A later change adds it once a key exists (research is in Notes below).
- **Local pick-up is the only way to order.** It's free, at a location and time slot the store defines. The buyer picks a slot, and slots have no capacity limit.
- Pick-up locations and slots are managed in a new **store admin portal**. Access is membership in a Rauthy **group** (`birdhaus-admins`) that any user can be added to. This is separate from Rauthy's own admin role and admin UI. Members see an **Admin** link in the header.

Rauthy facts:
- Requesting scope `groups` adds a `groups` claim (an array of group names) to the id_token the store already verifies.
- Each store client must list `groups` in its **Allowed Scopes**, or Rauthy silently drops it.
- Membership is copied into the token at sign-in, so removal takes effect at the next sign-in.
- A `birdhaus-admins` group grants nothing inside Rauthy itself.

## Data (new migration `server/migrations/005_pickup.sql`)

- `pickup_locations(id serial pk, name text not null, details text not null default '', active bool not null default true, created_at timestamptz not null default now())`. `details` holds the address and instructions shown to buyers.
- `pickup_slots(id serial pk, location_id int not null references pickup_locations, starts_at timestamptz not null, ends_at timestamptz not null check (ends_at > starts_at), active bool not null default true)`, plus an index on `starts_at`.
- `orders` gains:
  - `fulfillment text not null default 'ship' check (fulfillment in ('ship','pickup'))`. Past orders read as `ship`.
  - `pickup_slot_id int`, with no foreign key, so admin edits never block the webhook.
  - `pickup_label text`, a snapshot such as "Austin Farmers Market — Sat Dec 13, 9–11am CST".

Shipping columns (`shipping_amount`, `quoted_zip`) come later with the USPS change.

## Server

**`server/pickup.js`** (new):
- `upcomingSlots()`: active slots at active locations where `starts_at > now()`, ordered by time.
- `slotById(id)` and `slotLabel(slot)`, both formatted in `America/Chicago`.
- Admin helpers:
  - `listLocations`, `createLocation`, `setLocationActive`
  - `listSlots` (upcoming and recent), `createSlot`, `setSlotActive`
  - `pickupSchedule()`: paid pick-up orders grouped by slot (email, quantity)
  - `recentOrders(n)`

**`server/cart.js`**: the signed cart cookie gains `slot` (a pick-up slot id) alongside `qty`. Nothing price-related goes in the cookie.

**`server/auth.js`**
- Scope becomes `openid email profile groups`.
- On callback, `admin = Array.isArray(payload.groups) && payload.groups.includes(ADMIN_GROUP)`, where `ADMIN_GROUP` is an env var defaulting to `birdhaus-admins`. The session stores `admin` and `adminUntil = now + 12h`.
- `accountOf` returns `admin: true` only while `adminUntil` hasn't passed. After that, admin pages bounce through `/api/auth/login?next=/admin` to refresh the claim, which keeps revocation lag at roughly 12 hours instead of the 7-day session.
- Export `requireAdmin` middleware:
  - Signed-out users are redirected to sign in.
  - Signed-in users who aren't admins get 404.
  - `Cache-Control: no-store`, since the pages hold PII.
  - POSTs must carry a same-origin `Origin` header. Cookies are already `SameSite=Lax`.

**`server/index.js`** (reuse `chrome()`, `readCart`/`writeCart`, `batchStatus`, `formatTotal`, `lookupOrder`, `stepperLimit`):
- `chrome()` adds `isAdmin`.
- **Checkout becomes two steps:**
  - `GET /checkout`: the **delivery** step.
    - Shipping is a disabled radio, "Shipping — coming soon".
    - Pick-up offers a radio list of `upcomingSlots()`, each showing the location name, details and time.
    - If there are no upcoming slots, or the database is down, it says "No pick-up times are open right now — check back soon" and has no Continue button.
  - `POST /checkout/delivery`: validates that the slot exists, is active and is in the future. Writes `slot` to the cart, then 303 to `/checkout/pay`. Errors re-render the step. Plain form POST.
  - `GET /checkout/pay`: the payment page plus a breakdown: houses subtotal, "Pick-up: label — free", Total, and a "Change pick-up time" link. Redirects to `/checkout` if the cart has no valid slot.
- `POST /api/create-payment-intent` re-validates the slot from the cart (it must be active and in the future, otherwise 409 "Choose a new pick-up time").
  - `amount = qty × UNIT_PRICE_CENTS`, unchanged.
  - Metadata adds `fulfillment: "pickup"`, `pickup_slot_id` and `pickup_label`.
  - The description mentions pick-up.
- `/order`, `lookupOrder` and `server/order-format.js` pass `fulfillment` and `pickupLabel` from metadata. The confirmation shows "Pick-up: label" instead of "Ship to".
- **Admin routes**, all behind `requireAdmin`:
  - `GET /admin`: recent orders (number, date, email, quantity, total, status, method and pick-up label).
  - `GET /admin/pickup`: locations, slots, and the pick-up schedule (buyers per slot).
  - `POST /admin/pickup/locations`, `POST /admin/pickup/locations/:id/active` (enable/disable), `POST /admin/pickup/slots` (location, date, start and end time in US Central), `POST /admin/pickup/slots/:id/active`. Each is a 303 back to `/admin/pickup`.

**`server/db.js`**: `recordOrder` stores `fulfillment`, `pickup_slot_id` and `pickup_label` from intent metadata, and stays idempotent on the PaymentIntent id. Orders with no `fulfillment` in metadata default to `ship`.

## Views (PureScript)

- `src/Server/Render.purs`:
  - New `deliveryPage`.
  - `checkoutPage` gains the breakdown and drops the "Shipping address" label and mount point.
  - The confirmation shows the pick-up line.
  - The header gets `<a href="/admin">Admin</a>` when `isAdmin`.
  - Fine print on the product and cart pages becomes "Local pick-up only for now — shipping coming soon. Taxes not included."
- New `src/Server/Admin.purs` holds `adminOrdersPage` and `adminPickupPage`: plain tables and POST forms, re-exported through the `Server.Render` bundle entry, using the same `Html` DSL.
- Small CSS additions in `src/style.css`: the delivery options list, the disabled option styling, and admin tables.

## Client (`src/Client/Main.js`)

- Stop mounting the Address Element; pick-up needs no address. The Payment Element and email field stay.
- `confirmPayment` drops shipping; `return_url` stays `/order`.

## Config and docs

- `run.hs` and `scripts/dev-store.hs` gain `--admin-group` (default `birdhaus-admins`), which becomes the `ADMIN_GROUP` env var.
- Update AGENTS.md:
  - The price rule now points to `server/price.js`. The current text about `formatTotal` in `Main.purs` is outdated.
  - Document the admin group.
  - Pick-up only until USPS is added.
- Update the README.
- Commit this plan as `docs/design/fulfillment.md`, including the USPS notes for the follow-up.

## Manual steps for the owner (Rauthy Admin UI; can't be scripted)

1. Create the group `birdhaus-admins` and add yourself and other admins.
2. On **both** store clients (prod and dev), add `groups` to **Allowed Scopes**. Don't set "Login Group Prefix".
3. Sign out and back in on the store so the token carries the group.

## Rollout

Build and verify on dev (`scripts/dev-store.hs`, with migration 005 applied automatically on boot). Create a test location and slot in the dev admin. Promote to prod with `run.hs` only after approval, and only after prod has at least one pick-up slot. Otherwise nobody can check out.

## Verification

- `npm run build` with 0 PureScript warnings. `grep` confirms `server/views.js` has no browser globals.
- **Admin access:**
  - A `birdhaus-admins` member sees the Admin link.
  - A non-member gets 404 at `/admin`, and a signed-out visitor is sent to sign in.
  - A cross-origin POST is rejected.
  - After removing a member, access ends within 12 hours or at their next sign-in.
- **Admin pick-up management:** create a location and a slot, see it in checkout, disable it, and see it disappear.
- **Pick-up purchase on dev:**
  - add → `/checkout` shows shipping disabled → choose a slot → `/checkout/pay` shows "Pick-up … free" with no address form → pay with `pm_card_visa`.
  - The order row has `fulfillment = pickup` and `pickup_label`.
  - The confirmation and the admin schedule both show it.
- **No slots:** the delivery step shows the "check back soon" message, and create-intent refuses with 409.
- **Tampering:** a stale, inactive or invented slot id in the cookie is rejected at `/checkout/pay` and at create-intent.
- **Fail-open:** with the database down, pick-up is unavailable and checkout says so. The store pages still render. Auth down only hides the Admin link; it never blocks checkout.

## Notes for the later USPS change (researched, not built now)

- Domestic Prices 3.0: `POST https://apis.usps.com/prices/v3/base-rates/search`, with an OAuth client-credentials token from `/oauth2/v3/token`.
  - Fields: `mailClass` `USPS_GROUND_ADVANTAGE`, `processingCategory` MACHINABLE, `rateIndicator` SP, `priceType` RETAIL, `weight`/`length`/`width`/`height`, and the origin and destination ZIPs.
  - The price is in `totalBasePrice`.
- Limited to 60 calls per hour, so cache quotes by ZIP for the day. The test host is `apis-tem.usps.com`.
- Needs a USPS Business Account app (key and secret), a ship-from ZIP, and real package specs (placeholder: 3 lb, 12×9×9 in). Price per house.
