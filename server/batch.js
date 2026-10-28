// The current pre-order batch, configured by the deploy (run.hs). Dates are
// YYYY-MM-DD; pre-orders close at the end of BATCH_CLOSES_AT, US Central time.
export function currentBatch(env = process.env) {
  const cap = Number.parseInt(env.BATCH_CAP ?? "", 10);
  return {
    id: env.BATCH_ID || "xmas-2026",
    cap: Number.isInteger(cap) && cap >= 0 ? cap : null,
    closesAt: env.BATCH_CLOSES_AT ? new Date(`${env.BATCH_CLOSES_AT}T23:59:59.999-06:00`) : null,
    shipBy: env.BATCH_SHIP_BY || ""
  };
}

// "2026-12-15" -> "December 15"
export function displayDate(isoDate) {
  if (!isoDate) return "";
  return new Date(`${isoDate}T12:00:00Z`).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" });
}

// paid is null when the database is unreachable: the batch then stays open
// (a restore takes seconds, and a soft cap can absorb a few extra sales).
export function batchStatus(batch, paid, now = new Date()) {
  if (batch.closesAt && now > batch.closesAt) return { open: false, reason: "closed", remaining: 0 };
  if (batch.cap === null || paid === null) return { open: true, reason: "open", remaining: null };
  const remaining = Math.max(batch.cap - paid, 0);
  return remaining > 0 ? { open: true, reason: "open", remaining } : { open: false, reason: "sold-out", remaining: 0 };
}
