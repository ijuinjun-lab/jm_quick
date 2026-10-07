// 受付スタッフ用QR(受付キー)の統合テスト。アカウントを持たない受付スタッフの端末が、QRの受付キーだけで
// 対象イベントの受付(受付画面の表示・初回受付)をできること、それ以外(他イベント・管理機能・訂正取消・改ざん)はできないことを、
// ローカルのFirestore Emulator(localhostのみ)+実際のFirebase Admin SDKで確認する。実Firestore・Auth・メール送信は一切ない。
// データはすべて架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeRecord, HEADERS} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {withValidatedCommit} = require("../test_support/validated_commit");
const {createPassApi} = require("../confirmed/pass_api");
const {createReceptionKeyApi, RECEPTION_KEY_TTL_MS, RECEPTION_STAFF_KEYS_COLLECTION} = require("../confirmed/reception_key_api");
const {createReminderApi} = require("../confirmed/reminder_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {confirmedEventCallable, confirmedReceptionKeyCallable, RECEPTION_KEY_DENIED_MESSAGE} = require("../auth");
const {EVENT_SCOPES} = require("../event_scope");
const {assignmentDocId} = require("../event_access");
const {publicRequest} = require("../test_support/app_check");

const silent = {warn: () => {}, info: () => {}};
const APP_BASE_URL = "https://app.invalid";
const errorOf = async (promise) => { try { await promise; } catch (error) { return {code: error.code, message: error.message, details: error.details}; } assert.fail("拒否されるはず"); };

describe("受付スタッフ用QR(受付キー。Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let clock;
  let issue; // PC(正式ログインしたstaff以上)
  let device; // 受付端末(ログインなし・App Check・受付キー)
  let staffCheckIn; // 従来の正式ログインのstaff受付(回帰確認)

  const get = async (path) => (await db.doc(path).get()).data();
  const docs = async (path) => (await db.collection(path).get()).docs;
  const att = (p, programId) => get(`programAttendances/${p.participantId}_${programId}`);

  function makeApis() {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const passApi = createPassApi({getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent});
    const keyApi = createReceptionKeyApi({getDb: () => db, serverTimestamp, now: () => clock});
    // 本番(index.js)と同じ組み合わせ
    const issueCallable = confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, keyApi.issue, {db, logger: silent});
    const deviceOptions = {db, logger: silent, now: () => clock};
    const session = confirmedReceptionKeyCallable(keyApi.getSession, deviceOptions);
    const view = confirmedReceptionKeyCallable(passApi.getReceptionView, deviceOptions);
    const checkIn = confirmedReceptionKeyCallable(passApi.checkIn, deviceOptions);
    const staffCheckInCallable = confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, passApi.checkIn, {db, logger: silent});
    issue = (uid, data) => issueCallable.run({auth: uid ? {uid} : undefined, data});
    // 受付端末はFirebase Authを持たない(request.authなし)。App Check検証済みのリクエストだけ。
    device = {
      session: (data) => session.run(publicRequest({data})),
      view: (data) => view.run(publicRequest({data})),
      checkIn: (data) => checkIn.run(publicRequest({data})),
      checkInWithoutAppCheck: (data) => checkIn.run({data}),
    };
    staffCheckIn = (uid, data) => staffCheckInCallable.run({auth: {uid}, data});
  }

  async function seedEvent(eventId, overrides = {}) {
    await db.collection("events").doc(eventId).set({
      eventId, eventName: `架空イベント(${eventId})`, senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場ホール", contact: "架空事務局 support@example.invalid",
      programs: [{programId: "alpha", name: "譲渡会(ねこ)", order: 0}, {programId: "beta", name: "譲渡会(いぬ)", order: 1}, {programId: "gamma", name: "トークセッション", order: 2}],
      winnerMailTemplate: {subject: "件名", introBody: "冒頭", closingBody: "締め", notesBody: null, version: 1, updatedBy: "u-admin"},
      ...overrides,
    });
  }
  async function importInto(eventId, clientRequestId, rows) {
    const api = withValidatedCommit(createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()}));
    const records = rows.map((i) => makeRecord(i, {"午後参加時間": "13:00-14:00", "午後参加人数": "3"}));
    await api.commit({identity: {uid: "u-admin"}, data: buildImportRequest({table: {headers: HEADERS, records}, eventId, clientRequestId})});
    return (await db.collection("participants").where("eventId", "==", eventId).get()).docs.map((d) => d.data()).sort((a, b) => a.importRow - b.importRow);
  }
  const ids = (p) => ({eventId: p.eventId, participantId: p.participantId, publicId: p.publicId});
  const assign = (eventId, uid, role) => db.collection("eventAssignments").doc(assignmentDocId(eventId, uid)).set({eventId, uid, role, active: true, email: `${uid}@example.invalid`});

  let p1; let p2; let p3; let p4; // event1の参加者
  let q1; // event2の参加者

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    clock = Date.parse("2026-11-30T00:00:00Z");
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await seedEvent("event1");
    await seedEvent("event2");
    // 大久保さん相当: event1のevent_manager。別スタッフ相当: event1のstaff。event2の責任者は別人。
    await assign("event1", "u-okubo", "event_manager");
    await assign("event1", "u-staff1", "staff");
    await assign("event2", "u-other", "event_manager");
    [p1, p2, p3, p4] = await importInto("event1", "batchA", [1, 2, 3, 4]);
    [q1] = await importInto("event2", "batchB", [11]);
    makeApis();
  });

  const keyOf = async (uid = "u-okubo", eventId = "event1") => (await issue(uid, {eventId})).key;

  describe("受付キーの取得(PC・正式ログイン)", () => {
    test("対象イベントのevent_manager・staff・system adminは取得できる。同じイベントでは同じキー(何度表示しても同じQR)", async () => {
      const a = await issue("u-okubo", {eventId: "event1"});
      assert.match(a.key, /^[A-Za-z0-9_-]{43}$/);
      assert.equal(a.eventId, "event1");
      assert.equal(a.expiresAt, clock + RECEPTION_KEY_TTL_MS);
      assert.deepEqual(await issue("u-staff1", {eventId: "event1"}), a);
      assert.deepEqual(await issue("u-admin", {eventId: "event1"}), a);
      const stored = await get(`${RECEPTION_STAFF_KEYS_COLLECTION}/event1`);
      assert.equal(stored.issuedBy, "u-okubo");
      assert.match(stored.keyId, /^rk_[0-9a-f]{16}$/);
    });

    test("未ログイン・担当外(他イベントの責任者)・形式不正・legacyイベントでは取得できない", async () => {
      assert.equal((await errorOf(issue(null, {eventId: "event1"}))).code, "unauthenticated");
      assert.equal((await errorOf(issue("u-other", {eventId: "event1"}))).code, "permission-denied");
      assert.equal((await errorOf(issue("u-nobody", {eventId: "event1"}))).code, "permission-denied");
      assert.equal((await errorOf(issue("u-admin", {eventId: "event1", extra: 1}))).code, "invalid-argument");
      await seedEvent("legacy1", {flow: "legacy"});
      assert.equal((await errorOf(issue("u-admin", {eventId: "legacy1"}))).code, "failed-precondition");
      assert.equal((await docs(RECEPTION_STAFF_KEYS_COLLECTION)).length, 0, "キーは作られていない");
    });

    test("イベントごとに別のキー。同時に複数のPCで開いても、有効なキーは1つ", async () => {
      const results = await Promise.all(Array.from({length: 10}, () => issue("u-admin", {eventId: "event1"})));
      assert.equal(new Set(results.map((r) => r.key)).size, 1);
      const other = await issue("u-other", {eventId: "event2"});
      assert.notEqual(other.key, results[0].key);
    });

    test("有効期限は発行から24時間。期限切れ後に開くと新しいキーになり、古いキーは使えない", async () => {
      const first = await keyOf();
      clock += RECEPTION_KEY_TTL_MS - 1;
      assert.equal(await keyOf(), first, "期限内は同じキー");
      await device.view({...ids(p1), receptionKey: first});
      clock += 1;
      const denied = await errorOf(device.view({...ids(p1), receptionKey: first}));
      assert.equal(denied.code, "permission-denied");
      assert.equal(denied.details.code, "reception-key-invalid");
      const second = await keyOf();
      assert.notEqual(second, first);
      await device.view({...ids(p1), receptionKey: second});
    });
  });

  describe("受付端末(ログインなし・受付キーだけ)", () => {
    test("QRを読んだ直後の確認: イベント名と有効期限だけが返る(参加者情報・キー・発行者は返さない)", async () => {
      const key = await keyOf();
      const session = await device.session({eventId: "event1", receptionKey: key});
      assert.deepEqual(session, {eventId: "event1", eventName: "架空イベント(event1)", expiresAt: clock + RECEPTION_KEY_TTL_MS});
    });

    test("メールアドレス・パスワード・Firebase Authなしで、対象イベントの参加者QRを受付できる(受付履歴は受付キーのIDで残る)", async () => {
      const key = await keyOf();
      const view = await device.view({...ids(p1), receptionKey: key});
      assert.equal(view.eventId, "event1");
      assert.deepEqual(view.programs.map((x) => x.checkedIn), [false, false, false]);
      const result = await device.checkIn({...ids(p1), programId: "alpha", attendedCount: 2, receptionKey: key});
      assert.equal(result.alreadyCheckedIn, false);
      assert.equal(result.program.attendedCount, 2);
      const stored = await att(p1, "alpha");
      const {keyId} = await get(`${RECEPTION_STAFF_KEYS_COLLECTION}/event1`);
      assert.equal(stored.checkedInBy, `reception-key:${keyId}`);
      assert.ok(!JSON.stringify(stored).includes(key), "キー本体は受付記録に残さない");
      const history = await docs(`programAttendances/${p1.participantId}_alpha/history`);
      assert.equal(history.length, 1);
      assert.equal(history[0].data().changedBy, `reception-key:${keyId}`);
    });

    test("1件受付した後、同じ端末(同じキー)で次の参加者を続けて受付できる(QRの再読取は不要)", async () => {
      const key = await keyOf();
      for (const p of [p1, p2, p3]) {
        await device.view({...ids(p), receptionKey: key});
        const result = await device.checkIn({...ids(p), programId: "alpha", attendedCount: 1, receptionKey: key});
        assert.equal(result.alreadyCheckedIn, false);
      }
      for (const p of [p1, p2, p3]) assert.equal((await att(p, "alpha")).checkedIn, true);
      assert.equal((await att(p4, "alpha")).checkedIn, false);
    });

    test("同じ受付スタッフ用QRを端末A・B・Cで同時に使える(one-time tokenではない)。別々の参加者を同時に受付できる", async () => {
      const key = await keyOf();
      // 3台がそれぞれ同じQRを読む(3台とも同じキー)
      const sessions = await Promise.all([1, 2, 3].map(() => device.session({eventId: "event1", receptionKey: key})));
      assert.equal(sessions.length, 3);
      const results = await Promise.all([p1, p2, p3].map((p) => device.checkIn({...ids(p), programId: "beta", attendedCount: 3, receptionKey: key})));
      assert.ok(results.every((r) => r.alreadyCheckedIn === false));
      for (const p of [p1, p2, p3]) assert.equal((await att(p, "beta")).checkedIn, true);
      // 使った後もキーは有効なまま
      await device.view({...ids(p4), receptionKey: key});
      assert.equal((await docs(RECEPTION_STAFF_KEYS_COLLECTION)).length, 1);
    });

    test("重複受付判定は維持: 3台が同じ参加者・同じprogramを同時に受付しても成立は1回だけ。正式staffの受付とも二重にならない", async () => {
      const key = await keyOf();
      const results = await Promise.all(Array.from({length: 30}, (_, i) =>
        device.checkIn({...ids(p1), programId: "gamma", attendedCount: (i % 3) + 1, receptionKey: key})));
      assert.equal(results.filter((r) => r.alreadyCheckedIn === false).length, 1);
      assert.equal(results.filter((r) => r.alreadyCheckedIn === true).length, 29);
      assert.equal((await docs(`programAttendances/${p1.participantId}_gamma/history`)).length, 1);
      // 端末で受付済みのものを正式staffが受付しても上書きしない(既存の重複判定)
      const again = await staffCheckIn("u-staff1", {...ids(p1), programId: "gamma", attendedCount: 9});
      assert.equal(again.alreadyCheckedIn, true);
      // 正式staffが先に受付したものを端末で受付しても上書きしない
      await staffCheckIn("u-staff1", {...ids(p2), programId: "gamma", attendedCount: 1});
      const fromDevice = await device.checkIn({...ids(p2), programId: "gamma", attendedCount: 5, receptionKey: key});
      assert.equal(fromDevice.alreadyCheckedIn, true);
      assert.equal((await att(p2, "gamma")).checkedInBy, "u-staff1");
    });

    test("他イベントの参加者QRは受付できない(event1のキーでevent2の参加者。eventIdを書き換えても越境できない)", async () => {
      const key = await keyOf();
      // event1のキーのまま、参加者だけevent2のもの(eventIdはevent1)→ 参加者の所属イベントが一致しない
      const mismatch = await errorOf(device.checkIn({...ids(q1), eventId: "event1", programId: "alpha", attendedCount: 1, receptionKey: key}));
      assert.equal(mismatch.code, "failed-precondition");
      // eventIdをevent2へ書き換える → event1のキーはevent2のキーではない
      const rewritten = await errorOf(device.checkIn({...ids(q1), programId: "alpha", attendedCount: 1, receptionKey: key}));
      assert.equal(rewritten.code, "permission-denied");
      assert.equal(rewritten.details.code, "reception-key-invalid");
      assert.equal((await errorOf(device.view({...ids(q1), receptionKey: key}))).code, "permission-denied");
      assert.equal((await errorOf(device.session({eventId: "event2", receptionKey: key}))).code, "permission-denied");
      assert.equal((await att(q1, "alpha")).checkedIn, false);
      // event2のキーはevent2だけ
      const key2 = await keyOf("u-other", "event2");
      await device.checkIn({...ids(q1), programId: "alpha", attendedCount: 1, receptionKey: key2});
      assert.equal((await errorOf(device.view({...ids(p1), receptionKey: key2}))).code, "permission-denied");
    });

    test("無効なQR・改ざんしたキー・キーなし・App Checkなしは拒否(理由を区別しない同じ応答)", async () => {
      const key = await keyOf();
      const tampered = key.slice(0, -1) + (key.endsWith("A") ? "B" : "A");
      const baseline = await errorOf(device.checkIn({...ids(p1), programId: "alpha", attendedCount: 1, receptionKey: tampered}));
      assert.deepEqual(baseline, {code: "permission-denied", message: RECEPTION_KEY_DENIED_MESSAGE, details: {code: "reception-key-invalid"}});
      for (const receptionKey of [undefined, "", "short", "x".repeat(43), `${key}x`, 123, null, ["a"]]) {
        assert.deepEqual(await errorOf(device.checkIn({...ids(p1), programId: "alpha", attendedCount: 1, receptionKey})), baseline, String(receptionKey));
      }
      for (const data of [null, "x", [], {}]) assert.deepEqual(await errorOf(device.view(data)), baseline);
      assert.equal((await errorOf(device.checkInWithoutAppCheck({...ids(p1), programId: "alpha", attendedCount: 1, receptionKey: key}))).code, "unauthenticated");
      assert.equal((await att(p1, "alpha")).checkedIn, false);
    });

    test("受付キーを持っていても、ログイン中のFirebase Authユーザーとしては扱われない(request.authは見ない)", async () => {
      const key = await keyOf();
      // 端末に他人のログイン情報が混ざっていても、受付キーのguardはそれを使わず、キーだけで判定する
      const view = confirmedReceptionKeyCallable(async ({identity}) => identity, {db, logger: silent});
      const identity = await view.run(publicRequest({auth: {uid: "u-admin"}, data: {eventId: "event1", receptionKey: key}}));
      assert.equal(identity.systemAdmin, false);
      assert.equal(identity.receptionKey, true);
      assert.match(identity.uid, /^reception-key:rk_/);
      assert.equal(identity.eventId, "event1");
    });

    test("受付キーでは訂正・取消・管理API(イベント情報・CSV取込・当選メール・リマインド・スタッフ管理)を呼べない", async () => {
      const key = await keyOf();
      await device.checkIn({...ids(p1), programId: "alpha", attendedCount: 2, receptionKey: key});
      const serverTimestamp = () => env.FieldValue.serverTimestamp();
      const passApi = createPassApi({getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent});
      const winnerMailApi = createWinnerMailApi({getDb: () => db, serverTimestamp, generateQrPng: async () => Buffer.from(""), getAppBaseUrl: () => APP_BASE_URL});
      const reminderApi = createReminderApi({getDb: () => db, serverTimestamp, generateQrPng: async () => Buffer.from(""), getAppBaseUrl: () => APP_BASE_URL, winnerSendApi: {}});
      const importApi = createImportApi({getDb: () => db, serverTimestamp});
      // 本番と同じ認可(index.js)で定義した管理系callableへ、受付端末と同じリクエスト(ログインなし・App Check・受付キー)を送る
      const managementCallables = [
        confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, passApi.correct, {db, logger: silent}),
        confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, passApi.cancel, {db, logger: silent}),
        confirmedEventCallable("eventManager", EVENT_SCOPES.dataEventId, importApi.preview, {db, logger: silent}),
        confirmedEventCallable("eventManager", EVENT_SCOPES.dataEventId, winnerMailApi.getSettings, {db, logger: silent}),
        confirmedEventCallable("eventManager", EVENT_SCOPES.dataEventId, reminderApi.getSettings, {db, logger: silent}),
        confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, async () => ({key: "should-not-reach"}), {db, logger: silent}),
      ];
      for (const callable of managementCallables) {
        const error = await errorOf(callable.run(publicRequest({data: {...ids(p1), programId: "alpha", receptionKey: key}})));
        assert.equal(error.code, "unauthenticated");
      }
      // 受付キーから新しいキーを発行することもできない
      assert.equal((await errorOf(issue(null, {eventId: "event1", receptionKey: key}))).code, "unauthenticated");
      const stored = await att(p1, "alpha");
      assert.equal(stored.checkedIn, true);
      assert.equal(stored.attendedCount, 2, "訂正されていない");
    });
  });

  test("正式staff・adminの既存の受付は変わらず動く(受付キーなし)", async () => {
    const result = await staffCheckIn("u-staff1", {...ids(p1), programId: "alpha", attendedCount: 1});
    assert.equal(result.alreadyCheckedIn, false);
    assert.equal((await att(p1, "alpha")).checkedInBy, "u-staff1");
    assert.equal((await errorOf(staffCheckIn("u-other", {...ids(p2), programId: "alpha", attendedCount: 1}))).code, "permission-denied");
    await staffCheckIn("u-admin", {...ids(q1), programId: "alpha", attendedCount: 1});
  });
});
