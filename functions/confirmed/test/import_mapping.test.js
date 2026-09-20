const assert = require("node:assert/strict");
const {test} = require("node:test");
const {validateImportMapping, normalizeImportMapping, mappedColumns, ImportMappingError} =
  require("../import_mapping");
const {syntheticMapping} = require("../test_support/synthetic");

const codes = (mapping, options) => validateImportMapping(mapping, options).errors.map((e) => e.code);
const clone = (value) => JSON.parse(JSON.stringify(value));

test("有効なmappingを受け付け、既定値つきで正規化する(入力は変更しない)", () => {
  const input = syntheticMapping();
  const before = clone(input);
  assert.equal(validateImportMapping(input).valid, true);
  const normalized = normalizeImportMapping(input);
  assert.deepEqual(input, before);
  assert.equal(normalized.version, 3);
  assert.equal(normalized.programs[2].emptyMeans, "review");
  assert.equal(normalized.programs[2].slotFormat, "label");
  assert.equal(normalized.programs[2].slotColumn, null);
  assert.deepEqual(normalized.programs[0].notAttendingValues, ["参加を希望しない"]);
});

test("programIdはコードに固定されていない(任意の名前・個数を受け付ける)", () => {
  const mapping = syntheticMapping({
    programs: ["a", "b-2", "program-three", "x1y2", "z"].map((programId) => ({programId, countColumn: `${programId}人数`})),
  });
  assert.equal(validateImportMapping(mapping).valid, true);
  assert.deepEqual(normalizeImportMapping(mapping).programs.map((p) => p.programId),
    ["a", "b-2", "program-three", "x1y2", "z"]);
});

test("participation列の省略、時間欄と参加欄が同じ列、専用の参加列のいずれも表現できる", () => {
  const mapping = syntheticMapping({
    programs: [
      {programId: "count-only", countColumn: "人数A"},
      {programId: "same-column", participationColumn: "時間B", notAttendingValues: ["不参加"], slotColumn: "時間B", slotFormat: "timeRange", countColumn: "人数B"},
      {programId: "own-column", participationColumn: "参加C", attendingValues: ["はい"], emptyMeans: "notAttending", countColumn: "人数C"},
    ],
  });
  assert.equal(validateImportMapping(mapping).valid, true);
});

test("同一性(identity)の設定は廃止: 設定しても黙って無視せず拒否する", () => {
  assert.deepEqual(codes(syntheticMapping({identity: {strategy: "email"}})), ["identity-not-supported"]);
  for (const key of ["identity" + "Key", "dedupe", "uniqueBy", "skipDuplicates"]) {
    assert.deepEqual(codes(syntheticMapping({[key]: true})), ["unknown-key"], key);
  }
  const nested = syntheticMapping();
  nested.participant.dedupeByEmail = true;
  assert.deepEqual(codes(nested), ["unknown-key"]);
});

test("mappingの形が不正なら拒否する", () => {
  for (const bad of [null, undefined, "x", 1, [], true]) assert.deepEqual(codes(bad), ["mapping-not-object"]);
  for (const version of [undefined, 0, -1, 1.5, "1"]) {
    assert.deepEqual(codes(syntheticMapping({version})), ["invalid-version"], String(version));
  }
});

test("participantの必須列(氏名・メール)が無い/不正/重複ならエラー", () => {
  const missing = syntheticMapping();
  delete missing.participant.emailColumn;
  assert.deepEqual(codes(missing), ["required-column"]);
  const blank = syntheticMapping();
  blank.participant.nameColumn = "  ";
  assert.deepEqual(codes(blank), ["invalid-column"]);
  const dup = syntheticMapping();
  dup.participant.emailColumn = dup.participant.nameColumn;
  assert.deepEqual(codes(dup), ["duplicate-participant-column"]);
  assert.deepEqual(codes(syntheticMapping({participant: undefined})), ["participant-required"]);
});

test("programsの検証(空・programId不正・重複・countColumn・値の指定)", () => {
  assert.deepEqual(codes(syntheticMapping({programs: []})), ["programs-required"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a/b", countColumn: "n"}]})), ["invalid-program-id"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "Cat", countColumn: "n"}]})), ["invalid-program-id"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n"}, {programId: "a", countColumn: "m"}]})),
    ["duplicate-program-id"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a"}]})), ["required-column"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", attendingValues: ["はい"]}]})),
    ["values-without-participation-column"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", participationColumn: "p", attendingValues: ["はい"], notAttendingValues: [" はい "]}]})),
    ["values-overlap"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", participationColumn: "p", attendingValues: []}]})),
    ["invalid-values"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", participationColumn: "p", emptyMeans: "skip"}]})),
    ["invalid-empty-means"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", slotColumn: "s", slotFormat: "iso"}]})),
    ["invalid-slot-format"]);
  assert.deepEqual(codes(syntheticMapping({programs: [{programId: "a", countColumn: "n", slotFormat: "label"}]})),
    ["slot-format-without-slot-column"]);
});

test("mapping内のprogramIdがイベントのprogram(Phase 1のEventProgram)に存在しなければエラー", () => {
  const mapping = syntheticMapping();
  assert.equal(validateImportMapping(mapping, {eventProgramIds: ["alpha", "beta", "gamma", "extra"]}).valid, true);
  assert.deepEqual(codes(mapping, {eventProgramIds: ["alpha", "beta"]}), ["program-not-in-event"]);
  assert.equal(validateImportMapping(mapping).valid, true, "eventProgramIds未指定なら存在確認はしない");
});

test("rowChecksの検証", () => {
  assert.deepEqual(codes(syntheticMapping({rowChecks: "x"})), ["invalid-row-checks"]);
  assert.deepEqual(codes(syntheticMapping({rowChecks: [{column: "区分"}]})), ["invalid-values"]);
  assert.deepEqual(codes(syntheticMapping({rowChecks: [{column: "", allowedValues: ["a"]}]})), ["invalid-column"]);
  assert.equal(validateImportMapping(syntheticMapping({rowChecks: undefined})).valid, true);
});

test("キャンセル待ちを含む列名をマップすると警告する(エラーにはしない)", () => {
  const mapping = syntheticMapping({programs: [{programId: "a", countColumn: "キャンセル待希望人数"}]});
  const result = validateImportMapping(mapping);
  assert.equal(result.valid, true);
  assert.deepEqual(result.warnings, [{code: "waitlist-column", column: "キャンセル待希望人数"}]);
  assert.deepEqual(validateImportMapping(syntheticMapping()).warnings, []);
});

test("不正なmappingの正規化はImportMappingErrorを投げる", () => {
  assert.throws(() => normalizeImportMapping({}), (error) => error instanceof ImportMappingError &&
    error.code === "invalid-import-mapping" && error.errors.length > 0);
});

test("mappedColumns: mappingが読む列だけを重複なく返す(未マップの列は読まない)", () => {
  const columns = mappedColumns(normalizeImportMapping(syntheticMapping()));
  assert.deepEqual(new Set(columns), new Set(["rd", "氏名", "かな", "メールアドレス", "登録日時", "区分",
    "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数", "トークショー", "トークショー人数"]));
  assert.equal(columns.length, new Set(columns).size);
  for (const unmapped of ["都道府県", "思いやご意見", "キャンセル待希望人数"]) assert.ok(!columns.includes(unmapped));
});
