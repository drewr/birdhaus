import { query } from "./db.js";
import { ZONE, slotTime } from "./pickup.js";
import { geocodeAddress, milesBetween, zipCentroid } from "./geocode.js";

// Local delivery (docs/design/local-delivery.md): a flat per-order fee, to
// addresses within radius_miles of a home base, in slots the store defines.
// One settings row, managed on /admin/delivery.

export async function settings() {
  const { rows } = await query("select enabled, fee_cents, radius_miles, base_address, base_lat, base_lon from delivery_settings where id = 1");
  const s = rows[0];
  return {
    enabled: s.enabled,
    feeCents: s.fee_cents,
    radiusMiles: Number(s.radius_miles),
    baseAddress: s.base_address ?? "",
    base: s.base_lat === null ? null : { lat: s.base_lat, lon: s.base_lon }
  };
}

// Switched on with a home base; checkout also needs an upcoming slot.
export const offered = (s) => s.enabled && s.base !== null;

// Saves the settings, geocoding a changed base address. Returns an error
// message, or "" on success; an address Census can't match is refused.
export async function saveSettings({ enabled, feeCents, radiusMiles, baseAddress }) {
  const current = await settings();
  let base = current.base;
  if (baseAddress !== current.baseAddress || base === null) {
    const parts = parseOneLine(baseAddress);
    if (!parts) return "Enter the base address as: street, city, state ZIP.";
    let found;
    try {
      found = await geocodeAddress(parts);
    } catch {
      return "The Census geocoder is unavailable. Try again shortly.";
    }
    if (!found) return "Census couldn't find that address. Check the spelling.";
    base = found;
  }
  await query(
    `update delivery_settings set enabled = $1, fee_cents = $2, radius_miles = $3, base_address = $4,
       base_lat = $5, base_lon = $6, updated_at = now() where id = 1`,
    [enabled && base !== null, feeCents, radiusMiles, baseAddress, base?.lat ?? null, base?.lon ?? null]
  );
  return "";
}

// "1100 Congress Ave, Austin, TX 78701" -> address parts for the geocoder.
function parseOneLine(text) {
  const m = /^(.+?),\s*(.+?),\s*([A-Za-z]{2})\s+(\d{5})(?:-\d{4})?$/.exec(String(text).trim());
  return m ? { line1: m[1], city: m[2], state: m[3].toUpperCase(), postal_code: m[4] } : null;
}

// A wallet sheet reveals only the ZIP before the buyer confirms, so this is the
// in-sheet check: the ZIP's centroid against the radius.
export function checkZip(s, zip) {
  const point = zipCentroid(zip);
  return point !== null && milesBetween(s.base, point) <= s.radiusMiles;
}

// The authoritative check before payment: the geocoded street address. If
// Census is down or can't match the street, fall back to the ZIP centroid so a
// Census outage doesn't stop sales; such orders are flagged for the admin.
export async function checkAddress(s, address) {
  if (address?.country && address.country !== "US") return { ok: false, check: "exact" };
  let point = null;
  try {
    point = await geocodeAddress(address);
  } catch (error) {
    console.error("Census geocoding failed; checking the ZIP instead:", error.message);
  }
  if (point) return { ok: milesBetween(s.base, point) <= s.radiusMiles, check: "exact" };
  return { ok: checkZip(s, address?.postal_code), check: "zip" };
}

// -------------------------------------------------------------- slots

export const slotLabel = (slot) => slotTime(slot.starts_at, slot.ends_at);

export async function upcomingSlots() {
  const { rows } = await query(
    "select id, starts_at, ends_at, active from delivery_slots where active and starts_at > now() order by starts_at limit 100"
  );
  return rows;
}

// A slot the buyer may still book, or null.
export async function bookableSlot(id) {
  const slotId = Number.parseInt(id, 10);
  if (!Number.isInteger(slotId)) return null;
  const { rows } = await query("select id, starts_at, ends_at from delivery_slots where id = $1 and active and starts_at > now()", [slotId]);
  return rows[0] ?? null;
}

export async function listSlots() {
  const { rows } = await query("select id, starts_at, ends_at, active from delivery_slots where ends_at > now() - interval '7 days' order by starts_at");
  return rows;
}

// date is YYYY-MM-DD and start/end are HH:MM, all in the store's zone.
export async function createSlot(date, start, end) {
  await query(
    `insert into delivery_slots (starts_at, ends_at)
     values (($1::date + $2::time) at time zone '${ZONE}', ($1::date + $3::time) at time zone '${ZONE}')`,
    [date, start, end]
  );
}

export async function setSlotActive(id, active) {
  await query("update delivery_slots set active = $2 where id = $1", [id, active]);
}

// Paid delivery orders for slots that haven't ended long ago, by slot time.
export async function deliverySchedule() {
  const { rows } = await query(
    `select o.id, o.email, o.product, o.quantity, o.delivery_label, o.shipping, o.address_check, s.starts_at
     from orders o left join delivery_slots s on s.id = o.delivery_slot_id
     where o.fulfillment = 'delivery' and o.status = 'paid' and (s.ends_at is null or s.ends_at > now() - interval '7 days')
     order by s.starts_at nulls last, o.created_at`
  );
  return rows;
}
