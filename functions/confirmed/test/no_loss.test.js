// Phase 3 最重要の回帰テスト: 「主催者から提供された全レコードを、欠落なく処理する」。
// JM Quickは、同じ人物・同じメール・同じ氏名・同じ参照コード・過去のbatchとの一致を理由に、行を除外しない。
// 二重送信の防止は「人物」ではなく「batchId+行番号」(取込レコード)単位で行う。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {planImportBatch, importRecordId} = require("../import_batch_plan");
const {planImportRows, extractMappedRows} = require("../import_rows");
const {makeTable, makeRecord, batchInput, syntheticMapping, seededRandom, HEADERS, EVENT_DATE, ATTENDING, NOT_ATTENDING} =
  require("../test_support/synthetic");

const conserved = (plan) => {
  const {batch, records} = plan;
  assert.equal(records.length, batch.totalRows);
  assert.equal(batch.readyCount + batch.reviewCount + batch.errorCount, batch.totalRows);
  assert.equal(batch.totalRows + batch.blankRecordCount, batch.totalRecords);
  assert.equal(new Set(records.map((r) => r.importRecordId)).size, records.length, "importRecordIdは行ごとに一意");
};

test("100行入力 → 結果も必ず100行(入力順・行番号2〜101)", () => {
  const plan = planImportBatch(batchInput({table: makeTable(100)}));
  assert.equal(plan.batch.totalRows, 100);
  assert.equal(plan.records.length, 100);
  assert.deepEqual(plan.records.map((r) => r.sourceRowNumber), Array.from({length: 100}, (_, k) => k + 2));
  conserved(plan);
});

test("同じメールアドレス100行 → 100行すべて結果に残り、すべてready・participant候補も100件", () => {
  const plan = planImportBatch(batchInput({table: makeTable(100, () => ({"メールアドレス": "same@example.invalid"}))}));
  assert.equal(plan.records.length, 100);
  assert.equal(plan.batch.readyCount, 100);
  assert.equal(plan.batch.reviewCount + plan.batch.errorCount, 0, "同じメールは要確認の理由にならない");
  assert.equal(plan.records.filter((r) => r.participant && r.participant.email === "same@example.invalid").length, 100);
  assert.equal(plan.summary.participantCandidateCount, 100);
  conserved(plan);
});

test("同じrd(参照コード)100行 → 100行すべて結果に残り、sourceReferenceは参照情報として保持される", () => {
  const plan = planImportBatch(batchInput({table: makeTable(100, () => ({"rd": "R-SAME"}))}));
  assert.equal(plan.records.length, 100);
  assert.equal(plan.batch.readyCount, 100);
  assert.equal(plan.records.every((r) => r.participant.sourceReference === "R-SAME"), true);
  conserved(plan);
});

test("同じ氏名100行 → 100行すべて結果に残る", () => {
  const plan = planImportBatch(batchInput({table: makeTable(100, () => ({"氏名": "架空同姓同名"}))}));
  assert.equal(plan.records.length, 100);
  assert.equal(plan.batch.readyCount, 100);
  conserved(plan);
});

test("メール・氏名・rdがすべて同じ完全に同一の100行でも、100行すべて残る", () => {
  const record = makeRecord(1);
  const plan = planImportBatch(batchInput({table: {headers: [...HEADERS], records: Array.from({length: 100}, () => [...record])}}));
  assert.equal(plan.records.length, 100);
  assert.equal(plan.batch.readyCount, 100);
  conserved(plan);
});

test("同一メールで氏名だけ違う行も、取込を止めず全行が残る", () => {
  const plan = planImportBatch(batchInput({table: makeTable(50, () => ({"メールアドレス": "shared@example.invalid"}))}));
  assert.equal(plan.records.length, 50);
  assert.equal(new Set(plan.records.map((r) => r.participant.name)).size, 50);
  assert.equal(plan.batch.readyCount, 50);
});

test("前batchと同じ人物が新batchにいても、新batchの全行が処理対象になる(別の取込レコードとして)", () => {
  const table = makeTable(20);
  const first = planImportBatch(batchInput({batchId: "batchA", sequence: 1, table}));
  const second = planImportBatch(batchInput({batchId: "batchB", sequence: 2, table}));
  assert.equal(first.batch.totalRows, 20);
  assert.equal(second.batch.totalRows, 20);
  assert.equal(second.batch.readyCount, 20);
  const firstIds = new Set(first.records.map((r) => r.importRecordId));
  assert.equal(second.records.every((r) => !firstIds.has(r.importRecordId)), true, "同じ人物でもIDは別");
  assert.equal(second.records.every((r, i) => r.participant.email === first.records[i].participant.email), true);
  assert.equal(second.records.every((r) => r.status === "ready"), true);
  conserved(first);
  conserved(second);
});

test("batch A の10行目と batch B の10行目は異なるimportRecordId、同じbatchの10行目の再処理は同じID", () => {
  const table = makeTable(15);
  const a1 = planImportBatch(batchInput({batchId: "batchA", table}));
  const a2 = planImportBatch(batchInput({batchId: "batchA", table}));
  const b = planImportBatch(batchInput({batchId: "batchB", sequence: 2, table}));
  const row10 = (plan) => plan.records.find((r) => r.sourceRowNumber === 10);
  assert.notEqual(row10(a1).importRecordId, row10(b).importRecordId);
  assert.equal(row10(a1).importRecordId, row10(a2).importRecordId);
  assert.equal(row10(a1).importRecordId, importRecordId("batchA", 10));
  assert.notEqual(row10(a1).participantId, row10(b).participantId);
  assert.equal(row10(a1).participantId, row10(a2).participantId);
});

test("reviewの行は消えない(件数・行番号・理由が結果に残る)", () => {
  const plan = planImportBatch(batchInput({table: makeTable(40, (i) => (i % 4 === 0 ? {"午前参加時間": "22:20-22:20"} : {}))}));
  const review = plan.records.filter((r) => r.status === "review");
  assert.equal(review.length, 10);
  assert.equal(plan.records.length, 40);
  assert.equal(plan.batch.reviewCount, 10);
  assert.equal(review.every((r) => r.issues.length > 0 && r.participant && r.attendances.length > 0), true);
  conserved(plan);
});

test("errorの行は消えない(理由が結果に残る)", () => {
  const plan = planImportBatch(batchInput({table: makeTable(40, (i) => (i % 5 === 0 ? {"メールアドレス": "壊れた値"} : {}))}));
  const errors = plan.records.filter((r) => r.status === "error");
  assert.equal(errors.length, 8);
  assert.equal(plan.records.length, 40);
  assert.equal(errors.every((r) => r.issues[0].code === "email-invalid" && r.participant === null), true);
  conserved(plan);
});

test("全行がerror/全行がreviewでも、全行が結果に残る", () => {
  const allError = planImportBatch(batchInput({table: makeTable(25, () => ({"氏名": "", "メールアドレス": ""}))}));
  assert.deepEqual([allError.batch.totalRows, allError.batch.errorCount], [25, 25]);
  const allReview = planImportBatch(batchInput({table: makeTable(25, () => ({"区分": "変更申込"}))}));
  assert.deepEqual([allReview.batch.totalRows, allReview.batch.reviewCount], [25, 25]);
  conserved(allError);
  conserved(allReview);
});

test("ready+review+errorは、あらゆる内容の行(ランダム生成の不正値・矛盾を含む)でtotalRowsと一致する", () => {
  const random = seededRandom(20260920);
  const pick = (values) => values[Math.floor(random() * values.length)];
  const weird = ["", " ", "0", "-1", "2", "２", "abc", "22:20-22:20", "22:20-21:20", "10:00-11:00", ATTENDING, NOT_ATTENDING,
    "あ".repeat(70), "　", "=1+1", "a@b", "x@example.invalid", "X@Example.INVALID", "変更申込", "新規申込", "😀"];
  for (let round = 0; round < 20; round += 1) {
    const n = 1 + Math.floor(random() * 300);
    const records = Array.from({length: n}, () => HEADERS.map(() => pick(weird)));
    const plan = planImportBatch(batchInput({table: {headers: [...HEADERS], records}}));
    const blanks = records.filter((r) => r.every((v) => v.trim() === "")).length;
    assert.equal(plan.batch.totalRows + plan.batch.blankRecordCount, n, `round ${round}`);
    assert.equal(plan.batch.blankRecordCount, blanks);
    conserved(plan);
  }
});

test("入力の行番号が重複していて行を落とす可能性がある場合は、黙って処理せず例外にする", () => {
  const mapping = syntheticMapping();
  const {rows} = extractMappedRows(makeTable(3), mapping);
  assert.throws(() => planImportRows({rows: [...rows, rows[0]], mapping, eventDate: EVENT_DATE}), /duplicate sourceRowNumber/);
});

test("1行ごとの分類は他の行に依存しない(同じ行は、どの表に置いても同じ結果)", () => {
  const target = {"午前参加人数": "", "氏名": "架空単独"};
  const alone = planImportBatch(batchInput({table: makeTable(1, () => target)})).records[0];
  const among = planImportBatch(batchInput({table: makeTable(50, (i) => (i === 1 ? target : {"メールアドレス": "synthetic1@example.invalid"}))})).records[0];
  const strip = ({importRecordId: _id, ...rest}) => rest;
  assert.deepEqual(strip(among), strip(alone));
});
