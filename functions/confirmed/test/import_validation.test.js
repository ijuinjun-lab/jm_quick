// 取込前の検証(import_validation.js)。行の判定はpreview・commitと同じ計画(planImportBatchFromRows)の読み替えであること、
// 重複・無視される人数・参加タイプが「見える化」されるだけで、行が除外・統合されないことを確認する。データはすべて架空。
const {test} = require("node:test");
const assert = require("node:assert/strict");
const {extractMappedRows} = require("../import_rows");
const {planImportBatchFromRows} = require("../import_batch_plan");
const {validateImportPlan, existingEmailHashes, emailHash, fingerprintOf, createdEmailHashes, duplicateRows} = require("../import_validation");
const {resolveRecords} = require("../import_commit");
const {parseImportRequest} = require("../import_request");
const {buildImportRequest} = require("../../test_support/import_request_builder");
const {syntheticMapping, makeTable, batchInput, NOT_ATTENDING} = require("../test_support/synthetic");

function planOf(table, mapping = syntheticMapping()) {
  const extracted = extractMappedRows(table, mapping);
  return planImportBatchFromRows({
    ...batchInput({mapping}), rows: extracted.rows, blankRecordNumbers: extracted.blankRecordNumbers,
    totalRecords: extracted.totalRecords, eventProgramIds: ["alpha", "beta", "gamma"],
  });
}

const TYPED_EVENT = {
  programs: [{programId: "alpha"}, {programId: "beta"}, {programId: "gamma"}],
  participationMapping: {catProgramId: "alpha", dogProgramId: "beta", talkProgramId: "gamma"},
};

function validate(table, {mapping, existing = [], event = {participationMapping: null}} = {}) {
  const plan = planOf(table, mapping);
  const existingHashes = existingEmailHashes({eventId: "event1", participants: existing.map((email) => ({status: "active", email})), batches: []});
  return {plan, v: validateImportPlan({eventId: "event1", event, records: plan.records, existingHashes})};
}
const rowOf = (v, n) => v.rows.find((r) => r.sourceRowNumber === n);
const codes = (row) => row.findings.map((f) => f.code);

test("正常なCSVは全行が正常(警告・エラー0件)。総行数は計画と同じ", () => {
  const {v} = validate(makeTable(5));
  assert.deepEqual([v.totalRows, v.okCount, v.warningCount, v.errorCount], [5, 5, 0, 0]);
  assert.deepEqual(v.findingCounts, {});
  assert.equal(v.existingEmailDuplicateCount, 0);
  assert.equal(v.csvEmailDuplicateCount, 0);
});

test("行の判定はpreviewと同じ計画の読み替え: error→エラー、review→警告(検証とプレビューで食い違わない)", () => {
  const {plan, v} = validate(makeTable(6, (i) => ({
    1: {"メールアドレス": "not-an-email"}, 2: {"午前参加人数": "abc"}, 3: {"区分": "その他"},
  }[i] || {})));
  for (const record of plan.records) {
    const row = rowOf(v, record.sourceRowNumber);
    assert.equal(row.classification, record.status);
    if (record.status === "error") assert.equal(row.result, "error");
    if (record.status === "review") assert.equal(row.result, "warning");
  }
  assert.equal(v.errorCount, plan.batch.errorCount);
  assert.equal(v.totalRows, plan.batch.totalRows);
});

test("メール形式不正・人数形式不正・負数はエラー(既存の判定)", () => {
  const {v} = validate(makeTable(3, (i) => ({
    1: {"メールアドレス": "broken@"}, 2: {"午前参加人数": "二人"}, 3: {"午前参加人数": "-1"},
  }[i])));
  assert.deepEqual(codes(rowOf(v, 2)), ["email-invalid"]);
  assert.deepEqual(codes(rowOf(v, 3)), ["count-invalid"]);
  assert.deepEqual(codes(rowOf(v, 4)), ["count-invalid"]);
  assert.equal(v.errorCount, 3);
  assert.deepEqual(v.findingCounts, {"email-invalid": 1, "count-invalid": 2});
});

test("CSV内のメール重複は警告(大文字小文字・前後空白は既存のnormalizeEmailで同一視)。行は除外されない", () => {
  const {plan, v} = validate(makeTable(4, (i) => ({
    1: {"メールアドレス": "same@example.invalid"}, 3: {"メールアドレス": "  SAME@Example.invalid "},
  }[i] || {})));
  assert.equal(plan.records.length, 4);
  assert.deepEqual(codes(rowOf(v, 2)), ["email-duplicate-in-csv"]);
  assert.deepEqual(rowOf(v, 2).duplicateRows, [4]);
  assert.deepEqual(rowOf(v, 4).duplicateRows, [2]);
  assert.equal(rowOf(v, 2).classification, "ready", "計画上の分類(ready)は変わらない");
  assert.deepEqual([v.okCount, v.warningCount, v.errorCount, v.csvEmailDuplicateCount], [2, 2, 0, 2]);
});

test("既存の有効な参加者とのメール重複は警告。件数は行数で数える(有効でない参加者は数えない。取込回のハッシュは状態を問わず数える)", () => {
  const hashes = existingEmailHashes({eventId: "event1", participants: [
    {status: "active", email: " Synthetic1@Example.invalid"}, {status: "active", email: "synthetic2@example.invalid"},
    {status: "cancelled", email: "synthetic3@example.invalid"}, {status: "active"},
  ], batches: [
    {id: "done", status: "committed", createdEmailHashes: [emailHash("event1", "synthetic3@example.invalid")]},
  ]});
  assert.deepEqual([...hashes].sort(), ["synthetic1", "synthetic2", "synthetic3"].map((n) => emailHash("event1", `${n}@example.invalid`)).sort());
  const {v} = validate(makeTable(3), {existing: ["synthetic1@example.invalid", "synthetic2@example.invalid"]});
  assert.deepEqual(codes(rowOf(v, 2)), ["email-duplicate-existing"]);
  assert.deepEqual(codes(rowOf(v, 3)), ["email-duplicate-existing"]);
  assert.deepEqual(codes(rowOf(v, 4)), [], "有効でない参加者(cancelled)は重複に数えない");
  assert.equal(v.existingEmailDuplicateCount, 2);
  assert.deepEqual(v.existingDuplicateRows, [2, 3]);
});

test("取込中の取込回が作る参加者のメールも既存として数える。続きから完了する同じ取込回自身の分は数えない", () => {
  const batches = [{id: "inflight", status: "committing", createdEmailHashes: [emailHash("event1", "synthetic3@example.invalid")]}];
  const counted = existingEmailHashes({eventId: "event1", participants: [], batches});
  assert.ok(counted.has(emailHash("event1", "SYNTHETIC3@example.invalid ")), "同じnormalizeEmailで比べる");
  assert.equal(existingEmailHashes({eventId: "event1", participants: [{status: "active", email: "a@example.invalid", importBatchId: "inflight"}], batches, excludeBatchId: "inflight"}).size, 0);
  assert.notEqual(emailHash("event1", "a@example.invalid"), emailHash("event2", "a@example.invalid"), "ハッシュはイベントごとに別");
});

test("参加なのに人数なし・未知の時間枠は警告(既存のreview)", () => {
  const {v} = validate(makeTable(2, (i) => ({
    1: {"午前参加人数": ""}, 2: {"午前参加時間": "朝のどこか"},
  }[i])));
  assert.deepEqual(codes(rowOf(v, 2)), ["attending-count-missing"]);
  assert.deepEqual(codes(rowOf(v, 3)), ["slot-unparsed"]);
  assert.equal(v.warningCount, 2);
});

test("参加なのに時間枠が空は警告(slot-missing。参加列と時間列が別の形式)", () => {
  const mapping = syntheticMapping({programs: [
    {programId: "alpha", slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数"},
  ]});
  const {v} = validate(makeTable(1, () => ({"午前参加時間": ""})), {mapping});
  assert.deepEqual(codes(rowOf(v, 2)), ["slot-missing"]);
});

test("不参加なのに人数が残っている: 既定は既存どおり警告(review)、ignoreCountWhenNotAttendingでは取込対象のまま「無視される人数」として参考情報", () => {
  const leftover = (i) => (i === 1 ? {"午後参加時間": NOT_ATTENDING, "午後参加人数": "2"} : {});
  const strict = validate(makeTable(1, leftover)).v;
  assert.deepEqual(codes(rowOf(strict, 2)), ["not-attending-count-present"]);
  assert.equal(rowOf(strict, 2).classification, "review");

  const base = syntheticMapping();
  const mapping = {...base, programs: base.programs.map((p) => ({...p, ignoreCountWhenNotAttending: true}))};
  const {plan, v} = validate(makeTable(1, leftover), {mapping});
  assert.equal(plan.records[0].status, "ready", "既存の参加判定は変わらない(取込対象)");
  assert.deepEqual(plan.records[0].attendances.map((a) => a.programId), ["alpha", "gamma"], "不参加のprogramのattendanceは作らない");
  assert.deepEqual(rowOf(v, 2).findings, [{code: "not-attending-count-ignored", severity: "info", programId: "beta"}]);
  assert.equal(rowOf(v, 2).classification, "ready");
  // 参考情報: 行の判定は「参考」(警告ではない)。許可の鍵は無い(許可は要らない)。件数は参考情報として別に数える
  assert.equal(rowOf(v, 2).result, "info");
  assert.equal(rowOf(v, 2).approvalKeys, undefined);
  assert.deepEqual([v.okCount, v.warningCount, v.errorCount, v.infoCount], [0, 0, 0, 1]);
  assert.deepEqual(v.ignoredCountRows, [2]);
});

test("participationMappingのあるイベントでは参加タイプを返し、判定できない行は警告。無いイベントでは返さない", () => {
  const {v} = validate(makeTable(3, (i) => ({
    1: {"午後参加時間": "14:10-14:50", "午後参加人数": "1"},
    2: {"午前参加時間": NOT_ATTENDING, "午前参加人数": "", "トークショー": NOT_ATTENDING, "トークショー人数": ""},
  }[i] || {})), {event: TYPED_EVENT});
  assert.equal(rowOf(v, 2).participationType, "dog_cat_talk");
  assert.equal(rowOf(v, 4).participationType, "cat_talk");
  assert.equal(rowOf(v, 3).participationType, null);
  assert.deepEqual(codes(rowOf(v, 3)), ["no-program", "participation-type-undetermined"]);
  assert.equal(v.participationTypes.length, 7);
  assert.equal(v.participationTypes.find((t) => t.value === "cat_talk").count, 1);
  const untyped = validate(makeTable(1)).v;
  assert.equal("participationType" in untyped.rows[0], false);
  assert.equal("participationTypes" in untyped, false);
});

test("1行に複数の問題があれば、すべてを返す(エラーが1つでもあればエラー)", () => {
  const {v} = validate(makeTable(2, (i) => ({
    1: {"メールアドレス": "dup@example.invalid", "区分": "その他", "午前参加時間": "朝のどこか", "トークショー人数": "x"},
    2: {"メールアドレス": "dup@example.invalid"},
  }[i])), {existing: ["dup@example.invalid"]});
  const row = rowOf(v, 2);
  assert.deepEqual(codes(row).sort(), ["count-invalid", "email-duplicate-existing", "email-duplicate-in-csv", "row-check-failed", "slot-unparsed"]);
  assert.equal(row.result, "error");
  assert.equal(v.findingCounts["email-duplicate-existing"], 2);
});

test("取込回へ保存するメールのハッシュは「作られる参加者」だけ(未承認のreview・除外の行は含めない)", () => {
  const plan = planOf(makeTable(3, (i) => ({3: {"区分": "その他"}}[i] || {})));
  const base = {approvedReviewRows: [], excludedRows: []};
  const h = (i) => emailHash("event1", `synthetic${i}@example.invalid`);
  assert.deepEqual(createdEmailHashes("event1", resolveRecords(plan, base)), [h(1), h(2)].sort());
  assert.deepEqual(createdEmailHashes("event1", resolveRecords(plan, {...base, approvedReviewRows: [4]})), [h(1), h(2), h(3)].sort());
  assert.deepEqual(createdEmailHashes("event1", resolveRecords(plan, {...base, excludedRows: [{sourceRowNumber: 2, reason: "x"}]})), [h(2)]);
});

test("検証の指紋: 内容・次の取込回の番号・重複している行のどれが変わっても別の値。ファイル名・ラベル・管理者の判断では変わらない", () => {
  const parse = (o = {}, table = makeTable(3)) => parseImportRequest(buildImportRequest({table, ...o}), {commit: true});
  const fp = (request, seq = 2, existing = [], csv = []) => fingerprintOf({request, expectedImportSequence: seq, existingDuplicateRows: existing, csvDuplicateRows: csv});
  const base = fp(parse());
  assert.match(base, /^[0-9a-f]{64}$/);
  assert.equal(fp(parse({sourceFileName: "別名.csv", label: "x", approvedReviewRows: [], clientRequestId: "other"})), base);
  assert.notEqual(fp(parse({}, makeTable(3, (i) => (i === 2 ? {"氏名": "変更"} : {})))), base, "CSVの内容");
  assert.notEqual(fp(parse({fileHash: "b".repeat(64)})), base, "ファイル");
  assert.notEqual(fp(parse(), 3), base, "次の取込回の番号");
  assert.notEqual(fp(parse(), 2, [2]), base, "既存参加者との重複");
  assert.notEqual(fp(parse(), 2, [], [2, 3]), base, "CSV内の重複");
  const otherMapping = syntheticMapping({rowChecks: []});
  assert.notEqual(fp(parse({mapping: otherMapping})), base, "列の対応");
});

test("重複している行の定義は検証とcommitで同じ(duplicateRows)", () => {
  const {plan, v} = validate(makeTable(3, (i) => (i === 3 ? {"メールアドレス": "synthetic1@example.invalid"} : {})), {existing: ["synthetic2@example.invalid"]});
  const again = duplicateRows({eventId: "event1", records: plan.records,
    existingHashes: existingEmailHashes({eventId: "event1", participants: [{status: "active", email: "synthetic2@example.invalid"}], batches: []})});
  assert.deepEqual([again.existingDuplicateRows, again.csvDuplicateRows], [v.existingDuplicateRows, v.csvDuplicateRows]);
  assert.deepEqual(v.csvDuplicateRows, [2, 4]);
});

test("修正(corrections)は最終的な値として計画に重なる(原本のrowsは変えない)。除外した行は件数・重複の対象外", () => {
  const {toPlanRows} = require("../import_request");
  const table = makeTable(3, (i) => (i === 1 ? {"メールアドレス": "broken"} : i === 2 ? {"メールアドレス": "synthetic3@example.invalid"} : {}));
  const request = parseImportRequest(buildImportRequest({table, corrections: [{sourceRowNumber: 2, column: "メールアドレス", value: "Fixed@Example.invalid"}],
    excludedRows: [{sourceRowNumber: 4, reason: "x"}]}), {commit: false});
  const original = JSON.stringify(request.rows);
  const rows = toPlanRows(request);
  assert.equal(rows[0].cells["メールアドレス"], "Fixed@Example.invalid");
  assert.equal(JSON.stringify(request.rows), original, "原本の値は変えない");
  const plan = planImportBatchFromRows({...batchInput(), rows, blankRecordNumbers: [], totalRecords: 3, eventProgramIds: ["alpha", "beta", "gamma"]});
  assert.equal(plan.records[0].participant.email, "fixed@example.invalid", "修正後の値も既存のnormalizeEmailで判定する");
  const v = validateImportPlan({eventId: "event1", event: {participationMapping: null}, records: plan.records,
    existingHashes: new Set(), excluded: new Set([4]), corrected: new Set([2])});
  assert.deepEqual([v.okCount, v.excludedRowCount, v.correctedRowCount, v.importRowCount, v.csvEmailDuplicateCount], [2, 1, 1, 2, 0]);
});

test("修正の無い取込のrequestHashは従来と同じ(既存の取込回の冪等性)。修正・除外は指紋に含まれる", () => {
  const {requestHash} = require("../import_request");
  const parse = (o = {}) => parseImportRequest(buildImportRequest({table: makeTable(2), ...o}), {commit: true});
  const plain = parse();
  assert.ok(!("corrections" in JSON.parse(JSON.stringify({...plain, corrections: undefined}))));
  assert.equal(requestHash(parse({corrections: []})), requestHash(plain));
  assert.notEqual(requestHash(parse({corrections: [{sourceRowNumber: 2, column: "氏名", value: "修正"}]})), requestHash(plain));
  const fp = (r) => fingerprintOf({request: r, expectedImportSequence: 1, existingDuplicateRows: [], csvDuplicateRows: []});
  assert.notEqual(fp(parse({corrections: [{sourceRowNumber: 2, column: "氏名", value: "修正"}]})), fp(plain));
  assert.notEqual(fp(parse({excludedRows: [{sourceRowNumber: 2, reason: "x"}]})), fp(plain));
  assert.equal(fp(parse({excludedRows: [{sourceRowNumber: 2, reason: "x"}]})), fp(parse({excludedRows: [{sourceRowNumber: 2, reason: "別の理由"}]})), "除外の理由は指紋に影響しない");
});

// 許可の鍵: 行番号ではなく、その行の最終的な値(原本+修正)と警告の内容から作る。修正・重複相手の変化で鍵が変わる。
function approvalKeysFor(table, {corrections = [], existing = [], excludedRows = []} = {}) {
  const {toPlanRows} = require("../import_request");
  const {approvalKeysOf} = require("../import_validation");
  const request = parseImportRequest(buildImportRequest({table, corrections, excludedRows}), {commit: false});
  const planRows = toPlanRows(request);
  const plan = planImportBatchFromRows({...batchInput(), rows: planRows, blankRecordNumbers: [], totalRecords: table.records.length,
    eventProgramIds: ["alpha", "beta", "gamma"]});
  const excluded = new Set(request.excludedRows.map((e) => e.sourceRowNumber));
  const existingHashes = existingEmailHashes({eventId: "event1", participants: existing.map((email) => ({status: "active", email})), batches: []});
  const dup = duplicateRows({eventId: "event1", records: plan.records, existingHashes, excluded});
  const keys = approvalKeysOf({eventId: "event1", records: plan.records, planRows, dup, excluded});
  const v = validateImportPlan({eventId: "event1", event: {participationMapping: null}, records: plan.records, existingHashes, excluded, planRows});
  return {keys, v};
}
const fix = (sourceRowNumber, column, value) => ({sourceRowNumber, column, value});

test("許可の鍵: 許可が必要な警告(review・既存重複・CSV内重複)にだけあり、検証の行と同じ値。参考情報・正常な行には無い", () => {
  const table = makeTable(4, (i) => ({
    1: {"区分": "その他"},
    2: {"メールアドレス": "old@example.invalid"},
    3: {"メールアドレス": "pair@example.invalid"},
    4: {"メールアドレス": "pair@example.invalid", "午後参加時間": NOT_ATTENDING},
  }[i]));
  const {keys, v} = approvalKeysFor(table, {existing: ["old@example.invalid"]});
  assert.deepEqual(Object.keys(keys.get(2)), ["review"]);
  assert.deepEqual(Object.keys(keys.get(3)), ["existingDuplicate"]);
  assert.deepEqual(Object.keys(keys.get(4)), ["csvDuplicate"]);
  assert.deepEqual(Object.keys(keys.get(5)), ["csvDuplicate"]);
  for (const [n, k] of keys) assert.deepEqual(rowOf(v, n).approvalKeys, k);
  for (const k of [...keys.values()].flatMap(Object.values)) assert.match(k, /^[0-9a-f]{64}$/);
  assert.equal(new Set([...keys.values()].flatMap(Object.values)).size, 4, "行・種類ごとに別の鍵");
  // 除外した行には鍵が無い(許可は要らない)
  assert.equal(approvalKeysFor(table, {existing: ["old@example.invalid"], excludedRows: [{sourceRowNumber: 2, reason: "x"}]}).keys.has(2), false);
});

test("C/H: reviewの行を修正すると、同じ種類のreviewが残っても鍵が変わる(古い許可は流用できない)。他の行の鍵は変わらない", () => {
  const table = makeTable(3, (i) => (i === 1 ? {"午前参加時間": "朝のどこか"} : {}));
  const before = approvalKeysFor(table).keys;
  // 氏名だけ修正: 確認理由(slot-unparsed)は同じだが、行の内容が変わったので鍵は別
  const after = approvalKeysFor(table, {corrections: [fix(2, "氏名", "修正した架空氏名")]}).keys;
  assert.ok(after.get(2).review);
  assert.notEqual(after.get(2).review, before.get(2).review);
  // 確認理由が変わる修正(時間枠を空にする → 時間枠が無い)も別の鍵
  const changed = approvalKeysFor(table, {corrections: [fix(2, "午前参加時間", "")]});
  assert.notDeepEqual(rowOf(changed.v, 2).findings, [{code: "slot-unparsed", severity: "warning", programId: "alpha"}]);
  assert.ok(changed.keys.get(2).review);
  assert.notEqual(changed.keys.get(2).review, before.get(2).review);
  // 他の行の修正では、この行の鍵は変わらない
  const other = approvalKeysFor(table, {corrections: [fix(3, "氏名", "別の行")]}).keys;
  assert.equal(other.get(2).review, before.get(2).review);
});

test("G: 問題が消える修正 → 鍵は無くなる(許可は要らない)", () => {
  const table = makeTable(2, (i) => (i === 1 ? {"午前参加時間": "朝のどこか"} : i === 2 ? {"メールアドレス": "old@example.invalid"} : {}));
  const before = approvalKeysFor(table, {existing: ["old@example.invalid"]});
  assert.deepEqual([before.keys.has(2), before.keys.has(3)], [true, true]);
  const fixed = approvalKeysFor(table, {existing: ["old@example.invalid"],
    corrections: [fix(2, "午前参加時間", "10:00-11:00"), fix(3, "メールアドレス", "new@example.invalid")]});
  assert.equal(fixed.keys.size, 0);
  assert.deepEqual([fixed.v.warningCount, fixed.v.okCount], [0, 2]);
});

test("D/H: 既存重複の行のメールを、別の既存参加者のメールへ修正 → 同じ種類の警告でも鍵は別", () => {
  const table = makeTable(1, () => ({"メールアドレス": "old1@example.invalid"}));
  const existing = ["old1@example.invalid", "old2@example.invalid"];
  const before = approvalKeysFor(table, {existing}).keys.get(2).existingDuplicate;
  const after = approvalKeysFor(table, {existing, corrections: [fix(2, "メールアドレス", "old2@example.invalid")]}).keys.get(2).existingDuplicate;
  assert.ok(after);
  assert.notEqual(after, before);
});

test("E/H: CSV内重複の相手が変わる → 修正していない行の鍵も変わる(古い許可は流用できない)", () => {
  const table = makeTable(3, (i) => (i <= 2 ? {"メールアドレス": "pair@example.invalid"} : {}));
  const before = approvalKeysFor(table).keys;
  assert.deepEqual([...before.keys()], [2, 3]);
  // 4行目を同じメールへ修正: 2・3行目は修正していないが、重複相手が増えたので鍵が変わる
  const after = approvalKeysFor(table, {corrections: [fix(4, "メールアドレス", "pair@example.invalid")]}).keys;
  assert.notEqual(after.get(2).csvDuplicate, before.get(2).csvDuplicate);
  assert.notEqual(after.get(3).csvDuplicate, before.get(3).csvDuplicate);
  assert.ok(after.get(4).csvDuplicate);
  // 3行目を修正して重複が解消: 2・3行目とも鍵は無くなる
  const solved = approvalKeysFor(table, {corrections: [fix(3, "メールアドレス", "solo@example.invalid")]}).keys;
  assert.equal(solved.size, 0);
});
