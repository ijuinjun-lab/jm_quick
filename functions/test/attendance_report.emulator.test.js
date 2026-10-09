// 最終実績(getConfirmedAttendanceReport): 実際のindex.js(認可つき)+ Emulator + 実Admin SDK。
//  - 第5回相当の10名(HEBEL: ハウス3・メゾン2・いいえ5)+ 未知・空欄・属性なし(列の無い取込)・同じメールの別参加者
//  - 受付済み/未受付・複数program・人数訂正・受付取消を、正式な受付API(index.js)で作ってから出力を確認する
//  - 権限: system admin・担当event_managerだけ。staff・他イベント・未任命・受付キー(アカウント不要)は拒否
//  - 読み取りのみ(呼び出しの前後でFirestoreの内容が変わらない)
// データはすべて架空。メールは予約TLD .invalid のみ。実ファイル・実氏名・実メールは使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {validatedCommitRun} = require("../test_support/validated_commit");
const {publicRequest} = require("../test_support/app_check");
const {assignmentDocId} = require("../event_access");

const EV = "evReport0123456789";
const EV_OTHER = "evReportOther01234";
const EV_EMPTY = "evReportEmpty01234";
const NO = "参加を希望しない";
const HAUS = "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）";
const MAISON = "ヘーベルメゾンにお住まい";
const COLUMN = "HEBEL&#160;HAUSにお住まいですか";
const HEADERS = ["区分", "id", "氏名", "かな", "メールアドレス", COLUMN, "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数",
  "トークショー", "トークショー人数", "登録日時"];
const mapping = (hebel) => ({
  version: 1,
  participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス", registeredAtColumn: "登録日時",
    ...(hebel ? {hebelResidenceColumn: COLUMN} : {})},
  programs: [
    {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NO], emptyMeans: "notAttending",
      slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数", ignoreCountWhenNotAttending: true},
    {programId: "program-2", participationColumn: "午後参加時間", notAttendingValues: [NO], emptyMeans: "notAttending",
      slotColumn: "午後参加時間", slotFormat: "label", countColumn: "午後参加人数", ignoreCountWhenNotAttending: true},
    {programId: "program-3", participationColumn: "トークショー", attendingValues: ["参加を希望する"], notAttendingValues: [NO],
      emptyMeans: "notAttending", countColumn: "トークショー人数", ignoreCountWhenNotAttending: true},
  ],
});
// i番目の架空参加者。program-1: 1〜6、program-2: 4〜10、program-3: 1・5・9
const record = (i, hebel, email = `report${i}@example.invalid`) => ["新規申込", String(i), `架空 参加者${i}`, "かくう", email, hebel,
  i <= 6 ? "10:30-11:10" : NO, "2", i >= 4 ? "14:10-14:50" : NO, "3", [1, 5, 9].includes(i) ? "参加を希望する" : NO, "1",
  "2026-09-01 10:00:00"];
const FIFTH = [HAUS, HAUS, HAUS, MAISON, MAISON, "いいえ", "いいえ", "いいえ", "いいえ", "いいえ"];
const outcome = (promise) => promise.then(() => "ok", (error) => error.code || String(error));

describe("最終実績(getConfirmedAttendanceReport)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  const as = (uid, data) => ({auth: {uid}, data});
  const report = (uid, eventId = EV) => index.getConfirmedAttendanceReport.run(as(uid, {eventId}));
  const seedEvent = (eventId) => db.collection("events").doc(eventId).set({
    eventId, eventName: "架空イベント/最終実績:テスト", senderName: "架空事務局", flow: "confirmed",
    startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), venue: "架空会場",
    // 配列の順ではなくorder順に並ぶこと
    programs: [{programId: "program-3", name: "架空トーク", order: 2}, {programId: "program-1", name: "架空の譲渡会A", order: 0},
      {programId: "program-2", name: "架空の譲渡会B", order: 1}],
  });
  const commit = (records, {hebel, clientRequestId, approvedReviewRows, extra = {}}) => validatedCommitRun(index)(as("u-admin", buildImportRequest({
    table: {headers: HEADERS, records}, mapping: mapping(hebel), eventId: EV, clientRequestId,
    sourceFileName: hebel ? "架空.xlsx" : "架空.csv", fileHash: clientRequestId.padEnd(64, "0").slice(0, 64).replace(/[^0-9a-f]/g, "a"),
    approvedReviewRows, extra,
  })));
  const participantsOf = async (batchId) => (await db.collection("participants").where("importBatchId", "==", batchId).get())
    .docs.map((d) => d.data()).sort((a, b) => a.importRow - b.importRow);
  const target = (p, programId) => ({eventId: EV, participantId: p.participantId, publicId: p.publicId, programId});
  const dump = async () => {
    const out = {};
    for (const name of ["participants", "programAttendances", "importBatches", "events"]) {
      out[name] = (await db.collection(name).get()).docs.map((d) => [d.id, d.data()]).sort();
    }
    return JSON.stringify(out);
  };

  let fifth;
  let second;
  let third;

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    for (const [eventId, uid, role] of [[EV, "u-mgr", "event_manager"], [EV, "u-staff", "staff"], [EV_OTHER, "u-mgr-other", "event_manager"]]) {
      await db.collection("eventAssignments").doc(assignmentDocId(eventId, uid)).set(
        {eventId, uid, role, active: true, email: `${uid}@example.invalid`, assignedBy: "u-admin"});
    }
    await seedEvent(EV);
    await seedEvent(EV_OTHER);
    await seedEvent(EV_EMPTY);
    // 第1回: 第5回相当の10名(HEBEL列あり)
    await commit(FIFTH.map((h, i) => record(i + 1, h)), {hebel: true, clientRequestId: "bfifth"});
    // 第2回: 未知(許可して取込)・空欄(HEBEL列あり)
    await commit([record(11, "架空の未知の回答"), record(12, "")], {hebel: true, clientRequestId: "bsecond", approvedReviewRows: [2]});
    // 第3回: HEBEL列なし(属性なし)。1件は第1回の1人目と同じメールアドレス(別participantとして取り込む)
    await commit([record(13, HAUS, "report1@example.invalid"), record(14, "")], {hebel: false, clientRequestId: "bthird",
      extra: {acknowledgeExistingEmailDuplicates: true}});
    fifth = await participantsOf("bfifth");
    second = await participantsOf("bsecond");
    third = await participantsOf("bthird");
    // 正式な受付API(index.js)で受付・訂正・取消を作る
    const run = (name, data) => index[name].run(as("u-staff", data));
    await run("checkInConfirmedProgram", {...target(fifth[0], "program-1"), attendedCount: 2});
    await run("correctConfirmedProgramAttendance", {...target(fifth[0], "program-1"), attendedCount: 3});
    await run("checkInConfirmedProgram", {...target(fifth[0], "program-3"), attendedCount: 1});
    await run("checkInConfirmedProgram", {...target(fifth[1], "program-1"), attendedCount: 2});
    await run("cancelConfirmedProgramCheckIn", target(fifth[1], "program-1"));
    await run("checkInConfirmedProgram", {...target(fifth[4], "program-2"), attendedCount: 4});
  });

  test("参加者全員(未来場・属性なし・同じメールの別participantを含む)を、取込回→行番号の順に返す", async () => {
    const r = await report("u-mgr");
    assert.equal(r.eventId, EV);
    assert.equal(r.eventName, "架空イベント/最終実績:テスト");
    assert.deepEqual(r.programs.map((p) => [p.programId, p.name]), [["program-1", "架空の譲渡会A"], ["program-2", "架空の譲渡会B"], ["program-3", "架空トーク"]]);
    assert.equal(r.participants.length, 14);
    assert.deepEqual(r.participants.map((p) => p.importSequence), [...Array(10).fill(1), 2, 2, 3, 3]);
    assert.ok(r.participants.every((p) => p.batchCommitted === true && p.status === "active"));
    assert.deepEqual(r.participants.map((p) => p.participantId),
      [...fifth, ...second, ...third].map((p) => p.participantId));
    const same = r.participants.filter((p) => p.email === "report1@example.invalid");
    assert.equal(same.length, 2, "同じメールアドレスでも別participantとして2行");
    assert.notEqual(same[0].participantId, same[1].participantId);
  });

  test("HEBEL属性: ハウス3・メゾン2・いいえ5・未知(原文つき)・空欄、属性なしはフィールド自体なし", async () => {
    const r = await report("u-admin");
    const counts = {};
    for (const p of r.participants) {
      const key = p.hebelResidence ? p.hebelResidence.category : "(なし)";
      counts[key] = (counts[key] || 0) + 1;
    }
    assert.deepEqual(counts, {hebelHaus: 3, hebelMaison: 2, none: 5, unknown: 1, unset: 1, "(なし)": 2});
    assert.deepEqual(r.participants[0].hebelResidence, {category: "hebelHaus", label: HAUS});
    assert.deepEqual(r.participants[3].hebelResidence, {category: "hebelMaison", label: MAISON});
    assert.deepEqual(r.participants[5].hebelResidence, {category: "none", label: "該当なし（いいえ）"});
    assert.deepEqual(r.participants[10].hebelResidence, {category: "unknown", label: "未知のHEBEL属性", rawValue: "架空の未知の回答"});
    assert.deepEqual(r.participants[11].hebelResidence, {category: "unset", label: "未設定（空欄）"});
    assert.equal("hebelResidence" in r.participants[12], false);
  });

  test("受付結果: 予定人数・予定時間・受付済み(訂正後の人数・受付時刻)・取消は未受付・複数programの横展開", async () => {
    const r = await report("u-mgr");
    const programsOf = (i) => Object.fromEntries(r.participants[i].programs.map((p) => [p.programId, p]));
    const p1 = programsOf(0);
    assert.deepEqual(Object.keys(p1).sort(), ["program-1", "program-3"]);
    assert.equal(p1["program-1"].plannedCount, 2);
    assert.equal(p1["program-1"].timeText, "10:30-11:10");
    assert.equal(p1["program-1"].checkedIn, true);
    assert.equal(p1["program-1"].attendedCount, 3, "訂正後の最新の人数");
    assert.match(p1["program-1"].checkedInAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
    assert.equal(p1["program-3"].checkedIn, true);
    assert.equal(p1["program-3"].attendedCount, 1);
    assert.equal(p1["program-3"].timeText, null);
    const p2 = programsOf(1);
    assert.deepEqual(p2["program-1"], {programId: "program-1", plannedCount: 2, timeText: "10:30-11:10", checkedIn: false,
      attendedCount: null, checkedInAt: null}, "受付取消は未受付");
    const p5 = programsOf(4);
    assert.deepEqual(Object.keys(p5).sort(), ["program-1", "program-2", "program-3"]);
    assert.equal(p5["program-2"].attendedCount, 4);
    assert.equal(p5["program-2"].plannedCount, 3);
    assert.equal(p5["program-1"].checkedIn, false);
    // 受付が1件もない参加者(未来場)も、予定のprogramは全部出る
    const p10 = programsOf(9);
    assert.deepEqual(Object.keys(p10), ["program-2"]);
    assert.equal(p10["program-2"].checkedIn, false);
    const checkedIn = r.participants.flatMap((p) => p.programs.filter((a) => a.checkedIn)).length;
    assert.equal(checkedIn, 3);
  });

  test("権限: system admin・担当event_managerだけ。staff・他イベントのmanager・未任命・未ログイン・受付キーは拒否", async () => {
    assert.equal(await outcome(report("u-admin")), "ok");
    assert.equal(await outcome(report("u-mgr")), "ok");
    for (const uid of ["u-staff", "u-mgr-other", "u-nobody"]) assert.equal(await outcome(report(uid)), "permission-denied", uid);
    assert.equal(await outcome(report("u-mgr", EV_OTHER)), "permission-denied", "担当外のイベント");
    // アカウント不要の受付端末(受付キー+App Check、ログインなし)からは呼べない
    const key = (await index.issueReceptionStaffKey.run(as("u-staff", {eventId: EV}))).key;
    assert.equal(await outcome(index.getConfirmedAttendanceReport.run(publicRequest({data: {eventId: EV, receptionKey: key}}))), "unauthenticated");
    assert.equal(await outcome(index.getConfirmedAttendanceReport.run(as("u-admin", {eventId: EV, extra: 1}))), "invalid-argument");
  });

  test("読み取りのみ: 呼び出しの前後でFirestoreの内容が変わらない。0 participantのイベントは列だけ", async () => {
    const before = await dump();
    await report("u-admin");
    await report("u-mgr");
    assert.equal(await dump(), before);
    const empty = await report("u-admin", EV_EMPTY);
    assert.deepEqual(empty.participants, []);
    assert.equal(empty.programs.length, 3);
  });
});
