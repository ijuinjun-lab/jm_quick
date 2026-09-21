// Phase 10D: rate limit・walk-inのイベント単位上限が、同時リクエストでも超えないことを、ローカルのFirestore Emulator(localhostのみ)+
// 実際のFirebase Admin SDKのtransactionで検証する。メールはスタブ(実送信なし)。データはすべて架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {after, afterEach, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex, stubFetch} = require("../test_support/load_index");
const {publicRequest} = require("../test_support/app_check");
const {createRateLimiter} = require("../rate_limit");
const {RATE_LIMIT_POLICIES, RATE_LIMIT_RETENTION_MS, WALK_IN_EVENT_LIMIT, MINUTE} = require("../public_limits");

const code = (promise) => promise.then(() => "ok", (e) => e.code);
const count = (results, value) => results.filter((r) => r === value).length;

describe("公開APIの同時リクエスト(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  let net;
  let ipSeq = 0;
  const ip = () => `198.51.100.${(ipSeq = (ipSeq % 250) + 1)}`;

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    net = stubFetch();
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  afterEach(() => net?.restore());

  const seedEvent = (id, extra = {}) => db.collection("events").doc(id).set({
    eventId: id, eventName: "架空イベント", senderName: "架空事務局", startAt: env.Timestamp.fromDate(new Date(Date.now() + 3600e3)), ...extra,
  });
  const walkIn = (n, eventId = "e1") => index.registerWalkIn.run(publicRequest({data: {eventId, name: "当日 太郎", email: `walk${n}@example.invalid`, registeredCount: 1}}));
  const walkInCode = (n, eventId) => code(walkIn(n, eventId));

  test("rate limit: 同時に40回チェックしても、上限(5)を超えて許可されない。時間窓を越えると再び許可", async () => {
    let t = 5_000_000 * MINUTE;
    const limiter = createRateLimiter({getDb: () => db, getKey: () => "emulator-test-hmac-key-0123456789", now: () => t, retentionMs: RATE_LIMIT_RETENTION_MS, logger: {warn() {}, error() {}}});
    const policy = {name: "conc", scope: "ip", windowMs: MINUTE, limit: 5, onError: "closed"};
    const results = await Promise.all(Array.from({length: 40}, () => code(limiter.check(policy, "same-subject"))));
    assert.equal(count(results, "ok"), 5);
    assert.equal(count(results, "resource-exhausted"), 35);
    const other = await Promise.all(Array.from({length: 7}, () => code(limiter.check(policy, "another-subject"))));
    assert.equal(count(other, "ok"), 5, "別の識別子は独立して5回");
    t += MINUTE;
    assert.equal(await code(limiter.check(policy, "same-subject")), "ok");
    const docs = (await db.collection("rateLimits").get()).docs.map((d) => d.data());
    assert.ok(docs.every((d) => d.count <= 5), "どの窓のcountも上限を超えていない");
    assert.equal(JSON.stringify(docs).includes("same-subject"), false);
  });

  test("公開callableの閲覧: 同じ対象へ同時に20回でも、対象単位の上限(10/分)を超えて成功しない", async () => {
    await seedEvent("e1");
    await db.collection("participants").doc("p1").set({participantId: "p1", eventId: "e1", publicId: "pub_p1_0123456789abcdef01234567", name: "架空 太郎", email: "p1@example.invalid", registeredCount: 1});
    const results = await Promise.all(Array.from({length: 20}, () => code(index.getLegacyParticipantPage.run(
      publicRequest({data: {participantId: "p1", publicId: "pub_p1_0123456789abcdef01234567"}, rawRequest: {headers: {"x-forwarded-for": ip()}}})))));
    assert.ok(count(results, "ok") <= RATE_LIMIT_POLICIES.viewTarget.limit, `成功 ${count(results, "ok")}件`);
    assert.ok(count(results, "ok") >= 1, "上限までは通る");
    assert.equal(count(results, "ok") + count(results, "resource-exhausted"), 20);
  });

  test("walk-inのイベント単位上限: 残り3件のイベントへ同時に12件登録しても、ちょうど3件だけ成功し、超過分は何も作られず・メールも送られない", async () => {
    await seedEvent("e1", {walkInCount: WALK_IN_EVENT_LIMIT - 3});
    const results = await Promise.all(Array.from({length: 12}, (_, n) => walkInCode(n, "e1")));
    assert.equal(count(results, "ok"), 3);
    assert.equal(count(results, "resource-exhausted"), 9);
    assert.equal((await db.collection("events").doc("e1").get()).data().walkInCount, WALK_IN_EVENT_LIMIT);
    assert.equal((await db.collection("participants").where("eventId", "==", "e1").get()).size, 3);
    assert.equal((await db.collection("checkIns").where("eventId", "==", "e1").get()).size, 3);
    assert.equal((await db.collection("walkInRegistrations").where("eventId", "==", "e1").get()).size, 3);
    assert.equal(net.calls.length, 3, "メールは成功した3件だけ");
  });

  test("walk-inのカウンタ未設定の既存イベント: 既存のwalk-in件数を数えて初期化し、同時登録でも上限を超えない", async () => {
    await seedEvent("e2");
    const writer = db.bulkWriter();
    for (let i = 0; i < WALK_IN_EVENT_LIMIT - 2; i++) {
      writer.set(db.collection("participants").doc(`w${i}`), {participantId: `w${i}`, eventId: "e2", registrationType: "walkIn", name: "既存", publicId: `pub_w${i}_0123456789abcdef01234567`});
    }
    writer.set(db.collection("participants").doc("pre"), {participantId: "pre", eventId: "e2", registrationType: "preRegistered", name: "事前", publicId: "pub_pre_0123456789abcdef01234567"});
    await writer.close();
    const results = await Promise.all(Array.from({length: 6}, (_, n) => walkInCode(n, "e2")));
    assert.equal(count(results, "ok"), 2);
    assert.equal(count(results, "resource-exhausted"), 4);
    assert.equal((await db.collection("events").doc("e2").get()).data().walkInCount, WALK_IN_EVENT_LIMIT);
  });

  test("同一イベント+同一メールの同時登録は1件だけ(既存の重複防止が維持され、カウンタも1つだけ増える)", async () => {
    await seedEvent("e3");
    const results = await Promise.all(Array.from({length: 6}, () => code(index.registerWalkIn.run(publicRequest({
      data: {eventId: "e3", name: "当日 花子", email: "same@example.invalid", registeredCount: 1}, rawRequest: {headers: {"x-forwarded-for": ip()}}})))));
    assert.equal(count(results, "ok"), 1);
    assert.ok(results.filter((r) => r !== "ok").every((r) => r === "already-exists" || r === "resource-exhausted"), results.join(","));
    assert.equal((await db.collection("participants").where("eventId", "==", "e3").get()).size, 1);
    assert.equal((await db.collection("events").doc("e3").get()).data().walkInCount, 1);
    assert.equal(net.calls.length, 1);
  });
});
