import pg from "pg";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Connection settings come from the standard PG* environment variables. The
// pool is created on first use, and short timeouts keep a database restore
// from stalling requests: callers decide what to do when it is unreachable.
const migrationsDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "migrations");
let pool;

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
    console.warn("PGHOST is not set: orders and the waitlist are disabled.");
    return;
  }
  migrate().catch((error) => {
    console.error("Migrations failed, retrying in 15s:", error.message);
    setTimeout(migrateInBackground, 15000);
  });
}

export async function paidUnits(batch) {
  const { rows } = await query("select coalesce(sum(quantity), 0)::int as units from orders where batch = $1 and status = 'paid'", [batch]);
  return rows[0].units;
}

export async function recordOrder(intent) {
  await query(
    `insert into orders (id, batch, quantity, amount, currency, email, shipping, created_at)
     values ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8))
     on conflict (id) do nothing`,
    [
      intent.id,
      intent.metadata.batch || "unbatched",
      Number(intent.metadata.quantity) || 1,
      intent.amount_received || intent.amount,
      intent.currency,
      intent.receipt_email,
      intent.shipping ? JSON.stringify(intent.shipping) : null,
      intent.created
    ]
  );
}

export async function markRefunded(paymentIntentId) {
  await query("update orders set status = 'refunded' where id = $1", [paymentIntentId]);
}

export async function joinWaitlist(batch, email, quantity, postalCode) {
  await query(
    `insert into waitlist (batch, email, quantity, postal_code) values ($1, $2, $3, $4)
     on conflict (batch, email) do update set quantity = excluded.quantity, postal_code = excluded.postal_code, updated_at = now()`,
    [batch, email, quantity, postalCode]
  );
}
