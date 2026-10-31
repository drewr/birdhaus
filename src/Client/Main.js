import { loadStripe } from "@stripe/stripe-js";

// The account id is server-rendered onto <body data-account-id>; empty for guests.
const accountId = () => document.body?.dataset.accountId || "";

// Umami custom events. The tracker loads deferred and may be blocked, so this
// never throws. Every event carries loggedIn so conversions can be split.
function track(name, data) {
  try {
    window.umami?.track(name, { ...(data ?? {}), loggedIn: Boolean(accountId()) });
  } catch {
    // analytics must never break the store
  }
}

// Identify the signed-in user (the Rauthy subject, never the email), report a
// login after the callback redirect, and count a sold-out view.
export const initAnalytics = () => {
  const id = accountId();
  if (id) {
    try {
      window.umami?.identify({ id });
    } catch {
      // analytics must never break the store
    }
  }
  const params = new URLSearchParams(window.location.search);
  if (params.get("auth") === "in") {
    const url = new URL(window.location.href);
    url.searchParams.delete("auth");
    window.history.replaceState({}, "", url);
    window.addEventListener("load", () => track("login"), { once: true });
  }
  const reason = document.body?.dataset.batchReason;
  if (reason && reason !== "open") track("sold-out-view", { reason });
};

// Sign-out is a normal link to /api/auth/logout; fire the event before it leaves.
export const initSignOut = () => {
  for (const link of document.querySelectorAll("a[data-signout]")) {
    link.addEventListener("click", () => {
      try {
        window.umami?.track("logout", { loggedIn: true });
      } catch {
        // analytics must never break sign-out
      }
    });
  }
};

// The waitlist posts via HTMX; count a join when the swapped-in fragment is the
// joined state.
export const initWaitlistTracking = () => {
  document.body?.addEventListener("htmx:afterSwap", (event) => {
    const target = event.target;
    if (target && target.querySelector && target.querySelector("[data-waitlist-joined]")) {
      track("waitlist-join", {});
    }
  });
};

let elements;
let stripe;
let shippingAddress;
let paymentElement;

// Mount Stripe Elements on the checkout page. The server sets price and reads the
// quantity from the cart cookie, so the browser sends no amount.
async function initializeCheckout() {
  const form = document.getElementById("payment-form");
  const message = document.getElementById("payment-message");
  if (!form || form.dataset.initialized === "true") return;
  form.dataset.initialized = "true";
  const quantity = Number(document.getElementById("checkout")?.dataset.quantity) || undefined;
  track("checkout-start", { quantity });

  try {
    const response = await fetch("/api/create-payment-intent", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}"
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
  }
}

export const initCheckout = () => {
  if (document.getElementById("payment-form")) initializeCheckout();
};

async function submitPayment(event) {
  event.preventDefault();
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
      return_url: `${window.location.origin}/order`,
      receipt_email: email,
      payment_method_data: { billing_details: { email } }
    }
  });

  if (error) {
    message.textContent = error.message;
    submitButton.disabled = false;
  }
}

// On the confirmation page, count a paid pre-order once (a reload must not
// double-count). Status and quantity are server-rendered as data attributes.
export const initConfirmation = () => {
  const root = document.getElementById("payment-success");
  if (!root || root.dataset.orderStatus !== "succeeded") return;
  const quantity = Number(root.dataset.orderQuantity) || 1;
  const id = new URLSearchParams(window.location.search).get("payment_intent") || "order";
  try {
    const key = `tracked:${id}`;
    if (sessionStorage.getItem(key)) return;
    sessionStorage.setItem(key, "1");
  } catch {
    // storage unavailable: count it anyway
  }
  track("preorder-paid", { quantity });
};
