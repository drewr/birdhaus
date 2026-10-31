import { loadStripe } from "@stripe/stripe-js";

const params = new URLSearchParams(window.location.search);

export const isPaymentComplete = params.get("payment") === "complete";

const emptyOrder = { status: "error", message: "", number: "", date: "", items: "", total: "", email: "", shipTo: [], shipBy: "" };
const signedOut = { signedIn: false, id: "", email: "", name: "", authEnabled: true, signUpUrl: "" };

// Set by fetchMe. Every event carries loggedIn so conversions can be split.
let account = null;

// Umami custom events. The tracker loads deferred and may be blocked, so this
// never throws and silently does nothing without it.
function track(name, data) {
  try {
    window.umami?.track(name, { ...(data ?? {}), loggedIn: Boolean(account) });
  } catch {
    // analytics must never break the store
  }
}

// Wraps a promise-returning function as an EffectFnAff that always succeeds.
const effectFnAff = (run) => (_onError, onSuccess) => {
  const controller = new AbortController();
  run(controller.signal).then(onSuccess);
  return (_cancelError, _onCancelerError, onCancelerSuccess) => {
    controller.abort();
    onCancelerSuccess();
  };
};

// The signed-in account, if any. Also tells Umami who this is (the Rauthy
// subject, never the email) and reports a login after the callback redirect.
export const fetchMe = effectFnAff(async (signal) => {
  try {
    const response = await fetch("/api/me", { signal, headers: { accept: "application/json" } });
    if (!response.ok) return signedOut;
    const me = await response.json();
    if (!me.signedIn) return { ...signedOut, authEnabled: me.authEnabled !== false, signUpUrl: me.signUpUrl ?? "" };
    account = me;
    try {
      window.umami?.identify({ id: me.id });
    } catch {
      // analytics must never break sign-in
    }
    if (params.get("auth") === "in") {
      const url = new URL(window.location.href);
      url.searchParams.delete("auth");
      window.history.replaceState({}, "", url);
      window.addEventListener("load", () => track("login"), { once: true });
    }
    return { signedIn: true, id: me.id ?? "", email: me.email ?? "", name: me.name ?? "", authEnabled: true, signUpUrl: me.signUpUrl ?? "" };
  } catch {
    return signedOut;
  }
});

export const signOut = () => {
  try {
    window.umami?.track("logout", { loggedIn: true });
  } catch {
    // analytics must never break sign-out
  }
  // A full navigation, not fetch: the endpoint redirects to Rauthy to end the
  // identity session, then back to the store.
  window.location.assign("/api/auth/logout");
};

// If the batch can't be loaded, show the store as open; the server still
// enforces the cap when checkout starts.
const openBatch = { open: true, reason: "open", shipBy: "", remaining: -1 };

export const fetchBatch = effectFnAff(async (signal) => {
  try {
    const response = await fetch("/api/batch", { signal });
    if (!response.ok) return openBatch;
    const batch = await response.json();
    if (!batch.open) track("sold-out-view", { reason: batch.reason });
    return { open: batch.open, reason: batch.reason, shipBy: batch.shipBy ?? "", remaining: batch.remaining ?? -1 };
  } catch {
    return openBatch;
  }
});

export const joinWaitlist = (email) => (quantity) => (postalCode) => effectFnAff(async (signal) => {
  try {
    const response = await fetch("/api/waitlist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, quantity, postalCode }),
      signal
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) return result.error || "We could not save your spot. Please try again.";
    track("waitlist-join", { quantity });
    return "";
  } catch {
    return "We could not save your spot. Please try again.";
  }
});

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
    const order = formatOrder(await response.json());
    trackPaidOnce(id, order);
    return order;
  })().then(onSuccess, () => onSuccess(emptyOrder));

  return (_cancelError, _onCancelerError, onCancelerSuccess) => {
    controller.abort();
    onCancelerSuccess();
  };
};

// Reloading the confirmation page must not count the sale twice.
function trackPaidOnce(id, order) {
  if (order.status !== "succeeded") return;
  try {
    const key = `tracked:${id}`;
    if (sessionStorage.getItem(key)) return;
    sessionStorage.setItem(key, "1");
  } catch {
    // storage unavailable: count it anyway
  }
  track("preorder-paid", { quantity: order.quantity });
}

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
    shipTo: [order.shipping?.name, address.line1, address.line2, cityLine, address.country].filter(Boolean),
    shipBy: order.shipBy ?? "",
    quantity: order.quantity
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
  track("checkout-start", { quantity });

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
