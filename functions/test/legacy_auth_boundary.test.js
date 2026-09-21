// Phase 10C: 従来方式(legacy)の認証境界。実際のcallable(index.js)を、メモリ上のFirestoreと外部通信スタブだけで呼んで確認する。
//  - 認証なし・accessRoles無し・active=false・staff(admin専用の操作)は、副作用ゼロで拒否される
//  - 管理・メール・削除はadminだけ、受付はstaff/adminだけ、参加者本人APIはparticipantId+publicIdの組だけで動く
//  - 参加者本人APIは、存在しない・publicId不一致・legacyでない・不正な入力のすべてで「同じ応答」を返す
//  - 当日参加登録は公開のまま、入力・状態・件数を制限する
// (以前は認証なしで呼べた操作が拒否されるようになったため、その旨をテスト名に明記している)
const assert = require("node:assert/strict");
const {afterEach, describe, test} = require("node:test");
const {FakeFirestore, ts} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");
const {createLegacyApi} = require("../legacy/legacy_api");
const {publicRequest} = require("../test_support/app_check");
// Phase 10D: 公開callableはrate limitの記録(rateLimits/)を書く。「何も書き込まない」の検査は、業務データへの書込みを対象にする。
const businessWrites = (db) => db.writes.filter((w) => !w.path.startsWith("rateLimits/"));

const HOUR = 3600 * 1000;
const now = Date.now();
const PUB1 = "pub_p1_0123456789abcdef01234567";
const event = (id, extra = {}) => ({
  eventId: id, eventName: `イベント${id}`, senderName: `送信者${id}`, venue: "会場", contact: "問い合わせ",
  startAt: ts(new Date(now + HOUR)), registrationDeadline: ts(new Date(now - 24 * HOUR)),
  confirmationSendAt: ts(new Date(now - HOUR)), reconfirmEnabled: false, ...extra,
});
const participant = (id, eventId, extra = {}) => ({
  participantId: id, eventId, publicId: `pub_${id}_0123456789abcdef01234567`, name: `参加者${id}`, email: `${id}@example.com`,
  registeredCount: 2, registrationType: "preRegistered", invitationSent: false, participationConfirmed: false, reconfirmed: false,
  reconfirmationMailSent: false, attendanceResponse: null, ...extra,
});
const checkIn = (id, eventId, extra = {}) => ({participantId: id, eventId, checkedIn: false, attendedCount: null, checkedInAt: null, ...extra});

const ROLES = {
  "accessRoles/admin1": {role: "admin", active: true},
  "accessRoles/staff1": {role: "staff", active: true},
  "accessRoles/off1": {role: "admin", active: false},
};
const ADMIN = {uid: "admin1"};
const STAFF = {uid: "staff1"};

let net;
afterEach(() => net?.restore());
function setup(seed = {}) {
  const db = new FakeFirestore({...ROLES, ...seed});
  net = stubFetch();
  return {db, index: loadIndex(db), mail: net.calls};
}
const base = () => ({
  "events/e1": event("e1"), "participants/p1": participant("p1", "e1", {participationConfirmed: true}), "checkIns/p1": checkIn("p1", "e1"),
  "events/c1": event("c1", {flow: "confirmed"}), "participants/c1p": participant("c1p", "c1", {schemaVersion: 2}), "checkIns/c1p": checkIn("c1p", "c1"),
});
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const settings = {eventName: "新イベント", startAt: "2030-01-02T10:00:00.000Z", registrationDeadline: "2030-01-01T10:00:00.000Z", confirmationSendAt: "2030-01-01T09:00:00.000Z"};
const rec = {eventId: "e1", participantId: "p1", publicId: PUB1};

// 管理系(admin専用)の入口と、ガードを通ったあとに(不正な入力で)必ず失敗させる最小の入力
const ADMIN_ONLY = {
  sendParticipantMail: {}, startBulkInvitationMail: {}, startBulkReconfirmationMail: {}, deleteParticipant: {}, deleteEvent: {},
  listLegacyEvents: {}, getLegacyEventAdminView: {}, createLegacyEvent: {}, updateLegacyEventSettings: {}, createLegacyParticipant: {},
};
const STAFF_OK = {getLegacyReceptionView: {}, checkInLegacyParticipant: {}, updateLegacyAttendedCount: {}};
const denied = ["unauthenticated", "permission-denied"];

describe("認証境界(Phase 10C: 以前は認証なしで呼べた操作が、認証なしでは拒否される)", () => {
  for (const [name, data] of Object.entries(ADMIN_ONLY)) {
    test(`${name}: 認証なし・accessRoles無し・active=false・staffは拒否し、何も書き込まない。adminはガードを通る`, async () => {
      const {db, index, mail} = setup(base());
      const call = (auth) => code(index[name].run({auth, data}));
      assert.equal(await call(undefined), "unauthenticated");
      assert.equal(await call({uid: "nobody"}), "permission-denied");
      assert.equal(await call({uid: "off1"}), "permission-denied");
      assert.equal(await call(STAFF), "permission-denied");
      // bodyのrole/uid/emailは認可に使われない
      assert.equal(await code(index[name].run({auth: undefined, data: {...data, role: "admin", uid: "admin1", email: "a@example.com"}})), "unauthenticated");
      assert.equal(businessWrites(db).length, 0);
      assert.equal(mail.length, 0);
      assert.equal(denied.includes(await call(ADMIN)), false, "adminはガードを通る(入力不正などの別のエラーは可)");
    });
  }
  for (const [name, data] of Object.entries(STAFF_OK)) {
    test(`${name}: 認証なし・accessRoles無し・active=falseは拒否し、staffとadminはガードを通る`, async () => {
      const {db, index} = setup(base());
      const call = (auth) => code(index[name].run({auth, data}));
      assert.equal(await call(undefined), "unauthenticated");
      assert.equal(await call({uid: "nobody"}), "permission-denied");
      assert.equal(await call({uid: "off1"}), "permission-denied");
      assert.equal(businessWrites(db).length, 0);
      assert.equal(denied.includes(await call(STAFF)), false);
      assert.equal(denied.includes(await call(ADMIN)), false);
    });
  }
  test("参加者本人の公開APIは認証不要だが、publicIdが無ければ何も返さない", async () => {
    const {index} = setup(base());
    for (const name of ["getLegacyParticipantPage", "confirmLegacyParticipation", "answerLegacyReconfirmation"]) {
      assert.equal(await code(index[name].run(publicRequest({data: {participantId: "p1"}}))), "not-found", name);
    }
  });
});

describe("管理API(admin)", () => {
  test("イベント一覧: legacyには集計を付け、confirmedにはlegacyの参加者集計を付けない", async () => {
    const {index} = setup(base());
    const {events} = await index.listLegacyEvents.run({auth: ADMIN, data: {}});
    const e1 = events.find((e) => e.eventId === "e1");
    const c1 = events.find((e) => e.eventId === "c1");
    assert.equal(e1.summary.participantCount, 1);
    assert.equal(e1.summary.appliedCount, 2);
    assert.equal(c1.summary, undefined);
    assert.equal(c1.flow, "confirmed");
  });
  test("イベント詳細: legacyは参加者・受付を返す。confirmedは参加者を返さない。存在しなければnot-found", async () => {
    const {index} = setup(base());
    const legacy = await index.getLegacyEventAdminView.run({auth: ADMIN, data: {eventId: "e1"}});
    assert.equal(legacy.legacy, true);
    assert.equal(legacy.participants.length, 1);
    assert.equal(legacy.participants[0].email, "p1@example.com");
    assert.equal(legacy.checkIns.length, 1);
    const confirmed = await index.getLegacyEventAdminView.run({auth: ADMIN, data: {eventId: "c1"}});
    assert.equal(confirmed.legacy, false);
    assert.deepEqual(confirmed.participants, []);
    assert.equal(await code(index.getLegacyEventAdminView.run({auth: ADMIN, data: {eventId: "none"}})), "not-found");
    assert.equal(await code(index.getLegacyEventAdminView.run({auth: ADMIN, data: {eventId: "a/b"}})), "invalid-argument");
  });
  test("イベント作成: flowは書かれず(=従来方式)、flow・id等の余計なキーは拒否される", async () => {
    const {db, index} = setup();
    const {eventId} = await index.createLegacyEvent.run({auth: ADMIN, data: settings});
    const saved = db.store.get(`events/${eventId}`);
    assert.equal("flow" in saved, false);
    assert.equal(saved.reconfirmEnabled, false);
    const before = businessWrites(db).length;
    for (const extra of [{flow: "confirmed"}, {eventId: "x"}, {createdAt: "x"}]) {
      assert.equal(await code(index.createLegacyEvent.run({auth: ADMIN, data: {...settings, ...extra}})), "invalid-argument");
    }
    assert.equal(await code(index.createLegacyEvent.run({auth: ADMIN, data: {...settings, startAt: "not-a-date"}})), "invalid-argument");
    assert.equal(await code(index.createLegacyEvent.run({auth: ADMIN, data: {...settings, eventName: "  "}})), "invalid-argument");
    assert.equal(businessWrites(db).length, before);
  });
  test("イベント設定の更新: legacyのみ。confirmed・未知のflow・存在しないイベントは書込みなしで拒否", async () => {
    const seed = {...base(), "events/u1": event("u1", {flow: "confirmd"})};
    const {db, index} = setup(seed);
    await index.updateLegacyEventSettings.run({auth: ADMIN, data: {eventId: "e1", ...settings}});
    assert.equal(db.store.get("events/e1").eventName, "新イベント");
    assert.equal(db.store.get("events/e1").eventId, "e1");
    const before = businessWrites(db).length;
    assert.equal(await code(index.updateLegacyEventSettings.run({auth: ADMIN, data: {eventId: "c1", ...settings}})), "failed-precondition");
    assert.equal(await code(index.updateLegacyEventSettings.run({auth: ADMIN, data: {eventId: "u1", ...settings}})), "failed-precondition");
    assert.equal(await code(index.updateLegacyEventSettings.run({auth: ADMIN, data: {eventId: "none", ...settings}})), "not-found");
    assert.equal(await code(index.updateLegacyEventSettings.run({auth: ADMIN, data: {eventId: "e1", flow: "confirmed", ...settings}})), "invalid-argument");
    assert.equal(businessWrites(db).length, before);
  });
  test("参加者の手動登録: id・publicIdはサーバー生成(クライアント指定は拒否)。confirmed・orphanイベントには作れない", async () => {
    const {db, index} = setup(base());
    const data = {eventId: "e1", name: "  手動 花子 ", email: "Hanako@Example.COM", registeredCount: 3};
    const {participant: created} = await index.createLegacyParticipant.run({auth: ADMIN, data});
    assert.match(created.publicId, /^pub_[A-Za-z0-9_-]{32}$/);
    assert.equal(created.email, "hanako@example.com");
    assert.equal(created.name, "手動 花子");
    assert.equal(db.store.get(`checkIns/${created.participantId}`).eventId, "e1");
    const before = businessWrites(db).length;
    for (const extra of [{participantId: "x"}, {publicId: "pub_x"}, {participationConfirmed: true}, {flow: "confirmed"}]) {
      assert.equal(await code(index.createLegacyParticipant.run({auth: ADMIN, data: {...data, ...extra}})), "invalid-argument");
    }
    for (const bad of [{email: "x"}, {registeredCount: 0}, {registeredCount: 1000}, {registeredCount: 1.5}, {name: ""}, {registrationType: "confirmed"}]) {
      assert.equal(await code(index.createLegacyParticipant.run({auth: ADMIN, data: {...data, ...bad}})), "invalid-argument", JSON.stringify(bad));
    }
    assert.equal(await code(index.createLegacyParticipant.run({auth: ADMIN, data: {...data, eventId: "c1"}})), "failed-precondition");
    assert.equal(await code(index.createLegacyParticipant.run({auth: ADMIN, data: {...data, eventId: "none"}})), "not-found");
    assert.equal(businessWrites(db).length, before);
  });
});

describe("受付API(staff/admin。サーバーのtransactionで再検証)", () => {
  test("受付表示: メールアドレス・publicIdを返さない", async () => {
    const {index} = setup(base());
    const view = await index.getLegacyReceptionView.run({auth: STAFF, data: rec});
    assert.equal(view.participantName, "参加者p1");
    assert.equal(JSON.stringify(view).includes("@"), false);
    assert.equal(JSON.stringify(view).includes("pub_"), false);
  });
  test("受付表示・受付実行: publicId不一致・イベント不一致・confirmed・未知のflow・orphanは拒否し、書き込まない", async () => {
    const seed = {...base(), "events/u1": event("u1", {flow: "confirmd"}), "participants/u1p": participant("u1p", "u1"), "checkIns/u1p": checkIn("u1p", "u1"),
      "participants/o1": participant("o1", "gone"), "checkIns/o1": checkIn("o1", "gone")};
    const {db, index} = setup(seed);
    const cases = [
      {...rec, publicId: "pub_wrong_0123456789abcdef0123"},
      {...rec, eventId: "c1"},
      {eventId: "c1", participantId: "c1p", publicId: participant("c1p", "c1").publicId},
      {eventId: "u1", participantId: "u1p", publicId: participant("u1p", "u1").publicId},
      {eventId: "gone", participantId: "o1", publicId: participant("o1", "gone").publicId},
      {...rec, participantId: "nobody"},
    ];
    for (const data of cases) {
      assert.equal(await code(index.getLegacyReceptionView.run({auth: STAFF, data})), "failed-precondition", JSON.stringify(data));
      assert.equal(await code(index.checkInLegacyParticipant.run({auth: STAFF, data: {...data, attendedCount: 1}})), "failed-precondition", JSON.stringify(data));
      assert.equal(await code(index.updateLegacyAttendedCount.run({auth: STAFF, data: {...data, attendedCount: 1}})), "failed-precondition", JSON.stringify(data));
    }
    assert.equal(businessWrites(db).length, 0);
  });
  test("受付実行: 申込人数のスナップショットはサーバーの値。二重受付は2回目で書き換えない。人数修正は受付後のみ", async () => {
    const {db, index} = setup(base());
    assert.equal(await code(index.updateLegacyAttendedCount.run({auth: STAFF, data: {...rec, attendedCount: 1}})), "failed-precondition");
    assert.equal(await code(index.checkInLegacyParticipant.run({auth: STAFF, data: {...rec, attendedCount: 1, registeredCountSnapshot: 99}})), "invalid-argument");
    const first = await index.checkInLegacyParticipant.run({auth: STAFF, data: {...rec, attendedCount: 2}});
    assert.equal(first.alreadyCheckedIn, false);
    assert.equal(db.store.get("checkIns/p1").registeredCountSnapshot, 2);
    assert.equal(db.store.get("checkIns/p1").attendedCount, 2);
    const writes = businessWrites(db).length;
    const second = await index.checkInLegacyParticipant.run({auth: STAFF, data: {...rec, attendedCount: 5}});
    assert.equal(second.alreadyCheckedIn, true);
    assert.equal(businessWrites(db).length, writes);
    assert.equal(db.store.get("checkIns/p1").attendedCount, 2);
    await index.updateLegacyAttendedCount.run({auth: STAFF, data: {...rec, attendedCount: 1}});
    assert.equal(db.store.get("checkIns/p1").attendedCount, 1);
    for (const bad of [-1, 1.5, "2", 1000]) {
      assert.equal(await code(index.updateLegacyAttendedCount.run({auth: STAFF, data: {...rec, attendedCount: bad}})), "invalid-argument");
    }
  });
});

describe("参加者本人API(participantId+publicIdのcapability。無効な理由はすべて同じ応答)", () => {
  const page = (index, data) => index.getLegacyParticipantPage.run(publicRequest({data}));
  test("正しい組は最小限のDTOを返す(メールアドレス・publicId・内部IDを含まない)", async () => {
    const {index} = setup(base());
    const result = await page(index, {participantId: "p1", publicId: PUB1});
    assert.equal(result.participant.name, "参加者p1");
    const text = JSON.stringify(result);
    for (const forbidden of ["@", "pub_", "invitation", "mailLog", "participantId", "publicId"]) assert.equal(text.includes(forbidden), false, forbidden);
    assert.deepEqual(Object.keys(result).sort(), ["checkIn", "event", "participant"]);
  });
  test("存在しない・publicId不一致・confirmed・未知のflow・orphan・不正な入力は、すべて同一の応答", async () => {
    const seed = {...base(), "events/u1": event("u1", {flow: "confirmd"}), "participants/u1p": participant("u1p", "u1"),
      "participants/o1": participant("o1", "gone"), "participants/n1": participant("n1", "e1", {publicId: 5})};
    const {index} = setup(seed);
    const attempts = [
      {participantId: "p1", publicId: "pub_wrong_0123456789abcdef0123"},
      {participantId: "nobody", publicId: PUB1},
      {participantId: "c1p", publicId: participant("c1p", "c1").publicId},
      {participantId: "u1p", publicId: participant("u1p", "u1").publicId},
      {participantId: "o1", publicId: participant("o1", "gone").publicId},
      {participantId: "n1", publicId: "pub_n1_0123456789abcdef01234567"},
      {participantId: "p1", publicId: PUB1, extra: 1},
      {participantId: "../p1", publicId: PUB1},
      {participantId: "p1"},
      {participantId: {a: 1}, publicId: PUB1},
      {},
    ];
    const seen = new Set();
    for (const data of attempts) {
      const error = await page(index, data).then(() => null, (e) => e);
      assert.ok(error, JSON.stringify(data));
      seen.add(`${error.code}|${error.message}`);
    }
    assert.equal(seen.size, 1, [...seen].join(","));
  });
  test("正式登録: 書き込むのは登録済みでないときだけ。誤ったpublicId・confirmedの参加者には書き込まない", async () => {
    const seed = {...base(), "participants/p2": participant("p2", "e1"), "checkIns/p2": checkIn("p2", "e1")};
    const {db, index} = setup(seed);
    const p2 = {participantId: "p2", publicId: participant("p2", "e1").publicId};
    const result = await index.confirmLegacyParticipation.run(publicRequest({data: p2}));
    assert.equal(result.participant.participationConfirmed, true);
    assert.equal(db.store.get("participants/p2").participationConfirmed, true);
    const writes = businessWrites(db).length;
    await index.confirmLegacyParticipation.run(publicRequest({data: p2}));
    assert.equal(businessWrites(db).length, writes, "登録済みなら何も書かない");
    assert.equal(await code(index.confirmLegacyParticipation.run(publicRequest({data: {...p2, publicId: "pub_wrong_0123456789abcdef0123"}}))), "not-found");
    assert.equal(await code(index.confirmLegacyParticipation.run(publicRequest({data: {participantId: "c1p", publicId: participant("c1p", "c1").publicId}}))), "not-found");
    assert.equal(businessWrites(db).length, writes);
  });
  test("参加予定の回答: 登録済み・確認が有効・未回答のときだけ書く。回答済みは上書きしない。不正な回答値は拒否", async () => {
    const seed = {...base(), "events/e2": event("e2", {reconfirmEnabled: true}),
      "participants/r1": participant("r1", "e2", {participationConfirmed: true}), "checkIns/r1": checkIn("r1", "e2"),
      "participants/r2": participant("r2", "e2", {participationConfirmed: false})};
    const {db, index} = setup(seed);
    const key = (id) => ({participantId: id, publicId: participant(id, "e2").publicId});
    await index.answerLegacyReconfirmation.run(publicRequest({data: {...key("r1"), response: "attending"}}));
    assert.equal(db.store.get("participants/r1").attendanceResponse, "attending");
    assert.equal(db.store.get("participants/r1").reconfirmed, true);
    await index.answerLegacyReconfirmation.run(publicRequest({data: {...key("r1"), response: "notAttending"}}));
    assert.equal(db.store.get("participants/r1").attendanceResponse, "attending", "回答済みは上書きしない");
    await index.answerLegacyReconfirmation.run(publicRequest({data: {...key("r2"), response: "attending"}}));
    assert.equal(db.store.get("participants/r2").attendanceResponse, null, "未登録の参加者は回答できない");
    assert.equal(await code(index.answerLegacyReconfirmation.run(publicRequest({data: {...key("r1"), response: "maybe"}}))), "not-found");
    // 確認が無効なイベント(reconfirmEnabled=false)では書かない
    await index.answerLegacyReconfirmation.run(publicRequest({data: {participantId: "p1", publicId: PUB1, response: "attending"}}));
    assert.equal(db.store.get("participants/p1").attendanceResponse, null);
  });
});

describe("当日参加登録(公開のまま。入力・状態・件数を制限)", () => {
  let walkInSeq = 0;
  const input = (extra = {}) => ({data: {eventId: "e1", name: "当日 太郎", email: `walkin${++walkInSeq}@example.com`, registeredCount: 1, ...extra}});
  test("legacyの開催前後のイベントには登録でき、件名・本文・送信者はサーバー固定。二重送信は2回目を拒否して1件だけ", async () => {
    const {db, index, mail} = setup(base());
    const result = await index.registerWalkIn.run(publicRequest(input({email: "dup@example.com"})));
    assert.equal(result.success, true);
    assert.equal(mail.length, 1);
    assert.equal(mail[0].body.subject, "【イベントe1】ご登録ありがとうございます");
    assert.equal(mail[0].body.senderName, "送信者e1");
    assert.equal(await code(index.registerWalkIn.run(publicRequest(input({email: "dup@example.com"})))), "already-exists");
    assert.equal(db.writesTo("participants/").filter((w) => w.op === "create").length, 1);
    assert.equal(mail.length, 1);
  });
  test("想定外のキー(subject/text/senderName/participantId/publicId等)・過大な人数・URLやメール様の氏名・不正なメールは拒否し、何も書かない", async () => {
    const {db, index, mail} = setup(base());
    const before = businessWrites(db).length;
    const bad = [{subject: "x"}, {text: "x"}, {senderName: "x"}, {participantId: "x"}, {publicId: "x"}, {registeredCount: 51}, {registeredCount: 0}, {registeredCount: 1.5},
      {name: "http://evil.example/x"}, {name: "a@b.example"}, {name: ""}, {name: "x".repeat(61)}, {name: "改\n行"}, {email: "bad"}, {email: "a".repeat(250) + "@b.example"},
      {eventId: "a/b"}, {eventId: 5}];
    for (const extra of bad) {
      assert.equal(await code(index.registerWalkIn.run(publicRequest(input(extra)))), "invalid-argument", JSON.stringify(extra).slice(0, 60));
    }
    assert.equal(businessWrites(db).length, before);
    assert.equal(mail.length, 0);
  });
  test("終了済み・開催日時が未設定・イベントが存在しないときは登録を受け付けない", async () => {
    const seed = {"events/old": event("old", {startAt: ts(new Date(now - 72 * HOUR))}), "events/nostart": event("nostart", {startAt: undefined}),
      "events/ended": event("ended", {startAt: ts(new Date(now - 5 * HOUR)), endAt: ts(new Date(now - HOUR))}),
      "events/running": event("running", {startAt: ts(new Date(now - 5 * HOUR)), endAt: ts(new Date(now + HOUR))})};
    const {db, index, mail} = setup(seed);
    for (const id of ["old", "nostart", "ended"]) assert.equal(await code(index.registerWalkIn.run(publicRequest(input({eventId: id})))), "failed-precondition", id);
    assert.equal(await code(index.registerWalkIn.run(publicRequest(input({eventId: "none"})))), "not-found");
    assert.equal(businessWrites(db).length, 0);
    assert.equal(mail.length, 0);
    assert.equal((await index.registerWalkIn.run(publicRequest(input({eventId: "running"})))).success, true);
  });
});

describe("ログにメールアドレス・publicId・本文を出さない", () => {
  test("拒否・成功・受付のログにPIIが含まれない", async () => {
    const db = new FakeFirestore(base());
    const lines = [];
    const logger = {info: (...a) => lines.push(a), warn: (...a) => lines.push(a), error: (...a) => lines.push(a)};
    const api = createLegacyApi({getDb: () => db, serverTimestamp: () => ({}), logger});
    await api.getReceptionView({identity: {uid: "s"}, data: {...rec, publicId: "pub_wrong_0123456789abcdef0123"}}).catch(() => {});
    await api.getParticipantPage({data: {participantId: "p1", publicId: "pub_wrong_0123456789abcdef0123"}}).catch(() => {});
    await api.createParticipant({identity: {uid: "a"}, data: {eventId: "e1", name: "花子", email: "leak@example.com", registeredCount: 1}});
    await api.checkInParticipant({identity: {uid: "s"}, data: {...rec, attendedCount: 1}});
    assert.ok(lines.length >= 3);
    const text = JSON.stringify(lines);
    for (const forbidden of ["@example.com", "pub_", "花子"]) assert.equal(text.includes(forbidden), false, forbidden);
  });
});
