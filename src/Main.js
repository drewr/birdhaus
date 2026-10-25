import { loadStripe } from "@stripe/stripe-js";

const params = new URLSearchParams(window.location.search);

export const isPaymentComplete = params.get("payment") === "complete";

const emptyOrder = { status: "error", message: "", number: "", date: "", items: "", total: "", email: "", shipTo: [] };

// EffectFnAff: resolves to an order summary formatted for display. Failures
// resolve too, as status "error", so the page can still say something useful.
export const fetchOrder = (_onError, onSuccess) => {
  const id = params.get("payment_intent");
  const clientSecret = params.get("payment_intent_client_secret");
  const controller = new AbortController();

  (async () => {
    if (!id || !clientSecret) return emptyOrder;
    const response = await fetch(`/api/order/${encodeURIComponent(id)}?client_secret=${encodeURIComponent(clientSecret)}`, {
      signal: controller.signal
    });
    if (!response.ok) return emptyOrder;
    return formatOrder(await response.json());
  })().then(onSuccess, () => onSuccess(emptyOrder));

  return (_cancelError, _onCancelerError, onCancelerSuccess) => {
    controller.abort();
    onCancelerSuccess();
  };
};

function formatOrder(order) {
  const status =
    order.status === "succeeded" ? "succeeded"
    : order.status === "processing" ? "processing"
    : "failed";
  const money = new Intl.NumberFormat("en-US", { style: "currency", currency: order.currency.toUpperCase() });
  const address = order.shipping?.address ?? {};
  const cityLine = [address.city, [address.state, address.postal_code].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  return {
    status,
    message: order.error ?? "",
    number: order.id.slice(-8).toUpperCase(),
    date: new Date(order.created * 1000).toLocaleDateString("en-US", { dateStyle: "long" }),
    items: `${order.quantity} × Bluebird House`,
    total: `${money.format(order.amount / 100)} ${order.currency.toUpperCase()}`,
    email: order.email ?? "",
    shipTo: [order.shipping?.name, address.line1, address.line2, cityLine, address.country].filter(Boolean)
  };
}

export const startCheckout = (quantity) => () => {
  requestAnimationFrame(() => requestAnimationFrame(() => initializeCheckout(quantity)));
};

let elements;
let stripe;
let shippingAddress;
let paymentElement;

async function initializeCheckout(quantity) {
  const buyButton = document.querySelector(".product-details .buy-button");
  const form = document.getElementById("payment-form");
  const message = document.getElementById("payment-message");
  if (!form || form.dataset.initialized === "true") return;
  form.dataset.initialized = "true";
  if (buyButton) buyButton.disabled = true;

  try {
    const response = await fetch("/api/create-payment-intent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ quantity })
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Unable to start checkout.");

    stripe = await loadStripe(result.publishableKey);
    if (!stripe) throw new Error("Stripe could not be loaded. Please try again.");

    elements = stripe.elements({ clientSecret: result.clientSecret, appearance: { theme: "flat" } });
    shippingAddress = elements.create("address", { mode: "shipping" });
    shippingAddress.mount("#shipping-address");
    paymentElement = elements.create("payment");
    paymentElement.mount("#payment-element");
    form.addEventListener("submit", submitPayment);
  } catch (error) {
    message.textContent = error.message;
    form.dataset.initialized = "false";
    if (buyButton) buyButton.disabled = false;
  }
}

export const resetCheckout = () => {
  if (shippingAddress) shippingAddress.unmount();
  if (paymentElement) paymentElement.unmount();
  const form = document.getElementById("payment-form");
  if (form) {
    form.removeEventListener("submit", submitPayment);
    form.dataset.initialized = "false";
  }
  elements = undefined;
  shippingAddress = undefined;
  paymentElement = undefined;
};

async function submitPayment(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const message = document.getElementById("payment-message");
  const submitButton = document.getElementById("submit-payment");
  const email = document.getElementById("email").value;

  submitButton.disabled = true;
  message.textContent = "";
  const { error: submitError } = await elements.submit();
  if (submitError) {
    message.textContent = submitError.message;
    submitButton.disabled = false;
    return;
  }

  const { complete } = await shippingAddress.getValue();
  if (!complete) {
    message.textContent = "Please complete your shipping address.";
    submitButton.disabled = false;
    return;
  }

  const { error } = await stripe.confirmPayment({
    elements,
    confirmParams: {
      return_url: `${window.location.origin}/?payment=complete`,
      receipt_email: email,
      payment_method_data: { billing_details: { email } }
    }
  });

  if (error) {
    message.textContent = error.message;
    submitButton.disabled = false;
  }
}
