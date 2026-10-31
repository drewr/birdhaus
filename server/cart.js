import { cookies, sign, unsign, cookieOptions, now } from "./cookies.js";

// The cart is a single product, so it holds just a quantity, in a signed cookie
// (bh_cart). It is not an authorization boundary: quantity and price are
// re-validated server-side at checkout, so a tampered cookie can only change the
// display. The same signer as the auth session is reused.
const CART_COOKIE = "bh_cart";
const CART_TTL = 30 * 24 * 60 * 60;

const clampQty = (value) => {
  const q = Number.parseInt(value, 10);
  return Number.isInteger(q) ? Math.min(Math.max(q, 0), 99) : 0;
};

export function readCart(request) {
  const payload = unsign(cookies(request)[CART_COOKIE]);
  const qty = payload && Number.isInteger(payload.qty) ? Math.min(Math.max(payload.qty, 0), 99) : 0;
  return { qty };
}

export function writeCart(response, quantity) {
  const qty = clampQty(quantity);
  if (qty <= 0) return clearCart(response);
  response.cookie(CART_COOKIE, sign({ qty, exp: now() + CART_TTL }), cookieOptions(CART_TTL));
  return qty;
}

export function clearCart(response) {
  response.clearCookie(CART_COOKIE, cookieOptions(0));
  return 0;
}
