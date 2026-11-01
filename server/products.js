import { readFileSync } from "node:fs";
import { ADMIN_GROUP } from "./auth.js";

// What the listing and detail pages show about each product. Price lives in
// price.js and availability in the batch, so neither is repeated here.
// visibility is "public" (everyone, signed in or not) or { groups }: only
// accounts in one of those Rauthy groups see, add or buy it. batched products
// sell through the pre-order batch (cap, ship-by, waitlist); details shows the
// Bluebird House's feature, spec and FAQ sections. photos are listed in display
// order, the first being the default; their files come from
// scripts/product-photos.hs. A product without photos shows its image.
export const products = [
  {
    slug: "bluebird-house",
    name: "Bluebird House",
    summary: "A simple home for backyard bluebirds.",
    image: "/product-illustration.svg",
    imageAlt: "Illustration of a bluebird house",
    photos: [
      { name: "front", alt: "The Bluebird House from the front, with its round entrance hole" },
      { name: "back", alt: "The Bluebird House from the back" },
      { name: "interior", alt: "The Bluebird House with its front panel swung open to show the inside" }
    ],
    visibility: "public",
    batched: true,
    details: true
  },
  // For testing checkout end to end with a real card at Stripe's minimum.
  {
    slug: "demo-thing",
    name: "Demo Thing",
    summary: "A test item for trying checkout. Only store admins see it.",
    image: "/product-illustration.svg",
    imageAlt: "Placeholder illustration",
    photos: [],
    visibility: { groups: [ADMIN_GROUP] },
    batched: false,
    details: false
  }
];

// Each photo's files by width (server/data/photos/<slug>.json). Read at startup,
// so a photo listed above without generated files stops the server early.
const photoFiles = Object.fromEntries(
  products
    .filter((product) => product.photos.length > 0)
    .map((product) => [product.slug, JSON.parse(readFileSync(new URL(`./data/photos/${product.slug}.json`, import.meta.url), "utf8"))])
);
for (const product of products) {
  for (const photo of product.photos) {
    if (!photoFiles[product.slug]?.[photo.name]) throw new Error(`No files for photo ${product.slug}/${photo.name}; run scripts/product-photos.hs`);
  }
}

// What a page needs to show one photo: src for old browsers, srcset for the
// rest (the 160px size is only the detail page's thumbnail).
export function photoView(product, photo) {
  const files = photoFiles[product.slug][photo.name];
  return {
    name: photo.name,
    alt: photo.alt,
    src: files[800],
    srcset: [480, 800, 1200].map((width) => `${files[width]} ${width}w`).join(", "),
    thumb: files[160]
  };
}

const productBySlug = (slug) => products.find((product) => product.slug === slug) ?? null;

// account is auth.accountOf's, or null when signed out.
export function visibleTo(product, account) {
  if (product.visibility === "public") return true;
  return Boolean(account) && product.visibility.groups.some((group) => account.groups.includes(group));
}

// The product if it exists and this account may see it, else null.
export const visibleProduct = (slug, account) => {
  const product = productBySlug(slug);
  return product && visibleTo(product, account) ? product : null;
};

// For orders, which keep the slug.
export const productName = (slug) => productBySlug(slug)?.name ?? slug;
