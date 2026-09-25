// Phase 1B: confirmed業務callableのイベント単位の3階層認可を、実際の公開設定(functions/index.jsのexport)で検証する。
// ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDK。メール送信先(mail-api)への通信はスタブで遮断し、
// 実メールは1通も送らない(送信処理はmail-apiの能力確認で止まる)。データはすべて完全な架空(メールは予約TLD .invalid)。
//
//   admin(accessRoles。概念上のsystem_admin) … eventAssignments無しで全イベント・全機能
//   event_manager(eventAssignments)          … 担当イベントの管理業務+受付。他イベントは拒否
//   staff(eventAssignments)                  … 担当イベントの受付・訂正・取消だけ。CSV・メール・リマインドは拒否
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {assignmentDocId} = require("../event_access");

const EV_A = "evScopeA0123456789";
const EV_B = "evScopeB0123456789";
const TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "当選おめでとうございます。", closingBody: "お待ちしております。", notesBody: null, version: 1, updatedBy: "u-admin"};
const outcome = (promise) => promise.then(() => "ok", (error) => error.code || String(error));
const realFetch = globalThis.fetch;

describe("confirmed業務callableのイベント単位の認可(実際のindex.js + Emulator)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  let mailRequests;
  let unexpectedRequests;

  const as = (uid, data) => ({auth: {uid}, data});
  const call = (name, uid, data) => outcome(index[name].run(as(uid, data)));
  const seedEvent = (eventId, name) => db.collection("events").doc(eventId).set({
    eventId, eventName: name, senderName: "架空事務局", flow: "confirmed", contact: "架空事務局",
    startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
    venue: "架空会場", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
    programs: [{programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}, {programId: "gamma", name: "トーク", order: 2}],
    winnerMailTemplate: TEMPLATE, reminderEnabled: false,
  });
  const assign = (eventId, uid, role, active = true) => db.collection("eventAssignments").doc(assignmentDocId(eventId, uid)).set({
    eventId, uid, role, active, email: `${uid}@example.invalid`, assignedBy: "u-admin",
    assignedAt: env.FieldValue.serverTimestamp(), updatedAt: env.FieldValue.serverTimestamp(),
  });
  const importInto = (eventId, clientRequestId, n = 3) =>
    index.commitConfirmedImport.run(as("u-admin", buildImportRequest({table: makeTable(n), eventId, clientRequestId})));
  // 受付に使う参加者(participantId・publicId・programId)
  async function receptionTarget(eventId) {
    const participant = (await db.collection("participants").where("eventId", "==", eventId).get()).docs
      .map((doc) => ({participantId: doc.id, ...doc.data()})).sort((a, b) => (a.participantId < b.participantId ? -1 : 1))[0];
    const attendance = (await db.collection("programAttendances").where("participantId", "==", participant.participantId).get()).docs[0].data();
    return {eventId, participantId: participant.participantId, publicId: participant.publicId, programId: attendance.programId};
  }
  const attendanceOf = async (t) => (await db.collection("programAttendances").where("participantId", "==", t.participantId)
    .where("programId", "==", t.programId).get()).docs[0].data();

  let targetA;
  let targetB;

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    // 外部通信: Emulator以外は遮断。mail-api(架空URL)の能力確認は「未対応」を返し、送信処理を止める(実メール0)。
    mailRequests = [];
    unexpectedRequests = [];
    globalThis.fetch = async (url, init) => {
      const text = String(url);
      if (text.startsWith(env.origin)) return realFetch(url, init);
      if (text.startsWith("https://mail-api.invalid")) {
        mailRequests.push(text);
        return {ok: false, status: 503, json: async () => ({})};
      }
      unexpectedRequests.push(text);
      throw new Error(`unexpected outbound request blocked by test: ${text}`);
    };
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("u-legacy-staff").set({role: "staff", active: true});
    await seedEvent(EV_A, "架空イベントA");
    await seedEvent(EV_B, "架空イベントB");
    await assign(EV_A, "u-mgr-a", "event_manager");
    await assign(EV_A, "u-staff-a", "staff");
    await assign(EV_B, "u-mgr-b", "event_manager");
    await assign(EV_A, "u-off", "event_manager", false);
    await importInto(EV_A, "batchA1");
    await importInto(EV_B, "batchB1");
    targetA = await receptionTarget(EV_A);
    targetB = await receptionTarget(EV_B);
  });

  // 権限の無い側: 担当外(他イベントのmanager)・無効なassignment・assignment無し・従来の全体staff
  const OUTSIDERS_FOR_A = ["u-mgr-b", "u-off", "u-nobody", "u-legacy-staff"];

  describe("CSV取込・イベント概要(eventManager)", () => {
    test("admin・担当managerは成功、担当staff・他イベントmanager・無効・未任命・従来staffは拒否", async () => {
      const previewA = buildImportRequest({table: makeTable(2), eventId: EV_A, clientRequestId: "batchA2"});
      for (const uid of ["u-admin", "u-mgr-a"]) {
        assert.equal(await call("previewConfirmedImport", uid, previewA), "ok", uid);
        assert.equal(await call("getConfirmedEventSummary", uid, {eventId: EV_A}), "ok", uid);
      }
      for (const uid of ["u-staff-a", ...OUTSIDERS_FOR_A]) {
        assert.equal(await call("previewConfirmedImport", uid, previewA), "permission-denied", uid);
        assert.equal(await call("commitConfirmedImport", uid, buildImportRequest({table: makeTable(2), eventId: EV_A, clientRequestId: `x${uid.replace(/-/g, "")}`})), "permission-denied", uid);
        assert.equal(await call("getConfirmedEventSummary", uid, {eventId: EV_A}), "permission-denied", uid);
      }
      assert.equal(await call("commitConfirmedImport", "u-mgr-a", buildImportRequest({table: makeTable(2), eventId: EV_A, clientRequestId: "batchA2"})), "ok");
      assert.equal(await call("previewConfirmedImport", "u-mgr-a", buildImportRequest({table: makeTable(2), eventId: EV_B, clientRequestId: "batchB9"})), "permission-denied");
      assert.equal(await call("commitConfirmedImport", "u-mgr-a", buildImportRequest({table: makeTable(2), eventId: EV_B, clientRequestId: "batchB9"})), "permission-denied");
      assert.equal((await db.collection("importBatches").doc("batchB9").get()).exists, false, "拒否されたcommitは何も書かない");
      assert.equal(await call("previewConfirmedImport", "u-admin", buildImportRequest({table: makeTable(2), eventId: EV_B, clientRequestId: "batchB2"})), "ok", "adminは全イベント");
    });

    test("他イベントのbatchIdを自イベントの取込として偽装: previewは他イベントの取込回の情報を返さず、commitは拒否", async () => {
      const forged = buildImportRequest({table: makeTable(3), eventId: EV_A, clientRequestId: "batchB1"});
      const preview = await index.previewConfirmedImport.run(as("u-mgr-a", forged));
      assert.equal(preview.existingBatch, null, "EV_Bの取込回のstatus・sequenceを返さない");
      assert.equal(await call("commitConfirmedImport", "u-mgr-a", forged), "already-exists");
      const batch = (await db.collection("importBatches").doc("batchB1").get()).data();
      assert.equal(batch.eventId, EV_B, "EV_Bの取込回は変わらない");
      const own = await index.previewConfirmedImport.run(as("u-mgr-a", buildImportRequest({table: makeTable(3), eventId: EV_A, clientRequestId: "batchA1"})));
      assert.equal(own.existingBatch.status, "committed", "自イベントの取込回は従来どおり返す");
    });
  });

  describe("当選メール設定・プレビュー・送信ジョブ(eventManager)", () => {
    test("設定・保存・プレビュー・一覧・ジョブ作成: 担当managerとadminは成功、それ以外は拒否", async () => {
      const participantA = targetA.participantId;
      const calls = [
        ["getConfirmedWinnerMailSettings", {eventId: EV_A}],
        ["previewConfirmedWinnerMail", {eventId: EV_A, participantId: participantA}],
        ["listConfirmedWinnerMailBatches", {eventId: EV_A}],
      ];
      for (const uid of ["u-admin", "u-mgr-a"]) for (const [name, data] of calls) assert.equal(await call(name, uid, data), "ok", `${uid} ${name}`);
      for (const uid of ["u-staff-a", ...OUTSIDERS_FOR_A]) {
        for (const [name, data] of calls) assert.equal(await call(name, uid, data), "permission-denied", `${uid} ${name}`);
        assert.equal(await call("updateConfirmedWinnerMailTemplate", uid, {eventId: EV_A, template: TEMPLATE}), "permission-denied", uid);
        assert.equal(await call("createConfirmedWinnerMailJob", uid, {eventId: EV_A, batchId: "batchA1"}), "permission-denied", uid);
      }
      assert.equal(await call("createConfirmedWinnerMailJob", "u-mgr-a", {eventId: EV_A, batchId: "batchA1"}), "ok");
      assert.equal(await call("getConfirmedWinnerMailSettings", "u-mgr-a", {eventId: EV_B}), "permission-denied", "他イベント");
      assert.equal(await call("listConfirmedWinnerMailBatches", "u-mgr-a", {eventId: EV_B}), "permission-denied", "他イベント");
      assert.equal(await call("createConfirmedWinnerMailJob", "u-mgr-a", {eventId: EV_B, batchId: "batchB1"}), "permission-denied", "他イベント");
      assert.equal((await db.collection("sendJobs").doc("winner-batchB1").get()).exists, false);
    });

    test("偽装: 自イベントとして他イベントのbatch・participantを指定しても拒否", async () => {
      const batchMismatch = await index.createConfirmedWinnerMailJob.run(as("u-mgr-a", {eventId: EV_A, batchId: "batchB1"})).catch((e) => e);
      assert.equal(batchMismatch.code, "failed-precondition");
      assert.equal(batchMismatch.details.code, "batch-event-mismatch");
      const participantMismatch = await index.previewConfirmedWinnerMail.run(as("u-mgr-a", {eventId: EV_A, participantId: targetB.participantId})).catch((e) => e);
      assert.equal(participantMismatch.code, "failed-precondition");
      assert.equal(participantMismatch.details.code, "participant-event-mismatch");
      assert.equal((await db.collection("sendJobs").doc("winner-batchB1").get()).exists, false);
    });

    test("jobId系: 対象イベントはsendJobsの正本で決まる。他イベントのjobIdは(eventIdを名乗っても)拒否、自イベントは可", async () => {
      await index.createConfirmedWinnerMailJob.run(as("u-admin", {eventId: EV_A, batchId: "batchA1"}));
      await index.createConfirmedWinnerMailJob.run(as("u-admin", {eventId: EV_B, batchId: "batchB1"}));
      const jobB = {jobId: "winner-batchB1"};
      for (const name of ["getConfirmedWinnerMailJob", "processConfirmedWinnerMailJob", "retryFailedConfirmedWinnerMails", "startConfirmedWinnerMailDelivery"]) {
        assert.equal(await call(name, "u-mgr-a", jobB), "permission-denied", `${name}: 他イベントのjob`);
        assert.equal(await call(name, "u-mgr-a", {...jobB, eventId: EV_A}), "permission-denied", `${name}: eventIdを名乗っても無意味`);
        assert.equal(await call(name, "u-staff-a", {jobId: "winner-batchA1"}), "permission-denied", `${name}: staffは不可`);
        assert.equal(await call(name, "u-mgr-a", {jobId: "winner-nonexistent"}), "permission-denied", `${name}: 存在しないjobは権限なしと同じ応答`);
        assert.equal(await call(name, "u-admin", {jobId: "winner-nonexistent"}), "not-found", `${name}: adminには従来どおりnot-found`);
      }
      assert.equal(await call("getConfirmedWinnerMailJob", "u-mgr-a", {jobId: "winner-batchA1"}), "ok");
      assert.equal(await call("retryFailedConfirmedWinnerMails", "u-mgr-a", {jobId: "winner-batchA1"}), "ok");
      assert.equal(await call("getConfirmedWinnerMailJob", "u-mgr-b", jobB), "ok");
      assert.equal(await call("getConfirmedWinnerMailJob", "u-admin", jobB), "ok", "adminは全イベント");
      // 送信処理は認可を通るが、mail-apiの能力確認(スタブで未対応)で止まる。実メールは送らない
      assert.equal(await call("processConfirmedWinnerMailJob", "u-mgr-a", {jobId: "winner-batchA1"}), "failed-precondition");
      assert.equal(mailRequests.every((url) => url.endsWith("/health")), true, "送信要求は0件(能力確認だけ)");
      assert.equal(await call("getConfirmedWinnerMailJob", "u-mgr-a", {jobId: "bad/job"}), "invalid-argument");
    });
  });

  describe("前日リマインド(eventManager)", () => {
    test("全操作: 担当managerとadminは認可を通り、担当staff・他イベント・無効・未任命は拒否", async () => {
      const calls = [
        ["getConfirmedReminderSettings", {eventId: EV_A}],
        ["updateConfirmedReminderSettings", {eventId: EV_A, reminderEnabled: false}],
        ["previewConfirmedReminderMail", {eventId: EV_A, participantId: targetA.participantId}],
        ["startConfirmedReminderDelivery", {eventId: EV_A, dispatch: false}],
        ["getConfirmedReminderJob", {eventId: EV_A}],
        ["retryFailedConfirmedReminderMails", {eventId: EV_A}],
      ];
      for (const uid of ["u-admin", "u-mgr-a"]) {
        for (const [name, data] of calls) assert.notEqual(await call(name, uid, data), "permission-denied", `${uid} ${name}`);
      }
      assert.equal(await call("getConfirmedReminderSettings", "u-mgr-a", {eventId: EV_A}), "ok");
      for (const uid of ["u-staff-a", ...OUTSIDERS_FOR_A]) {
        for (const [name, data] of calls) assert.equal(await call(name, uid, data), "permission-denied", `${uid} ${name}`);
      }
      for (const [name, data] of calls) assert.equal(await call(name, "u-mgr-a", {...data, eventId: EV_B}), "permission-denied", `他イベント ${name}`);
      assert.equal(mailRequests.length, 0, "リマインドの操作ではメール送信へ接続しない");
    });
  });

  describe("受付・訂正・取消(eventStaff)", () => {
    test("担当staff: 受付画面・受付・人数訂正・受付取消が成功", async () => {
      const t = targetA;
      assert.equal((await index.getConfirmedReceptionView.run(as("u-staff-a", {eventId: t.eventId, participantId: t.participantId, publicId: t.publicId}))).eventId, EV_A);
      await index.checkInConfirmedProgram.run(as("u-staff-a", {...t, attendedCount: 1}));
      assert.equal((await attendanceOf(t)).checkedIn, true);
      assert.equal(await call("checkInConfirmedProgram", "u-staff-a", {...t, attendedCount: 1}), "ok", "二重受付は冪等(既存の挙動)");
      await index.correctConfirmedProgramAttendance.run(as("u-staff-a", {...t, attendedCount: 2}));
      assert.equal((await attendanceOf(t)).attendedCount, 2);
      await index.cancelConfirmedProgramCheckIn.run(as("u-staff-a", {eventId: t.eventId, participantId: t.participantId, publicId: t.publicId, programId: t.programId}));
      assert.equal((await attendanceOf(t)).checkedIn, false);
    });

    test("担当manager・adminも受付できる(上位roleの包含)。他イベントのstaff・manager・無効・未任命・従来staffは拒否", async () => {
      const view = (uid, t) => call("getConfirmedReceptionView", uid, {eventId: t.eventId, participantId: t.participantId, publicId: t.publicId});
      assert.equal(await view("u-mgr-a", targetA), "ok");
      assert.equal(await view("u-admin", targetA), "ok");
      assert.equal(await view("u-admin", targetB), "ok");
      for (const uid of OUTSIDERS_FOR_A) {
        assert.equal(await view(uid, targetA), "permission-denied", uid);
        assert.equal(await call("checkInConfirmedProgram", uid, {...targetA, attendedCount: 1}), "permission-denied", uid);
        assert.equal(await call("correctConfirmedProgramAttendance", uid, {...targetA, attendedCount: 1}), "permission-denied", uid);
        assert.equal(await call("cancelConfirmedProgramCheckIn", uid, {eventId: EV_A, participantId: targetA.participantId, publicId: targetA.publicId, programId: targetA.programId}), "permission-denied", uid);
      }
      assert.equal(await view("u-staff-a", targetB), "permission-denied", "担当staffでも他イベントの受付は不可");
      assert.equal(await call("checkInConfirmedProgram", "u-staff-a", {...targetB, attendedCount: 1}), "permission-denied");
      assert.equal((await attendanceOf(targetA)).checkedIn, false, "拒否された受付は反映されない");
      assert.equal((await attendanceOf(targetB)).checkedIn, false);
    });

    test("participant/eventId不一致: 自イベントのeventIdで他イベントの参加者を受付しようとしても拒否(何も書かない)", async () => {
      const forged = {...targetB, eventId: EV_A};
      const view = await index.getConfirmedReceptionView.run(as("u-staff-a", {eventId: EV_A, participantId: targetB.participantId, publicId: targetB.publicId})).catch((e) => e);
      assert.equal(view.code, "failed-precondition");
      for (const name of ["checkInConfirmedProgram", "correctConfirmedProgramAttendance"]) {
        assert.notEqual(await call(name, "u-staff-a", {...forged, attendedCount: 1}), "ok", name);
      }
      assert.notEqual(await call("cancelConfirmedProgramCheckIn", "u-staff-a", {eventId: EV_A, participantId: targetB.participantId, publicId: targetB.publicId, programId: targetB.programId}), "ok");
      assert.equal((await attendanceOf(targetB)).checkedIn, false);
    });

    test("担当staffはCSV・メール・リマインド・イベント概要を拒否される(自イベントでも)", async () => {
      assert.equal(await call("previewConfirmedImport", "u-staff-a", buildImportRequest({table: makeTable(1), eventId: EV_A, clientRequestId: "batchA7"})), "permission-denied");
      assert.equal(await call("getConfirmedWinnerMailSettings", "u-staff-a", {eventId: EV_A}), "permission-denied");
      assert.equal(await call("getConfirmedReminderSettings", "u-staff-a", {eventId: EV_A}), "permission-denied");
      assert.equal(await call("getConfirmedEventSummary", "u-staff-a", {eventId: EV_A}), "permission-denied");
    });

    test("不正な形式の入力は、権限の無いユーザーにもinvalid-argument(イベントの存在は推測させない)", async () => {
      assert.equal(await call("getConfirmedReceptionView", "u-staff-a", {participantId: targetA.participantId, publicId: targetA.publicId}), "invalid-argument");
      assert.equal(await call("getConfirmedReceptionView", "u-nobody", {eventId: "bad/event", participantId: "p", publicId: "x"}), "invalid-argument");
    });
  });

  describe("getEventKind(eventStaffOrLegacyStaff)", () => {
    test("担当staff・manager・adminはconfirmed、他イベントのstaffは拒否、従来のaccessRoles staffは従来どおり通る", async () => {
      for (const uid of ["u-staff-a", "u-mgr-a", "u-admin", "u-legacy-staff"]) {
        assert.deepEqual(await index.getEventKind.run(as(uid, {eventId: EV_A})), {kind: "confirmed"}, uid);
      }
      for (const uid of ["u-mgr-b", "u-off", "u-nobody"]) assert.equal(await call("getEventKind", uid, {eventId: EV_A}), "permission-denied", uid);
      assert.equal(await call("getEventKind", "u-staff-a", {eventId: EV_B}), "permission-denied");
    });
  });

  describe("systemAdmin専用・全件一覧", () => {
    test("イベント作成・全イベント一覧(listLegacyEvents)はadminだけ。event_manager・staffは拒否", async () => {
      const input = {requestId: "req-scope-0123456789", eventName: "架空の新イベント", startAt: "2026-12-01T01:00:00Z", venue: "架空会場",
        programs: [{programId: "alpha", name: "架空プログラム", order: 0}]};
      for (const uid of ["u-mgr-a", "u-staff-a", "u-nobody"]) {
        assert.equal(await call("createConfirmedEvent", uid, input), "permission-denied", uid);
        assert.equal(await call("listLegacyEvents", uid, {}), "permission-denied", uid);
      }
      assert.equal(await call("createConfirmedEvent", "u-admin", input), "ok");
      assert.equal((await index.listLegacyEvents.run(as("u-admin", {}))).events.length, 3);
    });
  });

  test("adminはeventAssignmentsが無くても全イベントの全業務を実行できる", async () => {
    assert.equal((await db.collection("eventAssignments").where("uid", "==", "u-admin").get()).size, 0);
    for (const eventId of [EV_A, EV_B]) {
      assert.equal(await call("getConfirmedEventSummary", "u-admin", {eventId}), "ok");
      assert.equal(await call("getConfirmedWinnerMailSettings", "u-admin", {eventId}), "ok");
      assert.equal(await call("getConfirmedReminderSettings", "u-admin", {eventId}), "ok");
    }
    await index.checkInConfirmedProgram.run(as("u-admin", {...targetB, attendedCount: 1}));
    await index.correctConfirmedProgramAttendance.run(as("u-admin", {...targetB, attendedCount: 2}));
    await index.cancelConfirmedProgramCheckIn.run(as("u-admin", {eventId: targetB.eventId, participantId: targetB.participantId, publicId: targetB.publicId, programId: targetB.programId}));
  });

  test("getMyAccessRole(Phase 1A)の応答は維持される", async () => {
    assert.deepEqual(await index.getMyAccessRole.run(as("u-admin", {})), {authenticated: true, role: "admin", systemAdmin: true, assignments: []});
    assert.deepEqual(await index.getMyAccessRole.run(as("u-staff-a", {})), {authenticated: true, role: null, systemAdmin: false, assignments: [{eventId: EV_A, role: "staff"}]});
  });

  test("外部通信はEmulatorと架空mail-apiの能力確認だけ(実メール0・想定外の通信0)", () => {
    assert.deepEqual(unexpectedRequests, []);
  });
});
