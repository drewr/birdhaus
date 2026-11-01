import { ADMIN_GROUP } from "./auth.js";

// What the listing and detail pages show about each product. Price lives in
// price.js and availability in the batch, so neither is repeated here.
// visibility is "public" (everyone, signed in or not) or { groups }: only
// accounts in one of those Rauthy groups see, add or buy it. batched products
// sell through the pre-order batch (cap, ship-by, waitlist); details shows the
// Bluebird House's feature, spec and FAQ sections.
export const products = [
  {
    slug: "bluebird-house",
    name: "Bluebird House",
    summary: "A simple home for backyard bluebirds.",
    image: "/product-illustration.svg",
    imageAlt: "Illustration of a bluebird house",
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
    visibility: { groups: [ADMIN_GROUP] },
    batched: false,
    details: false
  }
];

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
