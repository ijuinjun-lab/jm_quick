// キャンセル待ち繰り上げ当選の自動判定(waitlist_promotion.js)と、通知種別・自動除外のリクエスト解釈(import_request.js)。
// データはすべて架空(氏名・メールは架空、メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {parseTimeRange, parsePeopleCount, determineWaitlistPromotion} = require("../waitlist_promotion");
const {parseImportRequest, requestHash, toPlanRows, planMappingOf} = require("../import_request");
const {contentHash} = require("../import_validation");
const {notificationTypeOf, templateFieldFor} = require("../notification_type");

const WAITLIST = {
  optionsColumn: "キャンセル待希望枠", countColumn: "キャンセル待希望人数",
  options: [{label: "午前の部（猫）", programId: "program-1", kind: "猫"}, {label: "午後の部（犬）", programId: "program-2", kind: "犬"}],
};
const DOG_ALL = "午後の部（犬）14:10-14:50,午後の部（犬）14:50-15:30,午後の部（犬）15:30-16:10";
const headers = ["区分", "氏名", "メールアドレス", "キャンセル待希望枠", "キャンセル待希望人数"];
const row = (n, category, options, count) => ({sourceRowNumber: n, values: [category, `架空 参加者${n}`, `w${n}@example.invalid`, options, count]});
const determine = (rows, {sheet = "15時30分～16時10分", sheets = [sheet], file = "【犬15時30分～16時10分】架空の繰り上げリスト.xlsx",
  excluded = new Set()} = {}) =>
  determineWaitlistPromotion({request: {sourceFileName: file, sourceSheetName: sheet, sourceSheetCandidates: sheets, headers, rows},
    waitlist: WAITLIST, excluded});

test("時間枠: シート名の表記ゆれ(時分・コロン・全角・波ダッシュ)を同じ範囲として読む。読めないものはnull", () => {
  for (const text of ["15時30分～16時10分", "15:30-16:10", "１５：３０〜１６：１０", " 15:30 ~ 16:10 ", "15時30分-16時10分"]) {
    assert.deepEqual(parseTimeRange(text), {start: 930, end: 970}, text);
  }
  assert.deepEqual(parseTimeRange("15時～16時"), {start: 900, end: 960});
  for (const text of ["申込情報", "", "16:10-15:30", "25:00-26:00", "15:30", "犬15:30-16:10"]) assert.equal(parseTimeRange(text), null, text);
});

test("人数: 「N名」「N」を整数に。読めないものはnull", () => {
  assert.equal(parsePeopleCount("2名"), 2);
  assert.equal(parsePeopleCount("３名"), 3);
  assert.equal(parsePeopleCount(" 1 "), 1);
  assert.equal(parsePeopleCount("0名"), 0);
  for (const text of ["", "二名", "2人", "-1名", "1.5名"]) assert.equal(parsePeopleCount(text), null, text);
});

test("判定: シート名の時間枠＋希望枠の見出し → program、人数はキャンセル待希望人数(提出なしも対象)", () => {
  const r = determine([row(2, "提出なし", DOG_ALL, "1名"), row(3, "提出なし", DOG_ALL, "2名"), row(4, "提出なし", DOG_ALL, "3名")]);
  assert.equal(r.ok, true);
  assert.equal(r.programId, "program-2");
  assert.equal(r.kind, "犬");
  assert.equal(r.slotLabel, "15:30-16:10");
  assert.deepEqual([...r.counts], [[2, 1], [3, 2], [4, 3]]);
});

test("判定: 取込対象外(自動除外・管理者の除外)の行は判定に使わない。猫の時間枠も同じ規則", () => {
  const r = determine([row(2, "キャンセル", "", ""), row(3, "提出なし", "午前の部（猫）10:30-11:10,午前の部（猫）11:10-11:50", "2名")],
    {sheet: "10時30分～11時10分", file: "【猫10時30分～11時10分】架空.xlsx", excluded: new Set([2])});
  assert.equal(r.ok, true);
  assert.equal(r.programId, "program-1");
  assert.deepEqual([...r.counts], [[3, 2]]);
});

test("停止: 一意に判定できないときは理由を返し、推測で補わない", () => {
  const cases = [
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {sheet: ""}), "sheet-name-missing"],
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {sheet: "申込情報"}), "sheet-name-not-time-range"],
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {sheets: null}), "sheet-list-missing"],
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {sheets: ["14時10分～14時50分"]}), "sheet-not-in-list"],
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {sheets: ["14時10分～14時50分", "15時30分～16時10分"]}), "multiple-sheets"],
    [determine([row(2, "キャンセル", DOG_ALL, "1名")], {excluded: new Set([2])}), "no-target-rows"],
    [determine([row(2, "提出なし", "午後の部（犬）14:10-14:50", "1名")]), "slot-not-in-waitlist-options"],
    [determine([row(2, "提出なし", "午前の部（猫）15:30-16:10,午後の部（犬）15:30-16:10", "1名")], {file: "架空.xlsx"}), "slot-matches-multiple-options"],
    [determine([row(2, "提出なし", "トークセッション", "1名")]), "slot-not-in-waitlist-options"],
    [determine([row(2, "提出なし", DOG_ALL, "")]), "count-missing"],
    [determine([row(2, "提出なし", DOG_ALL, "二名")]), "count-unparsable"],
    [determine([row(2, "提出なし", DOG_ALL, "0名")]), "count-not-positive"],
    [determine([row(2, "提出なし", DOG_ALL, "1000名")]), "count-over-limit"],
    [determine([row(2, "提出なし", DOG_ALL, "1名")], {file: "【猫15時30分～16時10分】架空.xlsx"}), "file-name-kind-conflict"],
  ];
  for (const [result, code] of cases) {
    assert.equal(result.ok, false, code);
    assert.ok(result.reasons.some((r) => r.code === code), `${code}: ${JSON.stringify(result.reasons)}`);
  }
});

const MAPPING_BASE = {
  version: 1,
  participant: {nameColumn: "氏名", emailColumn: "メールアドレス"},
  programs: [
    {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: ["参加を希望しない"], emptyMeans: "notAttending",
      slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数", ignoreCountWhenNotAttending: true},
    {programId: "program-2", participationColumn: "午後参加時間", notAttendingValues: ["参加を希望しない"], emptyMeans: "notAttending",
      slotColumn: "午後参加時間", slotFormat: "label", countColumn: "午後参加人数", ignoreCountWhenNotAttending: true},
  ],
};
const HEADERS = ["氏名", "メールアドレス", "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数"];
const values = (n, am = "参加を希望しない", pm = "参加を希望しない") => [`架空 参加者${n}`, `n${n}@example.invalid`, am, "", pm, ""];
const baseData = (extra = {}) => ({
  eventId: "event1", clientRequestId: "breq1", sourceFileName: "架空.xlsx", fileHash: "a".repeat(64), mapping: MAPPING_BASE,
  headers: HEADERS, rows: [{rowNumber: 2, values: values(2, "10:30-11:10")}], totalRecords: 1, blankRecordNumbers: [], ...extra,
});

test("通常当選: 通知種別を省略・normalを明示しても、requestHash・内容の指紋は従来と同じ(既存の取込回と同じidentity)", () => {
  const legacy = parseImportRequest(baseData(), {commit: false});
  const explicit = parseImportRequest(baseData({notificationType: "normal"}), {commit: false});
  assert.equal(legacy.notificationType, "normal");
  assert.equal(requestHash(explicit), requestHash(legacy));
  assert.equal(contentHash(explicit), contentHash(legacy));
  assert.equal(planMappingOf(legacy), legacy.mapping, "通常当選の計画は元のmapping");
  assert.throws(() => parseImportRequest(baseData({sourceSheetName: "申込情報"}), {commit: false}), /invalid-source-sheet-name/);
  assert.throws(() => parseImportRequest(baseData({notificationType: "other"}), {commit: false}), /invalid-notification-type/);
});

test("自動除外: 区分=キャンセル(空白・全角半角のゆれを含む)を、管理者の除外とは別に持つ。管理者が重ねて除外はできない", () => {
  const mapping = {...MAPPING_BASE, autoExcludeRows: [{column: "区分", values: ["キャンセル"]}]};
  const data = baseData({mapping, headers: ["区分", ...HEADERS], totalRecords: 4, rows: [
    {rowNumber: 2, values: ["新規申込", ...values(2, "10:30-11:10")]},
    {rowNumber: 3, values: [" キャンセル ", ...values(3)]},
    {rowNumber: 4, values: ["ｷｬﾝｾﾙ", ...values(4)]},
    {rowNumber: 5, values: ["変更", ...values(5, "", "14:10-14:50")]},
  ]});
  const request = parseImportRequest(data, {commit: false});
  assert.deepEqual(request.autoExcludedRows.map((e) => [e.sourceRowNumber, e.auto]), [[3, true], [4, true]]);
  assert.deepEqual(request.excludedRows, []);
  assert.throws(() => parseImportRequest({...data, excludedRows: [{sourceRowNumber: 3, reason: "重ねて除外"}]}, {commit: false}),
    /exclusion-already-automatic/);
});

test("繰り上げ当選: 通知種別とmappingの判定規則は必ず対。シート名・通知種別はハッシュと指紋に入る(改ざんすると一致しない)", () => {
  const mapping = {...MAPPING_BASE, autoExcludeRows: [{column: "区分", values: ["キャンセル"]}], waitlist: WAITLIST};
  const data = {
    eventId: "event1", clientRequestId: "bwait1", sourceFileName: "【犬15時30分～16時10分】架空.xlsx", fileHash: "b".repeat(64), mapping,
    headers: ["区分", ...HEADERS, "キャンセル待希望枠", "キャンセル待希望人数"], totalRecords: 3, blankRecordNumbers: [],
    rows: [
      {rowNumber: 2, values: ["提出なし", ...values(2), DOG_ALL, "2名"]},
      // 元の申込にトークショー・午前の希望が残っていても、繰り上げ先(program-2)以外は作らない
      {rowNumber: 3, values: ["提出なし", ...values(3, "11:10-11:50"), DOG_ALL, "3名"]},
      {rowNumber: 4, values: ["キャンセル", ...values(4), "", ""]},
    ],
    notificationType: "waitlistPromotion", sourceSheetName: "15時30分～16時10分", sourceSheetCandidates: ["15時30分～16時10分"],
  };
  const request = parseImportRequest(data, {commit: false});
  assert.equal(request.waitlistResult.programId, "program-2");
  assert.deepEqual(request.autoExcludedRows.map((e) => e.sourceRowNumber), [4]);
  const mappingForPlan = planMappingOf(request);
  assert.deepEqual(mappingForPlan.programs.map((p) => p.programId), ["program-2"], "繰り上げ先のprogramだけ");
  const cells = toPlanRows(request).map((r) => [r.sourceRowNumber, r.cells["繰り上げ時間枠（自動判定）"], r.cells["繰り上げ人数（自動判定）"]]);
  assert.deepEqual(cells, [[2, "15:30-16:10", "2"], [3, "15:30-16:10", "3"], [4, "", ""]]);
  // 改ざん: 通知種別を外す・別の種別にする → mappingと対にならず拒否。シート名を変える → ハッシュ・指紋が変わる
  assert.throws(() => parseImportRequest({...data, notificationType: undefined, sourceSheetName: undefined, sourceSheetCandidates: undefined},
    {commit: false}),
    /notification-type-mapping-mismatch/);
  const otherSheet = parseImportRequest({...data, sourceSheetName: "15:30-16:10", sourceSheetCandidates: ["15:30-16:10"]}, {commit: false});
  assert.notEqual(requestHash(otherSheet), requestHash(request));
  assert.notEqual(contentHash(otherSheet), contentHash(request));
  // 対象のシートが複数のファイルは、1枚を選んで送っても判定しない(シートを選ぶ=時間枠を選ぶことになる)
  assert.throws(() => parseImportRequest({...data, sourceSheetCandidates: ["14時10分～14時50分", "15時30分～16時10分"]}, {commit: false}),
    (e) => e.details.code === "waitlist-undetermined" && e.details.reasons.some((r) => r.code === "multiple-sheets" && r.sheetCount === 2));
  assert.throws(() => parseImportRequest({...data, sourceSheetCandidates: undefined}, {commit: false}),
    (e) => e.details.code === "waitlist-undetermined" && e.details.reasons.some((r) => r.code === "sheet-list-missing"));
  // シートの一覧は検証の要求の一部(ハッシュ・指紋に入る)。通常当選では送らせない・形式の不正は拒否
  const withOther = {...data, sourceSheetCandidates: ["15時30分～16時10分", "別のシート"]};
  assert.notEqual(requestHash({...request, sourceSheetCandidates: withOther.sourceSheetCandidates}), requestHash(request));
  assert.notEqual(contentHash({...request, sourceSheetCandidates: withOther.sourceSheetCandidates}), contentHash(request));
  for (const bad of [[], ["a", "a"], [1], "15時30分～16時10分", ["x".repeat(101)]]) {
    assert.throws(() => parseImportRequest({...data, sourceSheetCandidates: bad}, {commit: false}), /invalid-source-sheet-candidates/);
  }
  assert.throws(() => parseImportRequest({...baseData(), sourceSheetCandidates: ["申込情報"]}, {commit: false}),
    /invalid-source-sheet-candidates/);
  // 判定できなければ止める(管理者の入力で補わない)
  assert.throws(() => parseImportRequest({...data, sourceSheetName: "申込情報", sourceSheetCandidates: ["申込情報"]}, {commit: false}),
    (e) => e.code === "failed-precondition" && e.details.code === "waitlist-undetermined" && e.message.includes("一意に判定できません"));
});

test("通知種別: 項目の無い既存の取込回は通常当選。テンプレートは種別で固定", () => {
  assert.equal(notificationTypeOf({}), "normal");
  assert.equal(notificationTypeOf(null), "normal");
  assert.equal(notificationTypeOf({notificationType: "unknown"}), "normal");
  assert.equal(notificationTypeOf({notificationType: "waitlistPromotion"}), "waitlistPromotion");
  assert.equal(templateFieldFor("normal"), "winnerMailTemplate");
  assert.equal(templateFieldFor("waitlistPromotion"), "waitlistWinnerMailTemplate");
});
