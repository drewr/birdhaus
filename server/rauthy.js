// Rauthy's admin API, so email sign-in happens on the store's own pages
// (docs/design/login-page.md). An API key with Users read/create/update, over
// the same private address as OIDC discovery.
const BASE = (process.env.OIDC_INTERNAL_URL || process.env.OIDC_ISSUER || "").replace(/\/+$/, "");
const KEY = process.env.RAUTHY_API_KEY || "";

export const isConfigured = () => Boolean(BASE && KEY);

async function call(method, path, body) {
  const response = await fetch(`${BASE}/auth/v1${path}`, {
    method,
    headers: { authorization: `API-Key ${KEY}`, ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(5000)
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`Rauthy ${method} ${path.split("/").slice(0, 2).join("/")} returned ${response.status}`);
  return response.json();
}

// The store's view of a Rauthy user.
function account(user) {
  return {
    sub: user.id,
    email: user.email.toLowerCase(),
    name: [user.given_name, user.family_name].filter(Boolean).join(" "),
    groups: user.groups ?? [],
    enabled: user.enabled,
    emailVerified: user.email_verified
  };
}

// Every account, oldest first. Rauthy pages its list above a threshold, but the
// largest page size covers everyone in one request.
export async function listUsers() {
  const users = await call("GET", "/users?page_size=65535");
  return (users ?? []).map((user) => ({
    sub: user.id,
    email: user.email.toLowerCase(),
    name: [user.given_name, user.family_name].filter(Boolean).join(" "),
    createdAt: new Date(user.created_at * 1000)
  }));
}

// Emails of the enabled accounts in a group, for notices to admins. The list
// endpoint doesn't carry groups, so each account is read in turn, a few at a
// time; the store is small and this runs only when a slot is sent.
export async function listGroupEmails(group) {
  const users = (await call("GET", "/users?page_size=65535")) ?? [];
  const emails = [];
  for (let i = 0; i < users.length; i += 8) {
    const accounts = await Promise.all(users.slice(i, i + 8).map((user) => findById(user.id)));
    for (const account of accounts) if (account?.enabled && account.groups.includes(group)) emails.push(account.email);
  }
  return emails;
}

export async function findById(id) {
  const user = await call("GET", `/users/${encodeURIComponent(id)}`);
  return user && account(user);
}

export async function findByEmail(email) {
  const user = await call("GET", `/users/email/${encodeURIComponent(email)}`);
  return user && account(user);
}

// Creating a user this way sends no email; the store already proved the address.
export async function create(email, name) {
  return account(await call("POST", "/users", { email, given_name: name, language: "en", roles: [] }));
}

export async function markVerified(id) {
  // Rauthy requires both lists, even when nothing is deleted.
  await call("PATCH", `/users/${encodeURIComponent(id)}`, { put: [{ key: "email_verified", value: true }], del: [] });
}
