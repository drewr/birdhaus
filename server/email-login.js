import crypto from "node:crypto";
import { cookies, sign, unsign, cookieOptions, now } from "./cookies.js";
import * as auth from "./auth.js";
import * as db from "./db.js";
import * as mail from "./mail.js";
import * as rauthy from "./rauthy.js";

// Passwordless email sign-in on the store's own pages (docs/design/login-page.md):
// the store emails a 6-digit code, and Rauthy's admin API holds the accounts.

const PENDING_COOKIE = "bh_login";
const PENDING_TTL = 10 * 60;
const SECRET = process.env.SESSION_SECRET || "";

export const isAvailable = () => auth.isConfigured() && rauthy.isConfigured() && mail.isConfigured() && db.isConfigured();

export function normalEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  return email.length <= 254 && /^[^\s@]{1,64}@[^\s@]+\.[^\s@]+$/.test(email) ? email : "";
}

// Rauthy's own rule for given_name.
export function normalName(value) {
  const name = String(value ?? "").trim().replace(/\s+/g, " ");
  return /^[\p{L}\p{M}\p{N}\p{Zs}'.-]{1,32}$/u.test(name) ? name : "";
}

const hash = (email, code) => crypto.createHmac("sha256", SECRET).update(`${email}:${code}`).digest("hex");

// "sent", "limited" (too many this hour) or throws when mail or the database fails.
export async function sendCode(email, purpose) {
  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, "0");
  if (!(await db.saveLoginCode(email, hash(email, code), purpose))) return "limited";
  await mail.sendCode(email, code, purpose);
  return "sent";
}

// A log in needs an existing, enabled account; a sign-up needs a free address.
// "sent", "limited", "unknown" (no account to log in to) or "exists".
export async function start(email, purpose) {
  const account = await rauthy.findByEmail(email);
  if (purpose === "login" && !account?.enabled) return "unknown";
  if (purpose === "signup" && account) return "exists";
  return sendCode(email, purpose);
}

// The address waiting for a code, and where to go afterwards. Lax, so a
// cross-site POST can't complete someone else's sign-in in this browser.
export function setPending(response, pending) {
  response.cookie(PENDING_COOKIE, sign({ ...pending, exp: now() + PENDING_TTL }), cookieOptions(PENDING_TTL));
}

export function readPending(request) {
  const pending = unsign(cookies(request)[PENDING_COOKIE]);
  return pending && typeof pending.email === "string" && ["login", "signup"].includes(pending.purpose) ? pending : null;
}

export const clearPending = (response) => response.clearCookie(PENDING_COOKIE, cookieOptions(0));

// "ok" with the account, "wrong" or "expired". On success a sign-up creates
// the Rauthy account and either way the address is marked verified.
export async function checkCode(pending, code) {
  const expected = (stored) => {
    const given = Buffer.from(hash(pending.email, code));
    const want = Buffer.from(stored);
    return given.length === want.length && crypto.timingSafeEqual(given, want);
  };
  const result = await db.useLoginCode(pending.email, pending.purpose, expected);
  if (result !== "ok") return { result };
  let account = await rauthy.findByEmail(pending.email);
  if (!account && pending.purpose === "signup") account = await rauthy.create(pending.email, pending.name);
  if (!account || !account.enabled) return { result: "expired" };
  if (!account.emailVerified) await rauthy.markVerified(account.sub);
  return { result: "ok", account: { ...account, emailVerified: true } };
}
