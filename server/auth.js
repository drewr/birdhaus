import crypto from "node:crypto";
import express from "express";
import { createRemoteJWKSet, jwtVerify } from "jose";
import * as db from "./db.js";

// OpenID Connect login against Rauthy (auth/README.md). The issuer, client and
// session key come from the birdhaus-store-auth Secret. A missing configuration
// only disables accounts: checkout and the rest of the store keep running.

const ISSUER = (process.env.OIDC_ISSUER || "").replace(/\/+$/, "");
const CLIENT_ID = process.env.OIDC_CLIENT_ID || "";
const CLIENT_SECRET = process.env.OIDC_CLIENT_SECRET || "";
const REDIRECT_URI = process.env.OIDC_REDIRECT_URI || "";
const SESSION_SECRET = process.env.SESSION_SECRET || "";

const SESSION_COOKIE = "bh_session";
const STATE_COOKIE = "bh_auth";
const SESSION_TTL = 7 * 24 * 60 * 60;

export const isConfigured = () => Boolean(ISSUER && CLIENT_ID && CLIENT_SECRET && REDIRECT_URI && SESSION_SECRET);

let discovery;
let jwks;

// Cached discovery and JWKS. A failure is retried on the next login instead of
// leaving the store unable to sign anyone in for the life of the instance.
async function metadata() {
  if (!discovery) {
    discovery = (async () => {
      const response = await fetch(`${ISSUER}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error(`discovery returned ${response.status}`);
      const found = await response.json();
      jwks = createRemoteJWKSet(new URL(found.jwks_uri));
      return found;
    })().catch((error) => {
      discovery = undefined;
      throw error;
    });
  }
  return discovery;
}

const now = () => Math.floor(Date.now() / 1000);

function cookies(request) {
  const found = {};
  for (const part of String(request.headers.cookie || "").split(";")) {
    const at = part.indexOf("=");
    if (at > 0) found[part.slice(0, at).trim()] = decodeURIComponent(part.slice(at + 1).trim());
  }
  return found;
}

// Value.MAC, so the browser can be trusted with the state and the session.
function sign(payload) {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const mac = crypto.createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  return `${body}.${mac}`;
}

function unsign(value) {
  if (!value) return null;
  const at = value.lastIndexOf(".");
  if (at < 0) return null;
  const body = value.slice(0, at);
  const expected = crypto.createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  const given = Buffer.from(value.slice(at + 1));
  const wanted = Buffer.from(expected);
  if (given.length !== wanted.length || !crypto.timingSafeEqual(given, wanted)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    return payload.exp && payload.exp > now() ? payload : null;
  } catch {
    return null;
  }
}

const secure = ISSUER.startsWith("https://");

function cookieOptions(maxAge) {
  return { httpOnly: true, secure, sameSite: "lax", path: "/", maxAge: maxAge * 1000 };
}

// Only same-site paths, so a crafted link cannot bounce a fresh login off-site.
function safeNext(value) {
  const next = typeof value === "string" ? value : "";
  return next.startsWith("/") && !next.startsWith("//") && next.length <= 512 ? next : "/";
}

// The signed-in account, or null. Attached to /api/create-payment-intent so the
// order keeps its owner through the webhook.
export function accountOf(request) {
  if (!isConfigured()) return null;
  const session = unsign(cookies(request)[SESSION_COOKIE]);
  if (!session || typeof session.sub !== "string") return null;
  return { sub: session.sub, email: session.email || "", name: session.name || "" };
}

export function me(request, response) {
  response.set("Cache-Control", "no-store");
  const account = accountOf(request);
  if (!account) return response.json({ signedIn: false });
  response.json({ signedIn: true, id: account.sub, email: account.email, name: account.name });
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
      url.searchParams.set("scope", "openid email profile");
      url.searchParams.set("redirect_uri", REDIRECT_URI);
      url.searchParams.set("state", state);
      url.searchParams.set("code_challenge", challenge);
      url.searchParams.set("code_challenge_method", "S256");
      // idp_hint is a Rauthy extension: skip the chooser and go straight to a
      // provider, for a dedicated "Sign in with Google" button.
      if (typeof request.query.provider === "string" && /^[a-z0-9_-]+$/i.test(request.query.provider)) {
        url.searchParams.set("idp_hint", request.query.provider);
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
      const email = typeof payload.email === "string" ? payload.email.toLowerCase() : "";
      const name = typeof payload.name === "string" ? payload.name : "";
      // Claim past guest orders only with an address the provider verified.
      if (payload.email_verified === true && email) {
        try {
          await db.linkOrders(payload.sub, email);
        } catch (error) {
          console.error("Could not link past orders:", error.message);
        }
      }
      response.cookie(SESSION_COOKIE, sign({ sub: payload.sub, email, name, exp: now() + SESSION_TTL }), cookieOptions(SESSION_TTL));
      // The fragment tells the store's client to count a login in analytics and
      // is removed from the address bar before the page settles.
      const destination = new URL(pending.next || "/", new URL(REDIRECT_URI).origin);
      destination.searchParams.set("auth", "in");
      response.redirect(destination.toString());
    } catch (error) {
      console.error("Could not finish sign-in:", error.message);
      response.status(502).json({ error: "Sign-in could not be completed. Please try again." });
    }
  });

  router.post("/logout", (request, response) => {
    response.clearCookie(SESSION_COOKIE, cookieOptions(0));
    response.json({ ok: true });
  });

  return router;
}
