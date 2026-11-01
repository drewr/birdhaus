# Plan: Organize the store's styles with Open Props and CSS layers

## Context

All styling is one hand-written file, `src/style.css` (154 lines, ~110 classes, two
custom properties `--line`/`--muted`, hard-coded px sizes and greys). It grew by
appending sections ("Server-rendered additions", "Delivery step", "Store admin"),
so related rules are scattered and values repeat: the 32px/-.04em page heading is
written four times, and the three bordered buttons share most declarations.

We surveyed Tailwind v4, UnoCSS (shortcuts) and Open Props + native cascade
layers. The owner chose **Open Props + layers**: no markup rewrite (the 132 `cls`
literals in `src/Server/*.purs` keep their semantic names), structure lives in CSS
files with an explicit layer order, and sizes and type come from Open Props'
scales instead of ad-hoc px. Vite already bundles the stylesheet via
`src/client-entry.js`; the look (monochrome, square corners, Arial, Architects
Daughter wordmark) must not change.

## Approach

**Dependencies (dev, exact versions):** `open-props` and `postcss-jit-props`.
`postcss-jit-props` (Open Props' recommended setup) emits only the props the CSS
actually uses, so the bundle doesn't grow by the whole Open Props sheet. Wire it
in `vite.config.js` under `css.postcss.plugins` with `OpenProps` as the source;
no separate postcss config file.

**File layout** (replaces `src/style.css`; `client-entry.js` imports the new entry):

```
src/styles/
  index.css        @layer reset, tokens, base, layout, components, pages;
                   then @import of each file below into its layer
  reset.css        box-sizing, body margin, form controls inherit font
  tokens.css       brand tokens on :root, built on Open Props
  base.css         element defaults: body type, links, headings
  layout.css       site header, wordmark, main width, footer, breakpoints
  components/
    buttons.css    .buy-button, .cart-link, .quantity-button, .text-button, .text-link
    forms.css      labels/inputs: waitlist, quantity field, payment form, admin form
    lists.css      the dt/dd grids: .order-summary, .spec-list; .admin-table
    notes.css      .fine-print, .preorder-note, .stock-note, error lines
    disclosure.css details/summary +/− (FAQ, inline waitlist)
  pages/
    product.css    product grid, media, features, trust strip, info sections
    cart.css       cart screen and cart box
    checkout.css   delivery options, pay page, Stripe mount spacing
    confirmation.css
    admin.css
```

Layer order makes precedence explicit (a page rule beats a component rule
without specificity tricks); native CSS nesting groups each block's states
(`:hover`, `:disabled`, `[open]`) with it. Vite inlines the `@import`s and
minifies; check during step 1 that `@import … layer(x)` survives Vite's import
inlining, and if it doesn't, wrap each file's body in `@layer x { }` instead.

**Tokens (`tokens.css`):** our names, Open Props values where a scale fits:
- colours: `--ink #111`, `--ink-hover #333`, `--line #d9d9d9`, `--muted #606060`,
  `--body-text #444`, `--danger #a11`, `--wash #fafafa`, `--wash-hover #f1f1f1`;
- fonts: `--font-body` (Arial stack), `--font-hand` (Architects Daughter stack);
- type: `--font-size-*`, `--font-lineheight-*`, `--font-letterspacing-*` from
  Open Props, plus `--title-size` / `--title-tracking` for the repeated page title;
- space: `--size-*` from Open Props for margins, padding and gaps, rounded to the
  nearest step only where it is invisible (e.g. 14px → `--size-3` 1rem is not, so
  keep a literal there with a comment rather than shift the design);
- breakpoints stay literal (760px, 520px) with a comment in `layout.css`, since
  custom media would need another PostCSS plugin.

**Small markup consolidation** (the only `.purs` edits): one shared `page-title`
class for the four repeated h1s (`.product-details h1`, `.cart-screen h1`,
`.confirmation h1`, `.admin h1`) in `Render.purs`/`Admin.purs`; otherwise class
names stay. Drop any rule whose class no longer appears in `src/Server`, `src/Client`
or `server/` (grep each class before deleting).

**Stripe:** `src/Client/Main.js` passes `appearance.variables` (`colorText`,
`colorPrimary`, `borderRadius: "0px"`, `fontFamily`) read with
`getComputedStyle(document.documentElement)` from the tokens, keeping
`theme: "flat"`, so the Payment, Address and Express Checkout elements match.

**Docs:** AGENTS.md conventions: styles live in `src/styles/`, one file per
component or page in its layer; colours, fonts and sizes come from `tokens.css`
(Open Props scales), never literals in component files unless the comment says
why; new layers go in the order line in `index.css`.

## Critical files

- `src/style.css` → removed; `src/styles/**` new
- `src/client-entry.js` (import path), `vite.config.js` (jit-props), `package.json`/lock
- `src/Server/Render.purs`, `src/Server/Admin.purs` (page-title only)
- `src/Client/Main.js` (Stripe appearance variables)
- `AGENTS.md`

## Verification

- `npm run build`: 0 PureScript warnings; built CSS contains each layer and only
  the Open Props variables used; size close to today's 9.5 kB (2.45 kB gzip).
- Pixel comparison, before vs after, with headless Chromium from nix
  (`chromium --headless --screenshot --window-size=1280,2400` and 375 px wide)
  against a local `npm start` on test keys: `/`, sold-out/waitlist, `/cart` with
  items, `/checkout`, `/checkout/pay` (pick-up and delivery), `/order`, and the
  admin pages (local admin session). Differences should be none or explained.
- HTMX swaps (cart quantity, waitlist join) render styled fragments.
- Push to `main` deploys dev; check the payment form and Express Checkout on
  dev.birdhaus.store in test mode. Prod only by release, after the owner's OK.
