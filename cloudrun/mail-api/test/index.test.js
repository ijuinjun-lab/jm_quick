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
