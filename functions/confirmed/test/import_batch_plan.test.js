const assert = require("node:assert/strict");
const {test} = require("node:test");
const {
  isValidBatchId, importRecordId, parseImportRecordId, participantIdForImportRecord, sha256Hex, planImportBatch,
  markExcludedByOperator,
} = require("../import_batch_plan");
const {isValidParticipantId, programAttendanceId, validateProgramAttendance} = require("../../programs");
const {makeTable, batchInput, HEADERS, makeRecord} = require("../test_support/synthetic");

test("importRecordIdはbatchIdと行番号から決定的に生成され、Firestoreの文書IDとして安全", () => {
  const id = importRecordId("batchA", 17);
  assert.equal(id, "batchA-000017");
  assert.equal(importRecordId("batchA", 17), id);
  assert.ok(!id.includes("/"));
  assert.deepEqual(parseImportRecordId(id), {batchId: "batchA", rowNumber: 17});
  assert.equal(importRecordId("batchA", 2), "batchA-000002");
  assert.equal(importRecordId("batchA", 999999), "batchA-999999");
});

test("別batchの同じ行番号は別ID、同じbatchの同じ行番号は同じID", () => {
  assert.notEqual(importRecordId("batchA", 10), importRecordId("batchB", 10));
  assert.equal(importRecordId("batchA", 10), importRecordId("batchA", 10));
  assert.notEqual(importRecordId("batchA", 10), importRecordId("batchA", 11));
});

test("IDと(batchId,行番号)は1対1に対応する(衝突しない)", () => {
  const ids = new Set();
  for (const batchId of ["a", "ab", "a1", "ab1", "A", "aB9"]) {
    for (const row of [1, 2, 9, 10, 99, 100, 123456, 999999]) {
      const id = importRecordId(batchId, row);
      assert.ok(!ids.has(id), id);
      ids.add(id);
      assert.deepEqual(parseImportRecordId(id), {batchId, rowNumber: row});
    }
  }
});

test("不正なbatchId・行番号ではIDを生成しない", () => {
  for (const bad of ["", "a-b", "a_b", "a/b", "a b", "日本語", "x".repeat(41), undefined, null, 1]) {
    assert.equal(isValidBatchId(bad), false, String(bad));
    assert.throws(() => importRecordId(bad, 2), /batchId/);
  }
  for (const bad of [0, -1, 1.5, 1000000, "2", NaN, undefined]) {
    assert.throws(() => importRecordId("batchA", bad), /rowNumber/, String(bad));
  }
  for (const bad of ["batchA", "batchA-17", "batchA-000000", "-000001", "a_b-000001", null]) {
    assert.equal(parseImportRecordId(bad), null, String(bad));
  }
});

test("取込レコードIDはそのままparticipantIdとして有効で、programAttendanceIdも作れる", () => {
  const recordId = importRecordId("batchA", 17);
  assert.equal(participantIdForImportRecord(recordId), recordId);
  assert.equal(isValidParticipantId(recordId), true);
  assert.equal(programAttendanceId(recordId, "alpha"), "batchA-000017_alpha");
  assert.throws(() => participantIdForImportRecord("batchA-17"), /importRecordId/);
});

test("planImportBatch: 取込回のモデル項目と件数", () => {
  const table = makeTable(6, (i) => (i === 2 ? {"午前参加人数": ""} : i === 4 ? {"氏名": ""} : {}));
  const plan = planImportBatch(batchInput({table}));
  assert.equal(plan.ok, true);
  assert.deepEqual(plan.batch, {
    batchId: "batchA", eventId: "event1", sequence: 1, label: "第1回", sourceFileName: "synthetic.csv",
    fileHash: "a".repeat(64), mappingVersion: 3, totalRows: 6, readyCount: 4, reviewCount: 1, errorCount: 1,
    excludedByOperatorCount: 0, blankRecordCount: 0, totalRecords: 6,
  });
  assert.equal(plan.batch.readyCount + plan.batch.reviewCount + plan.batch.errorCount, plan.batch.totalRows);
});

test("「システムがskipした件数」は存在しない(システムが行をskipする概念を持たない)", () => {
  const plan = planImportBatch(batchInput({table: makeTable(3)}));
  assert.equal(("skipped" + "Count") in plan.batch, false);
  assert.equal(("skipped" + "Count") in plan.summary, false);
  for (const record of plan.records) assert.equal(record.status === "skipped", false);
  assert.deepEqual([...new Set(plan.records.map((r) => r.status))], ["ready"]);
});

test("取込レコード: participantId・attendanceIdは取込レコードIDから決定的に決まり、attendanceはProgramAttendanceの規則を満たす", () => {
  const {records} = planImportBatch(batchInput({table: makeTable(2)}));
  const first = records[0];
  assert.equal(first.importRecordId, "batchA-000002");
  assert.equal(first.participantId, first.importRecordId);
  assert.equal(first.sourceRowNumber, 2);
  assert.equal(first.excludedByOperator, false);
  assert.deepEqual(first.attendances.map((a) => a.attendanceId), ["batchA-000002_alpha", "batchA-000002_gamma"]);
  for (const attendance of first.attendances) {
    assert.deepEqual(validateProgramAttendance(attendance), []);
    assert.equal(attendance.eventId, "event1");
    assert.equal(attendance.checkedIn, false);
  }
  assert.equal(records[1].importRecordId, "batchA-000003");
});

test("同じ入力から常に同じ計画になる(ネットワーク再試行しても同じID・同じ内容)", () => {
  const table = makeTable(20, (i) => (i % 4 === 0 ? {"午前参加人数": ""} : {}));
  assert.deepEqual(planImportBatch(batchInput({table})), planImportBatch(batchInput({table})));
});

test("必須列の欠落などファイル全体の問題は、行を捨てずにok:falseで報告する", () => {
  const table = makeTable(3);
  const headers = table.headers.map((h) => (h === "メールアドレス" ? "mail" : h));
  const plan = planImportBatch(batchInput({table: {headers, records: table.records}}));
  assert.deepEqual(plan, {ok: false, errors: [{code: "column-missing", column: "メールアドレス"}]});
});

test("空レコードは行に数えず、blankRecordCountとして必ず件数に出る(totalRows+blank=totalRecords)", () => {
  const table = makeTable(4);
  table.records.splice(2, 0, HEADERS.map(() => ""));
  table.records.push(HEADERS.map(() => " "));
  const plan = planImportBatch(batchInput({table}));
  assert.equal(plan.batch.totalRows, 4);
  assert.equal(plan.batch.blankRecordCount, 2);
  assert.equal(plan.batch.totalRecords, 6);
  assert.deepEqual(plan.blankRecordNumbers, [4, 7]);
  assert.deepEqual(plan.records.map((r) => r.sourceRowNumber), [2, 3, 5, 6]);
});

test("batchの入力検証(sequence・fileHash・ラベルなど)", () => {
  const table = makeTable(1);
  for (const bad of [{sequence: 0}, {sequence: 1.5}, {batchId: "a-b"}, {fileHash: "xyz"}, {eventId: ""}, {label: "x".repeat(101)},
    {sourceFileName: "x".repeat(256)}]) {
    assert.throws(() => planImportBatch(batchInput({table, ...bad})), Error, JSON.stringify(bad));
  }
});

test("fileHash: sha256(hex)を生成できる", () => {
  assert.equal(sha256Hex(Buffer.from("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert.match(sha256Hex(Buffer.from("synthetic")), /^[0-9a-f]{64}$/);
  assert.notEqual(sha256Hex(Buffer.from("a")), sha256Hex(Buffer.from("b")));
  assert.equal(sha256Hex(Buffer.from("a")), sha256Hex(Buffer.from("a")));
});

test("人が明示的に除外した行(excludedByOperator)は記録されるが、行は消えず件数も変わらない", () => {
  const plan = planImportBatch(batchInput({table: makeTable(5, (i) => (i === 3 ? {"氏名": ""} : {}))}));
  const target = plan.records[1].importRecordId;
  const after = markExcludedByOperator(plan, {recordIds: [target], operatorId: "operator-1", reason: "主催者へ確認済みのため送信しない"});
  assert.equal(after.records.length, 5);
  assert.equal(after.records[1].excludedByOperator, true);
  assert.equal(after.records[1].excludedBy, "operator-1");
  assert.equal(after.batch.excludedByOperatorCount, 1);
  for (const key of ["totalRows", "readyCount", "reviewCount", "errorCount"]) assert.equal(after.batch[key], plan.batch[key]);
  assert.equal(plan.records[1].excludedByOperator, false, "元の計画は変更されない");
  assert.equal(plan.records.filter((r) => r.excludedByOperator).length, 0);
});

test("除外には操作者・理由・実在するレコードIDが必須", () => {
  const plan = planImportBatch(batchInput({table: makeTable(2)}));
  const id = plan.records[0].importRecordId;
  assert.throws(() => markExcludedByOperator(plan, {recordIds: [], operatorId: "o", reason: "r"}), /recordIds/);
  assert.throws(() => markExcludedByOperator(plan, {recordIds: [id], operatorId: "", reason: "r"}), /operatorId/);
  assert.throws(() => markExcludedByOperator(plan, {recordIds: [id], operatorId: "o", reason: " "}), /reason/);
  assert.throws(() => markExcludedByOperator(plan, {recordIds: ["batchA-000099"], operatorId: "o", reason: "r"}), /unknown importRecordId/);
});

test("planImportBatch自身は決して行を除外済みにしない(excludedByOperatorは常にfalse)", () => {
  const table = makeTable(30, (i) => (i % 2 ? {"氏名": ""} : {"午前参加人数": ""}));
  const plan = planImportBatch(batchInput({table}));
  assert.equal(plan.records.some((r) => r.excludedByOperator), false);
  assert.equal(plan.batch.excludedByOperatorCount, 0);
  assert.equal(makeRecord(1).length, HEADERS.length);
});
