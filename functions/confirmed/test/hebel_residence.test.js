// HEBEL属性(受付の確認用)。データはすべて架空。
//  - 分類: 申込フォームの選択肢を区別する(booleanにしない)。空欄=未設定(問題にしない)。未知の値は丸めずreview
//  - mapping: 列の指定は任意。指定しないmappingの正規化結果・ハッシュは従来と同じ(既存の取込回の冪等性を壊さない)
//  - 検証: 行ごとの分類と分類別の件数(除外した行は数えない)。修正できる列
//  - 受付: participant正本から表示用の形を作る。フィールドの無い既存participantは返さない
//  - メール・Web参加証・QRには入らない
const {test} = require("node:test");
const assert = require("node:assert/strict");
const {
  HEBEL_RESIDENCE, CATEGORY_ORDER, classifyHebelResidence, hebelResidenceSummary, hebelResidenceView,
} = require("../hebel_residence");
const {normalizeImportMapping, mappedColumns, validateImportMapping} = require("../import_mapping");
const {planImportRows} = require("../import_rows");
const {validateImportPlan, contentHash} = require("../import_validation");
const {parseImportRequest, requestHash, correctableColumns} = require("../import_request");
const {planImportBatchFromRows} = require("../import_batch_plan");
const {buildMailSnapshot} = require("../mail_view_model");
const {renderWinnerMail, renderReminderMail} = require("../mail_render");
const {EVENT_ID} = require("../participation_types");
const {mapping: typedMapping, cells: typedCells, event, person} = require("../test_support/participation_fixture");
const {fakeQrPng, APP_BASE_URL} = require("../test_support/mail_fixtures");

const HAUS = "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）";
const MAISON = "ヘーベルメゾンにお住まい";
const NONE = "いいえ";
const COLUMN = "HEBEL&#160;HAUSにお住まいですか";

const baseMapping = (hebel) => ({
  version: 1,
  participant: {nameColumn: "氏名", emailColumn: "メールアドレス", ...(hebel ? {hebelResidenceColumn: hebel} : {})},
  programs: [{programId: "program-1", countColumn: "人数"}],
});
const row = (n, hebel, extra = {}) => ({
  sourceRowNumber: n,
  cells: {"氏名": `架空${n}`, "メールアドレス": `h${n}@example.invalid`, "人数": "1", [COLUMN]: hebel, ...extra},
});

test("分類: 申込フォームの3つの選択肢を区別し、空欄は未設定、それ以外は未知(丸めない)。原文は監査用に保持", () => {
  assert.deepEqual(classifyHebelResidence(HAUS), {category: "hebelHaus", rawValue: HAUS});
  assert.deepEqual(classifyHebelResidence(MAISON), {category: "hebelMaison", rawValue: MAISON});
  assert.deepEqual(classifyHebelResidence(NONE), {category: "none", rawValue: NONE});
  assert.deepEqual(classifyHebelResidence("  "), {category: "unset", rawValue: null});
  assert.deepEqual(classifyHebelResidence(undefined), {category: "unset", rawValue: null});
  for (const value of ["はい", "ヘーベル", "ヘーベルハウス", "いいえ。", "no", "false"]) {
    assert.deepEqual(classifyHebelResidence(value), {category: "unknown", rawValue: value}, value);
  }
  // 全角・半角、空白の揺れは同じ選択肢として扱う(原文はそのまま残す)
  const halfWidth = "ヘーベルハウスにお住まい(ヘーベルメゾンのオーナー様含む)";
  assert.deepEqual(classifyHebelResidence(` ${halfWidth} `), {category: "hebelHaus", rawValue: halfWidth});
  assert.equal(classifyHebelResidence("ヘーベルメゾン にお住まい").category, "hebelMaison");
});

test("集計: 全分類を固定の順序で返す(0件も含む)。想定外の値は未知として数える", () => {
  const summary = hebelResidenceSummary(["none", "none", "hebelHaus", "unset", "unknown", "???"]);
  assert.deepEqual(summary.map((s) => [s.category, s.count]),
    [["hebelHaus", 1], ["hebelMaison", 0], ["none", 2], ["unset", 1], ["unknown", 2]]);
  assert.deepEqual(summary.map((s) => s.category), CATEGORY_ORDER);
  assert.equal(summary.find((s) => s.category === "none").label, "該当なし（いいえ）");
  assert.equal(summary.find((s) => s.category === "hebelHaus").label, HAUS);
});

test("mapping: 指定は任意。指定しないmappingの正規化結果は従来と同じキーのまま(既存の取込回のハッシュは変わらない)", () => {
  const legacy = normalizeImportMapping(baseMapping(null));
  assert.deepEqual(Object.keys(legacy.participant),
    ["externalIdColumn", "nameColumn", "kanaColumn", "emailColumn", "registeredAtColumn"]);
  assert.deepEqual(mappedColumns(legacy), ["氏名", "メールアドレス", "人数"]);
  const withHebel = normalizeImportMapping(baseMapping(COLUMN));
  assert.equal(withHebel.participant.hebelResidenceColumn, COLUMN);
  assert.deepEqual(mappedColumns(withHebel), ["氏名", "メールアドレス", COLUMN, "人数"]);
  // 不正な指定・他の参加者項目との重複は拒否する
  assert.equal(validateImportMapping(baseMapping(" ")).valid, false);
  const dup = baseMapping("氏名");
  assert.ok(validateImportMapping(dup).errors.some((e) => e.code === "duplicate-participant-column"));
});

test("既存のリクエスト(HEBEL属性の列なし)のrequestHash・contentHashは、変更前の正規化結果で計算した値と同じ", () => {
  const data = {
    eventId: "event1", clientRequestId: "bcompat", sourceFileName: "architecture.csv", fileHash: "a".repeat(64),
    mapping: baseMapping(null), headers: ["氏名", "メールアドレス", "人数"],
    rows: [{rowNumber: 2, values: ["架空", "a@example.invalid", "1"]}], totalRecords: 1, blankRecordNumbers: [],
  };
  const request = parseImportRequest(data, {commit: false});
  // 変更前のnormalizeImportMappingが返していた形(hebelResidenceColumnのキーを持たない)
  const before = {...request, normalizedMapping: {
    version: 1,
    participant: {externalIdColumn: null, nameColumn: "氏名", kanaColumn: null, emailColumn: "メールアドレス", registeredAtColumn: null},
    rowChecks: [],
    programs: [{programId: "program-1", participationColumn: null, attendingValues: null, notAttendingValues: null,
      emptyMeans: "review", slotColumn: null, slotFormat: "label", countColumn: "人数", ignoreCountWhenNotAttending: false}],
  }};
  assert.equal(requestHash(request), requestHash(before));
  assert.equal(contentHash(request), contentHash(before));
  assert.equal(correctableColumns(request.normalizedMapping).has(COLUMN), false);
});

test("計画: 列を指定した取込だけ、行・participant候補にHEBEL属性を持つ。未知はreview(承認・修正・除外で対処)、空欄は問題にしない", () => {
  const {results} = planImportRows({
    rows: [row(2, HAUS), row(3, MAISON), row(4, NONE), row(5, ""), row(6, "架空の回答")],
    mapping: baseMapping(COLUMN),
  });
  assert.deepEqual(results.map((r) => r.status), ["ready", "ready", "ready", "ready", "review"]);
  assert.deepEqual(results.map((r) => r.participant.hebelResidence.category), ["hebelHaus", "hebelMaison", "none", "unset", "unknown"]);
  assert.deepEqual(results[4].issues.map((i) => [i.code, i.severity, i.column]), [["hebel-residence-unknown", "review", COLUMN]]);
  assert.equal(results[3].participant.hebelResidence.rawValue, null);
  // 列を指定しない取込(既存CSV): 計画にHEBEL属性は現れない(同じ値が別の列にあっても読まない)
  const legacy = planImportRows({rows: [row(2, "架空の回答")], mapping: baseMapping(null)}).results[0];
  assert.equal(legacy.status, "ready");
  assert.equal("hebelResidence" in legacy, false);
  assert.equal("hebelResidence" in legacy.participant, false);
});

test("HEBEL属性は参加判定・人数・7タイプを変えない(列の有無で同じ結果)", () => {
  const values = ["cat", "dog", "talk", "dog_cat_talk"];
  const withColumn = {...typedMapping, participant: {...typedMapping.participant, hebelResidenceColumn: COLUMN}};
  for (const value of values) {
    const cells = {...typedCells(value), [COLUMN]: MAISON};
    const a = planImportRows({rows: [{sourceRowNumber: 2, cells}], mapping: typedMapping}).results[0];
    const b = planImportRows({rows: [{sourceRowNumber: 2, cells}], mapping: withColumn}).results[0];
    assert.deepEqual([b.status, b.attendances, b.issues], [a.status, a.attendances, a.issues], value);
  }
});

test("検証: 行ごとの分類と、除外していない行の分類別件数を返す。列を指定しない取込では返さない", () => {
  const rows = [row(2, HAUS), row(3, MAISON), row(4, NONE), row(5, ""), row(6, "架空の回答"), row(7, NONE)];
  const plan = (mapping) => planImportBatchFromRows({
    eventId: "ev", batchId: "bplan", sequence: 1, label: "第1回", sourceFileName: "x.xlsx", fileHash: "b".repeat(64),
    mapping, rows, blankRecordNumbers: [], totalRecords: rows.length,
  });
  const v = validateImportPlan({eventId: "ev", event: {}, records: plan(baseMapping(COLUMN)).records, existingHashes: new Set(),
    excluded: new Set([7]), hebelResidenceMapped: true});
  assert.deepEqual(v.rows.map((r) => r.hebelResidence), ["hebelHaus", "hebelMaison", "none", "unset", "unknown", "none"]);
  assert.deepEqual(v.hebelResidenceSummary.map((s) => [s.category, s.count]),
    [["hebelHaus", 1], ["hebelMaison", 1], ["none", 1], ["unset", 1], ["unknown", 1]]);
  assert.equal(v.findingCounts["hebel-residence-unknown"], 1);
  assert.deepEqual(v.reviewRows, [6]);
  const legacy = validateImportPlan({eventId: "ev", event: {}, records: plan(baseMapping(null)).records, existingHashes: new Set()});
  assert.equal("hebelResidenceSummary" in legacy, false);
  assert.ok(legacy.rows.every((r) => !("hebelResidence" in r)));
});

test("修正: HEBEL属性の列は(列を指定した取込だけ)検証画面で修正できる。修正後の値で分類し直す", () => {
  const data = {
    eventId: "event1", clientRequestId: "bfix", sourceFileName: "x.xlsx", fileHash: "c".repeat(64),
    mapping: baseMapping(COLUMN), headers: ["氏名", "メールアドレス", COLUMN, "人数"],
    rows: [{rowNumber: 2, values: ["架空", "a@example.invalid", "架空の回答", "1"]}], totalRecords: 1, blankRecordNumbers: [],
    corrections: [{sourceRowNumber: 2, column: COLUMN, value: NONE}],
  };
  const request = parseImportRequest(data, {commit: false});
  assert.equal(correctableColumns(request.normalizedMapping).has(COLUMN), true);
  assert.deepEqual(request.corrections, [{sourceRowNumber: 2, column: COLUMN, value: NONE}]);
});

test("受付の表示: participant正本の分類から表示名を作る。フィールドが無ければnull。不正な形は未知(原文があれば添える)", () => {
  assert.equal(hebelResidenceView(undefined), null);
  assert.equal(hebelResidenceView(null), null);
  assert.deepEqual(hebelResidenceView({category: "hebelHaus", rawValue: HAUS}), {category: "hebelHaus", label: HAUS});
  assert.deepEqual(hebelResidenceView({category: "none", rawValue: NONE}), {category: "none", label: "該当なし（いいえ）"});
  assert.deepEqual(hebelResidenceView({category: "unset", rawValue: null}), {category: "unset", label: "未設定（空欄）"});
  assert.deepEqual(hebelResidenceView({category: "unknown", rawValue: "架空の回答"}),
    {category: "unknown", label: "未知のHEBEL属性", rawValue: "架空の回答"});
  assert.deepEqual(hebelResidenceView({category: "架空の分類"}), {category: "unknown", label: "未知のHEBEL属性"});
  assert.deepEqual(hebelResidenceView("hebelHaus"), {category: "unknown", label: "未知のHEBEL属性"});
  assert.equal(HEBEL_RESIDENCE.UNKNOWN, "unknown");
});

test("メール(当選・リマインド)・QR・Web参加証URLにHEBEL属性は入らない(participantにフィールドがあっても)", async () => {
  const {results} = planImportRows({rows: [{sourceRowNumber: 2, cells: typedCells("dog_cat_talk")}], mapping: typedMapping});
  const participant = {...person(), hebelResidence: {category: "hebelHaus", rawValue: HAUS}};
  const attendances = results[0].attendances.map((a) => ({...a, eventId: EVENT_ID, participantId: participant.participantId}));
  for (const [render, templateField] of [[renderWinnerMail, "winnerMailTemplate"], [renderReminderMail, "reminderMailTemplate"]]) {
    const {snapshot} = buildMailSnapshot(EVENT_ID, event(), {templateField});
    const mail = await render({snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
    assert.equal(mail.ok, true);
    const output = JSON.stringify({subject: mail.subject, text: mail.text, html: mail.html, qr: mail.qrPayload, url: mail.webPassUrl, vm: mail.viewModel});
    for (const word of ["ヘーベル", "hebel", "HEBEL属性", "hebelHaus"]) assert.equal(output.includes(word), false, word);
  }
});
