import MarkdownIt from "markdown-it";
import sanitizeHtml from "sanitize-html";
import * as db from "./db.js";

// Page copy admins edit at /admin/site (docs/design/site-copy.md). Each section
// keeps its built-in text, shown until an admin saves one and whenever the
// database is down, so a page always renders.
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

// Saved rows by key: { body, updated_at, updated_by }.
async function saved() {
  const { rows } = await db.query("select key, body, updated_at, updated_by from site_copy");
  return new Map(rows.map((row) => [row.key, row]));
}

// The rendered HTML for a page's sections, by key.
export async function html(keys) {
  let rows = new Map();
  if (db.isConfigured()) {
    try {
      rows = await saved();
    } catch (error) {
      console.error("Could not load page copy; showing the built-in text:", error.message);
    }
  }
  return Object.fromEntries(keys.map((key) => [key, render(rows.get(key)?.body ?? section(key).fallback)]));
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
