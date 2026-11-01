# Plan: Homepage hero, product listing and product detail URLs

## Context

`/` is the Bluebird House page, so the store has nowhere to say anything that
isn't about that one product. The owner wants:

- `/`: a full-width **hero** of text and images, filled in later, that links to
  the products;
- `/products`: a **listing** of the available products;
- `/products/<slug>`: the current product page, moved as is.

The hero's copy and images live in code (PureScript view plus files in
`public/`), with bracketed placeholders until the owner writes them, like the
product page's spec placeholders. Changing the copy is a commit and deploy.
The header gets a **Products** link on every page.

## Catalog

`server/products.js` (new) is the list of products, one for now:
`{ slug: "bluebird-house", name, summary, image, imageAlt }`. The price stays
in `server/price.js` and availability comes from the batch (`batchStatus`), so
the catalog holds only what the listing and detail pages show. `productBySlug`
looks one up. A second product later means a second entry plus its own price
and batch, which this plan doesn't build.

## Routes (`server/index.js`)

- `GET /`: `homePage` with the chrome only.
- `GET /products`: `productsPage` with one card per catalog entry: name,
  summary, price, and an availability line (`Pre-order · ships by …`,
  `Sold out — join the waitlist` or `Pre-orders have closed`).
- `GET /products/:slug`: the current `/` handler, unchanged except that it
  looks the product up; an unknown slug redirects 303 to `/products`.
- Redirects that meant "the product" now go to `/products/bluebird-house`:
  the non-HTMX waitlist POST. Ones that meant "the store" go to `/products`:
  `/cart/clear`, an empty `/cart`, "Continue shopping" and the confirmation
  page's "Back to the store". The unknown-path fallback stays `/`.

## Views

- `Server.Layout`: a `Products` text link in the header before the cart link,
  and `layoutWithHero`, which renders a full-width block between the header and
  `<main>` (so the hero spans the window instead of `main`'s 1040px column).
- `Server.Render`:
  - `homePage`: the hero, `section.hero` with `h1`, a paragraph, a
    "Shop bluebird houses" link styled like the buy button to `/products`, and
    an image slot (the product illustration until real photos exist). Copy is
    placeholder text in brackets.
  - `productsPage`: `page-title` "Products" and a grid of linked cards.
  - `productPage` keeps its markup; its data comes from the catalog entry.
- Sold-out tracking (`data-batch-reason`) stays on the detail page only.

## Styles

`src/styles/pages/home.css` (hero: wash background, two columns of text and
image that stack under 760px) and `src/styles/pages/products.css` (card grid,
`auto-fill` columns at least 240px wide), both in the `pages` layer and built
from the tokens.

## Docs

AGENTS.md "What this is" page list gains `/products` and `/products/:slug`;
README mentions where the hero copy lives.

## Verification

- `npm run build` with 0 warnings.
- The fixture renderer (scratchpad) gains the home and listing pages; screenshots
  at 1280 and 375 px. The product detail page renders pixel-identical to the
  old `/` apart from the new header link.
- On a local server: `/`, `/products`, `/products/bluebird-house` return 200;
  `/products/nope` redirects to `/products`; add to cart, waitlist (HTMX and
  no-JS form post), cart clear and "Continue shopping" land on the right pages.
- Push to `main` and check the same on dev.birdhaus.store.
