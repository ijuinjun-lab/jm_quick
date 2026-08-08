const assert = require("node:assert/strict");
const {after, before, test} = require("node:test");
const {createApp} = require("../index");

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
  const response = await fetch(`${baseUrl}/v1/mail/send`, {method: "POST", headers: {Authorization: "Bearer test-key", "Content-Type": "application/json"}, body: JSON.stringify({to: "USER@example.com", subject: " Subject ", text: " Body "})});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {ok: true, messageId: "sg-message-id"});
  assert.deepEqual(sent, {to: "user@example.com", subject: "Subject", text: "Body"});
});
