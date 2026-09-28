// @ts-check

const { Resend } = require("resend");

const FROM_EMAIL = process.env.FROM_EMAIL || "Stride <hello@strideapp.me>";

/** @type {import('resend').Resend | undefined} */
let _resend;
function getResend() {
  if (!_resend) {
    _resend = new Resend(process.env.RESEND_API_KEY);
  }
  return _resend;
}

/**
 * @param {string} to
 * @param {{ loginUrl: string, expiresInMinutes: number }} opts
 */
async function sendMagicLinkEmail(to, { loginUrl, expiresInMinutes }) {
  // resend 3.x never throws on a failed send: fetchRequest catches everything and RETURNS
  // `{ data: null, error }` — for a revoked key, an unverified domain, a quota, a 5xx, or no
  // network at all. This result was ignored, so /request-link answered {ok:true} for mail that
  // was never sent, with no log line and no Sentry event, and the magic link is the only way to
  // sign in. Throw instead, so the route's catch answers 500 and reports it. The message names
  // Resend's error, never the recipient: it goes to the log and to Sentry.
  const { error } = await getResend().emails.send({
    from: FROM_EMAIL,
    to,
    subject: "Log in to Stride",
    html: `
      <div style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 480px; margin: 0 auto; padding: 40px 20px;">
        <h2 style="margin-bottom: 24px;">Log in to Stride</h2>
        <p>Click the button below to log in. This link expires in ${expiresInMinutes} minutes.</p>
        <a href="${loginUrl}" style="display: inline-block; background: #34C759; color: white; padding: 12px 32px; border-radius: 8px; text-decoration: none; font-weight: 600; margin: 24px 0;">
          Log in to Stride
        </a>
        <p style="color: #888; font-size: 14px; margin-top: 32px;">If you didn't request this link, you can safely ignore this email.</p>
      </div>
    `,
  });
  if (error) {
    throw new Error(`Resend ${error.name || "error"}: ${error.message || "send failed"}`);
  }
}

module.exports = { sendMagicLinkEmail };
