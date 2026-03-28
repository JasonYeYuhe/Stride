const { Resend } = require("resend");

const FROM_EMAIL = process.env.FROM_EMAIL || "Stride <hello@strideapp.me>";

let _resend;
function getResend() {
  if (!_resend) {
    _resend = new Resend(process.env.RESEND_API_KEY);
  }
  return _resend;
}

async function sendMagicLinkEmail(to, { loginUrl, expiresInMinutes }) {
  await getResend().emails.send({
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
}

module.exports = { sendMagicLinkEmail };
