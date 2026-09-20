const express = require("express");
const sgMail = require("@sendgrid/mail");

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function cleanString(value, maxLength) {
  return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ""));
  const b = Buffer.from(String(right || ""));
  return a.length === b.length && require("crypto").timingSafeEqual(a, b);
}

function createMailer(env = process.env, client = sgMail) {
  const apiKey = cleanString(env.SENDGRID_API_KEY, 512);
  const fromEmail = cleanString(env.MAIL_FROM, 254);
  if (!apiKey || !EMAIL_PATTERN.test(fromEmail)) throw new Error("mail_not_configured");
  client.setApiKey(apiKey);
  const defaultFromName = cleanString(env.MAIL_FROM_NAME || "JMイベント事務局", 100);
  const replyTo = cleanString(env.MAIL_REPLY_TO || fromEmail, 254);
  return {
    async send({to, subject, text, senderName}) {
      const fromName = cleanString(senderName, 100) || defaultFromName;
      console.log("SendGrid dispatch", {fromEmail, fromName});
      const [response] = await client.send({
        to,
        from: {email: fromEmail, name: fromName},
        replyTo,
        subject,
        text,
      });
      return String(response?.headers?.["x-message-id"] || "");
    },
  };
}

function createApp({env = process.env, mailer} = {}) {
  const app = express();
  app.disable("x-powered-by");
  app.use(express.json({limit: "64kb"}));

  app.get("/health", (_req, res) => res.json({ok: true}));
  app.post("/v1/mail/send", async (req, res) => {
    const authorization = req.get("authorization") || "";
    const expected = `Bearer ${cleanString(env.MAIL_API_KEY, 512)}`;
    if (!env.MAIL_API_KEY || !safeEqual(authorization, expected)) {
      return res.status(401).json({ok: false, error: "unauthorized"});
    }

    const to = cleanString(req.body?.to, 254).toLowerCase();
    const subject = cleanString(req.body?.subject, 200);
    const text = cleanString(req.body?.text, 20000);
    const senderName = cleanString(req.body?.senderName, 100);
    if (!EMAIL_PATTERN.test(to) || !subject || !text) {
      return res.status(400).json({ok: false, error: "invalid_mail"});
    }

    try {
      const messageId = await (mailer || createMailer(env)).send({
        to, subject, text, senderName,
      });
      return res.json({ok: true, messageId});
    } catch (error) {
      console.error("mail send failed", {
        code: error?.code || "unknown",
        app: cleanString(req.body?.metadata?.app, 50),
      });
      return res.status(502).json({ok: false, error: "mail_provider_error"});
    }
  });
  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT || 8080);
  createApp().listen(port, () => console.log(`mail-api listening on ${port}`));
}

module.exports = {createApp, createMailer};
