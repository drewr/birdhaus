import MarkdownIt from "markdown-it";
import sanitizeHtml from "sanitize-html";
import * as db from "./db.js";

// Page copy admins edit at /admin/site (docs/design/site-copy.md). Each section
// keeps its built-in text, shown until an admin saves one and whenever the
// database is down, so a page always renders. An itemized section is a list of
// items, each a "## Title" line followed by its text; the Bluebird House's
// feature, spec, guarantee and FAQ sections are itemized.
export const SECTIONS = [
  {
    key: "home-welcome",
    label: "Front page: welcome",
    page: "/",
    fallback: `Hi there! Haven't you wanted your own **birdhouse** for Eastern Bluebirds?

It's very *easy*:

1. [Sign up](/login#create) to create your free account,
2. [Shop](/products) to get yours today, and
3. Add yourself to the waiting list to get notified when new birdhouses are available
`
  },
  {
    key: "checkout-delivery",
    label: "Checkout: delivery choice",
    page: "/checkout",
    fallback: `We're a Nashville-based business and only offer local pick-up and delivery right now. Questions? Email <info@birdhaus.store>.
`
  },
  {
    key: "bluebird-house-features",
    label: "Bluebird House: features",
    page: "/products/bluebird-house",
    itemized: true,
    fallback: `## 1½-inch entrance hole
Sized to the North American Bluebird Society standard: the right fit for bluebirds, too small for starlings. No perch, which predators would use.

## Ventilation
[Describe the vents that keep the box cool in summer.]

## Drainage
[Describe the floor drainage that keeps the nest dry.]

## Easy cleanout
[Describe the hinged or sliding panel for seasonal cleaning.]

## Simple mounting
[Describe how it mounts — pole, post or screws — and the recommended height.]

## Built to last
[Describe the wood and hardware — e.g. rot-resistant cedar, rust-resistant screws, no nails.]
`
  },
  {
    key: "bluebird-house-specs",
    label: "Bluebird House: specifications",
    page: "/products/bluebird-house",
    itemized: true,
    fallback: `## Material
[Wood species and grade — e.g. kiln-dried red cedar]

## Dimensions
[Height × width × depth]

## Weight
[Weight]

## Entrance hole
1½ in, about 6 in above the floor

## Base footprint
[Interior floor, width × depth]

## Hardware
[e.g. rust-resistant screws, no nails]

## Made in
[Origin]
`
  },
  {
    key: "bluebird-house-guarantees",
    label: "Bluebird House: what to expect",
    page: "/products/bluebird-house",
    itemized: true,
    fallback: `## Satisfaction guarantee
[Your returns or guarantee policy.]

## Pick-up and delivery
[Where pick-up is, and the local delivery area and fee.]

## Secure checkout
Payments are processed by Stripe.
`
  },
  {
    key: "bluebird-house-faq",
    label: "Bluebird House: questions",
    page: "/products/bluebird-house",
    itemized: true,
    fallback: `## How do I mount it, and how high?
[Your mounting guidance. Bluebird houses usually sit 5–6 feet up, in the open, away from heavy foot traffic.]

## How do I keep sparrows and predators out?
[The 1½-inch hole already blocks starlings. Add any guidance on house sparrows, baffles or predator guards.]

## How do I clean it?
[Your cleaning instructions, and how the box opens for it.]

## Does it come assembled?
[Assembled or flat-pack, and what's in the box.]

## When can I get it?
[How soon after ordering it's ready for pick-up or local delivery.]
`
  }
];

export const MAX_LENGTH = 20000;

export const section = (key) => SECTIONS.find((s) => s.key === key) ?? null;

// Markdown with inline HTML allowed, then sanitized: admins are trusted, but a
// stolen admin session must not be able to plant script on every visitor.
const markdown = new MarkdownIt({ html: true, linkify: true, typographer: true });
const allowed = {
  allowedTags: [...sanitizeHtml.defaults.allowedTags, "img", "h1", "h2"],
  allowedAttributes: { ...sanitizeHtml.defaults.allowedAttributes, img: ["src", "alt", "width", "height"], "*": ["class"] }
};

export const render = (body) => sanitizeHtml(markdown.render(body), allowed);

// An itemized section's items as { title, body }, or null when the text isn't
// one: no "## " heading, or text before the first.
export function items(body) {
  const out = [];
  for (const line of body.split("\n")) {
    const heading = line.match(/^##\s+(.*\S)\s*$/);
    if (heading) out.push({ title: heading[1], body: "" });
    else if (out.length) out[out.length - 1].body += `${line}\n`;
    else if (line.trim()) return null;
  }
  return out.length ? out : null;
}

// Plain sections render to HTML; itemized ones to [{ title, html }], the title
// left as text for the view to escape.
const renderSection = (s, body) =>
  s.itemized ? (items(body) ?? items(s.fallback)).map((item) => ({ title: item.title, html: render(item.body) })) : render(body);

// Saved rows by key: { body, updated_at, updated_by }.
async function saved() {
  const { rows } = await db.query("select key, body, updated_at, updated_by from site_copy");
  return new Map(rows.map((row) => [row.key, row]));
}

// A page's sections rendered by renderSection, by key.
export async function html(keys) {
  let rows = new Map();
  if (db.isConfigured()) {
    try {
      rows = await saved();
    } catch (error) {
      console.error("Could not load page copy; showing the built-in text:", error.message);
    }
  }
  return Object.fromEntries(keys.map((key) => [key, renderSection(section(key), rows.get(key)?.body ?? section(key).fallback)]));
}

// Every section with its source text, for the editor.
export async function list() {
  const rows = await saved();
  return SECTIONS.map((s) => ({ ...s, row: rows.get(s.key) ?? null }));
}

// An empty body goes back to the built-in text.
export async function save(key, body, email) {
  if (!body.trim()) return db.query("delete from site_copy where key = $1", [key]);
  await db.query(
    `insert into site_copy (key, body, updated_by) values ($1, $2, $3)
     on conflict (key) do update set body = excluded.body, updated_at = now(), updated_by = excluded.updated_by`,
    [key, body, email]
  );
}
