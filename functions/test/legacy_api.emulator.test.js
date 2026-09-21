// Phase 10C: 従来方式(legacy)の管理・受付・参加者本人APIを、ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDKで検証する。
// メモリ上のフェイクでは分からない、実際のtransaction・Timestamp・並行実行の挙動を確認する(実Firestore・メール送信は一切ない)。
// データはすべて架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {createLegacyApi} = require("../legacy/legacy_api");
const {confirmedCallable, publicCapabilityCallable} = require("../auth");
const {publicRequest} = require("../test_support/app_check");

const silent = {warn: () => {}, info: () => {}, error: () => {}};
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const PUB = "pub_e2e_0123456789abcdef0123456789";

describe("従来方式API(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let call;
  let publicCall;

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    const api = createLegacyApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp(), logger: silent});
    const admin = (fn) => confirmedCallable("admin", fn, {db, logger: silent});
    const staff = (fn) => confirmedCallable("staffOrAdmin", fn, {db, logger: silent});
    const table = {
      listEvents: admin(api.listEvents), adminView: admin(api.getEventAdminView), createEvent: admin(api.createEvent),
      updateEvent: admin(api.updateEventSettings), createParticipant: admin(api.createParticipant),
      receptionView: staff(api.getReceptionView), checkIn: staff(api.checkInParticipant), updateCount: staff(api.updateAttendedCount),
    };
    call = (name, uid, data) => table[name].run({auth: uid ? {uid} : undefined, data});
    const pub = {
      page: publicCapabilityCallable(api.getParticipantPage), confirm: publicCapabilityCallable(api.confirmParticipation),
      answer: publicCapabilityCallable(api.answerReconfirmation),
    };
    publicCall = (name, data) => pub[name].run(publicRequest({data}));
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("admin1").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("staff1").set({role: "staff", active: true});
    const T = env.Timestamp;
    await db.collection("events").doc("e1").set({eventId: "e1", eventName: "旧イベント", startAt: T.fromDate(new Date(Date.now() + 3600e3)), reconfirmEnabled: true});
    await db.collection("events").doc("c1").set({eventId: "c1", eventName: "新方式", flow: "confirmed", startAt: T.fromDate(new Date(Date.now() + 3600e3))});
    await db.collection("participants").doc("p1").set({participantId: "p1", eventId: "e1", publicId: PUB, name: "架空 太郎", email: "p1@example.invalid", registeredCount: 2, registrationType: "preRegistered", participationConfirmed: true, attendanceResponse: null});
    await db.collection("checkIns").doc("p1").set({participantId: "p1", eventId: "e1", checkedIn: false, attendedCount: null, checkedInAt: null});
    await db.collection("participants").doc("cp1").set({participantId: "cp1", eventId: "c1", publicId: PUB, name: "新方式 花子", email: "c1@example.invalid", schemaVersion: 2, status: "active"});
    await db.collection("checkIns").doc("cp1").set({participantId: "cp1", eventId: "c1", checkedIn: false});
  });

  test("イベント作成・一覧・詳細・更新(Timestamp変換・flow非書込み・confirmedの更新拒否)", async () => {
    const settings = {eventName: "新イベント", startAt: "2030-01-02T10:00:00.000Z", endAt: "2030-01-02T12:00:00.000Z", registrationDeadline: "2030-01-01T10:00:00.000Z", confirmationSendAt: "2030-01-01T09:00:00.000Z", venue: "会場"};
    const {eventId} = await call("createEvent", "admin1", settings);
    const saved = (await db.collection("events").doc(eventId).get()).data();
    assert.equal("flow" in saved, false);
    assert.equal(saved.startAt.toDate().toISOString(), "2030-01-02T10:00:00.000Z");
    const list = await call("listEvents", "admin1", {});
    assert.equal(list.events.length, 3);
    assert.equal(list.events.find((e) => e.eventId === "c1").summary, undefined);
    assert.equal(list.events.find((e) => e.eventId === "e1").summary.participantCount, 1);
    await call("updateEvent", "admin1", {eventId, ...settings, eventName: "更新後"});
    assert.equal((await db.collection("events").doc(eventId).get()).data().eventName, "更新後");
    assert.equal(await code(call("updateEvent", "admin1", {eventId: "c1", ...settings})), "failed-precondition");
    const view = await call("adminView", "admin1", {eventId: "e1"});
    assert.equal(view.legacy, true);
    assert.equal(view.participants[0].participantId, "p1");
    assert.equal((await call("adminView", "admin1", {eventId: "c1"})).participants.length, 0);
  });

  test("参加者の手動登録: 参加者と受付が同時に作られ、confirmedイベントには作れない", async () => {
    const {participant} = await call("createParticipant", "admin1", {eventId: "e1", name: "手動 花子", email: "Hanako@Example.invalid", registeredCount: 3});
    assert.equal((await db.collection("participants").doc(participant.participantId).get()).data().email, "hanako@example.invalid");
    assert.equal((await db.collection("checkIns").doc(participant.participantId).get()).data().checkedIn, false);
    assert.equal(await code(call("createParticipant", "admin1", {eventId: "c1", name: "x", email: "x@example.invalid", registeredCount: 1})), "failed-precondition");
    assert.equal((await db.collection("participants").where("eventId", "==", "c1").get()).size, 1, "confirmedの参加者は増えていない");
  });

  test("受付: 同時に2回受付しても、1回だけ成功する(transaction)。confirmedの参加者は受付できない", async () => {
    const key = {eventId: "e1", participantId: "p1", publicId: PUB};
    const results = await Promise.all([1, 2, 3].map((n) => call("checkIn", "staff1", {...key, attendedCount: n})));
    assert.equal(results.filter((r) => r.alreadyCheckedIn === false).length, 1);
    assert.equal(results.filter((r) => r.alreadyCheckedIn === true).length, 2);
    const saved = (await db.collection("checkIns").doc("p1").get()).data();
    assert.equal(saved.checkedIn, true);
    assert.equal(saved.registeredCountSnapshot, 2);
    assert.ok([1, 2, 3].includes(saved.attendedCount));
    await call("updateCount", "staff1", {...key, attendedCount: 1});
    assert.equal((await db.collection("checkIns").doc("p1").get()).data().attendedCount, 1);
    assert.equal(await code(call("checkIn", "staff1", {eventId: "c1", participantId: "cp1", publicId: PUB, attendedCount: 1})), "failed-precondition");
    assert.equal((await db.collection("checkIns").doc("cp1").get()).data().checkedIn, false, "confirmedの受付は変わらない");
  });

  test("参加者本人: 正しい組だけ表示・回答でき、confirmedの参加者は同じ「無効」応答。確認が無効/回答済みは書き込まない", async () => {
    const good = {participantId: "p1", publicId: PUB};
    const page = await publicCall("page", good);
    assert.equal(page.participant.name, "架空 太郎");
    assert.equal(JSON.stringify(page).includes("@"), false);
    const bad = await publicCall("page", {participantId: "cp1", publicId: PUB}).then(() => null, (e) => e);
    const wrong = await publicCall("page", {participantId: "p1", publicId: "pub_wrong_0123456789abcdef0123"}).then(() => null, (e) => e);
    assert.deepEqual([bad.code, bad.message], [wrong.code, wrong.message]);
    await publicCall("answer", {...good, response: "attending"});
    assert.equal((await db.collection("participants").doc("p1").get()).data().attendanceResponse, "attending");
    await publicCall("answer", {...good, response: "notAttending"});
    assert.equal((await db.collection("participants").doc("p1").get()).data().attendanceResponse, "attending", "回答済みは上書きしない");
    assert.equal(await code(publicCall("confirm", {participantId: "cp1", publicId: PUB})), "not-found");
    assert.equal((await db.collection("participants").doc("cp1").get()).data().participationConfirmed, undefined);
  });

  test("認証境界(実Admin SDK): 認証なし・accessRoles無し・staff(admin専用の操作)は拒否され、何も書かれない", async () => {
    const before = (await db.collection("events").get()).size;
    assert.equal(await code(call("createEvent", undefined, {})), "unauthenticated");
    assert.equal(await code(call("createEvent", "nobody", {})), "permission-denied");
    assert.equal(await code(call("createEvent", "staff1", {eventName: "x"})), "permission-denied");
    assert.equal(await code(call("createParticipant", "staff1", {eventId: "e1"})), "permission-denied");
    assert.equal((await db.collection("events").get()).size, before);
  });
});
