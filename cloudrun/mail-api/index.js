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

// --- 後方互換の拡張: html / attachments(任意) ---------------------------------------------------
// 既存呼出元は to / subject / text (/ senderName) だけを送る。html・attachmentsを送らない限り、動作は従来と同一。
// 任意ファイルを送れるAPIにしない: 添付は「htmlに埋め込む(cid)PNG画像」だけを許可し、個数・サイズ・種類を厳しく制限する。
const LIMITS = Object.freeze({
  maxHtmlChars: 100000,
  maxAttachments: 2,
  maxAttachmentBytes: 100 * 1024,
  maxTotalAttachmentBytes: 150 * 1024,
  allowedAttachmentContentTypes: Object.freeze(["image/png"]),
  allowedDispositions: Object.freeze(["inline"]),
});
const FEATURES = Object.freeze(["html", "attachments"]);
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const ATTACHMENT_NAME_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

// 不正ならnull。正しければ検証済みの添付一覧を返す(SendGridへ渡す形の前段)。
function parseAttachments(raw) {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > LIMITS.maxAttachments) return null;
  const seenIds = new Set();
  let total = 0;
  const result = [];
  for (const item of raw) {
    if (item === null || typeof item !== "object" || Array.isArray(item)) return null;
    const {filename, contentType, contentBase64, contentId, disposition} = item;
    if (Object.keys(item).some((key) => !["filename", "contentType", "contentBase64", "contentId", "disposition"].includes(key))) return null;
    if (typeof filename !== "string" || !ATTACHMENT_NAME_PATTERN.test(filename) || !filename.toLowerCase().endsWith(".png")) return null;
    if (!LIMITS.allowedAttachmentContentTypes.includes(contentType)) return null;
    if (!LIMITS.allowedDispositions.includes(disposition)) return null;
    if (typeof contentId !== "string" || !ATTACHMENT_NAME_PATTERN.test(contentId) || seenIds.has(contentId)) return null;
    seenIds.add(contentId);
    if (typeof contentBase64 !== "string" || contentBase64.length === 0 || contentBase64.length % 4 !== 0 ||
        !BASE64_PATTERN.test(contentBase64)) return null;
    // 復号後のサイズを、復号せずに上限判定(巨大な入力を展開しない)
    const padding = contentBase64.endsWith("==") ? 2 : contentBase64.endsWith("=") ? 1 : 0;
    const size = (contentBase64.length / 4) * 3 - padding;
    if (size > LIMITS.maxAttachmentBytes) return null;
    total += size;
    if (total > LIMITS.maxTotalAttachmentBytes) return null;
    const bytes = Buffer.from(contentBase64, "base64");
    // 厳密なbase64(再エンコードして一致)で、PNGの署名を持つものだけ。拡張子・contentTypeの偽装を防ぐ。
    if (bytes.toString("base64") !== contentBase64 || bytes.length !== size) return null;
    if (bytes.length < PNG_SIGNATURE.length || !bytes.subarray(0, PNG_SIGNATURE.length).equals(PNG_SIGNATURE)) return null;
    result.push({filename, contentType, contentBase64, contentId, disposition});
  }
  return result;
}

function createMailer(env = process.env, client = sgMail) {
  const apiKey = cleanString(env.SENDGRID_API_KEY, 512);
  const fromEmail = cleanString(env.MAIL_FROM, 254);
  if (!apiKey || !EMAIL_PATTERN.test(fromEmail)) throw new Error("mail_not_configured");
  client.setApiKey(apiKey);
  const defaultFromName = cleanString(env.MAIL_FROM_NAME || "JMイベント事務局", 100);
  const replyTo = cleanString(env.MAIL_REPLY_TO || fromEmail, 254);
  return {
    async send({to, subject, text, senderName, html, attachments}) {
      const fromName = cleanString(senderName, 100) || defaultFromName;
      console.log("SendGrid dispatch", {fromEmail, fromName});
      const [response] = await client.send({
        to,
        from: {email: fromEmail, name: fromName},
        replyTo,
        subject,
        text,
        // html・attachmentsは指定されたときだけ付ける(指定なしなら従来と同じ内容をSendGridへ渡す)
        ...(html ? {html} : {}),
        ...(attachments ? {
          attachments: attachments.map((a) => ({
            // SendGridのヘルパーは添付をそのままAPIへ渡す。APIのキーはsnake_case(content_id)。
            // camelCase(contentId)のままだとCID埋め込みが機能しない(テストでヘルパーの出力を確認している)。
            content: a.contentBase64, filename: a.filename, type: a.contentType,
            disposition: a.disposition, content_id: a.contentId,
          })),
        } : {}),
      });
      return String(response?.headers?.["x-message-id"] || "");
    },
  };
}

function createApp({env = process.env, mailer} = {}) {
  const app = express();
  app.disable("x-powered-by");
  // 従来は64kb。添付(QR PNG)を受けられるよう引き上げる。html・attachmentsを送らない呼出元には影響しない。
  app.use(express.json({limit: "512kb"}));

  // 呼出側(Functions)が、必要な機能を持つ版か送信前に確認できるようにする(旧版では features が無い=未対応)。
  app.get("/health", (_req, res) => res.json({ok: true, features: [...FEATURES], limits: LIMITS}));
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
    // 任意: html / attachments。不正な指定は黙って捨てず400で拒否する(QRなしの本文だけが送られる事故を防ぐ)。
    const rawHtml = req.body?.html;
    if (rawHtml !== undefined && (typeof rawHtml !== "string" || rawHtml.trim() === "" || rawHtml.length > LIMITS.maxHtmlChars)) {
      return res.status(400).json({ok: false, error: "invalid_mail"});
    }
    let attachments;
    if (req.body?.attachments !== undefined) {
      attachments = rawHtml === undefined ? null : parseAttachments(req.body.attachments);
      if (!attachments) return res.status(400).json({ok: false, error: "invalid_attachment"});
    }

    try {
      const messageId = await (mailer || createMailer(env)).send({
        to, subject, text, senderName,
        ...(rawHtml !== undefined ? {html: rawHtml} : {}),
        ...(attachments ? {attachments} : {}),
      });
      return res.json({ok: true, messageId});
    } catch (error) {
      console.error("mail send failed", {
        code: error?.code || "unknown",
        app: cleanString(req.body?.metadata?.app, 50),
      });
      // providerStatus: SendGridが返したHTTPステータス(拒否された=送られていないと判断できる4xx等)。不明ならnull。
      const providerStatus = Number.isInteger(error?.code) ? error.code : null;
      return res.status(502).json({ok: false, error: "mail_provider_error", providerStatus});
    }
  });
  return app;
}

if (require.main === module) {
  const port = Number(process.env.PORT || 8080);
  createApp().listen(port, () => console.log(`mail-api listening on ${port}`));
}

module.exports = {createApp, createMailer, parseAttachments, LIMITS, FEATURES};
