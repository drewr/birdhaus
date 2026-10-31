import crypto from "node:crypto";

// Signed-cookie primitives shared by the auth session (auth.js) and the cart
// (cart.js). Value.MAC with an HMAC over SESSION_SECRET, plus an `exp` the
// reader enforces. Factored out of auth.js so the cart reuses the same signer.

const SESSION_SECRET = process.env.SESSION_SECRET || "";

// TLS terminates at the edge; cookies are Secure whenever the public URL is
// https (keyed on the OIDC issuer, as the auth session always has been).
export const secure = (process.env.OIDC_ISSUER || "").startsWith("https://");

export const now = () => Math.floor(Date.now() / 1000);

export function cookies(request) {
  const found = {};
  for (const part of String(request.headers.cookie || "").split(";")) {
    const at = part.indexOf("=");
    if (at > 0) found[part.slice(0, at).trim()] = decodeURIComponent(part.slice(at + 1).trim());
  }
  return found;
}

export function sign(payload) {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const mac = crypto.createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  return `${body}.${mac}`;
}

export function unsign(value) {
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

export function cookieOptions(maxAge) {
  return { httpOnly: true, secure, sameSite: "lax", path: "/", maxAge: maxAge * 1000 };
}
