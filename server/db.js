import pg from "pg";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Connection settings come from the standard PG* environment variables. The
// pool is created on first use, and short timeouts keep a database restore
// from stalling requests: callers decide what to do when it is unreachable.
const migrationsDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "migrations");
let pool;
let migrations = "pending";

export const isConfigured = () => Boolean(process.env.PGHOST);

function getPool() {
  if (!pool) {
    pool = new pg.Pool({ max: 5, connectionTimeoutMillis: 3000, idleTimeoutMillis: 30000, query_timeout: 5000 });
    pool.on("error", (error) => console.error("Postgres pool error:", error.message));
  }
  return pool;
}

export const query = (text, params) => getPool().query(text, params);

// Numbered .sql files, each applied once in its own transaction. The advisory
// lock keeps two instances from applying the same migration.
export async function migrate() {
  const client = await getPool().connect();
  try {
    await client.query("select pg_advisory_lock(hashtext('birdhaus-migrations'))");
    await client.query("create table if not exists schema_migrations (version text primary key, applied_at timestamptz not null default now())");
    const applied = new Set((await client.query("select version from schema_migrations")).rows.map((row) => row.version));
    for (const file of readdirSync(migrationsDir).filter((name) => name.endsWith(".sql")).sort()) {
      if (applied.has(file)) continue;
      await client.query("begin");
      try {
        await client.query(readFileSync(path.join(migrationsDir, file), "utf8"));
        await client.query("insert into schema_migrations (version) values ($1)", [file]);
        await client.query("commit");
        console.log(`Applied migration ${file}`);
      } catch (error) {
        await client.query("rollback");
        throw error;
      }
    }
  } finally {
    await client.query("select pg_advisory_unlock(hashtext('birdhaus-migrations'))").catch(() => {});
    client.release();
  }
}

// The store must start without its database, so migrations retry in the
// background instead of failing startup.
export function migrateInBackground() {
  if (!isConfigured()) {
    console.warn("PGHOST is not set: orders, inventory and restock requests are disabled.");
    migrations = "not configured";
    return;
  }
  migrate().then(() => {
    migrations = "ok";
  }, (error) => {
    console.error("Migrations failed, retrying in 5s:", error.message);
    migrations = `failing: ${error.message}`;
    setTimeout(migrateInBackground, 5000);
  });
}

// For /api/health: a deploy is finished only once its migrations are applied.
export const migrationStatus = () => migrations;

// For delivery, address_check says how the radius was verified; a paid address
// whose ZIP differs from the one /api/delivery/verify passed is a mismatch.
function addressCheck(intent) {
  if (intent.metadata.fulfillment !== "delivery") return null;
  const check = intent.metadata.address_check;
  if (!check) return "none";
  const paidZip = String(intent.shipping?.address?.postal_code ?? "").slice(0, 5);
  return paidZip === intent.metadata.verified_zip ? check : "mismatch";
}

// Records the order and counts it against the product's inventory in one
// statement, so a redelivered event (the insert does nothing) never counts
// twice. Returns { product, before, after } when a tracked count changed.
export async function recordOrder(intent) {
  const fulfillment = ["pickup", "delivery"].includes(intent.metadata.fulfillment) ? intent.metadata.fulfillment : "ship";
  const { rows } = await query(
    `with placed as (
       insert into orders (id, batch, quantity, amount, currency, email, shipping, created_at, account_sub, fulfillment,
         pickup_slot_id, pickup_label, fee_amount, delivery_slot_id, delivery_label, address_check, product)
       values ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8), $9, $10, $11, $12, $13, $14, $15, $16, $17)
       on conflict (id) do nothing
       returning id, product, quantity
     ), counted as (
       update inventory set available = inventory.available - placed.quantity, updated_at = now()
       from placed where inventory.product = placed.product
       returning inventory.product, inventory.available + placed.quantity as before, inventory.available as after, placed.id
     ), logged as (
       insert into inventory_changes (product, before, after, reason, order_id)
       select product, before, after, 'order', id from counted
     )
     select product, before, after from counted`,
    [
      intent.id,
      intent.metadata.batch || "unbatched",
      Number(intent.metadata.quantity) || 1,
      intent.amount_received || intent.amount,
      intent.currency,
      intent.receipt_email,
      intent.shipping ? JSON.stringify(intent.shipping) : null,
      intent.created,
      intent.metadata.account_sub || null,
      fulfillment,
      Number(intent.metadata.pickup_slot_id) || null,
      intent.metadata.pickup_label || null,
      Number(intent.metadata.fee_cents) || 0,
      Number(intent.metadata.delivery_slot_id) || null,
      intent.metadata.delivery_label || null,
      addressCheck(intent),
      intent.metadata.product || "bluebird-house"
    ]
  );
  return rows[0] ?? null;
}

export async function markRefunded(paymentIntentId) {
  await query("update orders set status = 'refunded' where id = $1", [paymentIntentId]);
}

// Claims guest orders placed with an address the identity provider has verified.
// Older orders keep their guest attribution if the account is already set.
export async function linkOrders(accountSub, email) {
  await query("update orders set account_sub = $1 where email = $2 and account_sub is null", [accountSub, email]);
}

// Sign-in codes (docs/design/login-page.md): at most five sent per address an
// hour, ten minutes and five tries each, and a new code replaces older ones.
// Returns false when the address has hit the limit.
export async function saveLoginCode(email, codeHash, purpose) {
  await query("delete from login_codes where created_at < now() - interval '1 day'");
  const { rows } = await query("select count(*)::int as sent from login_codes where email = $1 and created_at > now() - interval '1 hour'", [email]);
  if (rows[0].sent >= 5) return false;
  await query("update login_codes set used_at = now() where email = $1 and used_at is null", [email]);
  await query("insert into login_codes (email, code_hash, purpose, expires_at) values ($1, $2, $3, now() + interval '10 minutes')", [email, codeHash, purpose]);
  return true;
}

// "ok", "wrong" (one try spent) or "expired" (no live code, or out of tries).
// The row is locked so parallel guesses can't exceed the tries.
export async function useLoginCode(email, purpose, matches) {
  const client = await getPool().connect();
  try {
    await client.query("begin");
    const { rows } = await client.query(
      `select id, code_hash, attempts from login_codes
       where email = $1 and purpose = $2 and used_at is null and expires_at > now()
       order by created_at desc limit 1 for update`,
      [email, purpose]
    );
    const row = rows[0];
    let result;
    if (!row || row.attempts >= 5) {
      result = "expired";
    } else if (matches(row.code_hash)) {
      await client.query("update login_codes set used_at = now() where id = $1", [row.id]);
      result = "ok";
    } else {
      await client.query("update login_codes set attempts = attempts + 1 where id = $1", [row.id]);
      result = row.attempts + 1 >= 5 ? "expired" : "wrong";
    }
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}
