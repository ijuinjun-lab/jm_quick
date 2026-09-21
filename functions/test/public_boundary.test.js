// Phase 10D: 公開callable(ログイン不要の5本)の最終境界。App Check・rate limit・walk-inのイベント単位上限・event kind API を、
// メモリ上のFirestoreと外部通信スタブだけで検証する(実App Check・実Firestore・実メールには一切接続しない)。
// 並行実行(transactionの直列化)は、実際のFirestoreの挙動が必要なため public_boundary.emulator.test.js で検証する。
const assert = require("node:assert/strict");
const {afterEach, describe, mock, test} = require("node:test");
const {FakeFirestore, ts} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");
const {TEST_APP, publicRequest} = require("../test_support/app_check");
const {requireAppCheck} = require("../auth");
const {createRateLimiter, clientIpOf} = require("../rate_limit");
const {RATE_LIMIT_POLICIES, RATE_LIMIT_RETENTION_MS, WALK_IN_EVENT_LIMIT, MINUTE, HOUR, DAY} = require("../public_limits");

const PUB = "pub_p1_0123456789abcdef01234567";
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const businessWrites = (db) => db.writes.filter((w) => !w.path.startsWith("rateLimits/"));
const ROLES = {
  "accessRoles/admin1": {role: "admin", active: true},
  "accessRoles/staff1": {role: "staff", active: true},
  "accessRoles/off1": {role: "admin", active: false},
};
const event = (id, extra = {}) => ({eventId: id, eventName: `イベント${id}`, senderName: "送信者", startAt: ts(new Date(Date.now() + HOUR)), reconfirmEnabled: true, ...extra});
const participant = (id, eventId, extra = {}) => ({participantId: id, eventId, publicId: `pub_${id}_0123456789abcdef01234567`, name: `参加者${id}`, email: `${id}@example.invalid`,
  registeredCount: 1, registrationType: "preRegistered", participationConfirmed: false, attendanceResponse: null, ...extra});

let net;
afterEach(() => { net?.restore(); mock.restoreAll(); });
function setup(seed = {}, {dbWrap} = {}) {
  const base = new FakeFirestore({...ROLES, ...seed});
  const db = dbWrap ? dbWrap(base) : base;
  net = stubFetch();
  return {db: base, index: loadIndex(db), mail: net.calls};
}
// 時刻を固定する(rate limitの時間窓・walk-inの受付可否をテスト中に動かさない)
function freezeClock() {
  const T = Math.ceil(Date.now() / DAY) * DAY + 30 * 1000;
  mock.method(Date, "now", () => T);
  return T;
}
const at = (ip) => ({headers: {"x-forwarded-for": ip}});
const req = (data, ip = "203.0.113.1") => ({data, app: TEST_APP, rawRequest: at(ip)});

describe("App Check(公開5本。実App Checkには接続しない)", () => {
  const PUBLIC = {
    getConfirmedParticipantPass: {participantId: "p1", publicId: PUB},
    getLegacyParticipantPage: {participantId: "p1", publicId: PUB},
    confirmLegacyParticipation: {participantId: "p1", publicId: PUB},
    answerLegacyReconfirmation: {participantId: "p1", publicId: PUB, response: "attending"},
    registerWalkIn: {eventId: "e1", name: "当日 太郎", email: "walk@example.invalid", registeredCount: 1},
  };
  const seed = () => ({"events/e1": event("e1"), "participants/p1": participant("p1", "e1", {participationConfirmed: true}), "checkIns/p1": {participantId: "p1", eventId: "e1", checkedIn: false}});

  for (const [name, data] of Object.entries(PUBLIC)) {
    test(`${name}: App Checkなし・不正(appIdなし)は拒否し、rate limitの記録も業務データの書込みもメール送信もない。検証済みなら従来の処理へ進む`, async () => {
      const {db, index, mail} = setup(seed());
      assert.equal(await code(index[name].run({data, rawRequest: at("203.0.113.9")})), "unauthenticated", "App Checkなし");
      assert.equal(await code(index[name].run({data, app: {}, rawRequest: at("203.0.113.9")})), "unauthenticated", "appIdなし(不正相当)");
      assert.equal(await code(index[name].run({data, app: {appId: ""}, rawRequest: at("203.0.113.9")})), "unauthenticated");
      assert.equal(db.writes.length, 0, "rate limitも数えない(拒否は何も書かない)");
      assert.equal(mail.length, 0);
      const ok = await code(index[name].run(publicRequest({data})));
      // 検証済みなら従来の処理へ進む(参加証はconfirmed専用のため、legacyの参加者では従来どおり「無効」応答=ハンドラまで到達)
      assert.equal(ok, name === "getConfirmedParticipantPass" ? "not-found" : "ok", "App Check検証済みなら従来の処理");
    });
  }

  test("拒否の応答は理由を区別せず、ログにはトークンを出さず理由コードだけを残す", () => {
    const lines = [];
    const logger = {warn: (...a) => lines.push(a)};
    const errors = [];
    for (const request of [{}, {app: {}}, {app: {appId: 5, token: {secret: "SECRET-TOKEN-VALUE"}}}]) {
      try { requireAppCheck(request, {logger}); } catch (error) { errors.push([error.code, error.message]); }
    }
    assert.equal(new Set(errors.map((e) => e.join("|"))).size, 1);
    assert.equal(errors.length, 3);
    const text = JSON.stringify(lines);
    assert.equal(text.includes("SECRET-TOKEN-VALUE"), false);
    assert.ok(text.includes("app-check-missing") && text.includes("app-check-invalid"));
  });

  test("管理・受付系のcallableはApp Checkを要求しない(認証+accessRolesが境界。今回は公開5本に限定)", async () => {
    const {index} = setup(seed());
    assert.notEqual(await code(index.listLegacyEvents.run({auth: {uid: "admin1"}, data: {}})), "unauthenticated");
    assert.equal(await code(index.listLegacyEvents.run({auth: {uid: "admin1"}, data: {}})), "ok");
  });
});

describe("rate limit(サーバー側・時刻とストレージを注入して境界を検証)", () => {
  const P = {name: "p", scope: "ip", windowMs: MINUTE, limit: 3, onError: "closed"};
  const make = (db, extra = {}) => {
    let t = 1_000_000 * MINUTE;
    const clock = {set: (v) => { t = v; }, get: () => t};
    const lines = [];
    const logger = {warn: (...a) => lines.push(a), error: (...a) => lines.push(a), info: (...a) => lines.push(a)};
    return {limiter: createRateLimiter({getDb: () => db, getKey: () => "unit-test-hmac-key-0123456789abcdef", now: clock.get, retentionMs: RATE_LIMIT_RETENTION_MS, logger, ...extra}), clock, lines};
  };

  test("上限未満は許可、上限ちょうどまで許可、超過は resource-exhausted。時間窓を越えると再び許可。別の識別子は独立", async () => {
    const db = new FakeFirestore();
    const {limiter, clock} = make(db);
    for (let i = 0; i < 3; i++) await limiter.check(P, "a");
    assert.equal(await code(limiter.check(P, "a")), "resource-exhausted");
    assert.equal(await code(limiter.check(P, "a")), "resource-exhausted");
    await limiter.check(P, "b");
    clock.set(clock.get() + MINUTE - 1);
    assert.equal(await code(limiter.check(P, "a")), "resource-exhausted", "窓の最後のミリ秒はまだ同じ窓");
    clock.set(clock.get() + 1);
    await limiter.check(P, "a");
    await limiter.check(P, "a");
    await limiter.check(P, "a");
    assert.equal(await code(limiter.check(P, "a")), "resource-exhausted");
  });

  test("ポリシーが違えば独立(閲覧の上限で更新が止まらない)。同じ識別子でもscope・policyが違えば別の枠", async () => {
    const db = new FakeFirestore();
    const {limiter} = make(db);
    for (let i = 0; i < RATE_LIMIT_POLICIES.viewTarget.limit; i++) await limiter.check(RATE_LIMIT_POLICIES.viewTarget, "p1");
    assert.equal(await code(limiter.check(RATE_LIMIT_POLICIES.viewTarget, "p1")), "resource-exhausted");
    await limiter.check(RATE_LIMIT_POLICIES.updateTarget, "p1");
  });

  test("保存されるのはpolicy・count・窓・期限だけ。メール・IP・participantId・publicIdの元値は、保存にもログにも応答にも出ない", async () => {
    const db = new FakeFirestore();
    const {limiter, lines} = make(db);
    const raw = ["203.0.113.77", "person@example.invalid", "participant-XYZ-123", "pub_secret_0123456789"];
    for (const value of raw) {
      for (let i = 0; i < 4; i++) await limiter.check(P, value).catch(() => {});
    }
    const errors = [];
    for (const value of raw) errors.push(await limiter.check(P, value).then(() => null, (e) => `${e.code}|${e.message}|${JSON.stringify(e.details)}`));
    const stored = JSON.stringify([...db.store.entries()]);
    for (const value of [...raw, "unit-test-hmac-key"]) {
      assert.equal(stored.includes(value), false, `保存: ${value}`);
      assert.equal(JSON.stringify(lines).includes(value), false, `ログ: ${value}`);
      assert.equal(errors.join("\n").includes(value), false, `応答: ${value}`);
    }
    for (const [path, data] of db.store) {
      assert.match(path, /^rateLimits\/p_[0-9a-f]{32}_\d+$/);
      assert.deepEqual(Object.keys(data).sort(), ["count", "expiresAt", "policy", "windowStart"]);
    }
    // 同じ値は同じ識別子、別の値は別の識別子(HMAC)
    assert.equal(new Set(errors).size, 1, "超過の応答は対象を区別できない");
  });

  test("保存先の障害: openのポリシーは処理を続け、closedのポリシーは unavailable(処理しない)。鍵が未設定でも同じ方針", async () => {
    const broken = {collection: () => ({doc: () => ({})}), runTransaction: async () => { throw new Error("storage down: person@example.invalid"); }};
    const {limiter, lines} = make(broken);
    await limiter.check({...P, onError: "open"}, "a");
    assert.equal(await code(limiter.check({...P, onError: "closed"}, "a")), "unavailable");
    assert.equal(JSON.stringify(lines).includes("person@example.invalid"), false, "エラーオブジェクトの中身をログに出さない");
    const noKey = createRateLimiter({getDb: () => new FakeFirestore(), getKey: () => undefined, now: () => 0, retentionMs: 1});
    assert.equal(await code(noKey.check({...P, onError: "closed"}, "a")), "unavailable", "鍵の未設定は拒否(closed)");
    await noKey.check({...P, onError: "open"}, "a");
  });

  test("方針の固定: 閲覧はfail-open、状態更新とwalk-inはfail-closed", () => {
    for (const name of ["viewIp", "viewTarget"]) assert.equal(RATE_LIMIT_POLICIES[name].onError, "open");
    for (const name of ["updateIp", "updateTarget", "walkInIp", "walkInTarget"]) assert.equal(RATE_LIMIT_POLICIES[name].onError, "closed");
  });

  test("初期値の目安: 閲覧 IP30/分・対象10/分、更新は閲覧より低い、walk-in IP5/時・宛先3/日。窓の期限にretentionが加わる", async () => {
    const p = RATE_LIMIT_POLICIES;
    assert.deepEqual([p.viewIp.limit, p.viewIp.windowMs, p.viewTarget.limit, p.viewTarget.windowMs], [30, MINUTE, 10, MINUTE]);
    assert.ok(p.updateIp.limit < p.viewIp.limit && p.updateTarget.limit < p.viewTarget.limit);
    assert.deepEqual([p.walkInIp.limit, p.walkInIp.windowMs, p.walkInTarget.limit, p.walkInTarget.windowMs], [5, HOUR, 3, DAY]);
    const db = new FakeFirestore();
    const {limiter, clock} = make(db);
    await limiter.check(P, "a");
    const [, data] = [...db.store][0];
    const windowStart = Math.floor(clock.get() / MINUTE) * MINUTE;
    assert.equal(data.windowStart.getTime(), windowStart);
    assert.equal(data.expiresAt.getTime(), windowStart + MINUTE + RATE_LIMIT_RETENTION_MS);
  });

  test("接続元IP: X-Forwarded-Forの末尾(クライアントが偽装できる先頭側は使わない)。無ければ固定値", () => {
    assert.equal(clientIpOf({rawRequest: {headers: {"x-forwarded-for": "1.1.1.1, 2.2.2.2, 3.3.3.3"}}}), "3.3.3.3");
    assert.equal(clientIpOf({rawRequest: {headers: {}, ip: "4.4.4.4"}}), "4.4.4.4");
    assert.equal(clientIpOf({}), "unknown");
    assert.equal(clientIpOf(undefined), "unknown");
  });
});

describe("公開APIのrate limit(callable経由)", () => {
  test("参加証・マイページの閲覧: 対象単位10回/分を超えると resource-exhausted。別の対象・別のIPは独立。App Check・capability照合は従来どおり", async () => {
    freezeClock();
    const seed = {"events/e1": event("e1"), "participants/p1": participant("p1", "e1"), "participants/p2": participant("p2", "e1")};
    const {index} = setup(seed);
    const view = (participantId, ip) => index.getLegacyParticipantPage.run(req({participantId, publicId: participant(participantId, "e1").publicId}, ip));
    for (let i = 0; i < RATE_LIMIT_POLICIES.viewTarget.limit; i++) assert.equal(await code(view("p1", `198.51.100.${i + 1}`)), "ok");
    assert.equal(await code(view("p1", "198.51.100.200")), "resource-exhausted");
    assert.equal(await code(view("p2", "198.51.100.200")), "ok", "別の対象は独立");
    // 同じIPからの閲覧は、対象が違っても30回/分まで
    const {index: index2} = setup({"events/e1": event("e1")});
    let last;
    for (let i = 0; i < RATE_LIMIT_POLICIES.viewIp.limit + 1; i++) last = await code(index2.getLegacyParticipantPage.run(req({participantId: `x${i}`, publicId: PUB}, "198.51.100.50")));
    assert.equal(last, "resource-exhausted");
  });

  test("制限超過の応答は共通(対象の存在・内部キーを含まない)。存在しない参加者でも存在する参加者でも同じ", async () => {
    freezeClock();
    const {index} = setup({"events/e1": event("e1"), "participants/p1": participant("p1", "e1")});
    const errors = [];
    for (const id of ["p1", "nobody"]) {
      for (let i = 0; i < RATE_LIMIT_POLICIES.viewTarget.limit; i++) await index.getLegacyParticipantPage.run(req({participantId: id, publicId: PUB}, `198.51.100.${(id === "p1" ? 0 : 100) + i + 1}`)).catch(() => {});
      errors.push(await index.getLegacyParticipantPage.run(req({participantId: id, publicId: PUB}, "198.51.100.250")).then(() => null, (e) => `${e.code}|${e.message}`));
    }
    assert.equal(errors[0], errors[1]);
    assert.match(errors[0], /^resource-exhausted\|/);
    assert.equal(/p1|nobody|pub_|rateLimits|hmac/i.test(errors[0]), false);
  });

  test("状態更新(正式登録・回答)は閲覧より厳しい上限(対象5回/分)。上限超過後は書込みされない", async () => {
    freezeClock();
    const {db, index} = setup({"events/e1": event("e1"), "participants/p1": participant("p1", "e1", {participationConfirmed: false})});
    const call = (n) => index.confirmLegacyParticipation.run(req({participantId: "p1", publicId: participant("p1", "e1").publicId}, `198.51.100.${n}`));
    for (let i = 1; i <= RATE_LIMIT_POLICIES.updateTarget.limit; i++) assert.equal(await code(call(i)), "ok");
    const writes = businessWrites(db).length;
    assert.equal(await code(call(99)), "resource-exhausted");
    assert.equal(businessWrites(db).length, writes);
  });

  test("保存先の障害: 閲覧はfail-open(従来どおり返る)、状態更新はfail-closed(書込みしない)", async () => {
    freezeClock();
    const wrap = (base) => ({
      collection: (name) => base.collection(name),
      doc: (p) => base.doc(p),
      bulkWriter: () => base.bulkWriter(),
      runTransaction: (fn) => base.runTransaction((tx) => fn({...tx, get: (ref) => { if (String(ref.path).startsWith("rateLimits/")) throw new Error("down"); return tx.get(ref); }})),
    });
    const {db, index} = setup({"events/e1": event("e1"), "participants/p1": participant("p1", "e1")}, {dbWrap: wrap});
    const key = {participantId: "p1", publicId: participant("p1", "e1").publicId};
    assert.equal(await code(index.getLegacyParticipantPage.run(req(key))), "ok");
    assert.equal(await code(index.confirmLegacyParticipation.run(req(key))), "unavailable");
    assert.equal(db.store.get("participants/p1").participationConfirmed, false);
  });
});

describe("registerWalkIn: rate limit・イベント単位上限・拒否時の部分状態なし", () => {
  const input = (n, extra = {}) => ({eventId: "e1", name: "当日 太郎", email: `walk${n}@example.invalid`, registeredCount: 1, ...extra});
  const walkIn = (index, data, ip) => index.registerWalkIn.run(req(data, ip));
  const snapshotState = (db) => ({participants: db.writesTo("participants/").length, checkIns: db.writesTo("checkIns/").length, walkIns: db.writesTo("walkInRegistrations/").length});

  test("接続元IP単位 5回/時: 6回目は resource-exhausted。拒否時は participant・checkIn・walkInRegistration・メールが0", async () => {
    freezeClock();
    const {db, index, mail} = setup({"events/e1": event("e1")});
    for (let n = 1; n <= RATE_LIMIT_POLICIES.walkInIp.limit; n++) assert.equal(await code(walkIn(index, input(n), "198.51.100.10")), "ok");
    const before = snapshotState(db);
    const mails = mail.length;
    assert.equal(await code(walkIn(index, input(99), "198.51.100.10")), "resource-exhausted");
    assert.deepEqual(snapshotState(db), before);
    assert.equal(mail.length, mails);
    assert.equal(await code(walkIn(index, input(100), "198.51.100.11")), "ok", "別のIPは独立");
  });

  test("宛先(メール)単位 3回/日: 同じメールでの4回目は拒否。イベントが違っても同じ宛先の枠。応答にメールを含まない", async () => {
    freezeClock();
    const {db, index, mail} = setup({"events/e1": event("e1"), "events/e2": event("e2")});
    const same = (eventId) => input(1, {eventId, email: "same@example.invalid"});
    await code(walkIn(index, same("e1"), "198.51.100.21"));
    await code(walkIn(index, same("e1"), "198.51.100.22")); // 重複(already-exists)でも数える
    await code(walkIn(index, same("e2"), "198.51.100.23"));
    const before = snapshotState(db);
    const mails = mail.length;
    const error = await walkIn(index, same("e2"), "198.51.100.24").then(() => null, (e) => e);
    assert.equal(error.code, "resource-exhausted");
    assert.equal(error.message.includes("same@example"), false);
    assert.deepEqual(snapshotState(db), before);
    assert.equal(mail.length, mails);
  });

  test("イベント単位の上限: 上限未満は登録でき、上限到達後は拒否(participant・checkIn・walkInRegistration・メールが0)。同一イベント+メールの重複防止は維持", async () => {
    freezeClock();
    const {db, index, mail} = setup({"events/e1": event("e1", {walkInCount: WALK_IN_EVENT_LIMIT - 2})});
    assert.equal(await code(walkIn(index, input(1), "198.51.100.31")), "ok");
    assert.equal(db.store.get("events/e1").walkInCount, WALK_IN_EVENT_LIMIT - 1);
    assert.equal(await code(walkIn(index, input(2), "198.51.100.32")), "ok");
    assert.equal(db.store.get("events/e1").walkInCount, WALK_IN_EVENT_LIMIT);
    const before = snapshotState(db);
    const mails = mail.length;
    const error = await walkIn(index, input(3), "198.51.100.33").then(() => null, (e) => e);
    assert.equal(error.code, "resource-exhausted");
    assert.deepEqual(snapshotState(db), before);
    assert.equal(mail.length, mails);
    assert.equal(db.store.get("events/e1").walkInCount, WALK_IN_EVENT_LIMIT, "拒否時にカウンタも増えない");
    // 登録済みの人の再送は、上限に達していても従来どおり「登録済み」(重複防止が先)
    assert.equal(await code(walkIn(index, input(1), "198.51.100.34")), "already-exists");
  });

  test("カウンタ未設定の既存イベント: walk-inとして作られた件数だけを数える(事前登録の参加者は数えない)", async () => {
    freezeClock();
    const seed = {"events/e1": event("e1"), "events/e2": event("e2")};
    for (let i = 0; i < WALK_IN_EVENT_LIMIT; i++) seed[`participants/w${i}`] = participant(`w${i}`, "e2", {registrationType: "walkIn"});
    for (let i = 0; i < WALK_IN_EVENT_LIMIT + 5; i++) seed[`participants/r${i}`] = participant(`r${i}`, "e1", {registrationType: "preRegistered"});
    const {db, index} = setup(seed);
    assert.equal(await code(walkIn(index, input(1), "198.51.100.41")), "ok", "事前登録が上限を超えていてもwalk-inは数えない");
    assert.equal(db.store.get("events/e1").walkInCount, 1);
    assert.equal(await code(walkIn(index, input(2, {eventId: "e2"}), "198.51.100.42")), "resource-exhausted", "walk-inがすでに上限");
    assert.equal(db.store.has("events/e2") && db.store.get("events/e2").walkInCount, undefined);
  });

  test("拒否の種類ごと(入力不正・終了後・confirmed・上限・rate limit)に、部分状態が残らない", async () => {
    freezeClock();
    const {db, index, mail} = setup({"events/e1": event("e1"), "events/c1": event("c1", {flow: "confirmed"}), "events/old": event("old", {startAt: ts(new Date(Date.now() - 72 * HOUR))})});
    const before = snapshotState(db);
    for (const data of [input(1, {subject: "x"}), input(2, {registeredCount: 51}), input(3, {eventId: "c1"}), input(4, {eventId: "old"}), input(5, {eventId: "none"})]) {
      assert.notEqual(await code(walkIn(index, data, "198.51.100.60")), "ok");
    }
    assert.deepEqual(snapshotState(db), before);
    assert.equal(mail.length, 0);
  });
});

describe("registerWalkInのログ(個人情報を出さない)", () => {
  test("メール送信に失敗しても、ログに宛先・氏名・publicIdが出ない(理由コードだけ)。登録自体は完了し、失敗は利用者へ共通の文言で返る", async () => {
    freezeClock();
    const {db, index} = setup({"events/e1": event("e1")});
    globalThis.fetch = async () => ({ok: false, status: 500, json: async () => ({error: "failed for leak-target@example.invalid 当日 太郎"})});
    const lines = [];
    mock.method(console, "error", (...args) => lines.push(args));
    mock.method(console, "log", (...args) => lines.push(args));
    mock.method(console, "warn", (...args) => lines.push(args));
    const result = await index.registerWalkIn.run(req({eventId: "e1", name: "当日 太郎", email: "leak-target@example.invalid", registeredCount: 1}, "198.51.100.77"));
    assert.equal(result.mailSent, false);
    assert.equal(result.mailError, "確認メールを送信できませんでした。");
    const text = JSON.stringify(lines);
    for (const forbidden of ["leak-target", "当日 太郎", "pub_", result.publicId, "198.51.100.77"]) assert.equal(text.includes(forbidden), false, forbidden);
    assert.equal(db.writesTo("participants/").length >= 1, true);
  });
});

describe("event kind API(getEventKind: staffOrAdminだけ。kindしか返さない)", () => {
  const seed = () => ({"events/e1": event("e1"), "events/c1": event("c1", {flow: "confirmed", winnerMailTemplate: {subject: "秘密の件名"}, contact: "連絡先", reminderSendAt: "x", importSequence: 3}),
    "events/u1": event("u1", {flow: "confirmd"}), "events/n1": event("n1", {flow: 1})});
  const call = (index, auth, data) => index.getEventKind.run({auth, data});

  test("未認証・accessRolesなし・active=falseは拒否(イベントを問い合わせない)。staffもadminも成功", async () => {
    const {db, index} = setup(seed());
    assert.equal(await code(call(index, undefined, {eventId: "e1"})), "unauthenticated");
    assert.equal(await code(call(index, {uid: "nobody"}, {eventId: "e1"})), "permission-denied");
    assert.equal(await code(call(index, {uid: "off1"}, {eventId: "e1"})), "permission-denied");
    assert.equal(db.writes.length, 0);
    for (const auth of [{uid: "staff1"}, {uid: "admin1"}]) {
      assert.deepEqual(await call(index, auth, {eventId: "e1"}), {kind: "legacy"});
      assert.deepEqual(await call(index, auth, {eventId: "c1"}), {kind: "confirmed"});
    }
  });

  test("返すのはkindだけ(イベント名・テンプレート・連絡先・reminder・importSequence等を含まない)", async () => {
    const {index} = setup(seed());
    const result = await call(index, {uid: "staff1"}, {eventId: "c1"});
    assert.deepEqual(Object.keys(result), ["kind"]);
    const text = JSON.stringify(result);
    for (const forbidden of ["秘密の件名", "連絡先", "reminder", "importSequence", "イベント", "senderName"]) assert.equal(text.includes(forbidden), false, forbidden);
  });

  test("未知のflow・型が不正なflow・存在しないイベントは、区別できない同一のエラー(fail-closed)。不正なeventId・余計なキーは拒否", async () => {
    const {index} = setup(seed());
    const errors = [];
    for (const eventId of ["u1", "n1", "missing"]) errors.push(await call(index, {uid: "staff1"}, {eventId}).then(() => null, (e) => `${e.code}|${e.message}`));
    assert.equal(new Set(errors).size, 1);
    assert.match(errors[0], /^failed-precondition\|/);
    for (const data of [{eventId: "a/b"}, {eventId: ""}, {eventId: 5}, {}, {eventId: "e1", extra: 1}, {eventId: "e1", role: "admin"}, null, "e1"]) {
      assert.equal(await code(call(index, {uid: "staff1"}, data)), "invalid-argument", JSON.stringify(data));
    }
  });
});
