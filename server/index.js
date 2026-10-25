import "dotenv/config";
import express from "express";
import Stripe from "stripe";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const app = express();
const port = Number(process.env.PORT || 4242);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
app.use(express.json());

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

  try {
    const stripe = new Stripe(secretKey);
    const intent = await stripe.paymentIntents.create({
      amount: quantity * 4000,
      currency: "usd",
      automatic_payment_methods: { enabled: true },
      description: `Birdhaus Bluebird House × ${quantity}`,
      metadata: { product: "bluebird-house", quantity: String(quantity) }
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
