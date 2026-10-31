# Plan: Local delivery (radius-limited, flat fee, delivery slots) with wallet address pre-fill

## Context

The fulfillment change in progress (`docs/design/fulfillment.md`) makes checkout a delivery step with local **pick-up** at admin-defined slots, with shipping greyed out until USPS. The owner now wants a third option, **local delivery**:

- Available only to addresses within a **configurable radius** of a home base, measured on the **exact street address** with the free **US Census Geocoder**.
- Costs a **configurable flat fee per order**.
- Happens in **admin-defined delivery slots** the buyer picks, like pick-up.
- When the buyer pays with **Apple Pay / Google Pay**, the wallet should **pre-fill the delivery address** (plus name, email and phone). This uses Stripe's **Express Checkout Element** (ECE). The current Payment Element never requests an address from wallets.

Constraint that shapes the design: while the wallet sheet is open, the address is **redacted to city, state, ZIP and country**. The street arrives only in the ECE `confirm` event. So the in-sheet radius check uses the **ZIP centroid**. The exact-address Census check runs at confirm time, before the charge.

**Depends on** the fulfillment change landing first: two-step checkout, `server/pickup.js`, the admin portal, `requireAdmin`, and the `orders.fulfillment` column.

## Data (new migration `server/migrations/006_local_delivery.sql`)

- `delivery_settings`: a single row (`id int primary key check (id = 1)`) with:
  - `enabled bool default false`
  - `fee_cents int not null default 0 check (fee_cents >= 0)`
  - `radius_miles numeric not null default 10 check (radius_miles > 0)`
  - `base_address text`, `base_lat double precision`, `base_lon double precision`, `updated_at`
- `delivery_slots(id serial pk, starts_at timestamptz, ends_at timestamptz check (ends_at > starts_at), active bool default true)`, plus an index on `starts_at`. This is a separate table from `pickup_slots`, so pick-up semantics stay untouched.
- `orders`:
  - Widen the `fulfillment` check to `('ship','pickup','delivery')`.
  - Add `fee_amount int not null default 0` (cents), `delivery_slot_id int`, `delivery_label text`, and `address_check text` (`'exact'` or `'zip'`, recording how the radius was verified).
  - The delivery address and phone already land in the existing `orders.shipping` jsonb from `intent.shipping`.

## Server

**`server/geocode.js`** (new):
- `geocodeAddress({ line1, city, state, postal_code })` calls `GET https://geocoding.geo.census.gov/geocoder/locations/address?street=&city=&state=&zip=&benchmark=Public_AR_Current&format=json`. It returns `{ lat, lon }` from `result.addressMatches[0].coordinates` (`y` is latitude, `x` is longitude), or null. Timeout: 5 s. Confirm the exact parameters against the Census docs while implementing.
- `zipCentroid(zip)` looks the ZIP up in the bundled `server/data/zcta-centroids.json`.
- `milesBetween(a, b)` is a haversine.
- Records `lastGeocodeFailure` for `/api/health`, matching the existing pattern; no extra calls.

**`scripts/zcta-centroids.hs`** (new turtle script): downloads the current Census Gazetteer ZCTA file (`…/gazetteer/<year>_Gazetteer/<year>_Gaz_zcta_national.zip`). It writes `server/data/zcta-centroids.json` (`{ "78701": [lat, lon], … }`, about 33k entries, under 1 MB) from `GEOID`, `INTPTLAT` and `INTPTLONG`. The output is committed, and the script is re-run yearly.

**`server/delivery.js`** (new):
- `settings()`, `saveSettings({ enabled, fee, radius, baseAddress })`. Saving geocodes the base address once and refuses to save if Census can't match it.
- `upcomingSlots()`, slot CRUD and labels in `America/Chicago`, mirroring `server/pickup.js` (reuse its formatting helper).
- `checkZip(zip)`: centroid distance compared with `radius_miles`. Used in the wallet sheet.
- `checkAddress(addr)`:
  1. Census exact geocode → `{ ok, check: 'exact' }`.
  2. If Census fails or finds no match, fall back to `checkZip` → `{ ok, check: 'zip' }`. These are flagged for the admin. The fallback is fail-open so a Census outage doesn't block sales; the fee and radius are still enforced by ZIP.
  3. An address outside the radius → `{ ok: false }`.

**`server/cart.js`**: the cart gains `fulfillment: 'delivery'` and a delivery `slot`, alongside pick-up's slot. The fee is never stored in the cookie.

**`server/index.js`**:
- **Delivery step** (`GET /checkout`): a "Local delivery — $fee" option is shown when settings are enabled, a base location is set and upcoming delivery slots exist. It lists those slots and adds the note "within N miles of …".
- `POST /checkout/delivery` accepts `fulfillment=delivery` plus a slot.
- **Pay page** for delivery: breakdown of houses, delivery fee, total, and "Delivery: slot label".
- `POST /api/create-payment-intent`: for delivery, `amount = qty × UNIT_PRICE_CENTS + fee_cents`. The fee is read from settings at this moment. Metadata adds `fulfillment`, `fee_cents`, `delivery_slot_id` and `delivery_label`.
- New `POST /api/delivery/check-zip`: `{ postal_code }` → `{ ok }`, ZIP centroid only. Used by the wallet sheet's `shippingaddresschange`.
- New `POST /api/delivery/verify`: `{ address, name, phone }`.
  - Runs `checkAddress`.
  - If it passes, **updates the PaymentIntent server-side**: `stripe.paymentIntents.update(id, { shipping: { name, phone, address }, metadata: { address_check } })`. The PaymentIntent is identified by the client secret the page holds, validated the way `lookupOrder` validates it.
  - Returns `{ ok }`, or a message such as "That address is outside our N-mile delivery area."
  - The server thereby records exactly which address passed the check.
- `/order` confirmation: "Delivery: slot label, to <address>".
- `/api/health`: adds a `geocoder` failure line, the same way as the webhook line.

**`server/db.js`**: `recordOrder` stores `fulfillment`, `fee_amount`, `delivery_slot_id`, `delivery_label` and `address_check` from metadata.

**Admin**, behind `requireAdmin`:
- `GET /admin/delivery`:
  - Settings form: enabled, fee in dollars, radius in miles, base address. It shows the matched coordinates or "Census couldn't find that address".
  - Delivery slots CRUD.
  - Delivery schedule: per slot, buyer name, phone, address, quantity, and a flag on `address_check = 'zip'`.
- Matching `POST` routes, each a 303 back. Add a link in the admin navigation.

## Client (`src/Client/Main.js`)

The pay page carries `data-fulfillment`, `data-fee` (for display only; never trusted) and `data-slot-label`.

**Delivery:**
- **Express Checkout Element** (wallets), configured with `shippingAddressRequired: true`, `allowedShippingCountries: ['US']`, `emailRequired`, `phoneNumberRequired`, and `shippingRates: [{ id: 'local', displayName: 'Local delivery — <slot>', amount: fee }]`.
- On `shippingaddresschange`: call `/api/delivery/check-zip`, then `resolve()` to keep the rate or `reject()` so the sheet shows the address as invalid.
- On `confirm`: call `/api/delivery/verify` with `event.shippingAddress`, name and phone. On failure, call `event.paymentFailed({ reason: 'invalid_shipping_address' })`. On success, call `stripe.confirmPayment({ elements, confirmParams: { return_url: '/order', receipt_email } })`.
- **Card path:** the Address Element (`mode: 'shipping'`, `allowedCountries: ['US']`, `fields.phone: 'always'`) plus the Payment Element. On submit, read `addressElement.getValue()`, call `/api/delivery/verify`, then `confirmPayment`. An out-of-area address shows the server's message.

**Pick-up** (bonus, cheap): mount the ECE with `emailRequired` so wallet buyers skip typing their email. No address is requested.

ECE and Payment Element share the same `elements` instance, created from the client secret. Check the option names against Stripe's ECE docs while implementing.

## Views (PureScript)

- `Render.purs`: the delivery option on the delivery page, the pay-page breakdown and the delivery mount points, and the confirmation delivery line.
- `Admin.purs`: the delivery settings, slots and schedule page.
- Fine print: "Local pick-up, or local delivery within N miles for $fee. Shipping coming soon."

## Config and docs

- No new secrets; Census needs no key.
- AGENTS.md: document the delivery radius and fee settings, the Census dependency and its ZIP fallback, the ZCTA data file and how to refresh it.
- Commit this plan as `docs/design/local-delivery.md`.

## Rollout

After the fulfillment change is merged and verified on dev:
1. Implement this change on dev, then run migration 006.
2. In the dev admin, set the base address, radius, fee and a delivery slot.
3. Verify (below), then promote to prod after approval with delivery settings in place. Delivery stays `enabled = false` until the owner switches it on.

## Verification

- `npm run build` with 0 warnings. The `server/views.js` browser-globals grep returns 0. The ZCTA JSON loads, and a known ZIP gives its centroid.
- **Geocoder:** a real in-area street address → `exact` and ok. An out-of-area address → rejected with the radius message. A nonsense street → falls back to `zip`. With the Census URL pointed at a dead host → falls back to `zip`, and `/api/health` reports geocoder failing.
- **Wallet (dev, test mode, real device):** Apple Pay / Google Pay sheet → choose an in-area address → the fee shows as the rate → pay. The order row has `fulfillment = delivery`, `fee_amount`, `delivery_label`, `address_check = exact`, and `shipping` with address and phone. An out-of-area address in the sheet is rejected.
- **Card path:** the Address Element is filled in and the server-verified address lands on the PaymentIntent (`intent.shipping`) and the order. Changing to an out-of-area address blocks payment.
- **Tampering:** the client can't lower the fee (the amount is server-computed). Calling verify with a different client secret returns 404. Skipping verify leaves `intent.shipping` empty, and the admin schedule flags the missing address.
- **Admin:** settings save geocodes the base address, an unmatched base address is refused, slots CRUD works, the schedule lists deliveries, and non-admins get 404.
- **Fail-open:** Census down → ZIP-based check and flagged orders. Database down → delivery and pick-up unavailable, the store still renders.
