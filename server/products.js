// What the listing and detail pages show about each product. Price lives in
// price.js and availability in the batch, so neither is repeated here.
export const products = [
  {
    slug: "bluebird-house",
    name: "Bluebird House",
    summary: "A simple home for backyard bluebirds.",
    image: "/product-illustration.svg",
    imageAlt: "Illustration of a bluebird house"
  }
];

export const productBySlug = (slug) => products.find((product) => product.slug === slug) ?? null;
