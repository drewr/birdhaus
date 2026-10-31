// The single source of truth for the price. The server sets it; the browser is
// never trusted with an amount (see create-payment-intent). Views format from
// here too, so the figure lives in exactly one place.
export const UNIT_PRICE_CENTS = 4000;

const usd = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

// Cents -> "$40.00 USD".
export function formatUsd(cents) {
  return `${usd.format(cents / 100)} USD`;
}

export function formatTotal(quantity) {
  return formatUsd(quantity * UNIT_PRICE_CENTS);
}
