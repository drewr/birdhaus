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
import * as pickup from "./pickup.js";
import * as delivery from "./delivery.js";
import { lastGeocodeFailure } from "./geocode.js";

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
    isAdmin: Boolean(account?.admin),
    cartQty: readCart(request).qty,
    reason
  };
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
  // Delivery falls back to ZIP checks while Census is down; report it so the
  // owner hears about it.
  health.geocoder = Date.now() - lastGeocodeFailure < 15 * 60 * 1000
    ? `failing: the Census geocoder could not be reached at ${new Date(lastGeocodeFailure).toISOString()}`
    : "ok";
  const ok = health.db !== "not configured" && !health.db.startsWith("failing") && health.webhook === "ok" && health.geocoder === "ok";
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

  // Pick-up or local delivery; shipping isn't offered yet. The fee comes from
  // the settings now, never from the browser.
  const choice = await cartChoice(request);
  if (!choice) return response.status(409).json({ error: "Choose a new delivery or pick-up time." });

  const shipBy = displayDate(batch.shipBy);
  const account = auth.accountOf(request);
  const metadata = {
    product: "bluebird-house",
    quantity: String(quantity),
    batch: batch.id,
    ship_by: batch.shipBy,
    fulfillment: choice.method
  };
  if (choice.method === "delivery") {
    Object.assign(metadata, { fee_cents: String(choice.feeCents), delivery_slot_id: String(choice.slot.id), delivery_label: choice.label });
  } else {
    Object.assign(metadata, { pickup_slot_id: String(choice.slot.id), pickup_label: choice.label });
  }
  if (account) metadata.account_sub = account.sub;
  try {
    const stripe = new Stripe(secretKey);
    const intent = await stripe.paymentIntents.create({
      amount: quantity * UNIT_PRICE_CENTS + choice.feeCents,
      currency: "usd",
      automatic_payment_methods: { enabled: true },
      description: `${shipBy ? "Pre-order: " : ""}Birdhaus Bluebird House × ${quantity}, ${choice.method === "delivery" ? "local delivery" : "pick-up"}: ${choice.label}`,
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
    quantity: Number(intent.metadata.quantity) || 1,
    shipBy: displayDate(intent.metadata.ship_by),
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
app.post("/api/delivery/check-zip", async (request, response) => {
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
app.post("/api/delivery/verify", async (request, response) => {
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
app.post("/cart/add", (request, response) => {
  const cart = readCart(request);
  const add = Number.parseInt(request.body?.quantity, 10);
  const qty = Number.isInteger(add) && add > 0 ? Math.min(cart.qty + add, 99) : Math.max(cart.qty, 1);
  writeCart(response, { ...cart, qty });
  response.redirect(303, "/cart");
});

// The cart stepper. HTMX gets the re-rendered #cart fragment; no-JS gets a 303.
app.post("/cart/update", async (request, response) => {
  const cart = readCart(request);
  const target = Number.parseInt(request.body?.quantity, 10);
  const qty = Number.isInteger(target) ? Math.min(Math.max(target, 1), 99) : cart.qty;
  writeCart(response, { ...cart, qty });
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
    wlPostalCode: "",
    fulfillmentNote: await fulfillmentNote()
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
    maxQuantity: stepperLimit(status),
    fulfillmentNote: await fulfillmentNote()
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.cartPage(vm));
});

// Checkout step 1: how to get the house. Shipping is shown but greyed out until
// USPS pricing is added (docs/design/fulfillment.md); the choices are pick-up
// and, when an admin has switched it on, local delivery (local-delivery.md).
async function deliveryPage(request, response, error = "") {
  const cart = readCart(request);
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
    quantity: cart.qty,
    total: formatTotal(cart.qty),
    error,
    slots: pickupSlots.map((p) => ({ id: p.id, location: p.name, details: p.details, time: pickup.slotTime(p.starts_at, p.ends_at), selected: chosen("pickup", p.id) })),
    deliveryFee: settings ? formatUsd(settings.feeCents) : "",
    deliveryRadius: settings ? String(settings.radiusMiles) : "",
    deliverySlots: deliverySlots.map((d) => ({ id: d.id, time: delivery.slotLabel(d), selected: chosen("delivery", d.id) }))
  };
  response.set("Cache-Control", "no-cache").type("html").send(views.deliveryPage(vm));
}

app.get("/checkout", (request, response) => {
  if (readCart(request).qty <= 0) return response.redirect(303, "/cart");
  return deliveryPage(request, response);
});

// The choice posts as "pickup:<slot id>" or "delivery:<slot id>".
app.post("/checkout/delivery", async (request, response) => {
  const cart = readCart(request);
  if (cart.qty <= 0) return response.redirect(303, "/cart");
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
app.get("/checkout/pay", async (request, response) => {
  const qty = readCart(request).qty;
  if (qty <= 0) return response.redirect(303, "/cart");
  const choice = await cartChoice(request);
  if (!choice) return response.redirect(303, "/checkout");
  const account = auth.accountOf(request);
  const subtotalCents = qty * UNIT_PRICE_CENTS;
  const vm = {
    ...chrome(request),
    quantity: qty,
    subtotal: formatTotal(qty),
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
    : { ...base, status: "error", message: "", number: "", date: "", items: "", total: "", email: "", shipTo: [], shipBy: "", quantity: 1, fulfillment: "ship", pickupLabel: "", deliveryLabel: "" };
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
      quantity: o.quantity,
      total: formatUsd(o.amount),
      status: o.status,
      method: o.fulfillment === "pickup" ? `Pick-up: ${o.pickup_label ?? ""}` : o.fulfillment === "delivery" ? `Delivery: ${o.delivery_label ?? ""}` : "Ship"
    }))
  }));
  response.type("html").send(views.adminOrdersPage({ orders: [], ...vm }));
});

app.get("/admin/pickup", auth.requireAdmin, async (request, response) => {
  const vm = await adminData(request, async () => {
    const [locations, slots, schedule] = await Promise.all([pickup.listLocations(), pickup.listSlots(), pickup.pickupSchedule()]);
    const now = new Date();
    return {
      locations: locations.map((l) => ({ id: l.id, name: l.name, details: l.details, active: l.active })),
      slots: slots.map((s) => ({ id: s.id, location: s.name, time: pickup.slotTime(s.starts_at, s.ends_at), active: s.active, past: s.ends_at < now })),
      schedule: schedule.map((o) => ({ slot: o.pickup_label ?? "", email: o.email ?? "", quantity: o.quantity, number: o.id.slice(-8).toUpperCase() }))
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

// Anything else: back to the storefront.
app.get(/.*/, (_request, response) => response.redirect(303, "/"));

app.listen(port, () => console.log(`Birdhaus server listening on http://localhost:${port}`));
