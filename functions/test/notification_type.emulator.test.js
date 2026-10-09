// 通常当選/キャンセル待ち繰り上げ当選: 実際のindex.js(認可つき)+ Emulator + 実Admin SDK。実メールは送らない(ジョブの作成まで)。
//  - 通常当選: 区分=キャンセルを自動除外(管理者は除外しない)。取込回に通知種別normal。監査行に自動除外を記録(氏名等は複製しない)
//  - 繰り上げ当選: シート名・キャンセル待希望枠・希望人数から繰り上げ先を自動判定。トークショー等は作らない。通知種別waitlistPromotion
//  - 判定不能は止める・通知種別の改ざんは拒否・二重/並列のcommitでも1回だけ
//  - 送信ジョブは取込回の正本の通知種別でテンプレートを決め、ジョブ・配送記録に固定する。既存の取込回(項目なし)は通常当選
//  - 受付・最終実績(通知種別)も確認する
// データはすべて架空。メールは予約TLD .invalid のみ。実ファイル・実氏名・実メールは使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {validatedCommitRun} = require("../test_support/validated_commit");
const {assignmentDocId} = require("../event_access");
const normalPreset = require("../confirmed/sippo_mail_preset");
const waitlistPreset = require("../confirmed/sippo_waitlist_mail_preset");

const EV = "evNotify0123456789";
const NO = "参加を希望しない";
const HEADERS = ["区分", "氏名", "かな", "メールアドレス", "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数",
  "トークショー", "トークショー人数", "キャンセル待希望枠", "キャンセル待希望人数"];
const DOG_ALL = "午後の部（犬）14:10-14:50,午後の部（犬）14:50-15:30,午後の部（犬）15:30-16:10";
const programs = () => [
  {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NO], emptyMeans: "notAttending",
    slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数", ignoreCountWhenNotAttending: true},
  {programId: "program-2", participationColumn: "午後参加時間", notAttendingValues: [NO], emptyMeans: "notAttending",
    slotColumn: "午後参加時間", slotFormat: "label", countColumn: "午後参加人数", ignoreCountWhenNotAttending: true},
  {programId: "program-3", participationColumn: "トークショー", attendingValues: ["参加を希望する"], notAttendingValues: [NO],
    emptyMeans: "notAttending", countColumn: "トークショー人数", ignoreCountWhenNotAttending: true},
];
const WAITLIST = {optionsColumn: "キャンセル待希望枠", countColumn: "キャンセル待希望人数",
  options: [{label: "午前の部（猫）", programId: "program-1", kind: "猫"}, {label: "午後の部（犬）", programId: "program-2", kind: "犬"}]};
const mapping = ({cancel = true, waitlist = false} = {}) => ({
  version: 1, participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス"},
  ...(cancel ? {autoExcludeRows: [{column: "区分", values: ["キャンセル"]}]} : {}), ...(waitlist ? {waitlist: WAITLIST} : {}),
  programs: programs(),
});
// 1行: [区分, 氏名, かな, メール, 午前時間, 午前人数, 午後時間, 午後人数, トーク, トーク人数, 待ち枠, 待ち人数]
const rec = (i, category, {am = NO, amN = "", pm = NO, pmN = "", talk = NO, talkN = "", wait = "", waitN = ""} = {}) =>
  [category, `架空 参加者${i}`, "かくう", `notify${i}@example.invalid`, am, amN, pm, pmN, talk, talkN, wait, waitN];
const outcome = (p) => p.then(() => "ok", (e) => (e.details && e.details.code) || e.code || String(e));
const TEMPLATE = (p) => ({subject: p.subject, introBody: p.introBody, closingBody: p.closingBody, notesBody: p.notesBody, adoptionNotesBody: p.adoptionNotesBody});

describe("通常当選/キャンセル待ち繰り上げ当選(Emulator + 実際のindex.js)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  const as = (uid, data) => ({auth: {uid}, data});
  const req = (records, {clientRequestId, waitlist = false, sheet, sheets, file, cancel = true, extra = {}}) => buildImportRequest({
    table: {headers: HEADERS, records}, mapping: mapping({cancel, waitlist}), eventId: EV, clientRequestId,
    sourceFileName: file || (waitlist ? "【犬15時30分～16時10分】架空の繰り上げリスト.xlsx" : "架空の申込リスト.xlsx"),
    fileHash: clientRequestId.replace(/[^0-9a-f]/g, "a").padEnd(64, "0").slice(0, 64),
    extra: {...(waitlist ? {notificationType: "waitlistPromotion", sourceSheetName: sheet || "15時30分～16時10分",
      sourceSheetCandidates: sheets || [sheet || "15時30分～16時10分"]} : {}), ...extra},
  });
  const commit = (data) => validatedCommitRun(index)(as("u-admin", data));
  const participantsOf = async (batchId) => (await db.collection("participants").where("importBatchId", "==", batchId).get())
    .docs.map((d) => d.data()).sort((a, b) => a.importRow - b.importRow);
  const attendancesOf = async (participantId) => (await db.collection("programAttendances").where("participantId", "==", participantId).get())
    .docs.map((d) => d.data());

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("eventAssignments").doc(assignmentDocId(EV, "u-staff")).set(
      {eventId: EV, uid: "u-staff", role: "staff", active: true, email: "u-staff@example.invalid", assignedBy: "u-admin"});
    await db.collection("events").doc(EV).set({
      eventId: EV, eventName: "架空イベント(通知種別)", senderName: "架空事務局", flow: "confirmed", contact: "架空事務局",
      startAt: env.Timestamp.fromDate(new Date("2026-11-29T01:00:00Z")), venue: "架空会場",
      programs: [{programId: "program-1", name: "架空の譲渡会（ねこ）", order: 0}, {programId: "program-2", name: "架空の譲渡会（いぬ）", order: 1},
        {programId: "program-3", name: "架空トーク", order: 2}],
      winnerMailTemplate: {...TEMPLATE(normalPreset), version: 1, updatedBy: "u-admin"}, reminderEnabled: false,
    });
  });

  test("通常当選: 区分=キャンセルは自動除外(参加者を作らない)。取込回はnormal。監査行に自動除外(氏名等は複製しない)", async () => {
    const records = [rec(1, "新規申込", {am: "10:30-11:10", amN: "2"}), rec(2, "キャンセル"), rec(3, "変更", {pm: "14:10-14:50", pmN: "1"})];
    const data = req(records, {clientRequestId: "bnormal"});
    const v = await index.validateConfirmedImport.run(as("u-admin", data));
    assert.equal(v.notificationType, "normal");
    assert.equal(v.autoExcludedRowCount, 1);
    assert.deepEqual(v.autoExcludedRows, [3]);
    assert.equal(v.importRowCount, 2);
    assert.equal(v.rows.find((r) => r.sourceRowNumber === 3).autoExcluded, true);
    assert.deepEqual(v.reviewRows, [], "キャンセル行(参加なし)を確認待ちにしない");
    const result = await commit(data);
    assert.equal(result.createdCount, 2);
    const batch = (await db.collection("importBatches").doc("bnormal").get()).data();
    assert.equal(batch.notificationType, "normal");
    assert.equal(batch.autoExcludedCount, 1);
    assert.equal((await participantsOf("bnormal")).length, 2);
    const audit = (await db.collection("importBatches").doc("bnormal").collection("rows").get()).docs.map((d) => d.data())
      .find((r) => r.sourceRowNumber === 3);
    assert.equal(audit.result, "excluded");
    assert.equal(audit.autoExcluded, true);
    assert.equal(audit.excludedByOperator, false);
    assert.equal(audit.excludedBy, "system:auto-exclusion");
    assert.match(audit.excludedReason, /原本でキャンセル/);
    assert.equal(JSON.stringify(audit).includes("架空 参加者2"), false, "監査行に氏名を複製しない");
  });

  test("繰り上げ当選: 繰り上げ先を自動判定(提出なし=対象、キャンセル=除外)。トークショー・午前は作らない。取込回はwaitlistPromotion", async () => {
    const records = [
      rec(1, "提出なし", {talk: "参加を希望する", talkN: "1", wait: DOG_ALL, waitN: "1名"}),
      rec(2, "提出なし", {wait: DOG_ALL, waitN: "2名"}),
      rec(3, "提出なし", {amN: "3", wait: DOG_ALL, waitN: "3名"}),
      rec(4, "キャンセル", {wait: DOG_ALL, waitN: "2名"}),
    ];
    const data = req(records, {clientRequestId: "bwait", waitlist: true});
    const v = await index.validateConfirmedImport.run(as("u-admin", data));
    assert.equal(v.notificationType, "waitlistPromotion");
    assert.deepEqual(v.waitlistPromotion, {programId: "program-2", slotLabel: "15:30-16:10", kind: "犬",
      rows: [{sourceRowNumber: 2, plannedCount: 1}, {sourceRowNumber: 3, plannedCount: 2}, {sourceRowNumber: 4, plannedCount: 3}]});
    assert.equal(v.autoExcludedRowCount, 1);
    assert.equal(v.importRowCount, 3);
    const result = await commit(data);
    assert.equal(result.createdCount, 3);
    const batch = (await db.collection("importBatches").doc("bwait").get()).data();
    assert.equal(batch.notificationType, "waitlistPromotion");
    assert.deepEqual(batch.waitlistPromotion, {programId: "program-2", slotLabel: "15:30-16:10", sourceSheetName: "15時30分～16時10分"});
    const people = await participantsOf("bwait");
    const attendances = await Promise.all(people.map((p) => attendancesOf(p.participantId)));
    assert.deepEqual(attendances.map((list) => list.map((a) => [a.programId, a.slotLabel, a.plannedCount])),
      [[["program-2", "15:30-16:10", 1]], [["program-2", "15:30-16:10", 2]], [["program-2", "15:30-16:10", 3]]]);
  });

  test("繰り上げ当選: 一意に判定できなければ止める(何も書かない)。通知種別・シート名の改ざんは拒否", async () => {
    const records = [rec(1, "提出なし", {wait: DOG_ALL, waitN: "2名"})];
    for (const [label, data] of [
      ["シート名が時間枠でない", req(records, {clientRequestId: "bbad1", waitlist: true, sheet: "申込情報"})],
      ["時間枠が希望枠に無い", req([rec(1, "提出なし", {wait: "午後の部（犬）14:10-14:50", waitN: "2名"})], {clientRequestId: "bbad2", waitlist: true})],
      ["人数が空", req([rec(1, "提出なし", {wait: DOG_ALL})], {clientRequestId: "bbad3", waitlist: true})],
      ["ファイル名の種別と矛盾", req(records, {clientRequestId: "bbad4", waitlist: true, file: "【猫15時30分～16時10分】架空.xlsx"})],
      ["全員キャンセル", req([rec(1, "キャンセル", {wait: DOG_ALL, waitN: "1名"})], {clientRequestId: "bbad5", waitlist: true})],
    ]) {
      assert.equal(await outcome(index.validateConfirmedImport.run(as("u-admin", data))), "waitlist-undetermined", label);
      assert.equal(await outcome(commit(data)), "waitlist-undetermined", label);
    }
    assert.equal((await db.collection("importBatches").get()).size, 0, "何も書かない");
    // 改ざん: 検証は繰り上げ、確定時にシート名を変える → 指紋が一致しない(再検証が必要)
    const data = req(records, {clientRequestId: "btamper", waitlist: true});
    const v = await index.validateConfirmedImport.run(as("u-admin", data));
    const forged = {...data, sourceSheetName: "15:30-16:10", sourceSheetCandidates: ["15:30-16:10"], expectedImportSequence: v.expectedImportSequence,
      validationFingerprint: v.validationFingerprint, approvalKeys: []};
    assert.equal(await outcome(index.commitConfirmedImport.run(as("u-admin", forged))), "import-state-changed");
    // 改ざん: 通知種別をnormalにする(mappingの判定規則と対にならない)
    const {notificationType, sourceSheetName, sourceSheetCandidates, ...asNormal} = forged; // eslint-disable-line no-unused-vars
    assert.equal(await outcome(index.commitConfirmedImport.run(as("u-admin", asNormal))), "notification-type-mapping-mismatch");
    assert.equal((await db.collection("importBatches").get()).size, 0);
  });

  test("繰り上げ当選: 対象のシートが複数のファイルから1枚だけを選んで送っても、検証・確定できない(API直呼び・改ざんを含む)", async () => {
    const records = [rec(1, "提出なし", {wait: DOG_ALL, waitN: "2名"})];
    const twoSheets = ["14時10分～14時50分", "15時30分～16時10分"];
    const reasonsOf = async (promise) => {
      try {
        await promise;
        return null;
      } catch (error) {
        return error.details;
      }
    };
    // 複数シートのファイル(シートの一覧が2枚)で、そのうち1枚を選んだ要求 → 検証もcommitも止まる
    const multi = req(records, {clientRequestId: "bmulti", waitlist: true, sheets: twoSheets});
    const details = await reasonsOf(index.validateConfirmedImport.run(as("u-admin", multi)));
    assert.equal(details.code, "waitlist-undetermined");
    assert.deepEqual(details.reasons, [{code: "multiple-sheets", sheetCount: 2}]);
    assert.equal(await outcome(commit(multi)), "waitlist-undetermined");
    // シートの一覧を送らない・選んだシートが一覧に無い要求も止まる
    const {sourceSheetCandidates, ...withoutList} = multi; // eslint-disable-line no-unused-vars
    assert.equal(await outcome(commit({...withoutList, clientRequestId: "bmulti"})), "waitlist-undetermined");
    assert.equal(await outcome(commit({...multi, sourceSheetCandidates: ["14時10分～14時50分"]})), "waitlist-undetermined");
    // 改ざん: 1枚として検証 → 確定時にシートの一覧を変える → 指紋が一致しない / 2枚なら判定しない
    const single = req(records, {clientRequestId: "bsingle", waitlist: true});
    const v = await index.validateConfirmedImport.run(as("u-admin", single));
    const base = {...single, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint, approvalKeys: []};
    assert.equal(await outcome(index.commitConfirmedImport.run(as("u-admin", {...base, sourceSheetCandidates: twoSheets}))),
      "waitlist-undetermined");
    assert.equal(await outcome(index.commitConfirmedImport.run(as("u-admin", {...base, sourceSheetCandidates: ["15時30分～16時10分", "別のシート"]}))),
      "waitlist-undetermined");
    // 通常当選の要求にシートの一覧を混ぜることもできない
    assert.equal(await outcome(index.validateConfirmedImport.run(as("u-admin",
      {...req([rec(1, "新規申込", {am: "10:30-11:10", amN: "1"})], {clientRequestId: "bnormalsheets"}), sourceSheetCandidates: ["申込情報"]}))),
    "invalid-source-sheet-candidates");
    assert.equal((await db.collection("importBatches").get()).size, 0, "何も書かない");
    assert.equal((await db.collection("participants").get()).size, 0);
    // 1枚のファイルとして検証した内容は、そのまま確定できる(正常系)
    const ok = await index.commitConfirmedImport.run(as("u-admin", base));
    assert.equal(ok.batchId, "bsingle");
  });

  test("二重・並列のcommit: 同じ内容は1回だけ取り込まれる(参加者は増えない)", async () => {
    const data = req([rec(1, "提出なし", {wait: DOG_ALL, waitN: "2名"}), rec(2, "提出なし", {wait: DOG_ALL, waitN: "1名"})],
      {clientRequestId: "bconc", waitlist: true});
    const v = await index.validateConfirmedImport.run(as("u-admin", data));
    const full = {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      approvalKeys: v.rows.flatMap((r) => Object.values(r.approvalKeys || {}))};
    const results = await Promise.allSettled([1, 2, 3].map(() => index.commitConfirmedImport.run(as("u-admin", full))));
    assert.ok(results.some((r) => r.status === "fulfilled"));
    const again = await index.commitConfirmedImport.run(as("u-admin", full));
    assert.equal(again.idempotentReplay, true);
    assert.equal((await participantsOf("bconc")).length, 2);
    assert.equal((await db.collection("importBatches").get()).size, 1);
  });

  test("送信ジョブ: 取込回の正本の通知種別でテンプレートを決め、ジョブ・配送記録に固定。既存の取込回(項目なし)は通常当選", async () => {
    await commit(req([rec(1, "新規申込", {am: "10:30-11:10", amN: "1"})], {clientRequestId: "bjobnormal"}));
    await commit(req([rec(2, "提出なし", {wait: DOG_ALL, waitN: "2名"})], {clientRequestId: "bjobwait", waitlist: true}));
    // 繰り上げ当選メールが未設定なら、繰り上げの取込回にはジョブを作らない(通常当選メールで代用しない)
    assert.equal(await outcome(index.createConfirmedWinnerMailJob.run(as("u-admin", {eventId: EV, batchId: "bjobwait"}))), "mail-not-ready");
    const saved = await index.updateConfirmedWinnerMailTemplate.run(as("u-admin",
      {eventId: EV, notificationType: "waitlistPromotion", template: TEMPLATE(waitlistPreset)}));
    assert.equal(saved.version, 1);
    // 繰り上げ用の保存は会場等のイベント共通設定を受け付けない(通常当選メールの設定はそのまま)
    assert.equal(await outcome(index.updateConfirmedWinnerMailTemplate.run(as("u-admin",
      {eventId: EV, notificationType: "waitlistPromotion", template: TEMPLATE(waitlistPreset), venueInfo: {address: "x", access: "y"}}))), "waitlist-template-only");
    const event = (await db.collection("events").doc(EV).get()).data();
    assert.equal(event.winnerMailTemplate.version, 1, "通常当選メールは変わらない");
    assert.equal(event.winnerMailTemplate.subject, normalPreset.subject);

    const list = await index.listConfirmedWinnerMailBatches.run(as("u-admin", {eventId: EV}));
    const byId = Object.fromEntries(list.batches.map((b) => [b.batchId, b]));
    assert.equal(byId.bjobnormal.notificationType, "normal");
    assert.equal(byId.bjobnormal.notificationTypeLabel, "通常当選");
    assert.equal(byId.bjobwait.notificationType, "waitlistPromotion");
    assert.equal(byId.bjobwait.mail.subject, waitlistPreset.subject);

    await index.createConfirmedWinnerMailJob.run(as("u-admin", {eventId: EV, batchId: "bjobwait", expectedTemplateVersion: 1}));
    await index.createConfirmedWinnerMailJob.run(as("u-admin", {eventId: EV, batchId: "bjobnormal", expectedTemplateVersion: 1}));
    const waitJob = (await db.collection("sendJobs").doc("winner-bjobwait").get()).data();
    assert.equal(waitJob.notificationType, "waitlistPromotion");
    assert.equal(waitJob.templateField, "waitlistWinnerMailTemplate");
    assert.equal(waitJob.snapshot.template.subject, waitlistPreset.subject);
    assert.match(waitJob.snapshot.template.introBody, /キャンセル待ちで承っておりましたお席のご用意ができましたので、ご連絡申し上げます。/);
    const normalJob = (await db.collection("sendJobs").doc("winner-bjobnormal").get()).data();
    assert.equal(normalJob.notificationType, "normal");
    assert.equal(normalJob.snapshot.template.subject, normalPreset.subject);
    const waitPeople = await participantsOf("bjobwait");
    const delivery = (await db.collection("mailDeliveries").doc(`${waitPeople[0].participantId}_winner`).get()).data();
    assert.equal(delivery.notificationType, "waitlistPromotion");
    // クライアントからテンプレート・通知種別を指定させない
    assert.equal(await outcome(index.createConfirmedWinnerMailJob.run(as("u-admin",
      {eventId: EV, batchId: "bjobwait", notificationType: "normal"}))), "unknown-key");

    // 既存の取込回(通知種別の項目なし)は通常当選として扱う
    await db.collection("importBatches").doc("bjobnormal").update({notificationType: env.FieldValue.delete()});
    const legacy = (await index.listConfirmedWinnerMailBatches.run(as("u-admin", {eventId: EV}))).batches.find((b) => b.batchId === "bjobnormal");
    assert.equal(legacy.notificationType, "normal");
  });

  test("プレビュー・QR・受付・最終実績: 繰り上げの参加者も通常と同じQR・受付。最終実績に通知種別", async () => {
    await commit(req([rec(1, "新規申込", {am: "10:30-11:10", amN: "1"})], {clientRequestId: "bpnormal"}));
    await commit(req([rec(2, "提出なし", {talk: "参加を希望する", talkN: "1", wait: DOG_ALL, waitN: "2名"})], {clientRequestId: "bpwait", waitlist: true}));
    await index.updateConfirmedWinnerMailTemplate.run(as("u-admin", {eventId: EV, notificationType: "waitlistPromotion", template: TEMPLATE(waitlistPreset)}));
    const [waitPerson] = await participantsOf("bpwait");
    const [normalPerson] = await participantsOf("bpnormal");
    const wp = await index.previewConfirmedWinnerMail.run(as("u-admin", {eventId: EV, participantId: waitPerson.participantId}));
    assert.equal(wp.notificationType, "waitlistPromotion");
    assert.equal(wp.subject, waitlistPreset.subject);
    assert.match(wp.text, /キャンセル待ちで承っておりましたお席のご用意ができましたので、ご連絡申し上げます。/);
    assert.match(wp.text, /架空の譲渡会（いぬ）/);
    assert.doesNotMatch(wp.text, /架空トーク/, "トークショーを当選に含めない");
    assert.equal(wp.qrPayload, `https://app.invalid/reception?eventId=${EV}&participantId=${waitPerson.participantId}&publicId=${encodeURIComponent(waitPerson.publicId)}`);
    const np = await index.previewConfirmedWinnerMail.run(as("u-admin", {eventId: EV, participantId: normalPerson.participantId}));
    assert.equal(np.notificationType, "normal");
    assert.equal(np.subject, normalPreset.subject);
    // 受付(正式staff)は通常と同じ
    const ids = {eventId: EV, participantId: waitPerson.participantId, publicId: waitPerson.publicId};
    const view = await index.getConfirmedReceptionView.run(as("u-staff", ids));
    assert.deepEqual(view.programs.map((p) => [p.programId, p.timeText, p.plannedCount]), [["program-2", "15:30-16:10", 2]]);
    const checked = await index.checkInConfirmedProgram.run(as("u-staff", {...ids, programId: "program-2", attendedCount: 2}));
    assert.equal(checked.program.checkedIn, true);
    // 最終実績
    const report = await index.getConfirmedAttendanceReport.run(as("u-admin", {eventId: EV}));
    assert.deepEqual(report.participants.map((p) => [p.importSequence, p.notificationType]), [[1, "normal"], [2, "waitlistPromotion"]]);
  });
});
