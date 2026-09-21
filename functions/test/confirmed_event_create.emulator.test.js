// Phase 11A: confirmedイベント作成API(createConfirmedEvent)を、ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDKで検証する。
//  - 同時実行・二重クリックでもイベントは1件だけ(実際のtransaction)
//  - 作成したイベントを、既存のconfirmed CSV取込(previewConfirmedImport / commitConfirmedImport)がそのまま利用できる
//  - 作成しただけでは、メール・reminder・Scheduler相当の処理が何も起きない(実transportは使わない)
// データはすべて完全な架空(メールは予約TLD .invalid)。実CSVは使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, syntheticMapping} = require("../confirmed/test_support/synthetic");
const {createEventCreateApi} = require("../confirmed/event_create_api");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {createReminderApi} = require("../confirmed/reminder_api");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const silent = {warn() {}, info() {}, error() {}};
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const NOW = new Date("2026-09-22T00:00:00Z").getTime();
const REQ = "req-emulator-0123456789";

describe("confirmedイベント作成API(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let create;
  let preview;
  let commit;
  let sendCalls;
  let reminder;
  let send;

  const serverTimestamp = () => env.FieldValue.serverTimestamp();
  const data = (extra = {}) => ({
    requestId: REQ, eventName: "PHASE11 STEP3 TEST(架空)", startAt: "2026-11-30T01:00:00Z", endAt: "2026-11-30T07:00:00Z", venue: "架空ホール",
    address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分",
    programs: [{programId: "alpha", name: "架空プログラム1", order: 0}, {programId: "beta", name: "架空プログラム2", order: 1}, {programId: "gamma", name: "架空プログラム3", order: 2}],
    ...extra,
  });
  const counts = async () => {
    const result = {};
    for (const collection of await db.listCollections()) result[collection.id] = (await collection.get()).size;
    return result;
  };

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    const wrap = (handler) => { const callable = confirmedCallable("admin", handler, {db, logger: silent}); return (request) => callable.run(request); };
    create = wrap(createEventCreateApi({getDb: () => db, serverTimestamp, logger: silent, now: () => NOW}).createEvent);
    const importApi = createImportApi({getDb: () => db, serverTimestamp});
    preview = wrap(importApi.preview);
    commit = wrap(importApi.commit);
    // 実transportは使わない: 呼ばれたら記録して失敗させる(メールが送られないことの確認用)
    send = createWinnerSendApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => "https://app.invalid",
      getTransport: () => ({send: async () => { sendCalls += 1; throw new Error("transport must not be used"); }})});
    reminder = createReminderApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => "https://app.invalid", winnerSendApi: send, now: () => NOW, logger: silent});
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    sendCalls = 0;
    await db.collection("accessRoles").doc("admin1").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("staff1").set({role: "staff", active: true});
  });
  const asAdmin = (payload) => ({auth: {uid: "admin1"}, data: payload});

  test("同じ作成要求を10並列で送っても、イベントは1件だけ作られる(二重クリック・再送・同時実行)。2回目以降は同じeventIdを返す", async () => {
    const results = await Promise.all(Array.from({length: 10}, () => create(asAdmin(data())).then((r) => r, (e) => ({error: e.code}))));
    assert.equal(results.filter((r) => r.error).length, 0, JSON.stringify(results.filter((r) => r.error)));
    assert.equal(new Set(results.map((r) => r.eventId)).size, 1);
    assert.equal(results.filter((r) => r.created === true).length, 1);
    assert.equal((await db.collection("events").get()).size, 1);
    // 同じrequestIdで内容だけ変えた再要求は拒否され、既存のイベントは変わらない
    const before = (await db.collection("events").doc(results[0].eventId).get()).data();
    assert.equal(await code(create(asAdmin(data({eventName: "別名"})))), "already-exists");
    assert.deepEqual((await db.collection("events").doc(results[0].eventId).get()).data(), before);
  });

  test("作成直後の状態: events以外のcollectionは何も作られず、reminderEnabled=false・テンプレート未設定。メール送信0", async () => {
    const before = await counts();
    const {eventId} = await create(asAdmin(data()));
    assert.deepEqual(await counts(), {...before, events: 1});
    const saved = (await db.collection("events").doc(eventId).get()).data();
    assert.equal(saved.flow, "confirmed");
    assert.equal(saved.reminderEnabled, false);
    assert.equal(saved.startAt.toDate().toISOString(), "2026-11-30T01:00:00.000Z");
    assert.equal(sendCalls, 0);
  });

  test("Scheduler相当の処理(reminderの検出・配送のsweep)を実行しても、作成直後のイベントからは何も起きない(job・メール0)", async () => {
    await create(asAdmin(data()));
    const reconciled = await reminder.reconcileDue({limit: 5});
    assert.deepEqual(reconciled.created, []);
    const sweep = await send.runSweep();
    assert.deepEqual(sweep, []);
    assert.equal((await db.collection("sendJobs").get()).size, 0);
    assert.equal((await db.collection("mailDeliveries").get()).size, 0);
    assert.equal(sendCalls, 0);
  });

  test("既存のconfirmed CSV取込がそのまま使える: preview→commit で、1行=1participant(同一氏名・同一メールも減らさない)・schemaVersion=2・status=active・importBatch=committed", async () => {
    const {eventId} = await create(asAdmin(data()));
    // 3行のうち2行は同じ氏名・同じメール(人物単位のdedupeをしないことの確認。すべて架空)
    const table = makeTable(3, (i) => (i >= 2 ? {"氏名": "架空 同名", "メールアドレス": "same-address@example.invalid"} : {}));
    const request = buildImportRequest({table, eventId, mapping: syntheticMapping()});
    const previewed = await preview(asAdmin(request));
    assert.equal(JSON.stringify(previewed).includes("failed"), false);
    const committed = await commit(asAdmin(request));
    assert.ok(committed.batchId || committed.importBatchId || committed);
    const participants = (await db.collection("participants").where("eventId", "==", eventId).get()).docs.map((d) => d.data());
    assert.equal(participants.length, 3, "1 CSV行 = 1 participant");
    assert.ok(participants.every((p) => p.schemaVersion === 2 && p.status === "active"));
    const batches = (await db.collection("importBatches").get()).docs.map((d) => d.data());
    assert.equal(batches.length, 1);
    assert.equal(batches[0].status, "committed");
    const attendances = (await db.collection("programAttendances").where("eventId", "==", eventId).get()).docs.map((d) => d.data());
    assert.ok(attendances.length >= 3);
    assert.ok(attendances.every((a) => Number.isInteger(a.plannedCount) && a.plannedCount >= 1), "人数の正本はplannedCount");
    // 取込でもメールは動かない
    assert.equal((await db.collection("sendJobs").get()).size, 0);
    assert.equal((await db.collection("mailDeliveries").get()).size, 0);
    assert.equal(sendCalls, 0);
    // eventの作成時の内容(programs・flow)は取込で書き換わらない
    const saved = (await db.collection("events").doc(eventId).get()).data();
    assert.equal(saved.flow, "confirmed");
    assert.deepEqual(saved.programs.map((p) => p.programId), ["alpha", "beta", "gamma"]);
    assert.equal(saved.reminderEnabled, false);
  });

  test("programIdは任意の安全な文字列でよい(program-a・custom-zeta-9)。取込のmappingに存在しないprogramIdは、既存どおり取込で拒否される", async () => {
    const {eventId} = await create(asAdmin(data({requestId: "req-custom-0123456789ab", programs: [
      {programId: "program-a", name: "A", order: 0}, {programId: "program-b", name: "B", order: 1}, {programId: "custom-zeta-9", name: "Z", order: 2}]})));
    const saved = (await db.collection("events").doc(eventId).get()).data();
    assert.deepEqual(saved.programs.map((p) => p.programId), ["program-a", "program-b", "custom-zeta-9"]);
    const request = buildImportRequest({table: makeTable(2), eventId, mapping: syntheticMapping()});
    await assert.rejects(preview(asAdmin(request)), (e) => e.code === "failed-precondition" && e.details && e.details.code === "program-not-in-event");
    assert.equal((await db.collection("participants").get()).size, 0);
  });

  test("認可: staffと未認証は作成できず、何も書かれない", async () => {
    const before = await counts();
    assert.equal(await code(create({auth: {uid: "staff1"}, data: data()})), "permission-denied");
    assert.equal(await code(create({auth: undefined, data: data()})), "unauthenticated");
    assert.deepEqual(await counts(), before);
  });
});
