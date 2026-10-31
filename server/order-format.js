// Format a Stripe order (from lookupOrder) into the flat, display-ready record
// the confirmation view renders. Moved server-side from the old client bundle so
// the page is server-rendered; status collapses to succeeded/processing/failed.
export function formatOrder(order) {
  const status =
    order.status === "succeeded" ? "succeeded"
    : order.status === "processing" ? "processing"
    : "failed";
  const currency = (order.currency || "usd").toUpperCase();
  const money = new Intl.NumberFormat("en-US", { style: "currency", currency });
  const address = order.shipping?.address ?? {};
  const cityLine = [address.city, [address.state, address.postal_code].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  return {
    status,
    message: order.error ?? "",
    number: (order.id || "").slice(-8).toUpperCase(),
    date: order.created ? new Date(order.created * 1000).toLocaleDateString("en-US", { dateStyle: "long" }) : "",
    items: `${order.quantity ?? 1} × Bluebird House`,
    total: `${money.format((order.amount || 0) / 100)} ${currency}`,
    email: order.email ?? "",
    shipTo: [order.shipping?.name, address.line1, address.line2, cityLine, address.country].filter(Boolean),
    shipBy: order.shipBy ?? "",
    quantity: order.quantity ?? 1
  };
}
