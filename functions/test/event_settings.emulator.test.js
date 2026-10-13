// イベント設定(getConfirmedEventSettings / updateConfirmedEventSettings)を、実際のindex.js + Firestore Emulator(localhostのみ)で検証する。
//  - 認可: システム管理者・そのイベントのイベント管理者だけ更新できる(受付スタッフ・他イベントの管理者・未ログインは拒否)
//  - 検証: 変更なし・開始>=終了・不正な日時・未知のキー・終了日時の削除は拒否。日本時間(+09:00)の入力はUTCのTimestampで保存
//  - 同時更新: 読み込んだ時点の値と現在値が違えば拒否し、何も書かない
//  - 変更履歴(settingsHistory)・送信済みメール件数。参加者・受付記録・送信履歴・テンプレート・programsは変えない
//  - 受付画面(QR)・受付は、変更後のイベント情報でそのまま動く
// データはすべて架空(メールは .invalid)。実際のメール送信はしない(外部への通信はテストが遮断する)。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {validatedCommitRun} = require("../test_support/validated_commit");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {assignmentDocId} = require("../event_access");

const EV_A = "evSettingsA0123456789";
const EV_B = "evSettingsB0123456789";
const TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "当選おめでとうございます。", closingBody: "お待ちしております。", notesBody: null, version: 1, updatedBy: "u-admin"};
const outcome = (promise) => promise.then(() => "ok", (error) => (error.details && error.details.code) || error.code || String(error));
const realFetch = globalThis.fetch;

describe("イベント設定(実際のindex.js + Emulator)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;

  const as = (uid, data) => ({auth: uid ? {uid} : undefined, data});
  const run = (name, uid, data) => index[name].run(as(uid, data));
  const call = (name, uid, data) => outcome(run(name, uid, data));
  const seedEvent = (eventId, extra = {}) => db.collection("events").doc(eventId).set({
    eventId, eventName: `架空イベント${eventId.slice(-2)}`, senderName: "架空事務局", flow: "confirmed", contact: "架空事務局",
    startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
    venue: "架空会場", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
    programs: [{programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}, {programId: "gamma", name: "トーク", order: 2}],
    winnerMailTemplate: TEMPLATE, reminderEnabled: false,
    ...extra,
  });
  const assign = (eventId, uid, role) => db.collection("eventAssignments").doc(assignmentDocId(eventId, uid)).set({
    eventId, uid, role, active: true, email: `${uid}@example.invalid`, assignedBy: "u-admin",
    assignedAt: env.FieldValue.serverTimestamp(), updatedAt: env.FieldValue.serverTimestamp(),
  });
  const eventData = async (eventId) => (await db.collection("events").doc(eventId).get()).data();
  const history = async (eventId) => (await db.collection("events").doc(eventId).collection("settingsHistory").get()).docs.map((d) => ({id: d.id, ...d.data()}));
  // 参加者・受付記録・送信履歴などの全件(変更されていないことの確認用)
  const snapshotOf = async (name) => (await db.collection(name).get()).docs.map((d) => [d.id, JSON.stringify(d.data())]).sort();

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    globalThis.fetch = async (url, init) => {
      if (String(url).startsWith(env.origin)) return realFetch(url, init);
      throw new Error(`unexpected outbound request blocked by test: ${url}`);
    };
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await seedEvent(EV_A, {endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z"))});
    await seedEvent(EV_B); // 終了日時が未設定のイベント
    await assign(EV_A, "u-mgr-a", "event_manager");
    await assign(EV_A, "u-staff-a", "staff");
    await assign(EV_B, "u-mgr-b", "event_manager");
  });

  test("取得: 基本情報(日時はUTCのISO)と送信済みメール件数(送信ジョブの合計)。受付スタッフ・他イベント・未ログインは拒否", async () => {
    await db.collection("sendJobs").doc(`winner-batchA`).set({eventId: EV_A, type: "winner", sentCount: 3, unknownCount: 1, failedCount: 0});
    await db.collection("sendJobs").doc(`winner-batchB`).set({eventId: EV_B, type: "winner", sentCount: 9, unknownCount: 0});
    const got = await run("getConfirmedEventSettings", "u-mgr-a", {eventId: EV_A});
    assert.deepEqual(got.settings, {
      eventName: "架空イベント89", startAt: "2026-11-30T01:00:00.000Z", endAt: "2026-11-30T07:00:00.000Z",
      venue: "架空会場", address: "架空県架空市1-2-3", access: "架空駅から徒歩5分",
    });
    assert.deepEqual(got.sentMail, {sentCount: 3, unknownCount: 1, jobCount: 1}, "他イベントの送信は数えない");
    assert.equal((await run("getConfirmedEventSettings", "u-admin", {eventId: EV_B})).settings.endAt, null);
    for (const [uid, expected] of [["u-staff-a", "permission-denied"], ["u-mgr-b", "permission-denied"], [null, "unauthenticated"]]) {
      assert.equal(await call("getConfirmedEventSettings", uid, {eventId: EV_A}), expected, String(uid));
    }
  });

  test("更新: イベント名・開催日時(日本時間の入力→UTC保存)・会場名・住所・アクセス。変更したフィールドだけ書き、履歴を追記", async () => {
    const before = await eventData(EV_A);
    const result = await run("updateConfirmedEventSettings", "u-mgr-a", {
      eventId: EV_A,
      changes: {eventName: "架空イベント(訂正)", startAt: "2026-12-01T10:30:00+09:00", endAt: "2026-12-01T16:00:00+09:00",
        venue: "架空第二会場", address: "架空県架空市9-9-9", access: ""},
      expected: {eventName: "架空イベント89", startAt: "2026-11-30T01:00:00.000Z", endAt: "2026-11-30T07:00:00.000Z",
        venue: "架空会場", address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
    });
    assert.deepEqual(result.changedFields, ["eventName", "startAt", "endAt", "venue", "address", "access"]);
    const after = await eventData(EV_A);
    assert.equal(after.eventName, "架空イベント(訂正)");
    assert.equal(after.startAt.toDate().toISOString(), "2026-12-01T01:30:00.000Z", "日本時間 10:30 → UTC 01:30");
    assert.equal(after.endAt.toDate().toISOString(), "2026-12-01T07:00:00.000Z");
    assert.equal(after.venue, "架空第二会場");
    assert.deepEqual(after.venueInfo, {address: "架空県架空市9-9-9", access: null}, "アクセスは空欄で消せる");
    // 基本情報以外は1つも変わらない
    for (const key of ["eventId", "flow", "programs", "winnerMailTemplate", "reminderEnabled", "senderName", "contact"]) {
      assert.deepEqual(after[key], before[key], key);
    }
    assert.equal(after.updatedBy, "u-mgr-a");
    const [h] = await history(EV_A);
    assert.equal(h.id, "settings-1");
    assert.equal(h.changedBy, "u-mgr-a");
    assert.ok(h.changedAt);
    assert.deepEqual(h.before.eventName, "架空イベント89");
    assert.deepEqual(h.after.startAt, "2026-12-01T01:30:00.000Z");
    assert.deepEqual(h.sentMailAtChange, {sentCount: 0, unknownCount: 0, jobCount: 0});
    // 2回目は連番で追記(既存の履歴は変えない)
    await run("updateConfirmedEventSettings", "u-admin", {eventId: EV_A, changes: {venue: "架空第三会場"}, expected: {venue: "架空第二会場"}});
    assert.deepEqual((await history(EV_A)).map((x) => x.id).sort(), ["settings-1", "settings-2"]);
    assert.deepEqual((await history(EV_A)).find((x) => x.id === "settings-2").changedFields, ["venue"]);
  });

  test("未設定の終了日時を追加できる(終了日時の削除はできない)", async () => {
    assert.equal(await call("updateConfirmedEventSettings", "u-mgr-b", {eventId: EV_B, changes: {endAt: "2026-11-30T17:00:00+09:00"}, expected: {endAt: null}}), "ok");
    assert.equal((await eventData(EV_B)).endAt.toDate().toISOString(), "2026-11-30T08:00:00.000Z");
    assert.equal(await call("updateConfirmedEventSettings", "u-mgr-b", {eventId: EV_B, changes: {endAt: null}, expected: {endAt: "2026-11-30T08:00:00.000Z"}}), "required");
    assert.equal(await call("updateConfirmedEventSettings", "u-mgr-b", {eventId: EV_B, changes: {endAt: ""}, expected: {endAt: "2026-11-30T08:00:00.000Z"}}), "required");
  });

  test("検証: 変更なし・開始>=終了・不正な日時・未知のキー・expected不足・空のイベント名/会場は拒否し、何も書かない", async () => {
    const before = JSON.stringify(await eventData(EV_A));
    const cases = [
      [{changes: {venue: "架空会場"}, expected: {venue: "架空会場"}}, "no-change"],
      [{changes: {startAt: "2026-11-30T01:00:00Z"}, expected: {startAt: "2026-11-30T10:00:00+09:00"}}, "no-change"], // 同じ時刻の別表記
      [{changes: {endAt: "2026-11-30T10:00:00+09:00"}, expected: {endAt: "2026-11-30T07:00:00.000Z"}}, "invalid-time-range"], // 終了=開始
      [{changes: {startAt: "2026-11-30T17:30:00+09:00"}, expected: {startAt: "2026-11-30T01:00:00.000Z"}}, "invalid-time-range"], // 開始>終了
      [{changes: {startAt: "2026-02-30T10:00:00+09:00"}, expected: {startAt: "2026-11-30T01:00:00.000Z"}}, "invalid-date"],
      [{changes: {startAt: "2026-11-30 10:00"}, expected: {startAt: "2026-11-30T01:00:00.000Z"}}, "invalid-date"], // オフセットなし
      [{changes: {startAt: "2026-11-30T25:00:00+09:00"}, expected: {startAt: "2026-11-30T01:00:00.000Z"}}, "invalid-date"],
      [{changes: {programs: []}, expected: {}}, "unknown-key"],
      [{changes: {eventId: "evOther"}, expected: {}}, "unknown-key"],
      [{changes: {venue: "x"}, expected: {}}, "expected-required"],
      [{changes: {}, expected: {}}, "nothing-to-update"],
      [{changes: {eventName: "  "}, expected: {eventName: "架空イベント89"}}, "required"],
      [{changes: {venue: ""}, expected: {venue: "架空会場"}}, "required"],
      [{changes: {eventName: "x".repeat(201)}, expected: {eventName: "架空イベント89"}}, "too-long"],
    ];
    for (const [body, expected] of cases) {
      assert.equal(await call("updateConfirmedEventSettings", "u-admin", {eventId: EV_A, ...body}), expected, JSON.stringify(body));
    }
    assert.equal(JSON.stringify(await eventData(EV_A)), before);
    assert.deepEqual(await history(EV_A), []);
  });

  test("権限: 更新できるのはシステム管理者・そのイベントのイベント管理者だけ。受付スタッフ・他イベントの管理者・未ログインは拒否(何も書かない)", async () => {
    const body = {eventId: EV_A, changes: {venue: "変更されてはならない会場"}, expected: {venue: "架空会場"}};
    for (const [uid, expected] of [["u-staff-a", "permission-denied"], ["u-mgr-b", "permission-denied"], [null, "unauthenticated"], ["u-nobody", "permission-denied"]]) {
      assert.equal(await call("updateConfirmedEventSettings", uid, body), expected, String(uid));
    }
    assert.equal((await eventData(EV_A)).venue, "架空会場");
    assert.equal(await call("updateConfirmedEventSettings", "u-mgr-a", body), "ok");
    // 受付キー(アカウント不要)の入口は無い
    assert.equal(Object.keys(index).some((name) => /EventSettings.*ByStaffKey/.test(name)), false);
  });

  test("同時更新: 読み込んだ時点の値と違えば拒否(他の人の変更を上書きしない)。当選メール設定で住所が変わった場合も検出", async () => {
    await run("updateConfirmedEventSettings", "u-mgr-a", {eventId: EV_A, changes: {venue: "先に保存した会場"}, expected: {venue: "架空会場"}});
    assert.equal(await call("updateConfirmedEventSettings", "u-admin", {eventId: EV_A, changes: {venue: "後から保存した会場"}, expected: {venue: "架空会場"}}),
      "event-settings-changed");
    assert.equal((await eventData(EV_A)).venue, "先に保存した会場");
    // 当選メール設定(既存の経路)で住所が変わった後に、古い住所を前提に保存しようとすると拒否
    await db.collection("events").doc(EV_A).update({venueInfo: {address: "当選メール設定で変えた住所", access: "架空駅から徒歩5分"}});
    assert.equal(await call("updateConfirmedEventSettings", "u-admin", {eventId: EV_A, changes: {address: "別の住所"}, expected: {address: "架空県架空市1-2-3"}}),
      "event-settings-changed");
    // 同時に2件: 成立するのは1件だけ
    const results = await Promise.all(["案X", "案Y"].map((v) => call("updateConfirmedEventSettings", "u-admin",
      {eventId: EV_A, changes: {eventName: v}, expected: {eventName: "架空イベント89"}})));
    assert.deepEqual(results.sort(), ["event-settings-changed", "ok"]);
    assert.equal((await history(EV_A)).length, 2, "成功した変更だけが履歴に残る");
  });

  test("送信済みメールがあれば件数を返し、履歴にも残す。メールは再送しない(送信ジョブ・配送記録は変えない)", async () => {
    await db.collection("sendJobs").doc("winner-batchA").set({eventId: EV_A, type: "winner", sentCount: 5, unknownCount: 0, status: "completed"});
    await db.collection("mailDeliveries").doc("pX_winner").set({eventId: EV_A, participantId: "pX", status: "sent", jobId: "winner-batchA"});
    const jobs = await snapshotOf("sendJobs");
    const deliveries = await snapshotOf("mailDeliveries");
    assert.equal((await run("getConfirmedEventSettings", "u-admin", {eventId: EV_A})).sentMail.sentCount, 5);
    await run("updateConfirmedEventSettings", "u-admin", {eventId: EV_A, changes: {venue: "変更後の会場"}, expected: {venue: "架空会場"}});
    assert.deepEqual((await history(EV_A))[0].sentMailAtChange, {sentCount: 5, unknownCount: 0, jobCount: 1});
    assert.deepEqual(await snapshotOf("sendJobs"), jobs);
    assert.deepEqual(await snapshotOf("mailDeliveries"), deliveries);
  });

  test("参加者・受付記録・取込回は変えない。受付画面(QR)・受付は変更後のイベント情報でそのまま動く", async () => {
    await validatedCommitRun(index)(as("u-admin", buildImportRequest({table: makeTable(3), eventId: EV_A, clientRequestId: "settingsBatch1"})));
    const participants = await snapshotOf("participants");
    const attendances = await snapshotOf("programAttendances");
    const batches = await snapshotOf("importBatches");
    await run("updateConfirmedEventSettings", "u-mgr-a", {
      eventId: EV_A, changes: {eventName: "訂正後の架空イベント", startAt: "2026-12-05T10:00:00+09:00", endAt: "2026-12-05T17:00:00+09:00"},
      expected: {eventName: "架空イベント89", startAt: "2026-11-30T01:00:00.000Z", endAt: "2026-11-30T07:00:00.000Z"},
    });
    assert.deepEqual(await snapshotOf("participants"), participants);
    assert.deepEqual(await snapshotOf("programAttendances"), attendances);
    assert.deepEqual(await snapshotOf("importBatches"), batches);
    const p = (await db.collection("participants").where("eventId", "==", EV_A).get()).docs[0];
    const a = (await db.collection("programAttendances").where("participantId", "==", p.id).get()).docs[0].data();
    const target = {eventId: EV_A, participantId: p.id, publicId: p.data().publicId};
    const view = await run("getConfirmedReceptionView", "u-staff-a", target);
    assert.equal(view.eventName, "訂正後の架空イベント", "受付画面は最新のイベント名");
    const checked = await run("checkInConfirmedProgram", "u-staff-a", {...target, programId: a.programId, attendedCount: 1});
    assert.equal(checked.program.checkedIn, true, "受付はそのまま動く");
  });
});
