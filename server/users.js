import * as db from "./db.js";
import * as rauthy from "./rauthy.js";

// The people at /admin/users: every Rauthy account, plus guests the store has
// seen (orders and restock requests from before sign-up was required), one row
// per email with what the store knows about them.

// waitingFor, a product slug, keeps only the people still waiting on it, in the
// order they asked, which is the order notifyWaiting emails them. accountsOk is
// false when Rauthy couldn't be read; the list then has only the store's people.
export async function list(waitingFor = null) {
  const [rows, accounts] = await Promise.all([stored(waitingFor), signedUp()]);
  const account = new Map((accounts ?? []).map((a) => [a.email, a]));
  const people = rows.map((row) => ({ ...row, name: account.get(row.email)?.name ?? "", since: earlier(row.first_seen, account.get(row.email)?.createdAt) }));
  if (!waitingFor) {
    const seen = new Set(rows.map((row) => row.email));
    for (const a of accounts ?? []) {
      if (!seen.has(a.email)) people.push({ email: a.email, name: a.name, since: a.createdAt, orders: 0, spent: 0, last_order: null, waiting: [] });
    }
    people.sort((a, b) => (b.last_order ?? b.since) - (a.last_order ?? a.since));
  }
  return { people, accountsOk: Boolean(accounts) };
}

const earlier = (a, b) => (b && b < a ? b : a);

async function signedUp() {
  if (!rauthy.isConfigured()) return null;
  try {
    return await rauthy.listUsers();
  } catch (error) {
    console.error("Could not list accounts:", error.message);
    return null;
  }
}

async function stored(waitingFor) {
  const { rows } = await db.query(
    `with seen as (
       select lower(email) as email, min(created_at) as first_seen
       from (select email, created_at from orders where email is not null
             union all select email, created_at from restock_requests) contacts
       group by 1
     ), paid as (
       select lower(email) as email, count(*)::int as orders, sum(amount)::bigint as spent, max(created_at) as last_order
       from orders where status = 'paid' and email is not null group by 1
     ), waiting as (
       select lower(email) as email, array_agg(product order by created_at) as products,
              min(created_at) filter (where product = $1) as asked
       from restock_requests where notified_at is null group by 1
     )
     select seen.email, seen.first_seen, coalesce(paid.orders, 0) as orders, coalesce(paid.spent, 0)::int as spent,
            paid.last_order, coalesce(waiting.products, '{}') as waiting
     from seen left join paid using (email) left join waiting using (email)
     where $1::text is null or waiting.asked is not null
     order by waiting.asked`,
    [waitingFor]
  );
  return rows;
}
