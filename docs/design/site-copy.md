# Page copy edited in the admin portal

## Context

Changing a sentence on the site meant a commit and a deploy. Admins now edit
sections of page text at `/admin/site`: the front page's welcome, the
introduction on the checkout's delivery step, and the Bluebird House page's
features, specifications, guarantees ("what to expect") and questions, which
started as bracketed placeholders.

## Design

- **Sections** are listed in `server/copy.js` (`SECTIONS`): a key, a label for
  the editor, the page it appears on, and the built-in text. A page asks for its
  sections by key and renders the HTML in its view with `raw`. Adding a section
  is a code change: an entry there, plus a `raw` slot in the page's view.
- **Itemized sections** (`itemized: true`) are lists the page lays out item by
  item, like the product page's feature grid, spec table and FAQ. Their text is
  one Markdown document in which each item starts with a `## Title` line and
  runs to the next; the title is plain text and the rest is rendered like any
  section. Saving text with no `## ` line, or with text before the first, is
  refused. Admins add, remove and reorder items by editing the text. Products
  with `details: true` (`server/products.js`) show the sections keyed
  `<slug>-features`, `-specs`, `-guarantees` and `-faq`.
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
- **Editor:** one form per section, posting to `/admin/site/:key` (admin only,
  same-origin) and redirecting back, like the other admin forms. Text is capped
  at 20,000 characters.
