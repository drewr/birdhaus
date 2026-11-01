import crypto from "node:crypto";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { cookies, sign, unsign, cookieOptions, now } from "./cookies.js";
import * as db from "./db.js";

// OpenID Connect login against Rauthy (auth/README.md). The issuer, client and
// session key come from the birdhaus-store-auth Secret. A missing configuration
// only disables accounts: checkout and the rest of the store keep running.

const ISSUER = (process.env.OIDC_ISSUER || "").replace(/\/+$/, "");
// The public hostname hairpins through the edge and times out from inside the
// Datum Network, so discovery, JWKS and the token exchange use the private
// address. The issuer stays public for token validation and browser redirects.
const INTERNAL = (process.env.OIDC_INTERNAL_URL || "").replace(/\/+$/, "");
const CLIENT_ID = process.env.OIDC_CLIENT_ID || "";
const CLIENT_SECRET = process.env.OIDC_CLIENT_SECRET || "";
const REDIRECT_URI = process.env.OIDC_REDIRECT_URI || "";
const SESSION_SECRET = process.env.SESSION_SECRET || "";

const SESSION_COOKIE = "bh_session";
const STATE_COOKIE = "bh_auth";
const SESSION_TTL = 7 * 24 * 60 * 60;
// Store admins are members of this Rauthy group (not Rauthy's own admin role).
// Membership is read from the id_token at sign-in, so the admin flag lapses
// sooner than the session and is refreshed by signing in again.
const ADMIN_GROUP = process.env.ADMIN_GROUP || "birdhaus-admins";
const ADMIN_TTL = 12 * 60 * 60;

export const isConfigured = () => Boolean(ISSUER && CLIENT_ID && CLIENT_SECRET && REDIRECT_URI && SESSION_SECRET);

let discovery;
let jwks;

// Cached discovery and JWKS. A failure is retried on the next login instead of
// leaving the store unable to sign anyone in for the life of the instance.
function internalEndpoint(url) {
  if (!INTERNAL) return url;
  const target = new URL(url);
  if (target.origin !== new URL(ISSUER).origin) return url;
  return `${INTERNAL}${target.pathname}${target.search}`;
}

async function metadata() {
  if (!discovery) {
    discovery = (async () => {
      const response = await fetch(`${INTERNAL || ISSUER}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error(`discovery returned ${response.status}`);
      const found = await response.json();
      found.token_endpoint = internalEndpoint(found.token_endpoint);
      found.jwks_uri = internalEndpoint(found.jwks_uri);
      jwks = createRemoteJWKSet(new URL(found.jwks_uri));
      return found;
    })().catch((error) => {
      discovery = undefined;
      throw error;
    });
  }
  return discovery;
}

// cookies/sign/unsign/cookieOptions/now live in cookies.js, shared with the cart.

// Starts sign-in through Rauthy, straight at an upstream provider (by its name
// in Rauthy, e.g. "google"). Email sign-in is the store's own (email-login.js).
export function loginUrl(next = "/", options = {}) {
  const query = new URLSearchParams();
  if (next !== "/") query.set("next", next);
  if (options.provider) query.set("provider", options.provider);
  const rest = query.toString();
  return `/api/auth/login${rest ? `?${rest}` : ""}`;
}

// Rauthy's upstream providers by lowercased name, for idp_hint. Its public
// list, cached briefly so a provider added in the admin UI shows up.
let providers;
let providersAt = 0;
async function providerId(name) {
  if (!providers || now() - providersAt > 600) {
    const response = await fetch(`${INTERNAL || ISSUER}/auth/v1/providers/minimal`, { signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error(`providers returned ${response.status}`);
    providers = new Map((await response.json()).map((provider) => [String(provider.name).toLowerCase(), provider.id]));
    providersAt = now();
  }
  return providers.get(name) ?? null;
}

// The session outlives the ID token (minutes, the client's token lifetime), and
// Rauthy rejects an id_token_hint more than ten minutes past its expiry. The
// token was verified at sign-in, so reading its exp unverified is enough here.
const HINT_GRACE = 600 - 60;
function hintUsable(idToken) {
  try {
    const { exp } = JSON.parse(Buffer.from(idToken.split(".")[1], "base64url").toString("utf8"));
    return Number.isInteger(exp) && exp + HINT_GRACE > now();
  } catch {
    return false;
  }
}

// Only same-site paths, so a crafted link cannot bounce a fresh login off-site.
export function safeNext(value) {
  const next = typeof value === "string" ? value : "";
  return next.startsWith("/") && !next.startsWith("//") && next.length <= 512 ? next : "/";
}

// The signed-in account, or null. Attached to /api/create-payment-intent so the
// order keeps its owner through the webhook.
export function accountOf(request) {
  if (!isConfigured()) return null;
  const session = unsign(cookies(request)[SESSION_COOKIE]);
  if (!session || typeof session.sub !== "string") return null;
  const admin = session.admin === true && Number(session.adminUntil) > now();
  return { sub: session.sub, email: session.email || "", name: session.name || "", admin };
}

// Gate for /admin. Signed-out visitors sign in (which also refreshes a lapsed
// admin flag); signed-in non-admins see a 404, so the portal isn't advertised.
// POSTs must come from this origin; session cookies are SameSite=Lax as well.
export function requireAdmin(request, response, next) {
  response.set("Cache-Control", "no-store");
  const account = accountOf(request);
  if (!account) {
    const next = request.method === "GET" ? safeNext(request.originalUrl) : "/admin";
    return response.redirect(303, `/login?next=${encodeURIComponent(next)}`);
  }
  if (!account.admin) return response.status(404).type("text").send("Not found");
  if (request.method === "POST" && !sameOrigin(request)) return response.status(403).type("text").send("Forbidden");
  next();
}

// A POST from the store's own pages. TLS ends at the edge, so the public
// origin comes from the redirect URI.
export function sameOrigin(request) {
  const origin = request.get("origin");
  return Boolean(origin) && (origin === new URL(REDIRECT_URI).origin || origin === `${request.protocol}://${request.get("host")}`);
}

// Signs the browser in, from either Google (through Rauthy) or an emailed
// code. Past guest orders are claimed only with a verified address. The admin
// flag comes from Rauthy groups and lapses before the session does.
export async function startSession(response, { sub, email, name, groups, emailVerified, idToken }) {
  if (emailVerified && email) {
    try {
      await db.linkOrders(sub, email);
    } catch (error) {
      console.error("Could not link past orders:", error.message);
    }
  }
  const admin = Array.isArray(groups) && groups.includes(ADMIN_GROUP);
  response.cookie(
    SESSION_COOKIE,
    sign({ sub, email, name, admin, adminUntil: now() + ADMIN_TTL, ...(idToken ? { id_token: idToken } : {}), exp: now() + SESSION_TTL }),
    cookieOptions(SESSION_TTL)
  );
}

// Where to land after signing in; ?auth=in tells the client to count a login
// and is removed from the address bar before the page settles.
export function landing(next) {
  const destination = new URL(next || "/", new URL(REDIRECT_URI).origin);
  destination.searchParams.set("auth", "in");
  return destination.toString();
}

export function me(request, response) {
  response.set("Cache-Control", "no-store");
  const authEnabled = isConfigured();
  const account = accountOf(request);
  if (!account) return response.json({ signedIn: false, authEnabled });
  response.json({ signedIn: true, authEnabled, id: account.sub, email: account.email, name: account.name });
}

// The token endpoint prefers basic auth unless it advertises only post.
async function exchange(found, fields) {
  const methods = found.token_endpoint_auth_methods_supported || [];
  const basic = methods.length === 0 || methods.includes("client_secret_basic");
  const body = new URLSearchParams({ ...fields, grant_type: "authorization_code" });
  const headers = { "content-type": "application/x-www-form-urlencoded" };
  if (basic) {
    headers.authorization = `Basic ${Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString("base64")}`;
  } else {
    body.set("client_id", CLIENT_ID);
    body.set("client_secret", CLIENT_SECRET);
  }
  const response = await fetch(found.token_endpoint, {
    method: "POST",
    headers,
    body,
    signal: AbortSignal.timeout(5000)
  });
  if (!response.ok) throw new Error(`token exchange returned ${response.status}`);
  return response.json();
}

export function routes() {
  const router = express.Router();

  router.get("/login", async (request, response) => {
    if (!isConfigured()) return response.status(503).json({ error: "Sign-in is not configured." });
    try {
      const found = await metadata();
      const state = crypto.randomBytes(16).toString("base64url");
      const verifier = crypto.randomBytes(32).toString("base64url");
      const challenge = crypto.createHash("sha256").update(verifier).digest("base64url");
      response.cookie(STATE_COOKIE, sign({ state, verifier, next: safeNext(request.query.next), exp: now() + 600 }), cookieOptions(600));
      const url = new URL(found.authorization_endpoint);
      url.searchParams.set("client_id", CLIENT_ID);
      url.searchParams.set("response_type", "code");
      url.searchParams.set("scope", "openid email profile groups");
      url.searchParams.set("redirect_uri", REDIRECT_URI);
      url.searchParams.set("state", state);
      url.searchParams.set("code_challenge", challenge);
      url.searchParams.set("code_challenge_method", "S256");
      // idp_hint is a Rauthy extension: its page goes straight on to the
      // provider, so the customer never chooses anything there. An unknown
      // provider or an unreachable list falls back to Rauthy's page.
      const provider = typeof request.query.provider === "string" ? request.query.provider.toLowerCase() : "";
      if (/^[a-z]{1,32}$/.test(provider)) {
        const id = await providerId(provider).catch((error) => {
          console.error("Could not list sign-in providers:", error.message);
          return null;
        });
        if (id) url.searchParams.set("idp_hint", id);
      }
      response.redirect(url.toString());
    } catch (error) {
      console.error("Could not start sign-in:", error.message);
      response.status(502).json({ error: "Sign-in is temporarily unavailable." });
    }
  });

  router.get("/callback", async (request, response) => {
    if (!isConfigured()) return response.status(503).json({ error: "Sign-in is not configured." });
    const pending = unsign(cookies(request)[STATE_COOKIE]);
    response.clearCookie(STATE_COOKIE, cookieOptions(0));
    if (!pending || typeof pending.state !== "string" || pending.state !== request.query.state) {
      return response.status(400).json({ error: "Sign-in expired. Please try again." });
    }
    try {
      const found = await metadata();
      const tokens = await exchange(found, {
        code: String(request.query.code || ""),
        redirect_uri: REDIRECT_URI,
        code_verifier: pending.verifier
      });
      const { payload } = await jwtVerify(tokens.id_token, jwks, {
        issuer: found.issuer,
        audience: CLIENT_ID,
        clockTolerance: 30
      });
      if (typeof payload.sub !== "string") throw new Error("no subject in the ID token");
      // The ID token is kept so sign-out can end the Rauthy session too;
      // without it Rauthy would silently sign the same user back in.
      // groups is present only when the client allows the scope; absent means not an admin.
      await startSession(response, {
        sub: payload.sub,
        email: typeof payload.email === "string" ? payload.email.toLowerCase() : "",
        name: typeof payload.name === "string" ? payload.name : "",
        groups: payload.groups,
        emailVerified: payload.email_verified === true,
        idToken: tokens.id_token
      });
      response.redirect(landing(pending.next));
    } catch (error) {
      console.error("Could not finish sign-in:", error.message);
      response.status(502).json({ error: "Sign-in could not be completed. Please try again." });
    }
  });

  // Sign-out always ends the store session. A Google session also ends
  // Rauthy's (RP-initiated), but only while the ID token can be passed as a
  // hint: without one Rauthy shows its own sign-out page, and customers never
  // see Rauthy. Email-code sessions have no Rauthy session to end.
  router.get("/logout", async (request, response) => {
    const session = unsign(cookies(request)[SESSION_COOKIE]);
    response.clearCookie(SESSION_COOKIE, cookieOptions(0));
    if (!session?.id_token || !hintUsable(session.id_token)) return response.redirect("/");
    try {
      const found = await metadata();
      if (!found.end_session_endpoint) return response.redirect("/");
      const url = new URL(found.end_session_endpoint);
      url.searchParams.set("id_token_hint", session.id_token);
      url.searchParams.set("post_logout_redirect_uri", new URL("/", new URL(REDIRECT_URI).origin).toString());
      response.redirect(url.toString());
    } catch (error) {
      console.error("Could not end the identity session:", error.message);
      response.redirect("/");
    }
  });

  return router;
}
