import * as db from "./db.js";

// Unit prices by product slug, in cents. The server sets them; the browser is
// never trusted with an amount (see create-payment-intent). Admins set them at
// /admin/inventory (the prices table); these built-in prices apply until then.
const BUILT_IN_CENTS = {
  "bluebird-house": 4000,
  "demo-thing": 50
};

// Stripe's minimum charge in USD, and a ceiling against a slipped digit.
export const MIN_CENTS = 50;
export const MAX_CENTS = 100000;

export const builtInPrice = (product) => BUILT_IN_CENTS[product.slug];

// The last price this instance read for each product, so a database blip
// keeps the owner's price instead of reverting to the built-in one.
const lastRead = new Map();

export async function unitPrice(product) {
  if (db.isConfigured()) {
    try {
      const { rows } = await db.query("select cents from prices where product = $1", [product.slug]);
      const cents = rows[0]?.cents ?? builtInPrice(product);
      lastRead.set(product.slug, cents);
      return cents;
    } catch (error) {
      console.error(`Could not read the price of ${product.slug}; using the last one read:`, error.message);
    }
  }
  return lastRead.get(product.slug) ?? builtInPrice(product);
}

// Saved prices by slug: { cents, updated_at, updated_by }, for the admin page.
export async function saved() {
  const { rows } = await db.query("select product, cents, updated_at, updated_by from prices");
  return new Map(rows.map((row) => [row.product, row]));
}

// Sets a price and logs the change, unless it's the price already charged.
export async function set(product, cents, email) {
  await db.query(
    `with old as (
       select coalesce((select cents from prices where product = $1), $3) as cents
     ), saved as (
       insert into prices (product, cents, updated_by) values ($1, $2, $4)
       on conflict (product) do update set cents = excluded.cents, updated_at = now(), updated_by = excluded.updated_by
     )
     insert into price_changes (product, before, after, actor)
     select $1, cents, $2, $4 from old where cents <> $2`,
    [product.slug, cents, builtInPrice(product), email]
  );
}

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

// Cents -> "$40.00 USD".
export function formatUsd(cents) {
  return `${usd.format(cents / 100)} USD`;
}
