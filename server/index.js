import "dotenv/config";
import express from "express";
import Stripe from "stripe";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { currentBatch } from "./batch.js";
import * as price from "./price.js";
import { unitPrice, formatUsd } from "./price.js";
import { readCart, writeCart, clearCart } from "./cart.js";
import { formatOrder } from "./order-format.js";
import { photoView, products, productName, visibleProduct, visibleTo } from "./products.js";
import * as auth from "./auth.js";
import * as emailLogin from "./email-login.js";
import * as db from "./db.js";
import * as pickup from "./pickup.js";
import * as delivery from "./delivery.js";
import * as copy from "./copy.js";
import * as inventory from "./inventory.js";
import * as users from "./users.js";
import * as mail from "./mail.js";
import { lastGeocodeFailure } from "./geocode.js";

const app = express();
const port = Number(process.env.PORT || 4242);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "dist");
const batch = currentBatch();
db.migrateInBackground();

// Set once SIGTERM arrives (see the end of this file). A draining instance
// closes each connection after its response, so the edge's pooled connections
// move to the other instance instead of waiting here to be cut.
let draining = false;
app.use((_request, response, next) => {
  if (draining) response.set("Connection", "close");
  next();
});

// Pages are rendered by PureScript (src/Server/Render.purs). In the image that
// is pre-bundled to server/views.js (the image ships no PureScript toolchain or
// output/); in dev we import the compiled module tree directly, so iterating
// needs only `spago build`, not a bundle step.
const prod = process.env.NODE_ENV === "production";
const views = await import(prod ? "./views.js" : "../output/Server.Render/index.js");

// Vite writes content-hashed asset names; the server-rendered <head> links them
// from the manifest. Read once in prod (fail fast if missing), per request in
// dev where the hashes change on each watch rebuild.
function readManifest() {
  try {
    return JSON.parse(readFileSync(path.join(dist, ".vite", "manifest.json"), "utf8"));
  } catch {
    return null;
  }
}
let manifest = readManifest();
function assets() {
  if (!prod) manifest = readManifest();
  const entry = manifest?.["src/client-entry.js"];
  if (!entry) return { css: "", js: "" };
  return { js: entry.file ? `/${entry.file}` : "", css: entry.css?.[0] ? `/${entry.css[0]}` : "" };
}

// Set by run.hs on the workload; /api/health and the footer report them. A
// local run asks git instead, marking uncommitted changes, so a screenshot
// from a dev machine is never mistaken for a deploy.
const appVersion = process.env.APP_VERSION || "local";
const appCommit = process.env.APP_COMMIT || localCommit();

function localCommit() {
  try {
    const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const sha = git("rev-parse", "HEAD");
    return git("status", "--porcelain", "--untracked-files=no") ? `${sha}-dirty` : sha;
  } catch {
    return "unknown";
  }
}

// The shared header/head/analytics fields every full page needs.
function chrome(request, reason = "open") {
  const account = auth.accountOf(request);
  const { css, js } = assets();
  return {
    css,
    js,
    accountId: account?.sub ?? "",
    accountLabel: account ? account.name || account.email : "",
    signedIn: Boolean(account),
    isAdmin: Boolean(account?.admin),
    cartQty: cartLine(request).qty,
    reason,
    version: appVersion,
    commit: appCommit.replace(/^([0-9a-f]{7})[0-9a-f]*/, "$1")
  };
}

// The cart's product and quantity, or { product: null, qty: 0 } when it's empty
// or holds a product this visitor can no longer see (an admin's groups lapse).
function cartLine(request) {
  const cart = readCart(request);
  const product = visibleProduct(cart.product, auth.accountOf(request));
  return product && cart.qty > 0 ? { product, qty: cart.qty } : { product: null, qty: 0 };
}

// The cart's delivery choice if it can still be booked: { method, slot, label,
// feeCents }. Null when unset, stale, delivery switched off, or the database is
// down: checkout then can't proceed, the rest of the store can.
async function cartChoice(request) {
  const { slot, method } = readCart(request);
  if (slot === null || !db.isConfigured()) return null;
  try {
    if (method === "delivery") {
      const s = await delivery.settings();
      const found = delivery.offered(s) ? await delivery.bookableSlot(slot) : null;
      return found && { method, slot: found, label: delivery.slotLabel(found), feeCents: s.feeCents };
    }
    const found = await pickup.bookableSlot(slot);
    return found && { method, slot: found, label: pickup.slotLabel(found), feeCents: 0 };
  } catch (error) {
    console.error("Could not load the delivery choice:", error.message);
    return null;
  }
}

// The delivery options line on the product and cart pages.
async function fulfillmentNote() {
  try {
    const s = db.isConfigured() ? await delivery.settings() : null;
    if (s && delivery.offered(s)) {
      return `Local pick-up, or local delivery within ${s.radiusMiles} miles for ${formatUsd(s.feeCents)}. Shipping coming soon. Taxes not included.`;
    }
  } catch (error) {
    console.error("Could not load delivery settings:", error.message);
  }
  return "Local pick-up only for now — shipping coming soon. Taxes not included.";
}

// The inventory decides (server/inventory.js): { open, reason, remaining },
// remaining null for no limit.
const availability = (product) => inventory.stock(product);

// Whether checkout can go ahead with the cart as it is; when not, /cart says why.
async function cartFits(line) {
  if (!line.product) return false;
  const status = await availability(line.product);
  return status.open && (status.remaining === null || line.qty <= status.remaining);
}

// Units the stepper may reach: what's left (when tracked) or 99.
function stepperLimit(status) {
  return status.remaining === null ? 99 : Math.max(Math.min(99, status.remaining), 1);
}

// When the webhook last failed to write to the database; /api/health reports it.
let lastWebhookFailure = 0;


// Stripe signs the raw body, so this route is registered before express.json().
// A database error returns 500 so that Stripe retries the event (for up to
// three days), which rides out a database restore.
app.post("/api/stripe-webhook", express.raw({ type: "application/json" }), async (request, response) => {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secretKey || !webhookSecret || !db.isConfigured()) {
    return response.status(503).json({ error: "Webhook is not configured." });
  }

  let event;
  try {
    event = new Stripe(secretKey).webhooks.constructEvent(request.body, request.get("stripe-signature"), webhookSecret);
  } catch (error) {
    return response.status(400).json({ error: `Invalid signature: ${error.message}` });
  }

  try {
    let change = null;
    if (event.type === "payment_intent.succeeded") {
      change = await db.recordOrder(event.data.object);
    } else if (event.type === "charge.refunded") {
      // Refunds don't restock: a returned house may not be sellable.
      const charge = event.data.object;
      if (charge.refunded && charge.payment_intent) await db.markRefunded(charge.payment_intent);
    }
    response.json({ received: true });
    await inventory.alertIfLow(change);
  } catch (error) {
    lastWebhookFailure = Date.now();
    console.error(`Could not record ${event.type} ${event.id}:`, error.message);
    response.status(500).json({ error: "Could not record the event." });
  }
});

app.use(express.json());
// HTMX and the no-JS form fallbacks post application/x-www-form-urlencoded.
app.use(express.urlencoded({ extended: false }));

// Accounts (auth/README.md). Sign-in is optional; a missing configuration or
// an unreachable identity service must never affect checkout.
app.use("/api/auth", auth.routes());
app.get("/api/me", auth.me);

// Probed every 5 minutes by birdhaus-watch (ops/watch). 503 names what failed.
app.get("/api/health", async (_request, response) => {
  response.set("Cache-Control", "no-store");
  // run.hs waits for the version it deployed, so it knows the rollout is done.
  const health = {
    version: appVersion,
    commit: appCommit,
    migrations: db.migrationStatus(),
    db: "not configured",
    webhook: "ok",
  };
  if (db.isConfigured()) {
    try {
      await Promise.race([db.query("select 1"), new Promise((_, reject) => setTimeout(() => reject(new Error("timed out")), 3000))]);
      health.db = "ok";
    } catch (error) {
      health.db = `failing: ${error.message}`;
    }
  }
  if (Date.now() - lastWebhookFailure < 15 * 60 * 1000) {
    health.webhook = `failing: a Stripe event could not be recorded at ${new Date(lastWebhookFailure).toISOString()}`;
  }
  // Delivery falls back to ZIP checks while Census is down; report it so the
  // owner hears about it.
  health.geocoder = Date.now() - lastGeocodeFailure < 15 * 60 * 1000
    ? `failing: the Census geocoder could not be reached at ${new Date(lastGeocodeFailure).toISOString()}`
    : "ok";
  const ok = health.db !== "not configured" && !health.db.startsWith("failing") && health.migrations === "ok" && health.webhook === "ok" && health.geocoder === "ok";
  response.status(ok ? 200 : 503).json(health);
});

// Checkout needs an account (docs/design/login-page.md), as do restock requests. Pages
// send a signed-out buyer to /login and back; the APIs answer 401.
function requireAccount(request, response, next) {
  if (auth.accountOf(request)) return next();
  if (request.path.startsWith("/api/")) return response.status(401).json({ error: "Please sign in to check out." });
  const back = request.method === "GET" ? request.originalUrl : "/checkout";
  response.redirect(303, `/login?next=${encodeURIComponent(auth.safeNext(back))}`);
}

// The product and quantity are the server's cart cookie, never a
// browser-supplied amount.
app.post("/api/create-payment-intent", requireAccount, async (request, response) => {
  const { product, qty: quantity } = cartLine(request);
  if (!product || !Number.isInteger(quantity) || quantity < 1 || quantity > 99) {
    return response.status(400).json({ error: "Your cart is empty." });
  }

  const secretKey = process.env.STRIPE_SECRET_KEY;
  const publishableKey = process.env.VITE_STRIPE_PUBLISHABLE_KEY || process.env.STRIPE_PUBLISHABLE_KEY;
  if (!secretKey || !publishableKey) {
    return response.status(503).json({ error: "Checkout is not configured yet. Please try again later." });
  }

  const status = await availability(product);
  if (!status.open) {
    const unavailable = status.reason === "unavailable";
    return response.status(409).json({ soldOut: !unavailable, error: unavailable ? "We can't check stock right now. Please try again shortly." : `The ${product.name} has sold out.` });
  }
  if (status.remaining !== null && quantity > status.remaining) {
    return response.status(409).json({ error: `Only ${status.remaining} left. Go back to your cart to lower the quantity.` });
  }

  // Pick-up or local delivery; shipping isn't offered yet. The fee comes from
  // the settings now, never from the browser.
  const choice = await cartChoice(request);
  if (!choice) return response.status(409).json({ error: "Choose a new delivery or pick-up time." });
  // The browser says only what the page showed, so a price or fee changed
  // since then is caught before charging; the amount is still the server's.
  const amount = quantity * (await unitPrice(product)) + choice.feeCents;
  if (request.body?.expectedCents !== undefined && request.body.expectedCents !== amount) {
    return response.status(409).json({ error: `The total is now ${formatUsd(amount)}. Reload the page to see the new price.` });
  }

  const account = auth.accountOf(request);
  // Unbatched orders are recorded as "unbatched".
  const metadata = {
    product: product.slug,
    quantity: String(quantity),
    fulfillment: choice.method
  };
  if (product.batched) metadata.batch = batch.id;
  if (choice.method === "delivery") {
    Object.assign(metadata, { fee_cents: String(choice.feeCents), delivery_slot_id: String(choice.slot.id), delivery_label: choice.label });
  } else {
    Object.assign(metadata, { pickup_slot_id: String(choice.slot.id), pickup_label: choice.label });
  }
  if (account) metadata.account_sub = account.sub;
  try {
    const stripe = new Stripe(secretKey);
    const intent = await stripe.paymentIntents.create({
      amount,
      currency: "usd",
      automatic_payment_methods: { enabled: true },
      description: `Birdhaus ${product.name} × ${quantity}, ${choice.method === "delivery" ? "local delivery" : "pick-up"}: ${choice.label}`,
      metadata
    });
    response.json({ clientSecret: intent.client_secret, publishableKey });
  } catch (error) {
    console.error("Unable to create Stripe PaymentIntent:", error.message);
    response.status(500).json({ error: "We could not start checkout. Please try again." });
  }
});

// A PaymentIntent, gated by its client_secret (possession proves it's the
// buyer, as Stripe appends it to the return URL). Null when anything is off.
async function intentForSecret(id, clientSecret) {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (typeof id !== "string" || !/^pi_[A-Za-z0-9]+$/.test(id)) return null;
  if (typeof clientSecret !== "string" || !clientSecret.startsWith(`${id}_secret_`)) return null;
  if (!secretKey) return null;
  try {
    const intent = await new Stripe(secretKey).paymentIntents.retrieve(id);
    return intent.client_secret === clientSecret ? intent : null;
  } catch (error) {
    if (error.code !== "resource_missing") console.error("Unable to retrieve Stripe PaymentIntent:", error.message);
    return null;
  }
}

// The order behind the return URL, as a trimmed view, or null.
async function lookupOrder(id, clientSecret) {
  const intent = await intentForSecret(id, clientSecret);
  if (!intent) return null;
  return {
    id: intent.id,
    status: intent.status,
    created: intent.created,
    amount: intent.amount,
    currency: intent.currency,
    product: productName(intent.metadata.product || "bluebird-house"),
    quantity: Number(intent.metadata.quantity) || 1,
    email: intent.receipt_email,
    shipping: intent.shipping && { name: intent.shipping.name, address: intent.shipping.address },
    fulfillment: ["pickup", "delivery"].includes(intent.metadata.fulfillment) ? intent.metadata.fulfillment : "ship",
    pickupLabel: intent.metadata.pickup_label || "",
    deliveryLabel: intent.metadata.delivery_label || "",
    error: intent.last_payment_error?.message
  };
}

// Kept as JSON too, for any out-of-band lookup.
app.get("/api/order/:id", async (request, response) => {
  response.set("Cache-Control", "no-store");
  const order = await lookupOrder(request.params.id, request.query.client_secret);
  if (!order) return response.status(404).json({ error: "Order not found." });
  response.json(order);
});

// -------------------------------------------------------------- local delivery

// The wallet sheet's check while open: only city, state and ZIP are revealed
// until the buyer confirms, so this tests the ZIP centroid.
app.post("/api/delivery/check-zip", requireAccount, async (request, response) => {
  response.set("Cache-Control", "no-store");
  try {
    const s = db.isConfigured() ? await delivery.settings() : null;
    response.json({ ok: Boolean(s && delivery.offered(s) && delivery.checkZip(s, request.body?.postal_code)) });
  } catch (error) {
    console.error("Could not check a delivery ZIP:", error.message);
    response.json({ ok: false });
  }
});

const PAYABLE = ["requires_payment_method", "requires_confirmation", "requires_action"];
const field = (value, max) => String(value ?? "").trim().slice(0, max);

// The authoritative radius check, just before payment: geocode the full
// address and, if it's in range, set it on the PaymentIntent from the server so
// the order records the address that passed. The client secret proves the
// caller is the buyer, as on /order.
app.post("/api/delivery/verify", requireAccount, async (request, response) => {
  response.set("Cache-Control", "no-store");
  const clientSecret = request.body?.clientSecret;
  const id = typeof clientSecret === "string" ? clientSecret.split("_secret_")[0] : "";
  const intent = await intentForSecret(id, clientSecret);
  if (!intent || intent.metadata.fulfillment !== "delivery" || !PAYABLE.includes(intent.status)) {
    return response.status(404).json({ error: "Checkout not found. Reload the page." });
  }
  const given = request.body?.address ?? {};
  const address = {
    line1: field(given.line1, 200),
    line2: field(given.line2, 200),
    city: field(given.city, 100),
    state: field(given.state, 50),
    postal_code: field(given.postal_code, 10),
    country: field(given.country, 2).toUpperCase() || "US"
  };
  const name = field(request.body?.name, 200);
  const phone = field(request.body?.phone, 40);
  if (!address.line1 || !address.city || !address.postal_code || !name) {
    return response.status(400).json({ error: "Enter the delivery name and full address." });
  }
  let s;
  try {
    s = await delivery.settings();
  } catch (error) {
    console.error("Could not load delivery settings:", error.message);
    return response.status(503).json({ error: "Delivery is unavailable right now. Please try again shortly." });
  }
  if (!delivery.offered(s)) return response.status(409).json({ error: "Local delivery isn't available right now." });
  const result = await delivery.checkAddress(s, address);
  if (!result.ok) return response.status(422).json({ error: `That address is outside our ${s.radiusMiles}-mile delivery area.` });
  try {
    await new Stripe(process.env.STRIPE_SECRET_KEY).paymentIntents.update(id, {
      shipping: { name, phone: phone || undefined, address },
      metadata: { address_check: result.check, verified_zip: address.postal_code.slice(0, 5) }
    });
  } catch (error) {
    console.error("Could not set the delivery address:", error.message);
    return response.status(500).json({ error: "We could not save the address. Please try again." });
  }
  response.json({ ok: true });
});

// -------------------------------------------------------------- cart mutations

// Add the chosen amount to what's already in the cart (form POST, 303 to /cart).
// The cart holds one product, so adding a different one replaces it.
// Never more than is left: asking for more fills the cart to what's left and
// /cart says so.
app.post("/cart/add", async (request, response) => {
  const product = visibleProduct(request.body?.product, auth.accountOf(request));
  if (!product) return response.redirect(303, "/products");
  const status = await availability(product);
  if (!status.open) return response.redirect(303, `/products/${product.slug}`);
  const line = cartLine(request);
  const held = line.product === product ? line.qty : 0;
  const add = Number.parseInt(request.body?.quantity, 10);
  const wanted = Number.isInteger(add) && add > 0 ? Math.min(held + add, 99) : Math.max(held, 1);
  const qty = Math.min(wanted, stepperLimit(status));
  writeCart(response, { ...readCart(request), product: product.slug, qty });
  response.redirect(303, qty < wanted ? "/cart?adjusted=1" : "/cart");
});

// The cart stepper. HTMX gets the re-rendered #cart fragment; no-JS gets a 303.
app.post("/cart/update", async (request, response) => {
  const hx = Boolean(request.get("HX-Request"));
  const { product, qty: held } = cartLine(request);
  if (!product) return hx ? response.set("HX-Redirect", "/products").end() : response.redirect(303, "/products");
  const status = await availability(product);
  // Sold out since the page loaded: /cart empties the cart and says so.
  if (!status.open && status.reason !== "unavailable") return hx ? response.set("HX-Redirect", "/cart").end() : response.redirect(303, "/cart");
  const target = Number.parseInt(request.body?.quantity, 10);
  const wanted = Number.isInteger(target) ? Math.min(Math.max(target, 1), 99) : held;
  const qty = status.open ? Math.min(wanted, stepperLimit(status)) : wanted;
  writeCart(response, { ...readCart(request), qty });
  if (hx) {
    const vm = await cartView(request, product, qty, status, qty < wanted ? adjustedNotice(qty) : "");
    return response.set("Cache-Control", "no-cache").type("html").send(views.cartFragment(vm));
  }
  response.redirect(303, "/cart");
});

app.post("/cart/clear", (request, response) => {
  clearCart(response);
  response.redirect(303, "/products");
});

// -------------------------------------------------------------- restock requests

// "Notify me when available" on a sold-out product. Signed-out shoppers get a
// sign-in link instead of this form; HTMX swaps in the confirmation.
app.post("/notify", async (request, response) => {
  if (!auth.sameOrigin(request)) return response.status(403).type("text").send("Forbidden");
  const account = auth.accountOf(request);
  const product = visibleProduct(request.body?.product, account);
  if (!product) return response.redirect(303, "/products");
  const page = `/products/${product.slug}`;
  const hx = Boolean(request.get("HX-Request"));
  if (!account?.email) {
    const login = `/login?next=${encodeURIComponent(page)}`;
    return hx ? response.set("HX-Redirect", login).end() : response.redirect(303, login);
  }
  let state = "requested";
  try {
    if (!db.isConfigured()) throw new Error("PGHOST is not set");
    await inventory.requestRestock(product.slug, account);
  } catch (error) {
    console.error("Could not save a restock request:", error.message);
    state = "error";
  }
  if (!hx) return response.redirect(303, page);
  response.type("html").send(views.notifyFragment({ slug: product.slug, notifyState: state, notifyEmail: account.email, loginHref: "" }));
});

// -------------------------------------------------------------- static + pages

// Image builds pin every file's mtime, so static's validators can't tell builds
// apart; hashed /assets are immutable, everything else no-cache.
app.use("/assets", express.static(path.join(dist, "assets"), { immutable: true, maxAge: "1y" }));
// Product photo names carry a content hash too (scripts/product-photos.hs).
app.use("/photos", express.static(path.join(dist, "photos"), { immutable: true, maxAge: "1y" }));
app.use(express.static(dist, {
  index: false,
  etag: false,
  lastModified: false,
  setHeaders: (response) => response.setHeader("Cache-Control", "no-cache")
}));

app.get("/", async (request, response) => {
  const text = await copy.html(["home-welcome"]);
  response.set("Cache-Control", "no-cache").type("html").send(views.homePage({ ...chrome(request), welcome: text["home-welcome"] }));
});

// The store's own sign-in (docs/design/login-page.md): log in or create an
// account, with Google (through Rauthy, nothing to do there) or an emailed
// code. A signed-in visitor is told so rather than bounced, since links like
// the hero's "Sign up" reach them too.
function loginView(request, extra = {}) {
  const next = auth.safeNext(extra.next ?? request.query.next);
  return {
    ...chrome(request),
    authEnabled: auth.isConfigured(),
    emailEnabled: emailLogin.isAvailable(),
    googleHref: auth.loginUrl(next, { provider: "google" }),
    loginEmail: "",
    loginError: "",
    signupName: "",
    signupEmail: "",
    signupError: "",
    ...extra,
    next
  };
}

const sendPage = (response, html, status = 200) => response.status(status).set("Cache-Control", "no-store").type("html").send(html);

app.get("/login", (request, response) => sendPage(response, views.loginPage(loginView(request))));

async function startEmail(request, response, purpose) {
  if (!auth.sameOrigin(request)) return response.status(403).type("text").send("Forbidden");
  const next = auth.safeNext(request.body?.next);
  const typedEmail = String(request.body?.email ?? "").trim().slice(0, 254);
  const typedName = String(request.body?.name ?? "").trim().slice(0, 64);
  const email = emailLogin.normalEmail(typedEmail);
  const name = emailLogin.normalName(typedName);
  const form = purpose === "login" ? { loginEmail: typedEmail } : { signupEmail: typedEmail, signupName: typedName };
  const fail = (message, extra = {}) =>
    sendPage(response, views.loginPage(loginView(request, { next, ...form, [`${purpose}Error`]: message, ...extra })), 400);

  if (!emailLogin.isAvailable()) return fail("Email sign-in isn't available right now. Please use Google, or try again shortly.");
  if (!email) return fail("Enter a valid email address.");
  if (purpose === "signup" && !name) return fail("Enter your name: up to 32 letters, spaces, hyphens or apostrophes.");
  let outcome;
  try {
    outcome = await emailLogin.start(email, purpose);
  } catch (error) {
    console.error("Could not send a sign-in code:", error.message);
    return fail("We couldn't send a code just now. Please try again.");
  }
  if (outcome === "unknown") return fail("There's no account with that email yet. You can create one here.", { signupEmail: typedEmail });
  if (outcome === "exists") return fail("You already have an account with that email. Log in with it here.", { loginEmail: typedEmail });
  if (outcome === "limited") return fail("We've sent several codes to that address. Please wait a while, then try again.");
  emailLogin.setPending(response, { email, purpose, name, next });
  response.redirect(303, "/login/code");
}

app.post("/login/email", (request, response) => startEmail(request, response, "login"));
app.post("/signup/email", (request, response) => startEmail(request, response, "signup"));

function codeView(request, pending, extra = {}) {
  return { ...chrome(request), email: pending.email, signingUp: pending.purpose === "signup", error: "", notice: "", ...extra };
}

app.get("/login/code", (request, response) => {
  const pending = emailLogin.readPending(request);
  if (!pending) return response.redirect(303, "/login");
  sendPage(response, views.codePage(codeView(request, pending)));
});

app.post("/login/code", async (request, response) => {
  if (!auth.sameOrigin(request)) return response.status(403).type("text").send("Forbidden");
  const pending = emailLogin.readPending(request);
  if (!pending) return response.redirect(303, "/login");
  const again = (error) => sendPage(response, views.codePage(codeView(request, pending, { error })), 400);
  const code = String(request.body?.code ?? "").replace(/\D/g, "");
  if (code.length !== 6) return again("Enter the 6-digit code from the email.");
  let checked;
  try {
    checked = await emailLogin.checkCode(pending, code);
  } catch (error) {
    console.error("Could not check a sign-in code:", error.message);
    return again("We couldn't check the code just now. Please try again.");
  }
  if (checked.result === "wrong") return again("That code isn't right. Check the email and try again.");
  if (checked.result !== "ok") return again("That code has expired or had too many tries. Send a new one below.");
  emailLogin.clearPending(response);
  await auth.startSession(response, checked.account);
  response.redirect(303, auth.landing(pending.next));
});

app.post("/login/resend", async (request, response) => {
  if (!auth.sameOrigin(request)) return response.status(403).type("text").send("Forbidden");
  const pending = emailLogin.readPending(request);
  if (!pending) return response.redirect(303, "/login");
  let outcome;
  try {
    outcome = await emailLogin.sendCode(pending.email, pending.purpose);
  } catch (error) {
    console.error("Could not resend a sign-in code:", error.message);
    return sendPage(response, views.codePage(codeView(request, pending, { error: "We couldn't send a code just now. Please try again." })), 400);
  }
  if (outcome === "limited") {
    return sendPage(response, views.codePage(codeView(request, pending, { error: "We've sent several codes already. Please wait a while, then try again." })), 400);
  }
  emailLogin.setPending(response, pending);
  sendPage(response, views.codePage(codeView(request, pending, { notice: "We sent a new code. Only the newest one works." })));
});

// The listing card's availability line.
function availabilityLine(status) {
  if (!status.open) return status.reason === "unavailable" ? "Temporarily unavailable" : "Sold out";
  if (status.remaining !== null && status.remaining <= inventory.LOW) return `Only ${status.remaining} left`;
  return "In stock";
}

app.get("/products", async (request, response) => {
  const account = auth.accountOf(request);
  const visible = products.filter((product) => visibleTo(product, account));
  const [statuses, prices] = await Promise.all([Promise.all(visible.map(availability)), Promise.all(visible.map(unitPrice))]);
  const vm = {
    ...chrome(request),
    products: visible.map((product, i) => {
      const photo = product.photos[0] && photoView(product, product.photos[0]);
      return {
        href: `/products/${product.slug}`,
        name: product.name,
        summary: product.summary,
        image: photo ? photo.src : product.image,
        imageAlt: photo ? photo.alt : product.imageAlt,
        srcset: photo ? photo.srcset : "",
        price: formatUsd(prices[i]),
        availability: availabilityLine(statuses[i])
      };
    })
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.productsPage(vm));
});

app.get("/products/:slug", async (request, response) => {
  const product = visibleProduct(request.params.slug, auth.accountOf(request));
  if (!product) return response.redirect(303, "/products");
  const account = auth.accountOf(request);
  const status = await availability(product);
  const line = cartLine(request);
  const inCart = line.product === product ? line.qty : 0;
  // ?photo= picks the photo shown, so the thumbnails work as plain links too.
  const photos = product.photos.map((photo) => photoView(product, photo));
  const shown = photos.find((photo) => photo.name === request.query.photo) ?? photos[0];
  const vm = {
    ...chrome(request, status.reason),
    slug: product.slug,
    name: product.name,
    summary: product.summary,
    image: shown ? shown.src : product.image,
    imageAlt: shown ? shown.alt : product.imageAlt,
    srcset: shown ? shown.srcset : "",
    thumbs: photos.length > 1
      ? photos.map((photo) => ({ ...photo, href: `?photo=${photo.name}`, current: photo === shown }))
      : [],
    open: status.open,
    reason: status.reason,
    details: product.details,
    inCart,
    // Said beside the quantity only when few are left.
    remaining: status.remaining !== null && status.remaining <= inventory.LOW ? status.remaining : -1,
    priceEach: formatUsd(await unitPrice(product)),
    // What can still be added on top of the cart; 0 means the cart has it all.
    maxQuantity: status.remaining === null ? 99 : Math.max(Math.min(status.remaining, 99) - inCart, 0),
    notifyState: status.open ? "" : (await inventory.hasRequested(product.slug, account)) ? "requested" : "ready",
    notifyEmail: account?.email ?? "",
    loginHref: `/login?next=${encodeURIComponent(`/products/${product.slug}`)}`,
    fulfillmentNote: await fulfillmentNote()
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.productPage(vm));
});

const adjustedNotice = (qty) => `Only ${qty} available, so we changed your quantity to ${qty}.`;

// The cart page and its HTMX fragment. qty 0 renders the "sold out and removed"
// state; checkout is offered only when the stock can be checked.
async function cartView(request, product, qty, status, notice) {
  const total = formatUsd(qty * (await unitPrice(product)));
  return {
    ...chrome(request),
    cartQty: qty,
    productName: product.name,
    productHref: `/products/${product.slug}`,
    lineTotal: total,
    subtotal: total,
    maxQuantity: stepperLimit(status),
    notice: status.reason === "unavailable" ? "We can't check stock right now, so checkout is paused. Try again shortly." : notice,
    checkoutOk: status.open && qty > 0,
    fulfillmentNote: await fulfillmentNote()
  };
}

// The cart is checked against what's left on every visit: more than that is cut
// to what's left, and a sold-out product is removed, saying so either way.
app.get("/cart", async (request, response) => {
  const { product, qty: held } = cartLine(request);
  if (!product) return response.redirect(303, "/products");
  const status = await availability(product);
  let qty = held;
  let notice = request.query.adjusted ? adjustedNotice(held) : "";
  if (!status.open && status.reason !== "unavailable") {
    qty = clearCart(response);
    notice = `The ${product.name} sold out, so we removed it from your cart.`;
  } else if (status.open && status.remaining !== null && held > status.remaining) {
    qty = writeCart(response, { ...readCart(request), qty: status.remaining });
    notice = adjustedNotice(qty);
  }
  const vm = await cartView(request, product, qty, status, notice);
  response.set("Cache-Control", "no-cache").type("html").send(views.cartPage(vm));
});

// Checkout step 1: how to get the house. Shipping is shown but greyed out until
// USPS pricing is added (docs/design/fulfillment.md); the choices are pick-up
// and, when an admin has switched it on, local delivery (local-delivery.md).
async function deliveryPage(request, response, error = "") {
  const cart = readCart(request);
  const { product, qty } = cartLine(request);
  let pickupSlots = [];
  let deliverySlots = [];
  let settings = null;
  if (db.isConfigured()) {
    try {
      settings = await delivery.settings();
      [pickupSlots, deliverySlots] = await Promise.all([
        pickup.upcomingSlots(),
        delivery.offered(settings) ? delivery.upcomingSlots() : []
      ]);
    } catch (failure) {
      console.error("Could not load delivery choices:", failure.message);
    }
  }
  const chosen = (method, id) => cart.method === method && cart.slot === id;
  const vm = {
    ...chrome(request),
    quantity: qty,
    productName: product.name,
    total: formatUsd(qty * (await unitPrice(product))),
    error,
    slots: pickupSlots.map((p) => ({ id: p.id, location: p.name, details: p.details, time: pickup.slotTime(p.starts_at, p.ends_at), selected: chosen("pickup", p.id) })),
    deliveryFee: settings ? formatUsd(settings.feeCents) : "",
    deliveryRadius: settings ? String(settings.radiusMiles) : "",
    deliverySlots: deliverySlots.map((d) => ({ id: d.id, time: delivery.slotLabel(d), selected: chosen("delivery", d.id) }))
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.deliveryPage(vm));
}

app.get("/checkout", requireAccount, async (request, response) => {
  if (!(await cartFits(cartLine(request)))) return response.redirect(303, "/cart");
  return deliveryPage(request, response);
});

// The choice posts as "pickup:<slot id>" or "delivery:<slot id>".
app.post("/checkout/delivery", requireAccount, async (request, response) => {
  if (!(await cartFits(cartLine(request)))) return response.redirect(303, "/cart");
  const cart = readCart(request);
  const [method, id] = String(request.body?.choice ?? "").split(":");
  const slotId = Number.parseInt(id, 10);
  let slot = null;
  if (Number.isInteger(slotId) && db.isConfigured()) {
    try {
      if (method === "delivery") {
        const s = await delivery.settings();
        slot = delivery.offered(s) ? await delivery.bookableSlot(slotId) : null;
      } else if (method === "pickup") {
        slot = await pickup.bookableSlot(slotId);
      }
    } catch (error) {
      console.error("Could not load the chosen slot:", error.message);
    }
  }
  if (!slot) return deliveryPage(request, response, "Choose a pick-up or delivery time from the list.");
  writeCart(response, { ...cart, method, slot: slot.id });
  response.redirect(303, "/checkout/pay");
});

// Checkout step 2: pay, with the delivery choice summarized. Delivery adds the
// address (or the wallet's) and the fee; the data attributes only drive the
// wallet sheet's display, the server sets the amount.
app.get("/checkout/pay", requireAccount, async (request, response) => {
  const line = cartLine(request);
  if (!(await cartFits(line))) return response.redirect(303, "/cart");
  const { product, qty } = line;
  const choice = await cartChoice(request);
  if (!choice) return response.redirect(303, "/checkout");
  const account = auth.accountOf(request);
  const subtotalCents = qty * (await unitPrice(product));
  const vm = {
    ...chrome(request),
    quantity: qty,
    productName: product.name,
    subtotal: formatUsd(subtotalCents),
    total: formatUsd(subtotalCents + choice.feeCents),
    fulfillment: choice.method,
    choiceLabel: choice.label,
    fee: formatUsd(choice.feeCents),
    subtotalCents,
    feeCents: choice.feeCents,
    email: account?.email ?? ""
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.checkoutPage(vm));
});

app.get("/order", async (request, response) => {
  response.set("Cache-Control", "no-store");
  const order = await lookupOrder(request.query.payment_intent, request.query.payment_intent_client_secret);
  const base = chrome(request);
  const vm = order
    ? { ...base, ...formatOrder(order) }
    : { ...base, status: "error", message: "", number: "", date: "", items: "", productName: "", total: "", email: "", shipTo: [], quantity: 1, fulfillment: "ship", pickupLabel: "", deliveryLabel: "" };
  response.type("html").send(views.confirmationPage(vm));
});

// -------------------------------------------------------------- admin

// Members of the Rauthy admin group (auth.requireAdmin). Pages hold buyer PII,
// so they are no-store; forms post back and redirect.
const orderDate = new Intl.DateTimeFormat("en-US", { timeZone: pickup.ZONE, dateStyle: "medium" });

async function adminData(request, load) {
  if (!db.isConfigured()) return { ...chrome(request), error: "The database is not configured." };
  try {
    return { ...chrome(request), error: "", ...(await load()) };
  } catch (error) {
    console.error("Admin page could not load:", error.message);
    return { ...chrome(request), error: "The database is unavailable. Try again shortly." };
  }
}

app.get("/admin", auth.requireAdmin, async (request, response) => {
  const vm = await adminData(request, async () => ({
    orders: (await pickup.recentOrders()).map((o) => ({
      number: o.id.slice(-8).toUpperCase(),
      date: orderDate.format(o.created_at),
      email: o.email ?? "",
      product: productName(o.product),
      quantity: o.quantity,
      total: formatUsd(o.amount),
      status: o.status,
      method: o.fulfillment === "pickup" ? `Pick-up: ${o.pickup_label ?? ""}` : o.fulfillment === "delivery" ? `Delivery: ${o.delivery_label ?? ""}` : "Ship"
    }))
  }));
  response.type("html").send(views.adminOrdersPage({ orders: [], ...vm }));
});

// Everyone signed up, and guests who ordered; ?waiting=<slug> narrows it to the
// people still waiting on that product (the link on /admin/inventory).
app.get("/admin/users", auth.requireAdmin, async (request, response) => {
  const product = products.find((p) => p.slug === request.query.waiting) ?? null;
  let partial = false;
  const vm = await adminData(request, async () => {
    const { people, accountsOk } = await users.list(product?.slug ?? null);
    partial = !accountsOk;
    return { users: people.map((u) => ({
      email: u.email,
      name: u.name,
      since: orderDate.format(u.since),
      orders: u.orders,
      spent: formatUsd(u.spent),
      lastOrder: u.last_order ? orderDate.format(u.last_order) : "—",
      waiting: u.waiting.map(productName).join(", ")
    })) };
  });
  const error = vm.error || (partial ? "The account list couldn't be loaded, so only people with orders or restock requests are shown." : "");
  response.type("html").send(views.adminUsersPage({ users: [], ...vm, error, filter: product?.name ?? "" }));
});

app.get("/admin/pickup", auth.requireAdmin, async (request, response) => {
  const vm = await adminData(request, async () => {
    const [locations, slots, schedule] = await Promise.all([pickup.listLocations(), pickup.listSlots(), pickup.pickupSchedule()]);
    const now = new Date();
    return {
      locations: locations.map((l) => ({ id: l.id, name: l.name, details: l.details, active: l.active })),
      slots: slots.map((s) => ({ id: s.id, location: s.name, time: pickup.slotTime(s.starts_at, s.ends_at), active: s.active, past: s.ends_at < now })),
      schedule: schedule.map((o) => ({ slot: o.pickup_label ?? "", email: o.email ?? "", product: productName(o.product), quantity: o.quantity, number: o.id.slice(-8).toUpperCase() }))
    };
  });
  response.type("html").send(views.adminPickupPage({ locations: [], slots: [], schedule: [], ...vm, error: adminNotice(request) || vm.error }));
});

// Runs an admin write, logging failures; every form redirects back regardless.
// Why a write was refused. Only these codes travel in the redirect's ?error=,
// so the page shows fixed text, never anything taken from the URL.
const ADMIN_ERRORS = {
  "location-name": "Give the location a name.",
  "slot-fields": "Choose a location, a date, and start and end times.",
  "slot-times": "The end time must be after the start time (check AM/PM).",
  "copy-section": "That section doesn't exist.",
  "copy-length": `Page copy can be at most ${copy.MAX_LENGTH} characters.`,
  "inventory-product": "That product isn't tracked.",
  "inventory-value": "Enter a whole number of 0 or more.",
  "inventory-changed": "The count changed while you were editing, probably from an order. The page now shows the current number; check it and save again.",
  "price-product": "That product doesn't exist.",
  "price-value": `Enter a price from ${formatUsd(price.MIN_CENTS)} to ${formatUsd(price.MAX_CENTS)}, like 40 or 39.50.`,
  "notify-empty": "Raise the count above 0 before emailing the people waiting.",
  "mail-off": "Email isn't configured, so nobody was emailed.",
  "no-database": "The database is not configured.",
  "save-failed": "That change couldn't be saved. Try again shortly."
};
const adminNotice = (request) => ADMIN_ERRORS[request.query.error] ?? "";

// write() returns an ADMIN_ERRORS code to refuse the change, or nothing.
async function adminWrite(response, write, back = "/admin/pickup") {
  let code = db.isConfigured() ? "" : "no-database";
  if (!code) {
    try {
      code = (await write()) ?? "";
    } catch (error) {
      console.error("Admin change failed:", error.message);
      code = "save-failed";
    }
  }
  response.redirect(303, code ? `${back}?error=${code}` : back);
}

// Slot form fields: a date and HH:MM times in the store's zone, end after start.
function slotProblem(date, start, end) {
  if (!DATE.test(date) || !TIME.test(start) || !TIME.test(end)) return "slot-fields";
  return end > start ? "" : "slot-times";
}

app.post("/admin/pickup/locations", auth.requireAdmin, (request, response) => {
  const name = String(request.body?.name ?? "").trim().slice(0, 120);
  const details = String(request.body?.details ?? "").trim().slice(0, 500);
  return adminWrite(response, async () => {
    if (!name) return "location-name";
    await pickup.createLocation(name, details);
  });
});

app.post("/admin/pickup/locations/:id/active", auth.requireAdmin, (request, response) =>
  adminWrite(response, () => pickup.setLocationActive(Number.parseInt(request.params.id, 10), request.body?.active === "true"))
);

app.post("/admin/pickup/slots", auth.requireAdmin, (request, response) => {
  const locationId = Number.parseInt(request.body?.location, 10);
  const date = String(request.body?.date ?? "");
  const start = String(request.body?.start ?? "");
  const end = String(request.body?.end ?? "");
  return adminWrite(response, async () => {
    const problem = Number.isInteger(locationId) ? slotProblem(date, start, end) : "slot-fields";
    if (problem) return problem;
    await pickup.createSlot(locationId, date, start, end);
  });
});

app.post("/admin/pickup/slots/:id/active", auth.requireAdmin, (request, response) =>
  adminWrite(response, () => pickup.setSlotActive(Number.parseInt(request.params.id, 10), request.body?.active === "true"))
);

// Local delivery settings, slots and schedule. Saving geocodes a changed base
// address, so an error re-renders the page with the message instead of
// redirecting.
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^\d{2}:\d{2}$/;

async function adminDeliveryPage(request, response, notice = "") {
  const vm = await adminData(request, async () => {
    const [s, slots, schedule] = await Promise.all([delivery.settings(), delivery.listSlots(), delivery.deliverySchedule()]);
    const now = new Date();
    return {
      enabled: s.enabled,
      fee: (s.feeCents / 100).toFixed(2),
      radius: String(s.radiusMiles),
      baseAddress: s.baseAddress,
      baseFound: s.base ? `${s.base.lat.toFixed(5)}, ${s.base.lon.toFixed(5)}` : "",
      slots: slots.map((d) => ({ id: d.id, time: delivery.slotLabel(d), active: d.active, past: d.ends_at < now })),
      schedule: schedule.map((o) => {
        const a = o.shipping?.address ?? {};
        return {
          slot: o.delivery_label ?? "",
          number: o.id.slice(-8).toUpperCase(),
          name: o.shipping?.name ?? "",
          phone: o.shipping?.phone ?? "",
          address: [a.line1, a.line2, [a.city, a.state, a.postal_code].filter(Boolean).join(" ")].filter(Boolean).join(", "),
          product: productName(o.product),
          quantity: o.quantity,
          check: o.address_check ?? "none"
        };
      })
    };
  });
  const empty = { enabled: false, fee: "0.00", radius: "", baseAddress: "", baseFound: "", slots: [], schedule: [] };
  response.type("html").send(views.adminDeliveryPage({ ...empty, ...vm, error: notice || vm.error }));
}

app.get("/admin/delivery", auth.requireAdmin, (request, response) => adminDeliveryPage(request, response, adminNotice(request)));

app.post("/admin/delivery/settings", auth.requireAdmin, async (request, response) => {
  const fee = Number.parseFloat(request.body?.fee);
  const radius = Number.parseFloat(request.body?.radius);
  if (!Number.isFinite(fee) || fee < 0 || fee > 1000 || !Number.isFinite(radius) || radius <= 0 || radius > 500) {
    return adminDeliveryPage(request, response, "Enter a fee from $0 to $1000 and a radius from 0 to 500 miles.");
  }
  let error = "";
  try {
    error = await delivery.saveSettings({
      enabled: request.body?.enabled === "on",
      feeCents: Math.round(fee * 100),
      radiusMiles: radius,
      baseAddress: String(request.body?.baseAddress ?? "").trim().slice(0, 300)
    });
  } catch (failure) {
    console.error("Could not save delivery settings:", failure.message);
    error = "The database is unavailable. Try again shortly.";
  }
  if (error) return adminDeliveryPage(request, response, error);
  response.redirect(303, "/admin/delivery");
});

app.post("/admin/delivery/slots", auth.requireAdmin, (request, response) => {
  const date = String(request.body?.date ?? "");
  const start = String(request.body?.start ?? "");
  const end = String(request.body?.end ?? "");
  return adminWrite(response, async () => {
    const problem = slotProblem(date, start, end);
    if (problem) return problem;
    await delivery.createSlot(date, start, end);
  }, "/admin/delivery");
});

app.post("/admin/delivery/slots/:id/active", auth.requireAdmin, (request, response) =>
  adminWrite(response, () => delivery.setSlotActive(Number.parseInt(request.params.id, 10), request.body?.active === "true"), "/admin/delivery")
);

// Page copy (docs/design/site-copy.md): one form per section, Markdown or HTML.
const savedAt = new Intl.DateTimeFormat("en-US", { timeZone: pickup.ZONE, dateStyle: "medium", timeStyle: "short" });

app.get("/admin/site", auth.requireAdmin, async (request, response) => {
  const vm = await adminData(request, async () => ({
    sections: (await copy.list()).map((s) => ({
      key: s.key,
      label: s.label,
      page: s.page,
      body: s.row?.body ?? s.fallback,
      saved: s.row ? `Last saved ${savedAt.format(s.row.updated_at)}${s.row.updated_by ? ` by ${s.row.updated_by}` : ""}.` : "Showing the built-in text."
    }))
  }));
  response.type("html").send(views.adminCopyPage({ sections: [], ...vm, error: adminNotice(request) || vm.error }));
});

app.post("/admin/site/:key", auth.requireAdmin, (request, response) => {
  const body = String(request.body?.body ?? "").replace(/\r\n/g, "\n");
  return adminWrite(response, async () => {
    if (!copy.section(request.params.key)) return "copy-section";
    if (body.length > copy.MAX_LENGTH) return "copy-length";
    await copy.save(request.params.key, body, auth.accountOf(request).email || null);
  }, "/admin/site");
});

// Inventory (docs/design/inventory.md): one form per tracked product. The
// hidden expected field is the count the admin saw, so a save never overwrites
// an order that landed meanwhile.
const changeReason = (change) =>
  change.kind === "price" ? `Price set by ${change.actor ?? "an admin"}`
    : change.reason === "order" ? `Order ${String(change.order_id ?? "").slice(-8).toUpperCase()}`
    : change.reason === "seed" ? "Starting count, from the batch cap"
    : `Set by ${change.actor ?? "an admin"}`;

app.get("/admin/inventory", auth.requireAdmin, async (request, response) => {
  const vm = await adminData(request, async () => ({
    products: (await inventory.list()).map((row) => ({
      slug: row.product.slug,
      name: row.product.name,
      tracked: row.available !== null,
      available: row.available ?? 0,
      sold: row.sold,
      waiting: row.waiting,
      price: (row.cents / 100).toFixed(2),
      changes: row.changes.map((c) => {
        const shown = (n) => (n === null ? "—" : c.kind === "price" ? formatUsd(n) : String(n));
        return { at: savedAt.format(c.at), from: shown(c.before), to: shown(c.after), reason: changeReason(c) };
      })
    }))
  }));
  const sent = Number.parseInt(request.query.sent, 10);
  const failed = Number.parseInt(request.query.failed, 10);
  const notice = Number.isInteger(sent)
    ? `Emailed ${sent} ${sent === 1 ? "person" : "people"}.${failed > 0 ? ` ${failed} couldn't be sent; email them again to retry.` : ""}`
    : "";
  response.type("html").send(views.adminInventoryPage({ products: [], ...vm, error: adminNotice(request) || vm.error, notice }));
});

const trackedProduct = (slug) => products.find((product) => product.slug === slug && product.inventory) ?? null;

app.post("/admin/inventory/:slug", auth.requireAdmin, (request, response) => {
  const value = String(request.body?.available ?? "").trim();
  const expected = String(request.body?.expected ?? "");
  return adminWrite(response, async () => {
    const product = trackedProduct(request.params.slug);
    if (!product) return "inventory-product";
    if (!/^\d{1,6}$/.test(value) || !/^-?\d{1,6}$/.test(expected)) return "inventory-value";
    const saved = await inventory.set(product.slug, Number(value), Number(expected), auth.accountOf(request).email || null);
    if (!saved) return "inventory-changed";
  }, "/admin/inventory");
});

// Any product's price, tracked or not. Dollars with at most two decimals.
app.post("/admin/inventory/:slug/price", auth.requireAdmin, (request, response) => {
  const value = String(request.body?.price ?? "").trim().replace(/^\$/, "");
  return adminWrite(response, async () => {
    const product = products.find((p) => p.slug === request.params.slug);
    if (!product) return "price-product";
    if (!/^\d{1,4}(\.\d{1,2})?$/.test(value)) return "price-value";
    const cents = Math.round(Number(value) * 100);
    if (cents < price.MIN_CENTS || cents > price.MAX_CENTS) return "price-value";
    await price.set(product, cents, auth.accountOf(request).email || null);
  }, "/admin/inventory");
});

// Emails everyone waiting on a product that's back in stock, then reports how
// many went out.
app.post("/admin/inventory/:slug/notify", auth.requireAdmin, async (request, response) => {
  const back = (query) => response.redirect(303, `/admin/inventory?${query}`);
  const product = trackedProduct(request.params.slug);
  if (!product) return back("error=inventory-product");
  if (!db.isConfigured()) return back("error=no-database");
  if (!mail.isConfigured()) return back("error=mail-off");
  try {
    if (!(await inventory.stock(product)).open) return back("error=notify-empty");
    const { sent, failed } = await inventory.notifyWaiting(product);
    back(`sent=${sent}&failed=${failed}`);
  } catch (error) {
    console.error("Could not email the people waiting:", error.message);
    back("error=save-failed");
  }
});

// Anything else: back to the storefront.
app.get(/.*/, (_request, response) => response.redirect(303, "/"));

const server = app.listen(port, () => console.log(`Birdhaus server listening on http://localhost:${port}`));

// Datum sends SIGTERM when it replaces or removes an instance. Keep answering
// for DRAIN_MS in case the edge still routes here, then stop accepting and let
// in-flight requests finish. run.hs gives the instance
// terminationGracePeriodSeconds to cover both; past that it is killed anyway.
const DRAIN_MS = 10_000;
process.once("SIGTERM", () => {
  console.log(`SIGTERM: draining for ${DRAIN_MS / 1000}s before closing`);
  draining = true;
  setTimeout(() => {
    server.close(() => process.exit(0));
    server.closeIdleConnections();
  }, DRAIN_MS);
});
