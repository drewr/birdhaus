import { query } from "./db.js";

// Pick-up locations and time slots (docs/design/fulfillment.md). Times are
// stored as timestamptz and entered and shown in the store's zone.
export const ZONE = "America/Chicago";

const day = new Intl.DateTimeFormat("en-US", { timeZone: ZONE, weekday: "short", month: "short", day: "numeric" });
const time = new Intl.DateTimeFormat("en-US", { timeZone: ZONE, hour: "numeric", minute: "2-digit", timeZoneName: "short" });
const timeShort = new Intl.DateTimeFormat("en-US", { timeZone: ZONE, hour: "numeric", minute: "2-digit" });

// "Sat, Dec 13, 9:00 AM – 11:00 AM CST"
export function slotTime(startsAt, endsAt) {
  return `${day.format(startsAt)}, ${timeShort.format(startsAt)} – ${time.format(endsAt)}`;
}

// The snapshot stored on the order and shown to the buyer.
export function slotLabel(slot) {
  return `${slot.name} — ${slotTime(slot.starts_at, slot.ends_at)}`;
}

const SLOT_COLUMNS = `s.id, s.location_id, s.starts_at, s.ends_at, s.active, l.name, l.details, l.active as location_active`;

// Slots a buyer can choose: active, at an active location, not yet started.
export async function upcomingSlots() {
  const { rows } = await query(
    `select ${SLOT_COLUMNS} from pickup_slots s join pickup_locations l on l.id = s.location_id
     where s.active and l.active and s.starts_at > now() order by s.starts_at limit 100`
  );
  return rows;
}

// A slot the buyer may still book, or null.
export async function bookableSlot(id) {
  const slotId = Number.parseInt(id, 10);
  if (!Number.isInteger(slotId)) return null;
  const { rows } = await query(
    `select ${SLOT_COLUMNS} from pickup_slots s join pickup_locations l on l.id = s.location_id
     where s.id = $1 and s.active and l.active and s.starts_at > now()`,
    [slotId]
  );
  return rows[0] ?? null;
}

// -------------------------------------------------------------- admin

export async function listLocations() {
  const { rows } = await query("select id, name, details, active from pickup_locations order by active desc, name");
  return rows;
}

export async function createLocation(name, details) {
  await query("insert into pickup_locations (name, details) values ($1, $2)", [name, details]);
}

export async function setLocationActive(id, active) {
  await query("update pickup_locations set active = $2 where id = $1", [id, active]);
}

// Upcoming slots plus the last week's, so recent ones stay visible.
export async function listSlots() {
  const { rows } = await query(
    `select ${SLOT_COLUMNS} from pickup_slots s join pickup_locations l on l.id = s.location_id
     where s.ends_at > now() - interval '7 days' order by s.starts_at`
  );
  return rows;
}

// date is YYYY-MM-DD and start/end are HH:MM, all in the store's zone.
export async function createSlot(locationId, date, start, end) {
  await query(
    `insert into pickup_slots (location_id, starts_at, ends_at)
     values ($1, ($2::date + $3::time) at time zone '${ZONE}', ($2::date + $4::time) at time zone '${ZONE}')`,
    [locationId, date, start, end]
  );
}

export async function setSlotActive(id, active) {
  await query("update pickup_slots set active = $2 where id = $1", [id, active]);
}

// Paid pick-up orders for slots that haven't ended long ago, by slot time.
export async function pickupSchedule() {
  const { rows } = await query(
    `select o.id, o.email, o.quantity, o.pickup_label, s.starts_at
     from orders o left join pickup_slots s on s.id = o.pickup_slot_id
     where o.fulfillment = 'pickup' and o.status = 'paid' and (s.ends_at is null or s.ends_at > now() - interval '7 days')
     order by s.starts_at nulls last, o.created_at`
  );
  return rows;
}

export async function recentOrders(limit = 50) {
  const { rows } = await query(
    `select id, created_at, email, quantity, amount, currency, status, fulfillment, pickup_label, delivery_label
     from orders order by created_at desc limit $1`,
    [limit]
  );
  return rows;
}
