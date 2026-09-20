// メール送信トランスポートのテスト。fetchは偽物で、実通信(SendGrid・Cloud Run)は一切行わない。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {createMailApiTransport} = require("../mail_transport");

const ENDPOINT = "https://mail-api.invalid";
const message = {to: "p@example.invalid", subject: "s", text: "t", html: "<p>t</p>", attachments: []};
const respond = (status, body) => async () => ({ok: status >= 200 && status < 300, status, json: async () => { if (body === undefined) throw new Error("no json"); return body; }});
const transportWith = (fetchFn) => createMailApiTransport({endpoint: ENDPOINT, apiKey: "test-only-key", fetchFn});

test("capability: html・attachmentsに対応していればok、旧版(featuresなし)・一部欠けは未対応(fail-closed)", async () => {
  assert.deepEqual(await transportWith(respond(200, {ok: true, features: ["html", "attachments"]})).capabilities(), {ok: true, missing: []});
  assert.deepEqual(await transportWith(respond(200, {ok: true})).capabilities(), {ok: false, missing: ["html", "attachments"]}, "旧版のmail-api");
  assert.deepEqual(await transportWith(respond(200, {ok: true, features: ["html"]})).capabilities(), {ok: false, missing: ["attachments"]});
  assert.equal((await transportWith(respond(500, {})).capabilities()).ok, false);
  assert.equal((await transportWith(respond(200, undefined)).capabilities()).ok, false, "応答が読めない");
  assert.equal((await transportWith(async () => { throw new Error("offline"); }).capabilities()).ok, false, "確認できない");
  assert.equal((await transportWith(respond(200, {features: "html"})).capabilities()).ok, false);
});

test("capability確認は /health へのGETで、認証キーを送らない", async () => {
  const seen = [];
  await transportWith(async (url, init) => { seen.push([url, init.method, init.headers]); return {ok: true, status: 200, json: async () => ({features: ["html", "attachments"]})}; }).capabilities();
  assert.deepEqual(seen, [[`${ENDPOINT}/health`, "GET", undefined]]);
});

test("send: 成功(200・ok・messageId)は sent。送信内容とAuthorizationヘッダを正しく渡す", async () => {
  let captured;
  const result = await transportWith(async (url, init) => { captured = {url, init}; return {ok: true, status: 200, json: async () => ({ok: true, messageId: "mid-1"})}; }).send(message);
  assert.deepEqual(result, {outcome: "sent", messageId: "mid-1"});
  assert.equal(captured.url, `${ENDPOINT}/v1/mail/send`);
  assert.equal(captured.init.method, "POST");
  assert.equal(captured.init.headers.Authorization, "Bearer test-only-key");
  assert.deepEqual(JSON.parse(captured.init.body), message);
});

test("send: 200でも成功応答が不正(ok=falseやmessageIdなし・JSONでない)なら unknown(送ったかもしれないため)", async () => {
  for (const body of [{ok: false}, {ok: true}, {ok: true, messageId: 1}, undefined, null]) {
    assert.deepEqual(await transportWith(respond(200, body)).send(message), {outcome: "unknown", errorCode: "invalid-success-response"});
  }
});

test("send: 相手へ渡っていないと確実な拒否(mail-api 400/401/403/404/413/415/422、プロバイダの4xx)は failed", async () => {
  for (const status of [400, 401, 403, 404, 413, 415, 422]) {
    assert.deepEqual(await transportWith(respond(status, {ok: false})).send(message), {outcome: "failed", errorCode: `mail-api-${status}`});
  }
  assert.deepEqual(await transportWith(respond(502, {ok: false, error: "mail_provider_error", providerStatus: 400})).send(message), {outcome: "failed", errorCode: "provider-400"});
  assert.deepEqual(await transportWith(respond(502, {providerStatus: 403})).send(message), {outcome: "failed", errorCode: "provider-403"});
});

test("send: 判断できないもの(5xx・プロバイダ5xx/不明・想定外のステータス)は unknown(自動再送しない)", async () => {
  for (const status of [500, 502, 503, 504, 429, 302, 418]) {
    const result = await transportWith(respond(status, {ok: false})).send(message);
    assert.equal(result.outcome, "unknown", String(status));
    assert.equal(result.errorCode, `mail-api-${status}`);
  }
  assert.equal((await transportWith(respond(502, {providerStatus: 503})).send(message)).outcome, "unknown");
  assert.equal((await transportWith(respond(502, {providerStatus: null})).send(message)).outcome, "unknown");
});

test("send: 通信例外の分類 — 接続できなかった(ENOTFOUND/ECONNREFUSED/EAI_AGAIN)は failed、タイムアウト・その他は unknown", async () => {
  const throwing = (error) => transportWith(async () => { throw error; }).send(message);
  for (const code of ["ENOTFOUND", "ECONNREFUSED", "EAI_AGAIN"]) {
    const error = new TypeError("fetch failed"); error.cause = {code};
    assert.deepEqual(await throwing(error), {outcome: "failed", errorCode: "network-unreachable"}, code);
  }
  const reset = new TypeError("fetch failed"); reset.cause = {code: "ECONNRESET"};
  assert.deepEqual(await throwing(reset), {outcome: "unknown", errorCode: "network-error"});
  const timeout = new Error("timeout"); timeout.name = "TimeoutError";
  assert.deepEqual(await throwing(timeout), {outcome: "unknown", errorCode: "timeout"});
  const abort = new Error("aborted"); abort.name = "AbortError";
  assert.deepEqual(await throwing(abort), {outcome: "unknown", errorCode: "timeout"});
  assert.deepEqual(await throwing(new Error("boom")), {outcome: "unknown", errorCode: "network-error"});
});

test("sendは例外を投げない。エラーコードに宛先メールアドレスを含めない", async () => {
  const result = await transportWith(async () => { throw new Error(`failed for ${message.to}`); }).send(message);
  assert.equal(JSON.stringify(result).includes("example.invalid"), false);
});

test("不正なエンドポイント(http・空)・キーなしでは生成できない", () => {
  for (const endpoint of ["http://mail-api.invalid", "", "mail-api.invalid", null, undefined]) {
    assert.throws(() => createMailApiTransport({endpoint, apiKey: "k", fetchFn: async () => ({})}), /endpoint/);
  }
  assert.throws(() => createMailApiTransport({endpoint: ENDPOINT, apiKey: "", fetchFn: async () => ({})}), /key/);
});
