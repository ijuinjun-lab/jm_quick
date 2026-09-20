const assert = require("node:assert/strict");
const {test} = require("node:test");
const {receptionQrPayload, webPassUrl, QR_CONTENT_ID} = require("../pass_urls");

const ids = {appBaseUrl: "https://app.invalid", eventId: "event1", participantId: "batchA-000002", publicId: "pub_0123456789abcdef0123456789abcdef"};

test("受付QRのペイロード: 従来のマイページ(participant_page.dart)が作る形式と同一", () => {
  // 従来: '/reception?eventId=${Uri.encodeQueryComponent(eventId)}&participantId=${id}&publicId=${Uri.encodeQueryComponent(publicId)}'
  assert.equal(receptionQrPayload(ids),
    "https://app.invalid/reception?eventId=event1&participantId=batchA-000002&publicId=pub_0123456789abcdef0123456789abcdef");
});

test("Web参加証URL: 従来のメール本文が使う /p/{participantId}?publicId= と同一", () => {
  assert.equal(webPassUrl(ids), "https://app.invalid/p/batchA-000002?publicId=pub_0123456789abcdef0123456789abcdef");
});

test("同じ入力からは常に同じ文字列(再送・再レンダリングでQRは変わらない)", () => {
  const first = receptionQrPayload(ids);
  for (let i = 0; i < 50; i += 1) assert.equal(receptionQrPayload({...ids}), first);
  assert.equal(webPassUrl(ids), webPassUrl({...ids}));
});

test("QRには氏名・メールアドレスなどの個人情報を含まない(内部IDと推測困難なpublicIdだけ)", () => {
  const payload = receptionQrPayload(ids);
  const query = new URL(payload).searchParams;
  assert.deepEqual([...query.keys()].sort(), ["eventId", "participantId", "publicId"]);
  assert.ok(!/@/.test(payload) && !/name|email|mail/i.test(payload));
});

test("末尾スラッシュ・パスつきのアプリURLを正規化し、http・不正なURLは拒否する", () => {
  assert.equal(receptionQrPayload({...ids, appBaseUrl: "https://app.invalid/"}), receptionQrPayload(ids));
  assert.ok(receptionQrPayload({...ids, appBaseUrl: "https://app.invalid/sub/"}).startsWith("https://app.invalid/sub/reception?"));
  for (const bad of ["http://app.invalid", "app.invalid", "https://", "javascript:alert(1)", "https://app.invalid/?x=1", "https://app invalid", "", null, undefined]) {
    assert.throws(() => receptionQrPayload({...ids, appBaseUrl: bad}), /appBaseUrl/, String(bad));
  }
});

test("不正なID(eventId・participantId・publicId)ではペイロード/URLを作らない", () => {
  for (const bad of [{eventId: "a/b"}, {eventId: ""}, {participantId: "a_b"}, {participantId: "a b"}, {participantId: "a&b"}, {publicId: "x"}, {publicId: "pub_short"},
    {publicId: "pub_0123456789abcdef0123456789abcde&"}, {publicId: undefined}]) {
    assert.throws(() => receptionQrPayload({...ids, ...bad}), Error, JSON.stringify(bad));
    assert.throws(() => webPassUrl({...ids, ...bad}), Error, JSON.stringify(bad));
  }
});

test("Content-IDは固定値(ユーザー入力を含まない)", () => assert.equal(QR_CONTENT_ID, "jm-quick-reception-qr"));
