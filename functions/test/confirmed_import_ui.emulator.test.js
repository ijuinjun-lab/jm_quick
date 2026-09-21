// Phase 11B: 取込画面(Flutter)が送るリクエストを、実際の取込API(preview / commit)とイベント概要API(getSummary)に、
// ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDKで通す。
//  - 共有fixture(test/fixtures/import_ui_case.json)はFlutter側のテストと同じファイル。Flutterが組み立てる形式がサーバーで受理される確認
//  - 3 programのイベント、1 CSV行=1参加者(同一メール100・同一氏名100でも減らない)、冪等な再送、メール関連0
// データはすべて完全な架空(メールは予約TLD .invalid)。実CSVは使わない。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {createEventCreateApi} = require("../confirmed/event_create_api");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "import_ui_case.json"), "utf8"));
const silent = {warn() {}, info() {}, error() {}};
const code = (promise) => promise.then(() => "ok", (e) => e.code);
const NOW = new Date("2026-09-22T00:00:00Z").getTime();

describe("取込画面の要求 × 実際の取込API(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let create;
  let summary;
  let preview;
  let commit;
  let sendCalls;

  const serverTimestamp = () => env.FieldValue.serverTimestamp();
  const asAdmin = (payload) => ({auth: {uid: "admin1"}, data: payload});
  const asStaff = (payload) => ({auth: {uid: "staff1"}, data: payload});
  const eventData = (extra = {}) => ({
    requestId: "req-import-ui-0123456789", eventName: "PHASE11 STEP3 TEST(架空)", startAt: "2026-11-30T01:00:00Z", endAt: "2026-11-30T07:00:00Z", venue: "架空ホール",
    address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分",
    programs: [{programId: "program-a", name: "架空プログラムA", order: 0}, {programId: "program-b", name: "架空プログラムB", order: 1}, {programId: "custom-zeta-9", name: "架空プログラムZ", order: 2}],
    ...extra,
  });
  const counts = async () => {
    const result = {};
    for (const collection of await db.listCollections()) result[collection.id] = (await collection.get()).size;
    return result;
  };
  const newEvent = async (extra) => (await create(asAdmin(eventData(extra)))).eventId;
  // Flutterが作る要求(共有fixture)。eventIdだけ、実際に作成したイベントのものへ差し替える
  const fixtureRequest = (eventId, extra = {}) => ({...structuredClone(FIXTURE.expectedRequest), eventId, ...extra});

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    const wrap = (name, handler) => { const callable = confirmedCallable(name, handler, {db, logger: silent}); return (request) => callable.run(request); };
    const eventApi = createEventCreateApi({getDb: () => db, serverTimestamp, logger: silent, now: () => NOW});
    create = wrap("admin", eventApi.createEvent);
    summary = wrap("admin", eventApi.getSummary);
    const importApi = createImportApi({getDb: () => db, serverTimestamp});
    preview = wrap("admin", importApi.preview);
    commit = wrap("admin", importApi.commit);
    // 実transportは使わない(呼ばれたら記録して失敗させる)
    createWinnerSendApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => "https://app.invalid",
      getTransport: () => ({send: async () => { sendCalls += 1; throw new Error("transport must not be used"); }})});
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    sendCalls = 0;
    await db.collection("accessRoles").doc("admin1").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("staff1").set({role: "staff", active: true});
  });

  describe("getConfirmedEventSummary(取込画面のイベント表示用。admin専用・読み取りだけ)", () => {
    test("adminは3 programのイベントの概要(名前・日時・会場・program)を得る。個人情報・内部情報は含まない。何も書き込まない", async () => {
      const eventId = await newEvent();
      const before = await counts();
      const result = await summary(asAdmin({eventId}));
      assert.deepEqual(Object.keys(result).sort(), ["endAt", "eventId", "eventName", "programs", "startAt", "venue"]);
      assert.equal(result.eventName, "PHASE11 STEP3 TEST(架空)");
      assert.equal(result.venue, "架空ホール");
      assert.equal(result.startAt, "2026-11-30T01:00:00.000Z");
      assert.deepEqual(result.programs, [
        {programId: "program-a", name: "架空プログラムA", order: 0}, {programId: "program-b", name: "架空プログラムB", order: 1}, {programId: "custom-zeta-9", name: "架空プログラムZ", order: 2}]);
      assert.deepEqual(await counts(), before);
    });
    test("未認証・権限なし・staffは拒否。legacy・存在しない・flow不明のイベントは同じ拒否(区別できない)。余計な入力も拒否", async () => {
      const eventId = await newEvent();
      await db.collection("events").doc("legacy1").set({flow: "legacy", eventName: "旧"});
      await db.collection("events").doc("unknown1").set({eventName: "flowなし"});
      assert.equal(await code(summary({auth: undefined, data: {eventId}})), "unauthenticated");
      assert.equal(await code(summary({auth: {uid: "nobody"}, data: {eventId}})), "permission-denied");
      assert.equal(await code(summary(asStaff({eventId}))), "permission-denied");
      const messages = [];
      for (const id of ["legacy1", "unknown1", "doesnotexist1"]) {
        messages.push(await summary(asAdmin({eventId: id})).then(() => "ok", (e) => `${e.code}:${e.message}`));
      }
      assert.deepEqual([...new Set(messages)].length, 1);
      assert.match(messages[0], /^failed-precondition:/);
      assert.equal(await code(summary(asAdmin({eventId, role: "admin"}))), "invalid-argument");
      assert.equal(await code(summary(asAdmin({eventId: "a/b"}))), "invalid-argument");
      assert.equal(await code(summary(asAdmin({}))), "invalid-argument");
    });
  });

  describe("共有fixture(Flutterが組み立てる要求)を実際のAPIへ", () => {
    test("previewは何も書かない。ready 2 / review 1 / error 1・空行1件。行のdedupeはない", async () => {
      const eventId = await newEvent();
      const before = await counts();
      const result = await preview(asAdmin(fixtureRequest(eventId)));
      assert.deepEqual(await counts(), {...before}, "previewはFirestoreへ書き込まない");
      assert.equal(result.totalRecords, 5);
      assert.equal(result.blankRecordCount, 1);
      const byClass = (name) => result.rows.filter((r) => r.classification === name).length;
      assert.equal(byClass("ready") + byClass("review") + byClass("error"), result.totalRows);
      assert.ok(byClass("error") >= 1);
      assert.equal(JSON.stringify(result).includes("publicId"), false, "previewにpublicIdは含まれない");
      assert.equal(JSON.stringify(result).includes("example.invalid"), false, "previewに個人情報(メール)を返さない");
    });

    test("commit: 1回目はcommitted、同じ要求の再送(応答喪失後の再試行・二重クリック)は同じ結果で二重に作らない", async () => {
      const eventId = await newEvent();
      const first = await commit(asAdmin(fixtureRequest(eventId)));
      assert.equal(first.status, "committed");
      assert.equal(first.batchId, FIXTURE.batchId);
      const created = (await db.collection("participants").where("eventId", "==", eventId).get()).size;
      assert.ok(created >= 2);
      const again = await commit(asAdmin(fixtureRequest(eventId)));
      assert.equal(again.status, "committed");
      assert.equal(again.idempotentReplay, true);
      assert.equal((await db.collection("participants").where("eventId", "==", eventId).get()).size, created);
      assert.equal((await db.collection("importBatches").get()).size, 1);
      // 並列(連打)でも参加者は増えない
      const parallel = await Promise.all(Array.from({length: 5}, () => commit(asAdmin(fixtureRequest(eventId))).then((r) => r.status, (e) => e.code)));
      assert.ok(parallel.every((s) => s === "committed" || s === "aborted" || s === "already-exists" || s === "failed-precondition"), JSON.stringify(parallel));
      assert.equal((await db.collection("participants").where("eventId", "==", eventId).get()).size, created);
    });

    test("承認した確認行(review)だけが追加で取り込まれ、承認しなかった行・エラー行は登録されない。取込でメール・jobは何も作られない", async () => {
      const eventId = await newEvent();
      const previewed = await preview(asAdmin(fixtureRequest(eventId)));
      const reviewRows = previewed.rows.filter((r) => r.classification === "review").map((r) => r.sourceRowNumber);
      const readyCount = previewed.rows.filter((r) => r.classification === "ready").length;
      const result = await commit(asAdmin(fixtureRequest(eventId, {approvedReviewRows: reviewRows, clientRequestId: "b2approved"})));
      assert.equal(result.status, "committed");
      assert.equal((await db.collection("participants").where("eventId", "==", eventId).get()).size, readyCount + reviewRows.length);
      for (const name of ["sendJobs", "mailDeliveries", "mailLogs", "mailJobs"]) {
        assert.equal((await db.collection(name).get()).size, 0, name);
      }
      assert.equal(sendCalls, 0);
      const saved = (await db.collection("events").doc(eventId).get()).data();
      assert.equal(saved.reminderEnabled, false);
      assert.equal(saved.flow, "confirmed");
    });

    test("publicIdはサーバーだけが生成する。要求にpublicId・participants・eventの内容を混ぜても拒否される", async () => {
      const eventId = await newEvent();
      for (const extra of [{publicId: "x".repeat(20)}, {participants: [{name: "偽装"}]}, {flow: "confirmed"}, {programs: []}, {createdBy: "attacker"}]) {
        assert.equal(await code(commit(asAdmin(fixtureRequest(eventId, extra)))), "invalid-argument", JSON.stringify(extra));
      }
      assert.equal((await db.collection("participants").get()).size, 0);
      await commit(asAdmin(fixtureRequest(eventId)));
      const publicIds = (await db.collection("participants").get()).docs.map((d) => d.data().publicId);
      assert.ok(publicIds.length >= 2);
      assert.ok(publicIds.every((id) => typeof id === "string" && id.length >= 20));
      assert.equal(new Set(publicIds).size, publicIds.length);
    });

    test("staff・権限なしは、previewもcommitも拒否される。legacy・存在しないイベントには取り込めない", async () => {
      const eventId = await newEvent();
      await db.collection("events").doc("legacy1").set({flow: "legacy", eventName: "旧"});
      for (const call of [preview, commit]) {
        assert.equal(await code(call(asStaff(fixtureRequest(eventId)))), "permission-denied");
        assert.equal(await code(call({auth: undefined, data: fixtureRequest(eventId)})), "unauthenticated");
        assert.notEqual(await code(call(asAdmin(fixtureRequest("legacy1")))), "ok");
        assert.notEqual(await code(call(asAdmin(fixtureRequest("doesnotexist1")))), "ok");
      }
      assert.equal((await db.collection("participants").get()).size, 0);
      assert.equal((await db.collection("importBatches").get()).size, 0);
    });
  });

  describe("1 CSV行 = 1参加者(人物単位のdedupeをしない)", () => {
    const mappingFor = () => structuredClone(FIXTURE.mapping);
    // fixtureと同じ列構成の架空の表。全行が正常(ready)になる値にする
    const bulk = (n, overrides) => {
      const table = makeTable(n, overrides);
      return buildImportRequest({table, eventId: "", mapping: mappingFor(), sourceFileName: "架空.csv", fileHash: "c".repeat(64), clientRequestId: `bulk${n}${Math.random().toString(36).slice(2, 8)}`});
    };
    test("同じメールアドレス100行 → 参加者100件・programAttendances(3program分)も減らない", async () => {
      const eventId = await newEvent();
      const request = {...bulk(100, () => ({"メールアドレス": "same-address@example.invalid", "午後参加時間": "13:00-14:00", "午後参加人数": "1"})), eventId};
      const previewed = await preview(asAdmin(request));
      assert.equal(previewed.rows.filter((r) => r.classification === "ready").length, 100);
      await commit(asAdmin(request));
      assert.equal((await db.collection("participants").where("eventId", "==", eventId).get()).size, 100);
      assert.equal((await db.collection("programAttendances").where("eventId", "==", eventId).get()).size, 300);
    });
    test("同じ氏名100行 → 参加者100件。人数の正本はplannedCountで、参加者数を勝手に集計・統合しない", async () => {
      const eventId = await newEvent();
      const request = {...bulk(100, () => ({"氏名": "架空 同名"})), eventId};
      await commit(asAdmin(request));
      const participants = (await db.collection("participants").where("eventId", "==", eventId).get()).size;
      assert.equal(participants, 100);
      const attendances = (await db.collection("programAttendances").where("eventId", "==", eventId).get()).docs.map((d) => d.data());
      assert.ok(attendances.length >= 200);
      assert.ok(attendances.every((a) => Number.isInteger(a.plannedCount) && a.plannedCount >= 1));
    });
  });
});
