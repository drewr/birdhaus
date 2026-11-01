import nodemailer from "nodemailer";

// Sign-in codes go out through SES SMTP with the birdhaus-ses settings Rauthy
// also uses. MAIL_LOG=1 prints the code instead, for local development.
const LOG = process.env.MAIL_LOG === "1";
let transport;

export const isConfigured = () =>
  LOG || Boolean(process.env.SMTP_URL && process.env.SMTP_USERNAME && process.env.SMTP_PASSWORD && process.env.SMTP_FROM);

export async function sendCode(to, code) {
  const subject = `${code} is your Birdhaus sign-in code`;
  const text = `Your Birdhaus sign-in code is ${code}.\n\nIt works for 10 minutes. If you didn't ask for it, you can ignore this email.\n`;
  if (LOG) return console.log(`[mail] to ${to}: ${subject}`);
  transport ??= nodemailer.createTransport({
    host: process.env.SMTP_URL,
    port: Number(process.env.SMTP_PORT) || 587,
    requireTLS: true,
    auth: { user: process.env.SMTP_USERNAME, pass: process.env.SMTP_PASSWORD },
    connectionTimeout: 5000,
    greetingTimeout: 5000,
    socketTimeout: 10000
  });
  await transport.sendMail({ from: process.env.SMTP_FROM, to, subject, text });
}
