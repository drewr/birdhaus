import * as db from "./db.js";
import * as mail from "./mail.js";
import * as price from "./price.js";
import { products } from "./products.js";

// Stock for products with inventory: true (docs/design/inventory.md). Admins
// set the count at /admin/inventory; each paid order counts it down
// (db.recordOrder). A tracked product with no row has none available.

// At or below this many, the product page says how many are left and the owner
// gets an email.
export const LOW = 3;

// { open, reason, remaining }: remaining is null for an untracked product (no
// limit). A tracked product stops selling when the count can't be read, so an
// outage never sells stock that isn't there.
export async function stock(product) {
  if (!product.inventory) return { open: true, reason: "open", remaining: null };
  let available;
  try {
    if (!db.isConfigured()) throw new Error("PGHOST is not set");
    const { rows } = await db.query("select available from inventory where product = $1", [product.slug]);
    available = rows[0]?.available ?? 0;
  } catch (error) {
    console.error(`Could not read stock for ${product.slug}; not selling it:`, error.message);
    return { open: false, reason: "unavailable", remaining: 0 };
  }
  const remaining = Math.max(available, 0);
  return { open: remaining > 0, reason: remaining > 0 ? "open" : "sold-out", remaining };
}

// The last ten changes to each product's count or price, newest first.
const RECENT = (table) =>
  `select * from (
     select *, row_number() over (partition by product order by at desc, id desc) as n from ${table}
   ) recent where n <= 10 order by at desc, id desc`;

// Every product for the admin page: its count (null when untracked), price,
// paid units, people waiting to hear it's back, and its last ten changes
// (kind "stock" or "price").
export async function list() {
  const [counts, prices, sold, waiting, stockChanges, priceChanges] = await Promise.all([
    db.query("select product, available, updated_at, updated_by from inventory"),
    price.saved(),
    db.query("select product, sum(quantity)::int as units from orders where status = 'paid' group by product"),
    db.query("select product, count(*)::int as people from restock_requests where notified_at is null group by product"),
    db.query(RECENT("inventory_changes")),
    db.query(RECENT("price_changes"))
  ]);
  const changes = [
    ...stockChanges.rows.map((row) => ({ ...row, kind: "stock" })),
    ...priceChanges.rows.map((row) => ({ ...row, kind: "price", reason: "admin" }))
  ].sort((a, b) => b.at - a.at);
  const count = new Map(counts.rows.map((row) => [row.product, row]));
  const units = new Map(sold.rows.map((row) => [row.product, row.units]));
  const people = new Map(waiting.rows.map((row) => [row.product, row.people]));
  return products.map((product) => ({
    product,
    available: product.inventory ? (count.get(product.slug)?.available ?? 0) : null,
    updated: count.get(product.slug) ?? null,
    cents: prices.get(product.slug)?.cents ?? price.builtInPrice(product),
    sold: units.get(product.slug) ?? 0,
    waiting: people.get(product.slug) ?? 0,
    changes: changes.filter((row) => row.product === product.slug).slice(0, 10)
  }));
}

// Sets the count only if it still holds what the admin saw (expected), so an
// order that lands while the form is open isn't overwritten. False if it moved.
export async function set(slug, value, expected, email) {
  await db.query("insert into inventory (product, available) values ($1, 0) on conflict do nothing", [slug]);
  const { rows } = await db.query(
    `with changed as (
       update inventory set available = $2, updated_at = now(), updated_by = $4
       where product = $1 and available = $3 returning available
     ), logged as (
       insert into inventory_changes (product, before, after, reason, actor)
       select $1, $3, available, 'admin', $4 from changed
     )
     select count(*)::int as n from changed`,
    [slug, value, expected, email]
  );
  return rows[0].n === 1;
}

// Asking again after being emailed puts the shopper back on the list.
export async function requestRestock(slug, account) {
  await db.query(
    `insert into restock_requests (product, email, account_sub) values ($1, $2, $3)
     on conflict (product, email) do update set account_sub = excluded.account_sub, notified_at = null, created_at = now()`,
    [slug, account.email, account.sub]
  );
}

// Whether this account is waiting on the product. False when the database is
// down: the page then offers the button again, which is harmless.
export async function hasRequested(slug, account) {
  if (!account?.email || !db.isConfigured()) return false;
  try {
    const { rows } = await db.query("select 1 from restock_requests where product = $1 and email = $2 and notified_at is null", [slug, account.email]);
    return rows.length > 0;
  } catch (error) {
    console.error("Could not check a restock request:", error.message);
    return false;
  }
}

// Emails everyone waiting, one at a time, marking each as they're sent so a
// failure part way through can be retried without emailing anyone twice.
export async function notifyWaiting(product) {
  const { rows } = await db.query("select email from restock_requests where product = $1 and notified_at is null order by created_at", [product.slug]);
  let sent = 0;
  for (const { email } of rows) {
    try {
      await mail.send(email, mail.restockEmail(product));
    } catch (error) {
      console.error(`Could not send a restock email for ${product.slug}:`, error.message);
      continue;
    }
    await db.query("update restock_requests set notified_at = now() where product = $1 and email = $2", [product.slug, email]);
    sent += 1;
  }
  return { sent, failed: rows.length - sent };
}

// After an order: tell the owner when the product drops to LOW or fewer, and
// again when it runs out (or is oversold). Best effort, after the order is
// safely recorded; without STOCK_ALERT_EMAIL the alert is only logged.
export async function alertIfLow(change) {
  if (!change) return;
  const product = products.find((p) => p.slug === change.product);
  const out = change.before > 0 && change.after <= 0;
  const low = change.before > LOW && change.after <= LOW && change.after > 0;
  if (!product || !(out || low)) return;
  const message = mail.stockAlertEmail(product, change.after);
  const to = process.env.STOCK_ALERT_EMAIL;
  if (!to) return console.warn(`[stock] ${message.subject} (STOCK_ALERT_EMAIL is not set)`);
  try {
    await mail.send(to, message);
  } catch (error) {
    console.error("Could not send the stock alert:", error.message);
  }
}
