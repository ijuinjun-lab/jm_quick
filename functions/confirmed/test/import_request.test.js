// 取込APIのリクエスト検証(純粋関数)のテスト。データはすべて架空。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {parseImportRequest, toPlanRows, requestHash} = require("../import_request");
const {planImportBatchFromRows, planImportBatch} = require("../import_batch_plan");
const {ApiError} = require("../api_error");
const {makeTable, batchInput, syntheticMapping, EVENT_DATE, HEADERS, makeRecord} = require("../test_support/synthetic");
const {normalizeImportMapping, mappedColumns} = require("../import_mapping");

// クライアントが送る形(mappingが読む列だけ)を、表から作る。
function body(table, extra = {}) {
  const columns = mappedColumns(normalizeImportMapping(syntheticMapping()));
  const indexes = columns.map((c) => table.headers.indexOf(c));
  const rows = []; const blank = [];
  table.records.forEach((record, position) => {
    if (record.every((v) => v.trim() === "")) blank.push(position + 2);
    else rows.push({rowNumber: position + 2, values: indexes.map((i) => record[i])});
  });
  return {eventId: "event1", clientRequestId: "batchA", sourceFileName: "f.csv", fileHash: "a".repeat(64), mapping: syntheticMapping(),
    headers: columns, rows, totalRecords: table.records.length, blankRecordNumbers: blank, ...extra};
}
const codeOf = (fn) => { try { fn(); return null; } catch (e) { assert.ok(e instanceof ApiError); assert.equal(e.code, "invalid-argument"); return e.details.code; } };

test("正しいリクエストを正規化する(行は番号順・batchIdはclientRequestId)", () => {
  const data = body(makeTable(4));
  data.rows.reverse();
  const request = parseImportRequest(data, {commit: false});
  assert.equal(request.batchId, "batchA");
  assert.deepEqual(request.rows.map((r) => r.sourceRowNumber), [2, 3, 4, 5]);
  assert.deepEqual(request.approvedReviewRows, []);
  assert.deepEqual(request.excludedRows, []);
});

test("行のつじつま(2..totalRecords+1が過不足なく1回ずつ)が合わなければ拒否する", () => {
  const table = makeTable(5);
  const drop = body(table); drop.rows.splice(1, 1);
  assert.equal(codeOf(() => parseImportRequest(drop, {commit: false})), "record-accounting-mismatch");
  const extra = body(table); extra.totalRecords = 4;
  assert.equal(codeOf(() => parseImportRequest(extra, {commit: false})), "record-accounting-mismatch");
  const dup = body(table); dup.rows[1].rowNumber = 2;
  assert.equal(codeOf(() => parseImportRequest(dup, {commit: false})), "duplicate-record-number");
  const overlap = body(table); overlap.blankRecordNumbers = [3];
  assert.equal(codeOf(() => parseImportRequest(overlap, {commit: false})), "duplicate-record-number");
  assert.equal(codeOf(() => parseImportRequest({...body(table), totalRecords: 5001}, {commit: false})), "invalid-total-records");
});

test("空レコードの申告を含め、全レコードが説明できれば受け付ける", () => {
  const table = makeTable(3);
  table.records.splice(1, 0, HEADERS.map(() => ""));
  const request = parseImportRequest(body(table), {commit: false});
  assert.deepEqual(request.blankRecordNumbers, [3]);
  assert.equal(request.rows.length, 3);
  assert.equal(request.totalRecords, 4);
});

test("headersはmappingが読む列と過不足なく一致(未マップの列を送らせない)", () => {
  const data = body(makeTable(2));
  assert.equal(codeOf(() => parseImportRequest({...data, headers: [...data.headers, "都道府県"]}, {commit: false})), "unexpected-column");
  assert.equal(codeOf(() => parseImportRequest({...data, headers: data.headers.filter((h) => h !== "氏名")}, {commit: false})), "column-missing");
  assert.equal(codeOf(() => parseImportRequest({...data, headers: [...data.headers, data.headers[0]]}, {commit: false})), "duplicate-header");
  assert.equal(codeOf(() => parseImportRequest({...data, headers: []}, {commit: false})), "invalid-headers");
});

test("未知のキー・不正な型は拒否する(氏名やparticipantデータを直接送らせない)", () => {
  const data = body(makeTable(2));
  for (const extra of [{participants: []}, {classification: "ready"}, {sequence: 3}, {createdBy: "x"}, {email: "a@example.invalid"}]) {
    assert.equal(codeOf(() => parseImportRequest({...data, ...extra}, {commit: true})), "unknown-key", JSON.stringify(extra));
  }
  for (const bad of [null, undefined, "x", 1, [], true]) assert.equal(codeOf(() => parseImportRequest(bad, {commit: false})), "body-not-object");
  assert.equal(codeOf(() => parseImportRequest({...data, mapping: {}}, {commit: false})), "invalid-mapping");
  assert.equal(codeOf(() => parseImportRequest({...data, mapping: {...syntheticMapping(), identity: {}}}, {commit: false})), "invalid-mapping");
});

test("判断(approvedReviewRows・excludedRows)はcommitだけが受け付け、形を検証する", () => {
  const data = body(makeTable(3));
  assert.equal(codeOf(() => parseImportRequest({...data, approvedReviewRows: [2]}, {commit: false})), "unknown-key");
  const ok = parseImportRequest({...data, approvedReviewRows: [4, 2], excludedRows: [{sourceRowNumber: 3, reason: " 理由 "}]}, {commit: true});
  assert.deepEqual(ok.approvedReviewRows, [2, 4]);
  assert.deepEqual(ok.excludedRows, [{sourceRowNumber: 3, reason: "理由"}]);
  for (const bad of [{approvedReviewRows: "x"}, {approvedReviewRows: [1]}, {approvedReviewRows: [2, 2]}, {approvedReviewRows: [2.5]},
    {excludedRows: [{sourceRowNumber: 2}]}, {excludedRows: [{sourceRowNumber: 2, reason: ""}]}, {excludedRows: [{sourceRowNumber: 2, reason: "x", by: "y"}]},
    {excludedRows: [{sourceRowNumber: 2, reason: "x"}, {sourceRowNumber: 2, reason: "y"}]}, {excludedRows: {}}]) {
    assert.ok(codeOf(() => parseImportRequest({...data, ...bad}, {commit: true})), JSON.stringify(bad));
  }
});

test("clientRequestId(=batchId)・eventId・fileHashの形式", () => {
  const data = body(makeTable(1));
  for (const id of ["", "a-b", "a_b", "a b", "x".repeat(41), 1, null]) assert.equal(codeOf(() => parseImportRequest({...data, clientRequestId: id}, {commit: false})), "invalid-client-request-id");
  for (const id of ["", "a/b", "a b", "x".repeat(129), 1]) assert.equal(codeOf(() => parseImportRequest({...data, eventId: id}, {commit: false})), "invalid-event-id");
  for (const h of ["", "xyz", "A".repeat(64), "a".repeat(63)]) assert.equal(codeOf(() => parseImportRequest({...data, fileHash: h}, {commit: false})), "invalid-file-hash");
});

test("値の個数がheadersと違う行は捨てず、structuralIssuesとして計画に渡す", () => {
  const data = body(makeTable(3));
  data.rows[1].values = data.rows[1].values.slice(0, 4);
  const request = parseImportRequest(data, {commit: false});
  const rows = toPlanRows(request);
  assert.equal(rows.length, 3);
  assert.deepEqual(rows[1].structuralIssues, ["row-length-mismatch"]);
  assert.equal(rows[0].structuralIssues, undefined);
  assert.equal(Object.keys(rows[0].cells).length, request.headers.length);
});

test("requestHash: 同じ内容は同じ、内容(値・判断・ファイル・ラベル)が違えば違う。プロパティの順序に依存しない", () => {
  const data = body(makeTable(5));
  const h = (extra = {}, commit = true) => requestHash(parseImportRequest({...data, ...extra}, {commit}));
  assert.equal(h(), h());
  assert.equal(h(), requestHash(parseImportRequest({...data, rows: [...data.rows].reverse()}, {commit: true})));
  const reordered = {...data, mapping: JSON.parse(JSON.stringify(data.mapping))};
  assert.equal(h(), requestHash(parseImportRequest(reordered, {commit: true})));
  const different = [h({approvedReviewRows: [2]}), h({excludedRows: [{sourceRowNumber: 2, reason: "x"}]}), h({fileHash: "b".repeat(64)}), h({label: "L"}),
    h({sourceFileName: "g.csv"}), h({eventId: "event2"}), h({rows: data.rows.map((r, i) => (i === 0 ? {...r, values: ["x", ...r.values.slice(1)]} : r))})];
  assert.equal(new Set([h(), ...different]).size, different.length + 1);
});

test("planImportBatchFromRows は planImportBatch(全レコードの表から)と同じ計画を作る", () => {
  const table = makeTable(12, (i) => (i % 4 === 0 ? {"午前参加人数": ""} : i === 5 ? {"氏名": ""} : {}));
  const viaTable = planImportBatch(batchInput({table}));
  const request = parseImportRequest(body(table), {commit: false});
  const viaRows = planImportBatchFromRows({...batchInput({table}), rows: toPlanRows(request), blankRecordNumbers: request.blankRecordNumbers,
    totalRecords: request.totalRecords, eventDate: EVENT_DATE});
  assert.deepEqual(viaRows.batch, viaTable.batch);
  assert.deepEqual(viaRows.records.map((r) => [r.importRecordId, r.status, r.issues.map((i) => i.code)]),
    viaTable.records.map((r) => [r.importRecordId, r.status, r.issues.map((i) => i.code)]));
});

test("mappingの重複判定に相当する設定(identity・dedupe等)はAPIでも受け付けない", () => {
  const data = body(makeTable(2));
  for (const key of ["identity", ["identity", "Key"].join(""), "dedupe", "uniqueBy"]) {
    assert.equal(codeOf(() => parseImportRequest({...data, mapping: {...syntheticMapping(), [key]: true}}, {commit: false})), "invalid-mapping", key);
  }
  assert.ok(makeRecord(1).length > 0);
});
