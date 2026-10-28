import "dotenv/config";
import express from "express";
import Stripe from "stripe";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { batchStatus, currentBatch, displayDate } from "./batch.js";
import * as db from "./db.js";

const app = express();
const port = Number(process.env.PORT || 4242);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const batch = currentBatch();
db.migrateInBackground();

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
    console.error(`Could not record ${event.type} ${event.id}:`, error.message);
    response.status(500).json({ error: "Could not record the event." });
  }
});

app.use(express.json());

// remaining is only shown once the batch is nearly gone (under 20% left).
app.get("/api/batch", async (_request, response) => {
  response.set("Cache-Control", "no-store");
  const status = batchStatus(batch, await paidUnits());
  const showRemaining = status.open && status.remaining !== null && batch.cap > 0 && status.remaining < batch.cap * 0.2;
  response.json({
    open: status.open,
    reason: status.reason,
    shipBy: displayDate(batch.shipBy),
    remaining: showRemaining ? status.remaining : null
  });
});

app.post("/api/waitlist", async (request, response) => {
  const email = String(request.body?.email ?? "").trim().toLowerCase();
  const quantity = request.body?.quantity;
  const postalCode = String(request.body?.postalCode ?? "").trim().slice(0, 12) || null;
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.length > 254) {
    return response.status(400).json({ error: "Enter a valid email address." });
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) {
    return response.status(400).json({ error: "Choose a quantity from 1 to 99." });
  }
  if (!db.isConfigured()) return response.status(503).json({ error: "The waitlist is not available yet." });
  try {
    await db.joinWaitlist(batch.id, email, quantity, postalCode);
    response.json({ ok: true });
  } catch (error) {
    console.error("Could not save a waitlist entry:", error.message);
    response.status(500).json({ error: "We could not save your spot. Please try again." });
  }
});

app.post("/api/create-payment-intent", async (request, response) => {
  const quantity = request.body?.quantity;
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) {
    return response.status(400).json({ error: "Choose a quantity from 1 to 99." });
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
  try {
    const stripe = new Stripe(secretKey);
    const intent = await stripe.paymentIntents.create({
      amount: quantity * 4000,
      currency: "usd",
      automatic_payment_methods: { enabled: true },
      description: shipBy ? `Pre-order: Birdhaus Bluebird House × ${quantity}, ships by ${shipBy}` : `Birdhaus Bluebird House × ${quantity}`,
      metadata: { product: "bluebird-house", quantity: String(quantity), batch: batch.id, ship_by: batch.shipBy }
    });
    response.json({ clientSecret: intent.client_secret, publishableKey });
  } catch (error) {
    console.error("Unable to create Stripe PaymentIntent:", error.message);
    response.status(500).json({ error: "We could not start checkout. Please try again." });
  }
});

// The confirmation page's lookup. Stripe appends payment_intent and
// payment_intent_client_secret to the return URL; requiring the matching
// secret keeps order details private to the buyer.
app.get("/api/order/:id", async (request, response) => {
  response.set("Cache-Control", "no-store");
  const id = request.params.id;
  const clientSecret = request.query.client_secret;
  const secretKey = process.env.STRIPE_SECRET_KEY;
  if (!/^pi_[A-Za-z0-9]+$/.test(id) || typeof clientSecret !== "string" || !clientSecret.startsWith(`${id}_secret_`)) {
    return response.status(404).json({ error: "Order not found." });
  }
  if (!secretKey) {
    return response.status(503).json({ error: "Checkout is not configured yet." });
  }

  try {
    const intent = await new Stripe(secretKey).paymentIntents.retrieve(id);
    if (intent.client_secret !== clientSecret) {
      return response.status(404).json({ error: "Order not found." });
    }
    response.json({
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
    });
  } catch (error) {
    if (error.code === "resource_missing") return response.status(404).json({ error: "Order not found." });
    console.error("Unable to retrieve Stripe PaymentIntent:", error.message);
    response.status(500).json({ error: "We could not load your order." });
  }
});

// Image builds pin every file's mtime, so static's size+mtime validators can't
// tell builds apart. Hashed assets never change; the page is sent from memory
// so its ETag is a hash of its content.
const dist = path.join(root, "dist");
const indexHtml = readFileSync(path.join(dist, "index.html"), "utf8");
app.use("/assets", express.static(path.join(dist, "assets"), { immutable: true, maxAge: "1y" }));
app.use(express.static(dist, {
  index: false,
  etag: false,
  lastModified: false,
  setHeaders: (response) => response.setHeader("Cache-Control", "no-cache")
}));
app.get(/.*/, (_request, response) => response.set("Cache-Control", "no-cache").type("html").send(indexHtml));

app.listen(port, () => console.log(`Birdhaus server listening on http://localhost:${port}`));
