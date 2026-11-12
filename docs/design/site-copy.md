# Page copy edited in place

## Context

Changing a sentence on the site meant a commit and a deploy. Admins now edit
sections of page text where they appear: the front page's welcome, the
introduction on the checkout's delivery step, and each product's features,
specifications, guarantees ("what to expect") and questions. An earlier version
edited them all on one admin page, `/admin/site`, which put product text far
from its product and needed code for each new product's sections.

## Design

- **Sections** are listed in `server/copy.js`: a key, a label for the editor, a
  view (how the page lays it out), and the built-in text. Page sections are
  listed by hand; adding one is an entry there plus a `block` in the page's
  view (`src/Server/Render.purs`). Every product in `server/products.js` gets
  four itemized sections, keyed `<slug>-features`, `-specs`, `-guarantees` and
  `-faq`, with no code per product; the Bluebird House's have built-in text,
  and others start empty.
- **Itemized sections** (`itemized: true`) are lists the page lays out item by
  item, like the product page's feature grid, spec table and FAQ. Their text is
  one Markdown document in which each item starts with a `## Title` line and
  runs to the next; the title is plain text and the rest is rendered like any
  section. Saving text with no `## ` line, or with text before the first, is
  refused. Admins add, remove and reorder items by editing the text. A section
  with no items is left off the page, except for admins, who see "Nothing here
  yet." with its Edit button.
- **Storage:** `site_copy` (migration 009) holds one row per edited section:
  the source text, when it was saved and by whom. A section without a row shows
  its built-in text, and so does every section while Postgres is down, so pages
  never fail on copy. Saving an empty section deletes its row.
- **Format:** the text is Markdown, and inline HTML is allowed (markdown-it with
  `html: true`). The result is sanitized with sanitize-html's default tag list
  plus `img`, `h1` and `h2`, `class` on any tag, and only http, https, mailto
  and tel links. Scripts, styles and event handlers are dropped: admins are
  trusted, but a stolen admin session must not be able to put script in front
  of every visitor.
- **Rendering** happens on each request, from the saved source, so a change to
  the sanitizer applies to text already saved. Pages are `no-cache` and both
  instances read the same table, so a save shows up on the next load.
- **Styles:** admin text can't carry the store's classes on its blocks, so the
  wrapper has `prose`, which gives its paragraphs and lists the `description`
  look.
- **Editing in place:** for an admin (the session's admin flag), each section
  has a small Edit button under it. HTMX swaps the section for its editor
  (`GET /admin/copy/:key/edit`): the source text, a format hint, who last saved
  it, and Save and Cancel. Save posts to `/admin/copy/:key` and swaps the
  rendered section back; Cancel fetches it again (`GET /admin/copy/:key`).
  The routes are behind `requireAdmin`, so membership is rechecked with Rauthy
  and POSTs must be same-origin; hiding the button from everyone else is only
  for looks. They answer with fragments, so a problem (text that isn't
  itemized, a database error) comes back as the editor with the message and a
  200 for HTMX to swap. If the text can't be loaded, the editor offers only
  Cancel, so nobody saves over text they haven't seen. Text is capped at 20,000
  characters. Without JavaScript the Edit button does nothing.
