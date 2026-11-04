import nodemailer from "nodemailer";

// Sign-in codes, restock notices and stock alerts go out through SES SMTP with
// the birdhaus-ses settings Rauthy also uses. MAIL_LOG=1 prints them instead,
// for local development.
const LOG = process.env.MAIL_LOG === "1";
// Links back to whichever store sent the code (dev or prod).
const SITE = (() => {
  try {
    return new URL(process.env.OIDC_REDIRECT_URI).origin;
  } catch {
    return "https://birdhaus.store";
  }
})();
let transport;

export const isConfigured = () =>
  LOG || Boolean(process.env.SMTP_URL && process.env.SMTP_USERNAME && process.env.SMTP_PASSWORD && process.env.SMTP_FROM);

const escape = (value) => value.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

// Mostly text: the HTML part only adds the name, a set-apart code and a
// footer link, with no images (often blocked, and a spam signal for a new
// sender). The code stays out of the subject.
export function codeEmail(code, purpose) {
  const action = purpose === "signup" ? "finish creating your Birdhaus account" : "sign in to Birdhaus";
  const host = new URL(SITE).host;
  const lines = [
    `Here's your code to ${action}. It works for 10 minutes.`,
    "If you didn't ask for it, you can ignore this email. Nobody can sign in without the code."
  ];
  const text = `Birdhaus\n\n${lines[0]}\n\n    ${code}\n\n${lines[1]}\n\nBirdhaus · ${SITE}\n`;
  const html = `<!doctype html>
<html lang="en"><body style="margin:0;padding:24px;background:#ffffff;color:#111111;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.5">
<div style="max-width:480px">
<p style="margin:0 0 24px;font-size:24px;font-weight:700">Birdhaus</p>
<p style="margin:0 0 16px">${escape(lines[0])}</p>
<p style="margin:0 0 24px;padding:16px;border:1px solid #d9d9d9;background:#fafafa;font-size:32px;font-weight:700;letter-spacing:0.15em;text-align:center">${escape(code)}</p>
<p style="margin:0 0 24px;color:#444444">${escape(lines[1])}</p>
<p style="margin:0;padding-top:16px;border-top:1px solid #d9d9d9;color:#606060;font-size:12px">Birdhaus · <a href="${escape(SITE)}" style="color:#606060">${escape(host)}</a></p>
</div>
</body></html>
`;
  return { subject: purpose === "signup" ? "Finish creating your Birdhaus account" : "Your Birdhaus sign-in code", text, html };
}

// Plain notes from the store: the logo, a few paragraphs and one link, in the
// same mostly-text layout as the code email. The logo sits on its own white
// card (scripts/brand-assets.hs), so dark-mode clients, which don't invert
// images, show it as is; with images blocked, its alt text takes the old
// heading's place.
function noteEmail(subject, lines, link) {
  const host = new URL(SITE).host;
  const text = `Birdhaus\n\n${lines.join("\n\n")}\n\n${link.label}: ${link.href}\n\nBirdhaus · ${SITE}\n`;
  const html = `<!doctype html>
<html lang="en"><body style="margin:0;padding:24px;background:#ffffff;color:#111111;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.5">
<div style="max-width:480px">
<p style="margin:0 0 24px"><img src="${escape(SITE)}/email-logo.png" width="200" height="191" alt="Birdhaus" style="display:block;border:0;font-size:24px;font-weight:700;color:#111111"></p>
${lines.map((line) => `<p style="margin:0 0 16px">${escape(line)}</p>`).join("\n")}
<p style="margin:8px 0 24px"><a href="${escape(link.href)}" style="color:#111111;font-weight:700">${escape(link.label)}</a></p>
<p style="margin:0;padding-top:16px;border-top:1px solid #d9d9d9;color:#606060;font-size:12px">Birdhaus · <a href="${escape(SITE)}" style="color:#606060">${escape(host)}</a></p>
</div>
</body></html>
`;
  return { subject, text, html };
}

// To a shopper who asked to hear when a sold-out product is back.
export const restockEmail = (product) =>
  noteEmail(`The ${product.name} is available again`, [
    `You asked us to let you know when the ${product.name} was back. It is, while stock lasts.`,
    "This is the only email you'll get about it. If it sells out again, you can ask to be notified again on the product page."
  ], { label: `Get your ${product.name}`, href: `${SITE}/products/${product.slug}` });

// To the owner (STOCK_ALERT_EMAIL) when an order leaves few or none.
export function stockAlertEmail(product, available) {
  const state = available < 0 ? `oversold by ${-available}` : available === 0 ? "sold out" : `down to ${available}`;
  return noteEmail(`${product.name} is ${state}`, [
    `An order just left the ${product.name} ${state}.`,
    available <= 0
      ? "Shoppers now see it as sold out and can ask to be notified. Raise the count when you have more, then email the people waiting."
      : "Shoppers see how many are left. Raise the count if you have more on hand."
  ], { label: "Open the inventory", href: `${SITE}/admin/inventory` });
}

export async function send(to, message) {
  if (LOG) return console.log(`[mail] to ${to}: ${message.subject}\n${message.text}`);
  transport ??= nodemailer.createTransport({
    host: process.env.SMTP_URL,
    port: Number(process.env.SMTP_PORT) || 587,
    requireTLS: true,
    auth: { user: process.env.SMTP_USERNAME, pass: process.env.SMTP_PASSWORD },
    connectionTimeout: 5000,
    greetingTimeout: 5000,
    socketTimeout: 10000
  });
  await transport.sendMail({ from: process.env.SMTP_FROM, to, ...message });
}

export async function sendCode(to, code, purpose) {
  if (LOG) return console.log(`[mail] to ${to}: ${codeEmail(code, purpose).subject}: ${code}`);
  await send(to, codeEmail(code, purpose));
}
