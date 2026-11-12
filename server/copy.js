import MarkdownIt from "markdown-it";
import sanitizeHtml from "sanitize-html";
import * as db from "./db.js";
import { products } from "./products.js";

// Page copy admins edit in place, on the page (docs/design/site-copy.md). Each
// section keeps its built-in text, shown until an admin saves one and whenever
// the database is down, so a page always renders. view says how the page lays
// a section out.
const PAGE_SECTIONS = [
  {
    key: "home-welcome",
    label: "welcome text",
    view: "prose",
    fallback: `Hi there! Haven't you wanted your own **birdhouse** for Eastern Bluebirds?

It's very *easy*:

1. [Sign up](/login#create) to create your free account,
2. [Shop](/products) to get yours today, and
3. Add yourself to the waiting list to get notified when new birdhouses are available
`
  },
  {
    key: "checkout-delivery",
    label: "delivery introduction",
    view: "prose",
    fallback: `We're a Nashville-based business and only offer local pick-up and delivery right now. Questions? Email <info@birdhaus.store>.
`
  }
];

// Every product has these itemized sections, keyed <slug>-<part>: a list of
// items, each a "## Title" line followed by its text. One with no text is left
// off the page, except for admins, who see it empty with its Edit button.
const PARTS = [
  { part: "features", label: "features", title: (product) => product.featuresTitle ?? "Features" },
  { part: "specs", label: "specifications", title: () => "Specifications" },
  { part: "guarantees", label: "what to expect", title: () => "" },
  { part: "faq", label: "questions", title: () => "Questions" }
];

// Built-in text for product sections, by key; the rest start empty.
const PRODUCT_FALLBACKS = {
  "bluebird-house-features": `## 1½-inch entrance hole
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
`,
  "bluebird-house-specs": `## Material
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
`,
  "bluebird-house-guarantees": `## Satisfaction guarantee
[Your returns or guarantee policy.]

## Pick-up and delivery
[Where pick-up is, and the local delivery area and fee.]

## Secure checkout
Payments are processed by Stripe.
`,
  "bluebird-house-faq": `## How do I mount it, and how high?
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
};

export const productKeys = (product) => PARTS.map(({ part }) => `${product.slug}-${part}`);

const SECTIONS = [
  ...PAGE_SECTIONS,
  ...products.flatMap((product) =>
    PARTS.map(({ part, label, title }) => ({
      key: `${product.slug}-${part}`,
      label: `${product.name} ${label}`,
      view: part,
      title: title(product),
      itemized: true,
      fallback: PRODUCT_FALLBACKS[`${product.slug}-${part}`] ?? ""
    }))
  )
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
function items(body) {
  const out = [];
  for (const line of body.split("\n")) {
    const heading = line.match(/^##\s+(.*\S)\s*$/);
    if (heading) out.push({ title: heading[1], body: "" });
    else if (out.length) out[out.length - 1].body += `${line}\n`;
    else if (line.trim()) return null;
  }
  return out.length ? out : null;
}

// What a view needs to show a section: html for a plain one, items (titles left
// as text for the view to escape) for an itemized one. editable shows the Edit
// button, for admins.
function block(s, body, editable) {
  const parsed = s.itemized ? (items(body) ?? items(s.fallback) ?? []) : [];
  return {
    key: s.key,
    label: s.label,
    view: s.view,
    title: s.title ?? "",
    html: s.itemized ? "" : render(body),
    items: parsed.map((item) => ({ title: item.title, html: render(item.body) })),
    editable
  };
}

// Sections by key for a page, from the saved text or, when there's none or the
// database is down, the built-in text.
export async function blocks(keys, editable) {
  let rows = new Map();
  if (db.isConfigured()) {
    try {
      const result = await db.query("select key, body from site_copy where key = any($1)", [keys]);
      rows = new Map(result.rows.map((row) => [row.key, row.body]));
    } catch (error) {
      console.error("Could not load page copy; showing the built-in text:", error.message);
    }
  }
  return Object.fromEntries(keys.map((key) => [key, block(section(key), rows.get(key) ?? section(key).fallback, editable)]));
}

// A section as just saved, to swap back into the page.
export const savedBlock = (key, body) => block(section(key), body.trim() ? body : section(key).fallback, true);

// The editor's text for a section and who last saved it ({ at, by }, or null
// for the built-in text). Throws when the database is down, so nobody edits the
// built-in text over a saved one.
export async function source(key) {
  const s = section(key);
  const { rows: [row] } = await db.query("select body, updated_at, updated_by from site_copy where key = $1", [key]);
  return { section: s, body: row?.body ?? s.fallback, saved: row ? { at: row.updated_at, by: row.updated_by } : null };
}

// Why this text can't be saved, or "".
export function problem(s, body) {
  if (body.length > MAX_LENGTH) return `The text can be at most ${MAX_LENGTH} characters.`;
  if (s.itemized && body.trim() && !items(body)) return "Start the text with a \"## \" line, and start each item with one.";
  return "";
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
