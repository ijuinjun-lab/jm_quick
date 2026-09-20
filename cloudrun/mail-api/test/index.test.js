const assert = require("node:assert/strict");
const {after, before, test} = require("node:test");
const {createApp, createMailer} = require("../index");

let server;
let baseUrl;
let sent;

before(async () => {
  const app = createApp({
    env: {MAIL_API_KEY: "test-key"},
    mailer: {async send(message) { sent = message; return "sg-message-id"; }},
  });
  server = app.listen(0);
  await new Promise(resolve => server.once("listening", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test("rejects requests without the shared key", async () => {
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {"Content-Type": "application/json"}, body: "{}"});
  assert.equal(response.status, 401);
});

test("validates the mail payload", async () => {
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify({to: "invalid", subject: "subject", text: "body"})});
  assert.equal(response.status, 400);
});

test("sends through the common SendGrid contract", async () => {
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify({to: "USER@example.com", senderName: " ペット防災イベント ", subject: " Subject ", text: " Body "})});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {ok: true, messageId: "sg-message-id"});
  assert.deepEqual(sent, {to: "user@example.com", senderName: "ペット防災イベント", subject: "Subject", text: "Body"});
});

// SendGridクライアントを差し替え、外部へは一切送信せずFromだけを検証する。
async function sendWithFakeClient(env, message) {
  let payload;
  const client = {
    setApiKey() {},
    async send(sent) {
      payload = sent;
      return [{headers: {"x-message-id": "message-id"}}];
    },
  };
  await createMailer({
    SENDGRID_API_KEY: "sendgrid-key",
    MAIL_FROM: "noreply@jmcom.co.jp",
    ...env,
  }, client).send({
    to: "user@example.com",
    subject: "件名",
    text: "本文",
    ...message,
  });
  return payload;
}

test("uses the event sender name without changing the sender address", async () => {
  const payload = await sendWithFakeClient(
    {MAIL_FROM_NAME: "旧表示名"},
    {senderName: "ペット防災イベント"},
  );
  assert.deepEqual(payload.from, {
    email: "noreply@jmcom.co.jp",
    name: "ペット防災イベント",
  });
});

test("falls back to MAIL_FROM_NAME when senderName is not given", async () => {
  for (const message of [{}, {senderName: ""}, {senderName: "   "}]) {
    const payload = await sendWithFakeClient({MAIL_FROM_NAME: "環境変数の表示名"}, message);
    assert.deepEqual(payload.from, {
      email: "noreply@jmcom.co.jp",
      name: "環境変数の表示名",
    });
  }
});

test("falls back to the JM default name when neither senderName nor MAIL_FROM_NAME is given", async () => {
  const payload = await sendWithFakeClient({}, {});
  assert.deepEqual(payload.from, {
    email: "noreply@jmcom.co.jp",
    name: "JMイベント事務局",
  });
});

test("accepts legacy callers that send only to, subject and text", async () => {
  sent = undefined;
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify({to: "legacy@example.com", subject: "件名", text: "本文"})});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {ok: true, messageId: "sg-message-id"});
  assert.equal(sent.to, "legacy@example.com");
  assert.equal(sent.subject, "件名");
  assert.equal(sent.text, "本文");
  assert.equal(sent.senderName, "");
});

// ---------------------------------------------------------------------------------------------
// html / attachments 拡張(後方互換)のテスト。SendGridへは接続しない(mailer/clientは偽物)。
// ---------------------------------------------------------------------------------------------
const {parseAttachments, LIMITS, FEATURES} = require("../index");
const {Mail} = require("@sendgrid/helpers/classes");

// 1x1のPNG(署名つき)
const PNG_1X1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
const png = (extraBytes = 0) => Buffer.concat([Buffer.from(PNG_1X1, "base64"), Buffer.alloc(extraBytes, 1)]).toString("base64");
const attachment = (overrides = {}) => ({filename: "qr.png", contentType: "image/png", contentBase64: PNG_1X1, contentId: "jm-quick-reception-qr", disposition: "inline", ...overrides});
const post = (body) => fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify(body)});
const base = {to: "user@example.invalid", subject: "件名", text: "本文", senderName: "送信者"};

test("後方互換: to/subject/textだけを送る従来の呼出元は、mailerへ従来と同じ4項目だけが渡り成功する", async () => {
  sent = undefined;
  const response = await post({to: "legacy@example.invalid", subject: "件名", text: "本文"});
  assert.equal(response.status, 200);
  assert.deepEqual(Object.keys(sent).sort(), ["senderName", "subject", "text", "to"]);
  assert.equal("html" in sent, false);
  assert.equal("attachments" in sent, false);
});

test("senderName互換: 指定あり・なしとも従来どおり", async () => {
  sent = undefined;
  assert.equal((await post({...base})).status, 200);
  assert.equal(sent.senderName, "送信者");
  assert.equal((await post({to: base.to, subject: "s", text: "t"})).status, 200);
  assert.equal(sent.senderName, "");
});

test("htmlは任意: htmlだけを付けて成功し、attachmentsは渡らない", async () => {
  sent = undefined;
  const response = await post({...base, html: "<p>本文</p>"});
  assert.equal(response.status, 200);
  assert.equal(sent.html, "<p>本文</p>");
  assert.equal("attachments" in sent, false);
});

test("attachmentsは任意: QR PNG 1件(cid・inline)がhtmlとともに成功する", async () => {
  sent = undefined;
  const response = await post({...base, html: '<img src="cid:jm-quick-reception-qr">', attachments: [attachment()]});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {ok: true, messageId: "sg-message-id"});
  assert.deepEqual(sent.attachments, [attachment()]);
});

test("不正なhtml(文字列以外・空白のみ・上限超過)は拒否する", async () => {
  for (const html of [1, {}, ["x"], "   ", "a".repeat(LIMITS.maxHtmlChars + 1)]) {
    const response = await post({...base, html});
    assert.equal(response.status, 400, String(html).slice(0, 10));
    assert.deepEqual(await response.json(), {ok: false, error: "invalid_mail"});
  }
});

test("不正な添付は400(invalid_attachment)で拒否され、送信されない", async () => {
  const bad = {
    "不正なbase64(文字)": attachment({contentBase64: "!!!!"}),
    "base64の長さが4の倍数でない": attachment({contentBase64: PNG_1X1.slice(0, -1)}),
    "PNG署名のない中身をpngと偽る": attachment({contentBase64: Buffer.from("<script>alert(1)</script>").toString("base64")}),
    "空のcontent": attachment({contentBase64: ""}),
    "許可されないcontentType(jpeg)": attachment({contentType: "image/jpeg"}),
    "許可されないcontentType(html)": attachment({contentType: "text/html"}),
    "許可されないcontentType(pdf)": attachment({contentType: "application/pdf", filename: "a.png"}),
    "拡張子がpngでない": attachment({filename: "qr.exe"}),
    "ファイル名にパス": attachment({filename: "../qr.png"}),
    "dispositionがattachment": attachment({disposition: "attachment"}),
    "contentIdに不正文字": attachment({contentId: "a b<>"}),
    "未知のキー": {...attachment(), url: "https://example.invalid/x"},
    "オブジェクトでない": "not-an-object",
  };
  for (const [label, item] of Object.entries(bad)) {
    sent = undefined;
    const response = await post({...base, html: "<p>x</p>", attachments: [item]});
    assert.equal(response.status, 400, label);
    assert.deepEqual(await response.json(), {ok: false, error: "invalid_attachment"}, label);
    assert.equal(sent, undefined, `${label}: 送信されていない`);
  }
});

test("添付の個数・サイズ上限: 個数超過・1件の超過・合計の超過・空配列・重複cidを拒否する", async () => {
  const many = Array.from({length: LIMITS.maxAttachments + 1}, (_, i) => attachment({contentId: `id${i}`, filename: `q${i}.png`}));
  const oneTooBig = attachment({contentBase64: png(LIMITS.maxAttachmentBytes)});
  const nearMax = png(LIMITS.maxAttachmentBytes - 200);
  const totalTooBig = [attachment({contentBase64: nearMax}), attachment({contentBase64: nearMax, contentId: "b", filename: "b.png"})];
  const cases = {"個数超過": many, "1件が上限超過": [oneTooBig], "合計が上限超過": totalTooBig, "空配列": [], "cid重複": [attachment(), attachment({filename: "b.png"})]};
  for (const [label, attachments] of Object.entries(cases)) {
    const response = await post({...base, html: "<p>x</p>", attachments});
    assert.equal(response.status, 400, label);
  }
  // 上限ちょうどは通る
  const ok = await post({...base, html: "<p>x</p>", attachments: [attachment({contentBase64: png(LIMITS.maxAttachmentBytes - 100)})]});
  assert.equal(ok.status, 200);
});

test("htmlの無いattachments(任意ファイル送信の抜け道)は拒否する", async () => {
  const response = await post({...base, attachments: [attachment()]});
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {ok: false, error: "invalid_attachment"});
});

test("parseAttachments: 許可条件を満たすものだけを返す", () => {
  assert.equal(parseAttachments([attachment()]).length, 1);
  for (const raw of [null, undefined, "x", [], {}, [null], [[]]]) assert.equal(parseAttachments(raw), null);
});

test("capability: /health が html・attachments 対応と上限を返す(旧版はfeaturesが無い)", async () => {
  const response = await fetch(`${baseUrl}/health`);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.deepEqual(body.features, ["html", "attachments"]);
  assert.deepEqual(FEATURES, ["html", "attachments"]);
  assert.deepEqual(body.limits.allowedAttachmentContentTypes, ["image/png"]);
  assert.equal(body.limits.maxAttachments, LIMITS.maxAttachments);
  assert.ok(body.limits.maxTotalAttachmentBytes >= body.limits.maxAttachmentBytes);
});

test("認証は従来どおり必須(htmlつきでも、キーなしは401)", async () => {
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({...base, html: "<p>x</p>"})});
  assert.equal(response.status, 401);
});

test("createMailer: html・attachmentsが無ければ、SendGridへ従来と同じ項目だけを渡す", async () => {
  const payload = await sendWithFakeClient({}, {});
  assert.deepEqual(Object.keys(payload).sort(), ["from", "replyTo", "subject", "text", "to"]);
});

test("createMailer: htmlと添付をSendGrid形式(content_id・inline・base64)へ変換する", async () => {
  const payload = await sendWithFakeClient({}, {html: '<img src="cid:jm-quick-reception-qr">', attachments: [attachment()]});
  // SendGrid公式ヘルパーで実際のAPI用JSONへ変換し、形式(content_id等)が正しいことを確認する(通信はしない)
  const json = new Mail(payload).toJSON();
  assert.deepEqual(json.content.map((c) => c.type), ["text/plain", "text/html"]);
  assert.equal(json.attachments.length, 1);
  assert.deepEqual(json.attachments[0], {content: PNG_1X1, filename: "qr.png", type: "image/png", disposition: "inline", content_id: "jm-quick-reception-qr"});
});

test("プロバイダ拒否の502に providerStatus(SendGridのHTTPステータス)を含め、呼出側が「送られていない」と判断できるようにする", async () => {
  const failing = createApp({env: {MAIL_API_KEY: "test-key"}, mailer: {async send() { const error = new Error("rejected"); error.code = 400; throw error; }}});
  const server2 = failing.listen(0);
  await new Promise((resolve) => server2.once("listening", resolve));
  const url = `http://127.0.0.1:${server2.address().port}/v1/mail/send`;
  const rejected = await fetch(url, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify(base)});
  assert.equal(rejected.status, 502);
  assert.deepEqual(await rejected.json(), {ok: false, error: "mail_provider_error", providerStatus: 400});
  server2.close();
  const unknown = createApp({env: {MAIL_API_KEY: "test-key"}, mailer: {async send() { throw new Error("network"); }}});
  const server3 = unknown.listen(0);
  await new Promise((resolve) => server3.once("listening", resolve));
  const response = await fetch(`http://127.0.0.1:${server3.address().port}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify(base)});
  assert.deepEqual(await response.json(), {ok: false, error: "mail_provider_error", providerStatus: null});
  server3.close();
});
