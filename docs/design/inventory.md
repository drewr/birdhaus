# Inventory

## Context

The only stock limit used to be the pre-order cap, `BATCH_CAP=20`, set by the
deploy and counted down by paid orders. Changing it meant a deploy, and a sold-out
product offered a waitlist form with a quantity and ZIP. The owner now sets how
many of each product are available at `/admin/inventory`, and shoppers see the
count when it's low and a "Notify me when available" button when it's gone.

## Decisions

- **The inventory replaces the batch cap.** Migration 010 started the Bluebird
  House at 20 minus its paid orders in `xmas-2026`, so shoppers saw no change.
  The store no longer takes pre-orders, so the batch's closing and ship-by dates
  are gone too; orders still record the batch ID (`server/batch.js`).
- **Tracking is set in code.** `inventory: true` in `server/products.js` marks a
  tracked product. The server knows that even with the database down, so it can
  stop selling the product. Demo Thing isn't tracked and is always available.
- **A tracked product stops selling while the database is down.** This is the
  one exception to "keep selling when Postgres is down". The product page shows
  "Temporarily unavailable", the cart keeps its contents but hides checkout, and
  checkout redirects to the cart. Untracked products keep selling.
- **Refunds don't restock.** A refunded house may not be resellable, so the
  owner adds units back by hand.

## How it works

- **Data** (migration 010):
  - `inventory`: one row per tracked product with its `available` count. A
    tracked product without a row counts as 0.
  - `inventory_changes`: every change, by an admin, an order or the seed.
  - `restock_requests`: one row per product and account email, with
    `notified_at` set once it's emailed. Rows from the old `waitlist` table
    were copied in, so people already waiting get the email too. `waitlist` is
    kept but no longer written.
- **Reading stock:** `inventory.stock(product)` (`server/inventory.js`) returns
  `{ open, reason, remaining }`. `availability()` in `server/index.js` adds the
  batch close date.
- **Orders count down in the webhook.** `db.recordOrder` inserts the order,
  decrements the count and logs the change in one statement, decrementing only
  when the insert happened. A redelivered event doesn't count twice.
- **The count may go below zero.** Two shoppers can pay for the last unit within
  seconds of each other: checkout checks stock when it creates the
  PaymentIntent, but the count only drops when the payment succeeds. Both orders
  are kept, and the admin page shows "Oversold by N".
- **Admin edits are compare-and-set.** Each form carries the count the admin
  saw (`expected`). If an order changed it meanwhile, the save is refused with
  "The count changed while you were editing" and the page shows the current
  number.

## Prices

- **Admins set each product's price** on the same page, tracked or not.
  `server/price.js` reads it from the `prices` table (migration 011); a product
  without a row sells at its built-in price there. Prices run from $0.50, Stripe's
  minimum, to $1,000.
- **Changes are logged** in `price_changes` and listed with the stock changes
  under "Recent changes". Saving the price already charged logs nothing.
- **A database blip keeps the owner's price.** Each instance remembers the last
  price it read and charges that until the database answers again; only an
  instance that has never read one falls back to the built-in price.
- **A price that changes mid-checkout isn't charged unseen.** The pay page sends
  the total it showed with `/api/create-payment-intent`. If the server's amount
  differs, it refuses with a 409 giving the new total, and the shopper reloads.
  The amount charged is still only the server's.
- **Paid orders keep what they paid.** Orders record Stripe's amount, so a later
  price change doesn't touch them.

## Shopper experience

- **Product page:**
  - With 3 or fewer left (`inventory.LOW`), "Only N left" sits beside the
    quantity.
  - The quantity can't go past what's left minus what's already in the cart.
    When the cart already holds everything left, the page says so instead of
    offering Add.
  - Sold out: "Sold out" replaces the quantity, and the button reads "Notify
    me when available". Signed in, it posts `/notify`; signed out, it links to
    sign-in and back. Once asked, the
    page says "We'll email … when it's available again".
- **Listing:** "In stock", "Only N left", "Sold out" or "Temporarily
  unavailable".
- **Cart** (checked on every visit):
  - Asking for more than is left fills the cart to what's left.
  - A cart holding more than is left is cut down, with "Only N available, so we
    changed your quantity to N" under the item.
  - A sold-out product is removed, saying so, with a link back to its page to
    ask to be notified.
- **Checkout** (`/checkout`, `/checkout/delivery`, `/checkout/pay`) redirects to
  the cart whenever the cart doesn't fit the stock, so the cart's notice
  explains. `/api/create-payment-intent` refuses such an order with a 409.

## Owner experience

- `/admin/inventory` lists every product. A tracked product shows:
  - its available count, with Save;
  - units sold;
  - how many people are waiting, linking to `/admin/users?waiting=<slug>`,
    which lists them oldest request first;
  - its last ten changes, under "Recent changes".
- **Emailing the people waiting:** once the count is above 0, "Email N people
  that it's back" sends each one a single restock email (`mail.restockEmail`)
  and marks them notified. A failure part way leaves the rest waiting, so
  clicking again retries without emailing anyone twice.
- **Low-stock email:** when an order takes a product from above 3 to 3 or
  fewer, and again when it reaches 0 or below, `mail.stockAlertEmail` goes to
  `STOCK_ALERT_EMAIL`. `run.hs --alert-email` sets it; prod deploys read it
  from the `ALERT_EMAIL` repository variable, so the address stays out of the
  repository. Without it the alert is only logged. Dev doesn't send alerts.

## Open work

- `scripts/demand.hs` still takes `--cap` and reads the old `waitlist` table.
  It should read `inventory` and `restock_requests` instead.
- Stock isn't reserved while a shopper pays, which is why the count can go
  negative. Reserving it would need an expiring hold per PaymentIntent.
