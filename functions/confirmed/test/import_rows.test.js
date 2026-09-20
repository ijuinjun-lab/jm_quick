const assert = require("node:assert/strict");
const {test} = require("node:test");
const {
  normalizeEmail, parseCount, parseSlot, parseRegisteredAt, planImportRows, extractMappedRows, summarizeResults,
  assertRowConservation,
} = require("../import_rows");
const {HEADERS, NOT_ATTENDING, ATTENDING, UNMAPPED_MARKER, EVENT_DATE, makeRecord, makeTable, syntheticMapping} =
  require("../test_support/synthetic");

// 表の各行をplanImportRowsへ渡し、結果を返す。
function plan(overridesFor, {mapping = syntheticMapping(), n = 1} = {}) {
  const extraction = extractMappedRows(makeTable(n, overridesFor), mapping);
  assert.equal(extraction.ok, true);
  return planImportRows({rows: extraction.rows, mapping, eventDate: EVENT_DATE});
}
const one = (overrides, options) => plan(() => overrides, options).results[0];
const issueCodes = (result) => result.issues.map((i) => i.code);

test("メールはtrim+小文字化のみ(Gmailのドット・+タグは除去しない)", () => {
  assert.equal(normalizeEmail("  Foo.Bar+Tag@Example.INVALID \n"), "foo.bar+tag@example.invalid");
  assert.equal(normalizeEmail("a.b.c+x@gmail.invalid"), "a.b.c+x@gmail.invalid");
  assert.equal(normalizeEmail(undefined), "");
});

test("氏名・かなは原文を尊重し前後の空白だけ除去する(姓名へ分割しない・内部の空白は変えない)", () => {
  const cases = ["架空　花子", "架空 花子", "架空花子", "  架空テスト  ", "　架空　テスト　"];
  for (const name of cases) {
    const {participant} = one({"氏名": name, "かな": ` かくう　てすと `});
    assert.equal(participant.name, name.trim());
    assert.equal(participant.kana, "かくう　てすと");
    assert.deepEqual(Object.keys(participant).filter((k) => /first|last|family|given|furigana/i.test(k)), []);
  }
});

test("participant候補の項目: 参照情報・申込日時・schemaVersion・status(人物識別の情報は持たない)", () => {
  const {participant, status} = one({"rd": "  REF-1 ", "登録日時": "2026年03月04日 05時06分07秒"});
  assert.equal(status, "ready");
  assert.deepEqual(participant, {
    sourceRowNumber: 2,
    sourceReference: "REF-1",
    name: "架空テスト001",
    kana: "かくうてすと",
    email: "synthetic1@example.invalid",
    sourceRegisteredAt: "2026-03-03T20:06:07.000Z", // 日本時間(UTC+9)として解釈
    schemaVersion: 2,
    status: "active",
  });
});

test("sourceReferenceはmappingされ値があるときだけ持つ", () => {
  const withoutMapping = syntheticMapping();
  delete withoutMapping.participant.externalIdColumn;
  assert.equal(one({}, {mapping: withoutMapping}).participant.sourceReference, null);
  assert.equal(one({"rd": "  "}).participant.sourceReference, null);
});

test("申込日時が解釈できなくても行の分類には影響せず、noticeだけ残る", () => {
  const result = one({"登録日時": "昨日の夕方"});
  assert.equal(result.status, "ready");
  assert.equal(result.participant.sourceRegisteredAt, null);
  assert.deepEqual(result.notices, [{code: "registered-at-unparsed", column: "登録日時"}]);
  assert.equal(parseRegisteredAt("2026-02-30 10:00"), null);
  assert.equal(parseRegisteredAt("2026/03/04 05:06"), "2026-03-03T20:06:00.000Z");
});

test("参加program(午前=alpha・トーク=gamma)のattendance候補が作られ、不参加programは作られない", () => {
  const {status, attendances} = one({});
  assert.equal(status, "ready");
  assert.deepEqual(attendances, [
    {programId: "alpha", plannedCount: 2, slotLabel: "10:00-11:00", startAt: "2026-11-30T01:00:00.000Z", endAt: "2026-11-30T02:00:00.000Z"},
    {programId: "gamma", plannedCount: 1, slotLabel: null, startAt: null, endAt: null},
  ]);
});

test("全programに参加する行は全attendanceが作られ、人数はplannedCountだけに入る", () => {
  const {attendances} = one({"午後参加時間": "14:00-15:30", "午後参加人数": "3"});
  assert.deepEqual(attendances.map((a) => [a.programId, a.plannedCount]), [["alpha", 2], ["beta", 3], ["gamma", 1]]);
  assert.equal(attendances[1].endAt, "2026-11-30T06:30:00.000Z");
  const legacyCountKey = ["registered", "Count"].join("");
  for (const a of attendances) assert.equal(legacyCountKey in a, false);
});

test("人数の解釈: 全角数字・名/人の接尾辞を許し、補完はしない", () => {
  assert.deepEqual(parseCount("２"), {kind: "ok", value: 2});
  assert.deepEqual(parseCount(" 3名 "), {kind: "ok", value: 3});
  assert.deepEqual(parseCount("4人"), {kind: "ok", value: 4});
  assert.deepEqual(parseCount(""), {kind: "empty"});
  assert.deepEqual(parseCount("0"), {kind: "zero"});
  for (const bad of ["-1", "2.5", "二名", "abc", "1000", "99999999999999999999", "2名様"]) {
    assert.equal(parseCount(bad).kind, "invalid", bad);
  }
  assert.deepEqual(parseCount("999"), {kind: "ok", value: 999});
});

test("時間枠: slotLabelは原文を保持し、HH:MM-HH:MMで終了>開始のときだけstartAt/endAtを作る", () => {
  const ok = parseSlot(" 10:00-11:30 ", "timeRange", EVENT_DATE);
  assert.deepEqual(ok, {slotLabel: "10:00-11:30", startAt: "2026-11-30T01:00:00.000Z", endAt: "2026-11-30T02:30:00.000Z", problem: null});
  assert.equal(parseSlot("９:30〜１０:45", "timeRange", EVENT_DATE).endAt, "2026-11-30T01:45:00.000Z");
  assert.equal(parseSlot("９:30〜１０:45", "timeRange", EVENT_DATE).slotLabel, "９:30〜１０:45");
});

test("時間枠: 長さ0・逆転・未知形式は補正せず、startAt/endAtを作らない(slotLabelは原文のまま)", () => {
  const cases = [["22:20-22:20", "zero-length"], ["22:20-21:20", "reversed"], ["午前の部", "unparsed"], ["25:00-26:00", "unparsed"],
    ["10:70-11:00", "unparsed"], ["10:00", "unparsed"]];
  for (const [label, problem] of cases) {
    assert.deepEqual(parseSlot(label, "timeRange", EVENT_DATE), {slotLabel: label, startAt: null, endAt: null, problem}, label);
  }
});

test("時間枠: format=labelでは構造化せず原文だけ保持し、60文字を超える原文は使えない", () => {
  assert.deepEqual(parseSlot("午前の部", "label", undefined), {slotLabel: "午前の部", startAt: null, endAt: null, problem: null});
  assert.equal(parseSlot("あ".repeat(61), "label").problem, "too-long");
  assert.equal(parseSlot("あ".repeat(60), "label").problem, null);
});

test("review: 不自然な時間枠(長さ0・逆転・未知形式)は補正せずreviewにし、attendance候補は原文のslotLabelで残す", () => {
  for (const [label, code] of [["22:20-22:20", "slot-zero-length"], ["22:20-21:20", "slot-reversed"], ["午前の部", "slot-unparsed"]]) {
    const result = one({"午前参加時間": label});
    assert.equal(result.status, "review", label);
    assert.deepEqual(issueCodes(result), [code]);
    assert.deepEqual(result.issues[0], {code, severity: "review", programId: "alpha", column: "午前参加時間"});
    const alpha = result.attendances.find((a) => a.programId === "alpha");
    assert.deepEqual([alpha.slotLabel, alpha.startAt, alpha.endAt], [label, null, null]);
  }
});

test("review: 参加希望なのに人数がない", () => {
  const result = one({"午前参加人数": ""});
  assert.equal(result.status, "review");
  assert.deepEqual(issueCodes(result), ["attending-count-missing"]);
  assert.deepEqual(result.attendances.map((a) => a.programId), ["gamma"]);
});

test("review: 不参加なのに人数が入っている(自動判断しない・attendanceは作らない)", () => {
  const result = one({"午後参加人数": "2"});
  assert.equal(result.status, "review");
  assert.deepEqual(issueCodes(result), ["not-attending-count-present"]);
  assert.deepEqual(result.attendances.map((a) => a.programId), ["alpha", "gamma"]);
  assert.equal(one({"午後参加人数": "0"}).status, "ready", "人数0は不参加と矛盾しない");
});

test("review: 未知の参加状態・参加状態が空・必要な時間枠がない", () => {
  assert.deepEqual(issueCodes(one({"トークショー": "たぶん参加"})), ["participation-unknown"]);
  assert.deepEqual(issueCodes(one({"トークショー": ""})), ["participation-empty"]);
  const slotMissing = one({"午前参加時間": "  "});
  assert.deepEqual(issueCodes(slotMissing), ["participation-empty"]);
  const sameColumnEmpty = syntheticMapping();
  sameColumnEmpty.programs[0].emptyMeans = "notAttending";
  assert.equal(one({"午前参加時間": "", "午前参加人数": ""}, {mapping: sameColumnEmpty}).status, "ready");
  const separate = syntheticMapping();
  separate.programs[0] = {programId: "alpha", participationColumn: "トークショー", attendingValues: [ATTENDING], slotColumn: "午前参加時間", slotFormat: "timeRange", countColumn: "午前参加人数"};
  assert.deepEqual(issueCodes(one({"午前参加時間": " "}, {mapping: separate})), ["slot-missing"]);
});

test("review: 区分などのrowCheck列が許可値でない行(行そのものの意味が確定できない)", () => {
  const result = one({"区分": "変更申込"});
  assert.equal(result.status, "review");
  assert.deepEqual(result.issues, [{code: "row-check-failed", severity: "review", column: "区分"}]);
});

test("review: どのprogramにも参加しない行は当選者として不完全なのでreview", () => {
  const result = one({"午前参加時間": NOT_ATTENDING, "午前参加人数": "", "トークショー": NOT_ATTENDING, "トークショー人数": ""});
  assert.equal(result.status, "review");
  assert.deepEqual(issueCodes(result), ["no-program"]);
  assert.deepEqual(result.attendances, []);
  assert.ok(result.participant, "participant候補は残る");
});

test("error: 氏名・メールの欠落と形式不正(participant候補は作らないが行は結果に残る)", () => {
  assert.deepEqual(issueCodes(one({"氏名": "  "})), ["name-missing"]);
  assert.deepEqual(issueCodes(one({"メールアドレス": ""})), ["email-missing"]);
  for (const bad of ["not-an-email", "a@b", "a b@example.invalid", "＠example.invalid"]) {
    const result = one({"メールアドレス": bad});
    assert.equal(result.status, "error", bad);
    assert.deepEqual(issueCodes(result), ["email-invalid"]);
    assert.equal(result.participant, null);
  }
});

test("error: 人数が数値として不正(参加希望+0、数字以外、範囲外)", () => {
  for (const count of ["0", "abc", "-1", "1000"]) {
    const result = one({"午前参加人数": count});
    assert.equal(result.status, "error", count);
    assert.deepEqual(issueCodes(result), ["count-invalid"]);
    assert.ok(result.participant, "人数不正でもparticipant候補は残る");
  }
});

test("error: 60文字を超える時間枠の原文はattendanceにできないためerror(補正・切り詰めはしない)", () => {
  const result = one({"午前参加時間": "あ".repeat(61)});
  assert.equal(result.status, "error");
  assert.deepEqual(issueCodes(result), ["slot-too-long"]);
  assert.deepEqual(result.attendances.map((a) => a.programId), ["gamma"]);
});

test("errorがreviewより優先し、複数の指摘はすべて残る", () => {
  const result = one({"氏名": "", "午前参加時間": "22:20-22:20", "区分": "変更申込"});
  assert.equal(result.status, "error");
  assert.deepEqual(issueCodes(result), ["name-missing", "row-check-failed", "slot-zero-length"]);
});

test("participation列が無いprogramは人数だけで判定する(空・0=不参加、数値=参加、不正値=error)", () => {
  const mapping = syntheticMapping({programs: [{programId: "solo", countColumn: "午前参加人数"}]});
  assert.equal(one({"午前参加人数": "2"}, {mapping}).attendances[0].plannedCount, 2);
  assert.deepEqual(one({"午前参加人数": ""}, {mapping}).issues.map((i) => i.code), ["no-program"]);
  assert.deepEqual(one({"午前参加人数": "0"}, {mapping}).issues.map((i) => i.code), ["no-program"]);
  assert.deepEqual(one({"午前参加人数": "abc"}, {mapping}).issues.map((i) => i.code), ["count-invalid"]);
});

test("attendingValuesのみ指定: 列挙外の非空の値は未知(review)、notAttendingValuesのみ指定: 空以外は参加", () => {
  const onlyAttending = syntheticMapping({programs: [{programId: "t", participationColumn: "トークショー", attendingValues: [ATTENDING], countColumn: "トークショー人数"}]});
  assert.deepEqual(issueCodes(one({"トークショー": NOT_ATTENDING, "トークショー人数": ""}, {mapping: onlyAttending})), ["participation-unknown"]);
  const onlyNot = syntheticMapping({programs: [{programId: "t", participationColumn: "トークショー", notAttendingValues: [NOT_ATTENDING], countColumn: "トークショー人数"}]});
  assert.equal(one({"トークショー": "どんな文字列でも"}, {mapping: onlyNot}).attendances.length, 1);
});

test("未マップの列の内容は結果に一切現れない(データ最小化)", () => {
  const {results} = plan(() => ({}), {n: 3});
  const serialized = JSON.stringify(results);
  for (const unmapped of [UNMAPPED_MARKER, "架空県", "9名"]) assert.ok(!serialized.includes(unmapped), unmapped);
  const extraction = extractMappedRows(makeTable(1), syntheticMapping());
  assert.ok(!Object.keys(extraction.rows[0].cells).some((c) => ["都道府県", "思いやご意見", "キャンセル待希望人数"].includes(c)));
});

test("issueには個人情報の値を含めない(列名・programId・コードのみ)", () => {
  const result = one({"氏名": "", "メールアドレス": "秘密の値"});
  const text = JSON.stringify(result.issues);
  assert.ok(!text.includes("秘密の値"));
  assert.ok(!text.includes("synthetic"));
});

test("行の中で例外が起きても、その行はerrorとして結果に残る(行を落とさない)", () => {
  const mapping = syntheticMapping();
  const throwing = {get [mapping.participant.nameColumn]() { throw new Error("boom"); }};
  const {results, summary} = planImportRows({
    rows: [{sourceRowNumber: 2, cells: {}}, {sourceRowNumber: 3, cells: throwing}, {sourceRowNumber: 4, cells: {}}],
    mapping, eventDate: EVENT_DATE,
  });
  assert.equal(results.length, 3);
  assert.deepEqual(results.map((r) => r.sourceRowNumber), [2, 3, 4]);
  assert.deepEqual(results[1].issues.map((i) => i.code), ["internal-error"]);
  assert.equal(results[1].status, "error");
  assert.equal(summary.totalRows, 3);
});

test("planImportRowsは不正な入力(行番号の重複・timeRangeで開催日なし)を黙って処理せず例外にする", () => {
  const mapping = syntheticMapping();
  const rows = [{sourceRowNumber: 2, cells: {}}, {sourceRowNumber: 2, cells: {}}];
  assert.throws(() => planImportRows({rows, mapping, eventDate: EVENT_DATE}), /duplicate sourceRowNumber/);
  assert.throws(() => planImportRows({rows: [{sourceRowNumber: 2, cells: {}}], mapping}), /eventDate/);
  assert.throws(() => planImportRows({rows: [{sourceRowNumber: 0, cells: {}}], mapping, eventDate: EVENT_DATE}), /sourceRowNumber/);
  const labelOnly = syntheticMapping({programs: [{programId: "a", countColumn: "午前参加人数"}]});
  assert.doesNotThrow(() => planImportRows({rows: [{sourceRowNumber: 2, cells: {}}], mapping: labelOnly}));
});

test("extractMappedRows: 列の欠落・曖昧さ・行の長さ不整合・空レコード", () => {
  const mapping = syntheticMapping();
  const table = makeTable(3);
  const missing = extractMappedRows({headers: table.headers.filter((h) => h !== "氏名"), records: table.records.map((r) => r.filter((_, i) => table.headers[i] !== "氏名"))}, mapping);
  assert.deepEqual(missing, {ok: false, errors: [{code: "column-missing", column: "氏名"}]});
  const ambiguous = extractMappedRows({headers: [...table.headers, "氏名"], records: table.records.map((r) => [...r, "x"])}, mapping);
  assert.deepEqual(ambiguous, {ok: false, errors: [{code: "column-ambiguous", column: "氏名"}]});

  const records = [...table.records, HEADERS.map(() => ""), HEADERS.map(() => "  "), makeRecord(9).slice(0, 5)];
  const result = extractMappedRows({headers: table.headers, records}, mapping);
  assert.equal(result.ok, true);
  assert.equal(result.totalRecords, 6);
  assert.deepEqual(result.blankRecordNumbers, [5, 6], "空レコードは黙って捨てず番号を返す");
  assert.deepEqual(result.rows.map((r) => r.sourceRowNumber), [2, 3, 4, 7]);
  assert.deepEqual(result.rows[3].structuralIssues, ["row-length-mismatch"]);
  assert.equal(result.rows.length + result.blankRecordNumbers.length, result.totalRecords);
  const {results} = planImportRows({rows: result.rows, mapping, eventDate: EVENT_DATE});
  assert.equal(results[3].status, "review");
  assert.ok(results[3].issues.some((i) => i.code === "row-length-mismatch"));
});

test("ヘッダーのBOM・前後空白があっても列を見つけられる", () => {
  const table = makeTable(1);
  const headers = [...table.headers];
  headers[0] = `﻿${headers[0]}`;
  headers[2] = ` ${headers[2]} `;
  assert.equal(extractMappedRows({headers, records: table.records}, syntheticMapping()).ok, true);
});

test("集計: ready+review+errorは常にtotalRowsと一致し、欠落を検出できる", () => {
  const {results, summary} = plan((i) => (i % 3 === 0 ? {"午前参加人数": ""} : i % 5 === 0 ? {"氏名": ""} : {}), {n: 30});
  assert.equal(summary.totalRows, 30);
  assert.equal(summary.readyCount + summary.reviewCount + summary.errorCount, 30);
  assert.deepEqual(summarizeResults(results), summary);
  assert.throws(() => assertRowConservation(30, results.slice(1)), /row conservation violated/);
  assert.throws(() => assertRowConservation(30, [...results, results[0]]), /row conservation violated/);
  assert.throws(() => assertRowConservation(30, results, {...summary, readyCount: summary.readyCount - 1}), /row conservation violated/);
});
