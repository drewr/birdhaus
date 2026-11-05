import * as db from "./db.js";

// The people the store's own tables know about (/admin/users): anyone with an
// order or a restock request, grouped by email. Accounts that never did either
// live only in Rauthy and aren't listed.

// waitingFor, a product slug, keeps only the people still waiting on it, in the
// order they asked, which is the order notifyWaiting emails them.
export async function list(waitingFor = null) {
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
     order by case when $1::text is null then null else waiting.asked end,
              coalesce(paid.last_order, seen.first_seen) desc
     limit case when $1::text is null then 500 end`,
    [waitingFor]
  );
  return rows;
}
