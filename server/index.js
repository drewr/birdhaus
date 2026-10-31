import "dotenv/config";
import express from "express";
import Stripe from "stripe";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { batchStatus, currentBatch, displayDate } from "./batch.js";
import { UNIT_PRICE_CENTS, formatUsd, formatTotal } from "./price.js";
import { readCart, writeCart, clearCart } from "./cart.js";
import { formatOrder } from "./order-format.js";
import * as auth from "./auth.js";
import * as db from "./db.js";

const app = express();
const port = Number(process.env.PORT || 4242);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dist = path.join(root, "dist");
const batch = currentBatch();
db.migrateInBackground();

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
    cartQty: readCart(request).qty,
    reason
  };
}

// Units the stepper may reach: the batch cap (when nearly gone) or 99.
function stepperLimit(status) {
  return status.remaining === null ? 99 : Math.max(Math.min(99, status.remaining), 1);
}

// When the webhook last failed to write to the database; /api/health reports it.
let lastWebhookFailure = 0;

// Paid units in the batch, or null when there is no database or it is down.
async function paidUnits() {
  if (!db.isConfigured()) return null;
  try {
    return await db.paidUnits(batch.id);
  } catch (error) {
    console.error("Could not count paid pre-orders; leaving the batch open:", error.message);
    return null;
  }
}

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
    if (event.type === "payment_intent.succeeded") {
      await db.recordOrder(event.data.object);
    } else if (event.type === "charge.refunded") {
      const charge = event.data.object;
      if (charge.refunded && charge.payment_intent) await db.markRefunded(charge.payment_intent);
    }
    response.json({ received: true });
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
  const health = { db: "not configured", webhook: "ok" };
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
  const ok = health.db !== "not configured" && !health.db.startsWith("failing") && health.webhook === "ok";
  response.status(ok ? 200 : 503).json(health);
});

// The quantity is the server's cart cookie, never a browser-supplied amount.
app.post("/api/create-payment-intent", async (request, response) => {
  const quantity = readCart(request).qty;
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) {
    return response.status(400).json({ error: "Your cart is empty." });
  }

  const secretKey = process.env.STRIPE_SECRET_KEY;
  const publishableKey = process.env.VITE_STRIPE_PUBLISHABLE_KEY || process.env.STRIPE_PUBLISHABLE_KEY;
  if (!secretKey || !publishableKey) {
    return response.status(503).json({ error: "Checkout is not configured yet. Please try again later." });
  }

  const status = batchStatus(batch, await paidUnits());
  if (!status.open) {
    return response.status(409).json({ soldOut: true, error: status.reason === "closed" ? "Pre-orders for this batch have closed." : "This batch has sold out." });
  }
  if (status.remaining !== null && quantity > status.remaining) {
    return response.status(409).json({ error: `Only ${status.remaining} left in this batch. Lower the quantity, or join the waitlist for more.` });
  }

  const shipBy = displayDate(batch.shipBy);
  const account = auth.accountOf(request);
  const metadata = { product: "bluebird-house", quantity: String(quantity), batch: batch.id, ship_by: batch.shipBy };
  if (account) metadata.account_sub = account.sub;
  try {
    const stripe = new Stripe(secretKey);
    const intent = await stripe.paymentIntents.create({
      amount: quantity * UNIT_PRICE_CENTS,
      currency: "usd",
      automatic_payment_methods: { enabled: true },
      description: shipBy ? `Pre-order: Birdhaus Bluebird House × ${quantity}, ships by ${shipBy}` : `Birdhaus Bluebird House × ${quantity}`,
      metadata
    });
    response.json({ clientSecret: intent.client_secret, publishableKey });
  } catch (error) {
    console.error("Unable to create Stripe PaymentIntent:", error.message);
    response.status(500).json({ error: "We could not start checkout. Please try again." });
  }
});

// Retrieve an order, gated by the client_secret Stripe appended to the return
// URL (possession proves it's the buyer). Returns a trimmed view or null.
async function lookupOrder(id, clientSecret) {
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (typeof id !== "string" || !/^pi_[A-Za-z0-9]+$/.test(id)) return null;
  if (typeof clientSecret !== "string" || !clientSecret.startsWith(`${id}_secret_`)) return null;
  if (!secretKey) return null;
  try {
    const intent = await new Stripe(secretKey).paymentIntents.retrieve(id);
    if (intent.client_secret !== clientSecret) return null;
    return {
      id: intent.id,
      status: intent.status,
      created: intent.created,
      amount: intent.amount,
      currency: intent.currency,
      quantity: Number(intent.metadata.quantity) || 1,
      shipBy: displayDate(intent.metadata.ship_by),
      email: intent.receipt_email,
      shipping: intent.shipping && { name: intent.shipping.name, address: intent.shipping.address },
      error: intent.last_payment_error?.message
    };
  } catch (error) {
    if (error.code === "resource_missing") return null;
    console.error("Unable to retrieve Stripe PaymentIntent:", error.message);
    return null;
  }
}

// Kept as JSON too, for any out-of-band lookup.
app.get("/api/order/:id", async (request, response) => {
  response.set("Cache-Control", "no-store");
  const order = await lookupOrder(request.params.id, request.query.client_secret);
  if (!order) return response.status(404).json({ error: "Order not found." });
  response.json(order);
});

// -------------------------------------------------------------- cart mutations

// Add the chosen amount to what's already in the cart (form POST, 303 to /cart).
app.post("/cart/add", (request, response) => {
  const current = readCart(request).qty;
  const add = Number.parseInt(request.body?.quantity, 10);
  const qty = Number.isInteger(add) && add > 0 ? Math.min(current + add, 99) : Math.max(current, 1);
  writeCart(response, qty);
  response.redirect(303, "/cart");
});

// The cart stepper. HTMX gets the re-rendered #cart fragment; no-JS gets a 303.
app.post("/cart/update", async (request, response) => {
  const target = Number.parseInt(request.body?.quantity, 10);
  const qty = Number.isInteger(target) ? Math.min(Math.max(target, 1), 99) : readCart(request).qty;
  writeCart(response, qty);
  if (request.get("HX-Request")) {
    const status = batchStatus(batch, await paidUnits());
    const vm = {
      ...chrome(request),
      cartQty: qty,
      lineTotal: formatTotal(qty),
      subtotal: formatTotal(qty),
      shipBy: displayDate(batch.shipBy),
      maxQuantity: stepperLimit(status)
    };
    return response.set("Cache-Control", "no-cache").type("html").send(views.cartFragment(vm));
  }
  response.redirect(303, "/cart");
});

app.post("/cart/clear", (request, response) => {
  clearCart(response);
  response.redirect(303, "/");
});

// -------------------------------------------------------------- waitlist

app.post("/waitlist", async (request, response) => {
  const account = auth.accountOf(request);
  const authEnabled = auth.isConfigured();
  const base = {
    authEnabled,
    signUpUrl: auth.signUpUrl(),
    signedIn: Boolean(account),
    accountLabel: account ? account.name || account.email : ""
  };
  const hx = Boolean(request.get("HX-Request"));
  const email = account ? account.email : String(request.body?.email ?? "").trim().toLowerCase();
  const quantity = Number.parseInt(request.body?.quantity, 10);
  const postalCode = String(request.body?.postalCode ?? "").trim().slice(0, 12) || null;

  const fail = (message) => {
    if (!hx) return response.redirect(303, "/");
    const vm = { ...base, wlState: "error", wlMessage: message, wlEmail: email, wlQuantity: Number.isInteger(quantity) ? String(quantity) : "", wlPostalCode: postalCode ?? "" };
    return response.status(200).type("html").send(views.waitlistFragment(vm));
  };

  // Joining requires an account when sign-in is available. A guest-only
  // deployment (no auth) still takes an email.
  if (authEnabled && !account) return fail("Please sign in to join the waitlist.");
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) return fail("Enter a valid email address.");
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) return fail("Choose a quantity from 1 to 99.");
  if (!db.isConfigured()) return fail("The waitlist is not available yet.");
  try {
    await db.joinWaitlist(batch.id, email, quantity, postalCode, account?.sub ?? null);
  } catch (error) {
    console.error("Could not save a waitlist entry:", error.message);
    return fail("We could not save your spot. Please try again.");
  }
  if (!hx) return response.redirect(303, "/");
  const vm = { ...base, wlState: "joined", wlMessage: "", wlEmail: email, wlQuantity: String(quantity), wlPostalCode: postalCode ?? "" };
  response.type("html").send(views.waitlistFragment(vm));
});

// -------------------------------------------------------------- static + pages

// Image builds pin every file's mtime, so static's validators can't tell builds
// apart; hashed /assets are immutable, everything else no-cache.
app.use("/assets", express.static(path.join(dist, "assets"), { immutable: true, maxAge: "1y" }));
app.use(express.static(dist, {
  index: false,
  etag: false,
  lastModified: false,
  setHeaders: (response) => response.setHeader("Cache-Control", "no-cache")
}));

app.get("/", async (request, response) => {
  const status = batchStatus(batch, await paidUnits());
  const showRemaining = status.open && status.remaining !== null && batch.cap > 0 && status.remaining < batch.cap * 0.2;
  const vm = {
    ...chrome(request, status.reason),
    authEnabled: auth.isConfigured(),
    signUpUrl: auth.signUpUrl(),
    open: status.open,
    shipBy: displayDate(batch.shipBy),
    remaining: showRemaining ? status.remaining : -1,
    priceEach: formatUsd(UNIT_PRICE_CENTS),
    maxQuantity: stepperLimit(status),
    wlState: "editing",
    wlMessage: "",
    wlEmail: "",
    wlQuantity: "1",
    wlPostalCode: ""
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.productPage(vm));
});

app.get("/cart", async (request, response) => {
  const qty = readCart(request).qty;
  if (qty <= 0) return response.redirect(303, "/");
  const status = batchStatus(batch, await paidUnits());
  const vm = {
    ...chrome(request),
    cartQty: qty,
    lineTotal: formatTotal(qty),
    subtotal: formatTotal(qty),
    shipBy: displayDate(batch.shipBy),
    maxQuantity: stepperLimit(status)
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.cartPage(vm));
});

app.get("/checkout", (request, response) => {
  const qty = readCart(request).qty;
  if (qty <= 0) return response.redirect(303, "/cart");
  const vm = { ...chrome(request), quantity: qty, total: formatTotal(qty) };
  response.set("Cache-Control", "no-cache").type("html").send(views.checkoutPage(vm));
});

app.get("/order", async (request, response) => {
  response.set("Cache-Control", "no-store");
  const order = await lookupOrder(request.query.payment_intent, request.query.payment_intent_client_secret);
  const base = chrome(request);
  const vm = order
    ? { ...base, ...formatOrder(order) }
    : { ...base, status: "error", message: "", number: "", date: "", items: "", total: "", email: "", shipTo: [], shipBy: "", quantity: 1 };
  response.type("html").send(views.confirmationPage(vm));
});

// Anything else: back to the storefront.
app.get(/.*/, (_request, response) => response.redirect(303, "/"));

app.listen(port, () => console.log(`Birdhaus server listening on http://localhost:${port}`));
