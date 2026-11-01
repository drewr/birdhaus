// The single source of truth for prices, by product slug. The server sets them;
// the browser is never trusted with an amount (see create-payment-intent).
// Views format from here too, so each figure lives in exactly one place.
const UNIT_PRICES_CENTS = {
  "bluebird-house": 4000,
  // Stripe's minimum charge in USD.
  "demo-thing": 50
};

export const unitPrice = (product) => UNIT_PRICES_CENTS[product.slug];

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

// Cents -> "$40.00 USD".
export function formatUsd(cents) {
  return `${usd.format(cents / 100)} USD`;
}

export function formatTotal(product, quantity) {
  return formatUsd(quantity * unitPrice(product));
}
