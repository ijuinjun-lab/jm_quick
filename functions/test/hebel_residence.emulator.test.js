// HEBEL属性: 取込(検証 → commit)でparticipantへ保存し、受付(正式staff・受付キー)だけに表示する(Emulator + 実Admin SDK)。
//  - 列を指定した取込: participant.hebelResidence = {category, rawValue}。未知の値は許可したときだけ「未知」として保存
//  - 列を指定しない取込(既存CSV・第1回): フィールド自体を持たない。受付の応答にも出ない
//  - 第1回(属性なし)の後に第2回(属性あり)を取り込んでも、第1回の参加者は変わらない
//  - 参加証(getPass)・QRには入らない。受付操作(checkIn)はそのまま
// データはすべて架空。メールは予約TLD .invalid のみ。実ファイル・実氏名・実メールは使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {createImportApi} = require("../confirmed/import_api");
const {withValidatedCommit} = require("../test_support/validated_commit");
const {createPassApi} = require("../confirmed/pass_api");
const {createReceptionKeyApi} = require("../confirmed/reception_key_api");
const {confirmedEventCallable, confirmedPublicPassCallable, confirmedReceptionKeyCallable} = require("../auth");
const {EVENT_SCOPES} = require("../event_scope");
const {assignmentDocId} = require("../event_access");
const {publicRequest} = require("../test_support/app_check");

const silent = {warn: () => {}, info: () => {}};
const APP_BASE_URL = "https://app.invalid";
const NOT_ATTENDING = "参加を希望しない";
const HAUS = "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）";
const MAISON = "ヘーベルメゾンにお住まい";
const COLUMN = "HEBEL&#160;HAUSにお住まいですか";
const HEADERS = ["区分", "id", "氏名", "かな", "メールアドレス", COLUMN, "午前参加時間", "午前参加人数", "登録日時"];

const mapping = (hebel) => ({
  version: 1,
  participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス", registeredAtColumn: "登録日時",
    ...(hebel ? {hebelResidenceColumn: COLUMN} : {})},
  programs: [{programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NOT_ATTENDING],
    emptyMeans: "notAttending", slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数",
    ignoreCountWhenNotAttending: true}],
});
const record = (i, hebel) => ["新規申込", String(i), `架空 参加者${i}`, "かくう", `attr${i}@example.invalid`, hebel,
  "10:30-11:10", "2", "2026-09-01 10:00:00"];

describe("HEBEL属性: 取込で保存し、受付だけに表示する(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let importApi;
  let staffView;
  let deviceView;
  let staffCheckIn;
  let pass;
  let issueKey;

  const participantsOf = async (batchId) => (await db.collection("participants").where("importBatchId", "==", batchId).get())
    .docs.map((d) => d.data()).sort((a, b) => a.importRow - b.importRow);
  const ids = (p) => ({eventId: p.eventId, participantId: p.participantId, publicId: p.publicId});

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("eventAssignments").doc(assignmentDocId("event1", "u-staff")).set(
      {eventId: "event1", uid: "u-staff", role: "staff", active: true, email: "u-staff@example.invalid"});
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント(属性)", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), venue: "架空会場",
      programs: [{programId: "program-1", name: "架空の譲渡会", order: 0}],
    });
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    importApi = withValidatedCommit(createImportApi({getDb: () => db, serverTimestamp}));
    const passApi = createPassApi({getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent});
    const keyApi = createReceptionKeyApi({getDb: () => db, serverTimestamp, now: () => Date.parse("2026-11-30T00:00:00Z")});
    const view = confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, passApi.getReceptionView, {db, logger: silent});
    const checkIn = confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, passApi.checkIn, {db, logger: silent});
    const device = confirmedReceptionKeyCallable(passApi.getReceptionView,
      {db, logger: silent, now: () => Date.parse("2026-11-30T00:00:00Z")});
    const issue = confirmedEventCallable("eventStaff", EVENT_SCOPES.dataEventId, keyApi.issue, {db, logger: silent});
    const publicPass = confirmedPublicPassCallable(passApi.getPass, {logger: silent});
    staffView = (data) => view.run({auth: {uid: "u-staff"}, data});
    staffCheckIn = (data) => checkIn.run({auth: {uid: "u-staff"}, data});
    deviceView = (data) => device.run(publicRequest({data}));
    issueKey = async () => (await issue.run({auth: {uid: "u-staff"}, data: {eventId: "event1"}})).key;
    pass = (data) => publicPass.run(publicRequest({data}));
  });

  const commit = (records, {hebel, clientRequestId, approvedReviewRows, fileHash}) => importApi.commit({
    identity: {uid: "u-admin"},
    data: buildImportRequest({
      table: {headers: HEADERS, records}, mapping: mapping(hebel), eventId: "event1", clientRequestId,
      sourceFileName: hebel ? "架空.xlsx" : "架空.csv", fileHash, approvedReviewRows,
    }),
  });

  test("列を指定した取込: 分類と原文をparticipantへ保存し、正式staff・受付キーの受付画面に表示。参加証には出さない", async () => {
    const records = [record(1, HAUS), record(2, MAISON), record(3, "いいえ"), record(4, ""), record(5, "架空の未知の回答")];
    // 検証: 未知の値は確認が必要(許可するまで取り込めない)
    const validation = await importApi.validate({identity: {uid: "u-admin"}, data: buildImportRequest({
      table: {headers: HEADERS, records}, mapping: mapping(true), eventId: "event1", clientRequestId: "bfull",
      sourceFileName: "架空.xlsx", fileHash: "e".repeat(64),
    })});
    assert.deepEqual(validation.hebelResidenceSummary.map((s) => [s.category, s.count]),
      [["hebelHaus", 1], ["hebelMaison", 1], ["none", 1], ["unset", 1], ["unknown", 1]]);
    assert.deepEqual(validation.reviewRows, [6]);
    const result = await commit(records, {hebel: true, clientRequestId: "bfull", fileHash: "e".repeat(64), approvedReviewRows: [6]});
    assert.equal(result.createdCount, 5);
    const ps = await participantsOf("bfull");
    assert.deepEqual(ps.map((p) => p.hebelResidence), [
      {category: "hebelHaus", rawValue: HAUS}, {category: "hebelMaison", rawValue: MAISON},
      {category: "none", rawValue: "いいえ"}, {category: "unset", rawValue: null},
      {category: "unknown", rawValue: "架空の未知の回答"},
    ]);
    // 正式staffの受付
    const v1 = await staffView(ids(ps[0]));
    assert.deepEqual(v1.hebelResidence, {category: "hebelHaus", label: HAUS});
    const v5 = await staffView(ids(ps[4]));
    assert.deepEqual(v5.hebelResidence, {category: "unknown", label: "未知のHEBEL属性", rawValue: "架空の未知の回答"});
    assert.deepEqual((await staffView(ids(ps[3]))).hebelResidence, {category: "unset", label: "未設定（空欄）"});
    // アカウント不要の受付(受付キー): 同じ表示
    const key = await issueKey();
    const d2 = await deviceView({...ids(ps[1]), receptionKey: key});
    assert.deepEqual(d2.hebelResidence, {category: "hebelMaison", label: MAISON});
    // 受付操作は従来どおり
    const checked = await staffCheckIn({...ids(ps[1]), programId: "program-1", attendedCount: 2});
    assert.equal(checked.program.checkedIn, true);
    // 参加証(本人向け)・QRには入らない
    const p = await pass({participantId: ps[0].participantId, publicId: ps[0].publicId});
    const text = JSON.stringify(p);
    for (const word of ["hebel", "ヘーベル", "HEBEL"]) assert.equal(text.includes(word), false, word);
    assert.equal(p.qrPayload, `${APP_BASE_URL}/reception?eventId=event1&participantId=${ps[0].participantId}&publicId=${ps[0].publicId}`);
  });

  test("後方互換: 列を指定しない取込(既存CSV・第1回)はフィールドを持たず、受付にも出ない。第2回で属性ありを取り込んでも第1回は変わらない", async () => {
    // 第1回: 既存CSV相当(HEBEL属性の列を指定しない。同じ列の値があっても読まない)
    await commit([record(1, HAUS), record(2, "いいえ")], {hebel: false, clientRequestId: "bfirst", fileHash: "1".repeat(64)});
    const first = await participantsOf("bfirst");
    assert.ok(first.every((p) => !("hebelResidence" in p)));
    const before = JSON.stringify(first);
    const v = await staffView(ids(first[0]));
    assert.equal("hebelResidence" in v, false);
    assert.equal(v.participantName, "架空 参加者1");
    // 第2回: Excel(属性あり。別の申込者)
    await commit([record(3, MAISON)], {hebel: true, clientRequestId: "bsecond", fileHash: "2".repeat(64)});
    const second = await participantsOf("bsecond");
    assert.deepEqual(second[0].hebelResidence, {category: "hebelMaison", rawValue: MAISON});
    assert.equal(JSON.stringify(await participantsOf("bfirst")), before);
    // 受付キー経由でも、属性の無い第1回の参加者には出ない
    const key = await issueKey();
    assert.equal("hebelResidence" in await deviceView({...ids(first[1]), receptionKey: key}), false);
  });

  test("取込の監査行(importBatches/rows)・取込回には、HEBEL属性の原文を複製しない", async () => {
    await commit([record(1, HAUS)], {hebel: true, clientRequestId: "baudit", fileHash: "3".repeat(64)});
    const rows = await db.collection("importBatches").doc("baudit").collection("rows").get();
    const batch = (await db.collection("importBatches").doc("baudit").get()).data();
    const text = JSON.stringify([batch, ...rows.docs.map((d) => d.data())]);
    assert.equal(text.includes(HAUS), false);
  });
});
