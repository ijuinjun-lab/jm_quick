// Phase 11A: 新方式(confirmed)イベントの作成API(createConfirmedEvent)。実際のcallable(index.js)を、メモリ上のFirestoreと
// 外部通信スタブだけで呼んで確認する(実Firestore・実Auth・実メールには一切接続しない)。データはすべて完全な架空。
//  - 認可(admin専用)、入力検証、作成結果(flowはサーバー固定・reminderは無効・メール関連は何も作らない)
//  - 冪等性(同じrequestIdの再試行は1件だけ。内容が違えば拒否)、既存イベントの保護、programの独立性
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {afterEach, describe, test} = require("node:test");
const {FakeFirestore, ts} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");
const {createEventCreateApi, deriveEventId} = require("../confirmed/event_create_api");

const ROLES = {
  "accessRoles/admin1": {role: "admin", active: true},
  "accessRoles/admin2": {role: "admin", active: true},
  "accessRoles/staff1": {role: "staff", active: true},
  "accessRoles/off1": {role: "admin", active: false},
};
const ADMIN = {uid: "admin1"};
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const detail = (promise) => promise.then(() => null, (e) => e.details && e.details.code);
const REQ = "req-0123456789abcdef0123";

const future = (days = 30, hour = 1) => new Date(Date.now() + days * 86400e3 + hour * 3600e3).toISOString();
const input = (extra = {}) => ({
  requestId: REQ, eventName: "PHASE11 STEP3 TEST(架空)", startAt: future(30), endAt: future(30, 6), venue: "架空ホール", address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分",
  programs: [{programId: "program-a", name: "架空プログラムA", order: 0}, {programId: "program-b", name: "架空プログラムB", order: 1}, {programId: "custom-zeta-9", name: "架空プログラムZ", order: 2}],
  ...extra,
});

let net;
afterEach(() => net?.restore());
function setup(seed = {}) {
  const db = new FakeFirestore({...ROLES, ...seed});
  net = stubFetch();
  return {db, index: loadIndex(db), mail: net.calls};
}
const create = (index, auth, data) => index.createConfirmedEvent.run({auth, data});
const eventsOf = (db) => [...db.store.entries()].filter(([p]) => p.startsWith("events/")).map(([p, d]) => [p.slice(7), d]);

describe("認可(admin専用。以前は作成経路自体が無かった)", () => {
  test("未認証・accessRolesなし・active=false・staffは拒否し、何も書き込まない。adminだけ成功する", async () => {
    const {db, index} = setup();
    assert.equal(await code(create(index, undefined, input())), "unauthenticated");
    assert.equal(await code(create(index, {uid: "nobody"}, input())), "permission-denied");
    assert.equal(await code(create(index, {uid: "off1"}, input())), "permission-denied");
    assert.equal(await code(create(index, {uid: "staff1"}, input())), "permission-denied");
    assert.equal(db.writes.length, 0);
    assert.equal(await code(create(index, ADMIN, input())), "ok");
    assert.equal(eventsOf(db).length, 1);
  });
  test("bodyのrole・uid・emailで権限昇格できない(staff・未認証のまま)。flow・eventId・createdBy・updatedByも受け付けない", async () => {
    const {db, index} = setup();
    for (const extra of [{role: "admin"}, {uid: "admin1"}, {email: "a@example.invalid"}, {flow: "confirmed"}, {flow: "legacy"}, {eventId: "x"}, {createdBy: "admin1"}, {updatedBy: "admin1"}, {reminderEnabled: true}, {winnerMailTemplate: {}}]) {
      assert.equal(await code(create(index, {uid: "staff1"}, input(extra))), "permission-denied", JSON.stringify(extra));
      assert.equal(await code(create(index, undefined, input(extra))), "unauthenticated", JSON.stringify(extra));
      assert.equal(await code(create(index, ADMIN, input(extra))), "invalid-argument", `adminでも余計なキーは拒否: ${JSON.stringify(extra)}`);
    }
    assert.equal(db.writes.length, 0);
  });
  test("公開callableは増えていない(createConfirmedEventはadmin専用の1本だけの追加)", () => {
    const source = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
    assert.match(source, /exports\.createConfirmedEvent = confirmedCallable\("admin", eventCreateApi\.createEvent/);
  });
});

describe("入力検証", () => {
  const bad = async (extra, expected) => {
    const {db, index} = setup();
    assert.equal(await code(create(index, ADMIN, input(extra))), "invalid-argument", JSON.stringify(extra).slice(0, 80));
    if (expected) assert.equal(await detail(create(index, ADMIN, input(extra))), expected);
    assert.equal(db.writes.length, 0, "拒否時は何も書き込まない");
  };
  test("イベント名の空・型不正・長すぎ・制御文字を拒否する", async () => {
    await bad({eventName: ""}, "required"); await bad({eventName: "   "}, "required"); await bad({eventName: 5}, "invalid-type");
    await bad({eventName: "x".repeat(201)}, "too-long"); await bad({eventName: "改\n行"}, "invalid-character"); await bad({eventName: undefined}, "required");
  });
  test("開催日時: 必須・不正な形式・存在しない日付・過去を拒否する。endAtがstartAt以前なら拒否", async () => {
    await bad({startAt: undefined}, "required"); await bad({startAt: "2030-01-01"}, "invalid-date"); await bad({startAt: "not-a-date"}, "invalid-date");
    await bad({startAt: "2030-02-30T10:00:00Z"}, "invalid-date"); await bad({startAt: "2001-01-01T00:00:00Z"}, "start-in-past");
    await bad({startAt: future(30), endAt: future(29)}, "invalid-time-range"); await bad({startAt: future(30), endAt: future(30, 1)}, "invalid-time-range");
    await bad({endAt: "garbage"}, "invalid-date");
  });
  test("会場は必須。住所・アクセスは任意(空は未設定)で、長すぎる値は拒否する", async () => {
    await bad({venue: ""}, "required"); await bad({venue: "x".repeat(301)}, "too-long"); await bad({address: "x".repeat(301)}); await bad({access: "x".repeat(1001)});
    const {db, index} = setup();
    await create(index, ADMIN, input({address: "", access: undefined}));
    assert.deepEqual(eventsOf(db)[0][1].venueInfo, {address: null, access: null});
  });
  test("programは1件以上必須。programIdの空・不正・重複、名前の空、orderの不正・重複を拒否する", async () => {
    await bad({programs: []}, "programs-required"); await bad({programs: undefined}, "programs-required"); await bad({programs: "x"}, "programs-required");
    const p = (extra = {}) => ({programId: "program-a", name: "架空A", order: 0, ...extra});
    await bad({programs: [p({programId: ""})]}, "invalid-program-id");
    for (const programId of ["A", "a_b", "a/b", "-a", "a-", "x".repeat(41), 5, null, "日本語"]) await bad({programs: [p({programId})]}, "invalid-program-id");
    await bad({programs: [p(), p({name: "別名"})]}, "duplicate-program-id");
    await bad({programs: [p({name: ""})]}, "required"); await bad({programs: [p({name: "  "})]}, "required");
    await bad({programs: [p({order: -1})]}, "invalid-order"); await bad({programs: [p({order: 1.5})]}, "invalid-order"); await bad({programs: [p({order: "1"})]}, "invalid-order");
    await bad({programs: [p(), p({programId: "program-b"})]}, "duplicate-order");
    await bad({programs: [p({extra: 1})]}, "unknown-key"); await bad({programs: [p({endAt: future(2), startAt: future(3)})]});
    await bad({programs: Array.from({length: 31}, (_, i) => p({programId: `p${i}`, order: i}))}, "too-many-programs");
  });
  test("requestIdの形式が不正なら拒否する(個人情報を入れない前提の固定形式)", async () => {
    await bad({requestId: undefined}, "invalid-request-id"); await bad({requestId: "short"}, "invalid-request-id"); await bad({requestId: "a b c d e f g h i j k l"}, "invalid-request-id");
    await bad({requestId: "x".repeat(65)}, "invalid-request-id");
  });
  test("リクエスト本体がオブジェクトでなければ拒否する", async () => {
    const {index} = setup();
    for (const data of [null, undefined, "x", 5, [], [input()]]) assert.equal(await code(create(index, ADMIN, data)), "invalid-argument");
  });
});

describe("作成結果", () => {
  test("eventドキュメントが1件だけ作られる。flowはサーバー固定で confirmed。eventIdは安全に生成される。応答は最小限", async () => {
    const {db, index} = setup();
    const result = await create(index, ADMIN, input());
    assert.deepEqual(Object.keys(result).sort(), ["created", "eventId", "eventName", "kind"]);
    assert.equal(result.kind, "confirmed");
    assert.equal(result.created, true);
    assert.match(result.eventId, /^ev[0-9a-f]{30}$/);
    assert.equal(eventsOf(db).length, 1);
    const saved = db.store.get(`events/${result.eventId}`);
    assert.equal(saved.flow, "confirmed");
    assert.equal(saved.eventId, result.eventId);
    assert.equal(saved.eventName, "PHASE11 STEP3 TEST(架空)");
    assert.equal(saved.createdBy, "admin1");
    assert.equal(saved.updatedBy, "admin1");
    assert.ok("createdAt" in saved && "updatedAt" in saved);
    assert.equal(JSON.stringify(result).includes("Template"), false);
  });
  test("日時・会場・venueInfo・programsが入力どおり保存される(order・programIdを保持。表示順の正本はorder)", async () => {
    const {db, index} = setup();
    const data = input({senderName: "架空事務局", contact: "架空連絡先 000-0000"});
    const {eventId} = await create(index, ADMIN, data);
    const saved = db.store.get(`events/${eventId}`);
    assert.equal(saved.startAt.getTime(), new Date(data.startAt).getTime());
    assert.equal(saved.endAt.getTime(), new Date(data.endAt).getTime());
    assert.equal(saved.venue, "架空ホール");
    assert.deepEqual(saved.venueInfo, {address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分"});
    assert.equal(saved.senderName, "架空事務局");
    assert.equal(saved.contact, "架空連絡先 000-0000");
    assert.deepEqual(saved.programs.map((p) => [p.programId, p.name, p.order]), [["program-a", "架空プログラムA", 0], ["program-b", "架空プログラムB", 1], ["custom-zeta-9", "架空プログラムZ", 2]]);
  });
  test("endAt・senderName・contactは任意(未指定なら endAt=null、senderName・contactは保存しない)", async () => {
    const {db, index} = setup();
    const {eventId} = await create(index, ADMIN, input({endAt: undefined}));
    const saved = db.store.get(`events/${eventId}`);
    assert.equal(saved.endAt, null);
    assert.equal("senderName" in saved, false);
    assert.equal("contact" in saved, false);
  });
  test("orderを省略すると入力順になり、orderを指定すれば入力順に依存しない(programIdの辞書順にも依存しない)", async () => {
    const {db, index} = setup();
    const a = await create(index, ADMIN, input({requestId: "req-aaaaaaaaaaaaaaaaaaaa", programs: [{programId: "zzz", name: "Z"}, {programId: "aaa", name: "A"}]}));
    assert.deepEqual(db.store.get(`events/${a.eventId}`).programs.map((p) => [p.programId, p.order]), [["zzz", 0], ["aaa", 1]]);
    const b = await create(index, ADMIN, input({requestId: "req-bbbbbbbbbbbbbbbbbbbb", programs: [{programId: "zzz", name: "Z", order: 5}, {programId: "aaa", name: "A", order: 2}]}));
    assert.deepEqual(db.store.get(`events/${b.eventId}`).programs.map((p) => [p.programId, p.order]), [["zzz", 5], ["aaa", 2]]);
  });
  test("programの属性(名前・時間・note)は独立して保存され、他のprogramへ複製されない。programIdによる特殊処理は無い", async () => {
    const {db, index} = setup();
    const start = future(30, 1); const end = future(30, 2);
    const {eventId} = await create(index, ADMIN, input({programs: [
      {programId: "program-a", name: "A", order: 0, startAt: start, endAt: end, note: "メモA"},
      {programId: "program-b", name: "B", order: 1},
      {programId: "custom-zeta-9", name: "Z", order: 2, note: "メモZ"},
    ]}));
    const [a, b, z] = db.store.get(`events/${eventId}`).programs;
    assert.equal(a.startAt.getTime(), new Date(start).getTime());
    assert.equal(a.endAt.getTime(), new Date(end).getTime());
    assert.equal(a.note, "メモA");
    assert.deepEqual(Object.keys(b).sort(), ["name", "order", "programId"]);
    assert.equal(z.note, "メモZ");
    assert.equal("startAt" in z, false);
    const source = fs.readFileSync(path.join(__dirname, "..", "confirmed", "event_create_api.js"), "utf8");
    for (const name of ["いぬ", "ねこ", "トーク", "program-a", "custom-zeta"]) assert.equal(source.includes(name), false, `固有のprogram名をコードに持たない: ${name}`);
  });
  test("メール関連は何も作らない: reminderEnabled=false、winnerMailTemplate・reminderMailTemplate・reminderSendAtは未設定。participant・importBatch・sendJobs・mailDeliveries・mailLogs・checkIns・programAttendancesは0件。メール送信0件", async () => {
    const {db, index, mail} = setup();
    const {eventId} = await create(index, ADMIN, input());
    const saved = db.store.get(`events/${eventId}`);
    assert.equal(saved.reminderEnabled, false);
    for (const key of ["winnerMailTemplate", "reminderMailTemplate", "reminderSendAt", "reminderJobReady", "importSequence"]) assert.equal(key in saved, false, key);
    const paths = [...db.store.keys()].filter((p) => !p.startsWith("accessRoles/") && !p.startsWith("events/"));
    assert.deepEqual(paths, [], "events以外のドキュメントは作られない");
    assert.equal(db.writes.length, 1);
    assert.equal(db.writes[0].op, "create");
    assert.equal(mail.length, 0);
  });
});

describe("冪等性(二重クリック・応答消失後の再試行・同時実行)", () => {
  test("同じrequestId+同じ内容の再試行は、同じeventIdを返し、eventは1件のまま。既存のeventは書き換えない", async () => {
    const {db, index} = setup();
    const data = input();
    const first = await create(index, ADMIN, data);
    const writes = db.writes.length;
    const second = await create(index, ADMIN, data);
    const third = await create(index, ADMIN, {...data});
    assert.equal(second.eventId, first.eventId);
    assert.equal(second.created, false);
    assert.equal(third.created, false);
    assert.equal(eventsOf(db).length, 1);
    assert.equal(db.writes.length, writes, "再試行では何も書かない");
  });
  test("同じrequestId+異なる内容は拒否(already-exists / request-id-conflict)。既存のeventは変更されない", async () => {
    const {db, index} = setup();
    const first = await create(index, ADMIN, input());
    const before = JSON.stringify([...db.store.entries()].filter(([p]) => p.startsWith("events/")));
    for (const changed of [{eventName: "別名"}, {venue: "別会場"}, {programs: [{programId: "x1", name: "X", order: 0}]}, {address: "別住所"}]) {
      const error = await create(index, ADMIN, input(changed)).then(() => null, (e) => e);
      assert.equal(error.code, "already-exists");
      assert.equal(error.details.code, "request-id-conflict");
    }
    assert.equal(JSON.stringify([...db.store.entries()].filter(([p]) => p.startsWith("events/"))), before);
    assert.equal(eventsOf(db).length, 1);
    void first;
  });
  test("別のrequestIdなら別のイベント。別の管理者が同じrequestIdを使っても別のeventIdになり、他の管理者のイベントは変更されない", async () => {
    const {db, index} = setup();
    const a = await create(index, ADMIN, input());
    const b = await create(index, ADMIN, input({requestId: "req-other-0123456789abc"}));
    const c = await create(index, {uid: "admin2"}, input());
    assert.equal(new Set([a.eventId, b.eventId, c.eventId]).size, 3);
    assert.equal(eventsOf(db).length, 3);
    assert.equal(db.store.get(`events/${a.eventId}`).createdBy, "admin1");
    assert.equal(db.store.get(`events/${c.eventId}`).createdBy, "admin2");
  });
  test("eventIdが衝突しても既存のイベントを上書き・変換しない(legacyイベント・別内容のconfirmedイベント)", async () => {
    const legacyId = deriveEventId("admin1", REQ);
    const legacy = {eventId: legacyId, eventName: "既存の従来方式イベント", startAt: ts(new Date(Date.now() + 86400e3))};
    const {db, index} = setup({[`events/${legacyId}`]: legacy});
    const before = JSON.stringify(db.store.get(`events/${legacyId}`));
    assert.equal(await code(create(index, ADMIN, input())), "already-exists");
    assert.equal(JSON.stringify(db.store.get(`events/${legacyId}`)), before);
    assert.equal("flow" in db.store.get(`events/${legacyId}`), false, "legacyがconfirmedに変換されない");
    const confirmedId = deriveEventId("admin1", "req-other-0123456789abc");
    const other = {eventId: confirmedId, flow: "confirmed", eventName: "既存のconfirmed", createdBy: "someone", createRequestHash: "x", programs: []};
    const {db: db2, index: index2} = setup({[`events/${confirmedId}`]: other});
    assert.equal(await code(create(index2, ADMIN, input({requestId: "req-other-0123456789abc"}))), "already-exists");
    assert.equal(JSON.stringify(db2.store.get(`events/${confirmedId}`)), JSON.stringify(other));
  });
  test("既存のイベント(legacy・confirmed)があっても、作成はそれらを1件も変更しない。confirmedをlegacyへ、legacyをconfirmedへ変換しない", async () => {
    const seed = {
      "events/legacy1": {eventId: "legacy1", eventName: "従来", startAt: ts(new Date(Date.now() + 86400e3)), reminderEnabled: false},
      "events/conf1": {eventId: "conf1", flow: "confirmed", eventName: "新方式", programs: [{programId: "a", name: "A", order: 0}], reminderEnabled: true},
      "participants/p1": {participantId: "p1", eventId: "legacy1"}, "checkIns/p1": {participantId: "p1", eventId: "legacy1"},
    };
    const {db, index} = setup(seed);
    const before = JSON.stringify([...db.store.entries()].filter(([p]) => !p.startsWith("accessRoles/")));
    await create(index, ADMIN, input());
    const after = [...db.store.entries()].filter(([p]) => !p.startsWith("accessRoles/") && !p.startsWith("events/ev"));
    assert.equal(JSON.stringify(after), before);
  });
  test("legacyのcreateLegacyEventは従来どおり(flowを書かない)。confirmedの作成とは別の入口", async () => {
    const {db, index} = setup();
    const {eventId} = await index.createLegacyEvent.run({auth: ADMIN, data: {eventName: "従来イベント", startAt: "2030-01-02T10:00:00.000Z", registrationDeadline: "2030-01-01T10:00:00.000Z", confirmationSendAt: "2030-01-01T09:00:00.000Z"}});
    assert.equal("flow" in db.store.get(`events/${eventId}`), false);
    assert.equal(await code(index.createLegacyEvent.run({auth: ADMIN, data: {eventName: "x", startAt: "2030-01-02T10:00:00.000Z", registrationDeadline: "2030-01-01T10:00:00.000Z", confirmationSendAt: "2030-01-01T09:00:00.000Z", flow: "confirmed"}})), "invalid-argument");
  });
});

describe("ログ・純粋関数", () => {
  test("ログにはUID・eventIdだけ(イベント名・会場・requestIdを出さない)", async () => {
    const db = new FakeFirestore();
    const lines = [];
    const logger = {info: (...a) => lines.push(a), warn: (...a) => lines.push(a)};
    const api = createEventCreateApi({getDb: () => db, serverTimestamp: () => ({}), logger});
    await api.createEvent({identity: {uid: "admin1"}, data: input()});
    await api.createEvent({identity: {uid: "admin1"}, data: input({eventName: "別"})}).catch(() => {});
    const text = JSON.stringify(lines);
    for (const forbidden of ["PHASE11", "架空ホール", REQ, "架空駅"]) assert.equal(text.includes(forbidden), false, forbidden);
    assert.ok(lines.length >= 2);
  });
  test("eventIdの導出は決定的(同じUID+requestIdなら同じ)で、UIDまたはrequestIdが違えば別。requestIdの元値は復元できない形式", () => {
    assert.equal(deriveEventId("u1", REQ), deriveEventId("u1", REQ));
    assert.notEqual(deriveEventId("u1", REQ), deriveEventId("u2", REQ));
    assert.notEqual(deriveEventId("u1", REQ), deriveEventId("u1", `${REQ}x`));
    assert.equal(deriveEventId("u1", REQ).includes(REQ), false);
  });
});
