import nodemailer from "nodemailer";

// Sign-in codes go out through SES SMTP with the birdhaus-ses settings Rauthy
// also uses. MAIL_LOG=1 prints the code instead, for local development.
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

export async function sendCode(to, code, purpose) {
  const message = codeEmail(code, purpose);
  if (LOG) return console.log(`[mail] to ${to}: ${message.subject}: ${code}`);
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
