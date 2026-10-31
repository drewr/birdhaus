import { cookies, sign, unsign, cookieOptions, now } from "./cookies.js";

// The cart is a single product, so it holds a quantity plus the chosen pick-up
// slot id, in a signed cookie (bh_cart). It is not an authorization boundary:
// quantity, price and slot are re-validated server-side at checkout, so a
// tampered cookie can only change the display. Prices are never stored here.
const CART_COOKIE = "bh_cart";
const CART_TTL = 30 * 24 * 60 * 60;

const clampQty = (value) => {
  const q = Number.parseInt(value, 10);
  return Number.isInteger(q) ? Math.min(Math.max(q, 0), 99) : 0;
};

export function readCart(request) {
  const payload = unsign(cookies(request)[CART_COOKIE]);
  const qty = payload && Number.isInteger(payload.qty) ? Math.min(Math.max(payload.qty, 0), 99) : 0;
  const slot = payload && Number.isInteger(payload.slot) ? payload.slot : null;
  return { qty, slot };
}

// Writes { qty, slot }; an empty cart clears the cookie.
export function writeCart(response, cart) {
  const qty = clampQty(cart.qty);
  if (qty <= 0) return clearCart(response);
  const slot = Number.isInteger(cart.slot) ? cart.slot : null;
  response.cookie(CART_COOKIE, sign({ qty, slot, exp: now() + CART_TTL }), cookieOptions(CART_TTL));
  return qty;
}

export function clearCart(response) {
  response.clearCookie(CART_COOKIE, cookieOptions(0));
  return 0;
}
