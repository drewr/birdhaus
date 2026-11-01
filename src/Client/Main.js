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
let clientSecret;
let addressElement;

// Stripe's iframes can't see our CSS, so hand them the tokens from
// src/styles/tokens.css.
function stripeAppearance() {
  const token = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return {
    theme: "flat",
    variables: {
      fontFamily: token("--font-body"),
      colorPrimary: token("--ink"),
      colorText: token("--ink"),
      colorTextSecondary: token("--muted"),
      colorDanger: token("--danger"),
      borderRadius: "0px"
    }
  };
}

// The pay page: wallet buttons (Express Checkout) above the card form. The
// server set the amount (houses plus any delivery fee) from the cart; the
// page's data attributes only label the wallet sheet. A delivery address comes
// from the wallet or the Address Element and is checked and saved on the
// PaymentIntent by the server (/api/delivery/verify) before payment.
async function initializeCheckout() {
  const form = document.getElementById("payment-form");
  const message = document.getElementById("payment-message");
  if (!form || form.dataset.initialized === "true") return;
  form.dataset.initialized = "true";
  const section = document.getElementById("checkout");
  const delivering = section?.dataset.fulfillment === "delivery";
  const quantity = Number(section?.dataset.quantity) || undefined;
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

    clientSecret = result.clientSecret;
    const appearance = stripeAppearance();
    elements = stripe.elements({ clientSecret, appearance });
    mountExpressCheckout(section, delivering);
    if (delivering) {
      // Its own group, so confirming doesn't attach it: the server sets the
      // shipping address it verified.
      addressElement = stripe.elements({ appearance }).create("address", {
        mode: "shipping",
        allowedCountries: ["US"],
        fields: { phone: "always" },
        validation: { phone: { required: "always" } }
      });
      addressElement.mount("#shipping-address");
    }
    elements.create("payment").mount("#payment-element");
    form.addEventListener("submit", submitPayment);
  } catch (error) {
    message.textContent = error.message;
    form.dataset.initialized = "false";
  }
}

export const initCheckout = () => {
  if (document.getElementById("payment-form")) initializeCheckout();
};

// Apple Pay / Google Pay and the like. For delivery the wallet supplies the
// address, name and phone; while the sheet is open only the ZIP is known, so
// that's checked first and the full address again on confirm.
function mountExpressCheckout(section, delivering) {
  const options = { emailRequired: true };
  if (delivering) {
    const quantity = Number(section.dataset.quantity) || 1;
    Object.assign(options, {
      shippingAddressRequired: true,
      allowedShippingCountries: ["US"],
      phoneNumberRequired: true,
      // The intent's amount already includes the fee, so the rate is $0 and the
      // fee is a line item; a priced rate would count it twice.
      shippingRates: [{ id: "local-delivery", displayName: `Local delivery — ${section.dataset.slotLabel}`, amount: 0 }],
      lineItems: [
        { name: `${quantity} × ${section.dataset.productName}`, amount: Number(section.dataset.subtotalCents) || 0 },
        { name: "Local delivery", amount: Number(section.dataset.feeCents) || 0 }
      ]
    });
  }
  const express = elements.create("expressCheckout", options);
  if (delivering) {
    express.on("shippingaddresschange", async (event) => {
      let ok = false;
      try {
        const response = await fetch("/api/delivery/check-zip", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ postal_code: event.address?.postal_code })
        });
        ok = response.ok && (await response.json()).ok === true;
      } catch {
        // a failed check rejects the address; the buyer can retry
      }
      if (ok) event.resolve({});
      else event.reject();
    });
  }
  express.on("confirm", (event) => confirmExpress(event, delivering));
  express.mount("#express-checkout");
}

async function confirmExpress(event, delivering) {
  const message = document.getElementById("payment-message");
  const { error: submitError } = await elements.submit();
  if (submitError) {
    event.paymentFailed({ reason: "fail" });
    message.textContent = submitError.message;
    return;
  }
  if (delivering) {
    const problem = await verifyAddress({
      name: event.shippingAddress?.name || event.billingDetails?.name,
      phone: event.billingDetails?.phone,
      address: event.shippingAddress?.address
    });
    if (problem) {
      event.paymentFailed({ reason: "invalid_shipping_address", message: problem });
      message.textContent = problem;
      return;
    }
  }
  const error = await confirm({ receipt_email: event.billingDetails?.email || document.getElementById("email").value || undefined });
  if (error) message.textContent = error.message;
}

// "" when the server accepted the address (and saved it on the PaymentIntent),
// otherwise the message to show.
async function verifyAddress(details) {
  try {
    const response = await fetch("/api/delivery/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ clientSecret, ...details })
    });
    if (response.ok) return "";
    return (await response.json().catch(() => ({}))).error || "We couldn't check that address. Please try again.";
  } catch {
    return "We couldn't check that address. Please try again.";
  }
}

async function confirm(params) {
  const { error } = await stripe.confirmPayment({
    elements,
    confirmParams: { return_url: `${window.location.origin}/order`, ...params }
  });
  return error;
}

// The card form. For delivery, the Address Element's address is checked by the
// server first.
async function submitPayment(event) {
  event.preventDefault();
  const message = document.getElementById("payment-message");
  const submitButton = document.getElementById("submit-payment");
  const email = document.getElementById("email").value;
  const fail = (text) => {
    message.textContent = text;
    submitButton.disabled = false;
  };

  submitButton.disabled = true;
  message.textContent = "";
  if (addressElement) {
    const { complete, value } = await addressElement.getValue();
    if (!complete) return fail("Please complete the delivery address.");
    const problem = await verifyAddress({ name: value.name, phone: value.phone, address: value.address });
    if (problem) return fail(problem);
  }
  const { error: submitError } = await elements.submit();
  if (submitError) return fail(submitError.message);

  const error = await confirm({ receipt_email: email, payment_method_data: { billing_details: { email } } });
  if (error) fail(error.message);
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

// The product page's thumbnails swap the main photo in place. Without script
// they are links that reload the page on that photo; a modified click still
// opens one in a new tab.
export const initGallery = () => {
  const photo = document.getElementById("product-photo");
  const thumbs = [...document.querySelectorAll(".product-thumb")];
  for (const thumb of thumbs) {
    thumb.addEventListener("click", (event) => {
      if (!photo || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      photo.srcset = thumb.dataset.srcset;
      photo.src = thumb.dataset.src;
      photo.alt = thumb.dataset.alt;
      for (const other of thumbs) other.setAttribute("aria-current", String(other === thumb));
      window.history.replaceState(null, "", thumb.href);
    });
  }
};
