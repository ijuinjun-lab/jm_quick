// 最終実績(buildAttendanceReport)の純粋関数テスト。データはすべて架空。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {buildAttendanceReport} = require("../attendance_report_api");

const EVENT_ID = "evReportUnit0001";
const event = {
  eventName: "架空イベント", startAt: new Date("2026-11-30T01:00:00Z"),
  // 配列の順序ではなく order で並ぶこと
  programs: [{programId: "talk", name: "架空トーク", order: 2}, {programId: "cat", name: "架空の譲渡会A", order: 0},
    {programId: "dog", name: "架空の譲渡会B", order: 1}],
};
const participant = (id, extra = {}) => ({id, data: {eventId: EVENT_ID, name: `架空 ${id}`, kana: "かくう", email: `${id}@example.invalid`,
  status: "active", schemaVersion: 2, importBatchId: "b1", importRow: 2, ...extra}});
const attendance = (participantId, programId, extra = {}) => ({eventId: EVENT_ID, participantId, programId, plannedCount: 2,
  checkedIn: false, ...extra});
const batches = new Map([["b1", {eventId: EVENT_ID, sequence: 1, status: "committed"}], ["b2", {eventId: EVENT_ID, sequence: 2, status: "committing"}],
  ["bx", {eventId: "otherEvent", sequence: 9, status: "committed"}]]);

test("program列はevent.programsのorder順。event.programsに無いprogramのattendanceも落とさず末尾に並べる", () => {
  const report = buildAttendanceReport({eventId: EVENT_ID, event, batches, participants: [participant("p1")],
    attendances: [attendance("p1", "removed"), attendance("p1", "cat")]});
  assert.deepEqual(report.programs.map((p) => [p.programId, p.name, p.inEvent]),
    [["cat", "架空の譲渡会A", true], ["dog", "架空の譲渡会B", true], ["talk", "架空トーク", true], ["removed", "removed", false]]);
  assert.equal(report.eventName, "架空イベント");
  assert.equal(report.startAt, "2026-11-30T01:00:00.000Z");
});

test("受付結果は正本の現在値: 受付済みは人数・時刻あり、取消済み(checkedIn:false)は人数・時刻を使わない", () => {
  const at = new Date("2026-11-30T01:23:45Z");
  const report = buildAttendanceReport({eventId: EVENT_ID, event, batches, participants: [participant("p1")], attendances: [
    attendance("p1", "cat", {checkedIn: true, attendedCount: 3, checkedInAt: {toDate: () => at}, slotLabel: "10:30-11:10"}),
    // 取消済みに古い値が残っていても使わない(正本ではnullになる)
    attendance("p1", "dog", {checkedIn: false, attendedCount: 5, checkedInAt: at}),
  ]});
  const [row] = report.participants;
  assert.deepEqual(row.programs.find((p) => p.programId === "cat"),
    {programId: "cat", plannedCount: 2, timeText: "10:30-11:10", checkedIn: true, attendedCount: 3, checkedInAt: "2026-11-30T01:23:45.000Z"});
  assert.deepEqual(row.programs.find((p) => p.programId === "dog"),
    {programId: "dog", plannedCount: 2, timeText: null, checkedIn: false, attendedCount: null, checkedInAt: null});
});

test("全員を返す(statusで絞らない)。並びは取込回→行番号。取込回は同じイベントのbatchだけ。未完了の取込回はbatchCommitted:false", () => {
  const report = buildAttendanceReport({eventId: EVENT_ID, event, batches, attendances: [], participants: [
    participant("p3", {importBatchId: "b2", importRow: 2}),
    participant("p2", {importRow: 3, status: "cancelled"}),
    participant("p1", {importRow: 2}),
    participant("p4", {importBatchId: "bx"}),
    participant("p5", {importBatchId: undefined, importRow: undefined}),
  ]});
  assert.deepEqual(report.participants.map((r) => [r.participantId, r.importSequence, r.batchCommitted, r.status]), [
    ["p1", 1, true, "active"], ["p2", 1, true, "cancelled"], ["p3", 2, false, "active"], ["p4", null, false, "active"], ["p5", null, null, "active"],
  ]);
  assert.deepEqual(report.participants[0].programs, [], "programの無いparticipantも出す");
});

test("HEBEL属性は受付画面と同じ表示。未知は原文を添える。フィールドの無いparticipantは返さない", () => {
  const rows = buildAttendanceReport({eventId: EVENT_ID, event, batches, attendances: [], participants: [
    participant("p1", {importRow: 2, hebelResidence: {category: "hebelHaus", rawValue: "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）"}}),
    participant("p2", {importRow: 3, hebelResidence: {category: "none", rawValue: "いいえ"}}),
    participant("p3", {importRow: 4, hebelResidence: {category: "unknown", rawValue: "架空の回答"}}),
    participant("p4", {importRow: 5}),
  ]}).participants;
  assert.deepEqual(rows.map((r) => r.hebelResidence), [
    {category: "hebelHaus", label: "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）"},
    {category: "none", label: "該当なし（いいえ）"},
    {category: "unknown", label: "未知のHEBEL属性", rawValue: "架空の回答"},
    undefined,
  ]);
  assert.equal("hebelResidence" in rows[3], false);
});

test("同じメールアドレスの別participantは統合しない。他イベント・一覧に無いparticipantのattendanceは含めない", () => {
  const report = buildAttendanceReport({eventId: EVENT_ID, event, batches, participants: [
    participant("p1", {email: "same@example.invalid", importRow: 2}), participant("p2", {email: "same@example.invalid", importRow: 3}),
  ], attendances: [attendance("p1", "cat"), attendance("p2", "cat"), {...attendance("p1", "dog"), eventId: "otherEvent"}, attendance("ghost", "talk")]});
  assert.equal(report.participants.length, 2);
  assert.deepEqual(report.participants.map((r) => r.programs.map((p) => p.programId)), [["cat"], ["cat"]]);
  assert.equal(report.programs.length, 3, "他イベント・一覧外のattendanceでprogram列を増やさない");
});

test("0 participant: 列(program)だけを返す", () => {
  const report = buildAttendanceReport({eventId: EVENT_ID, event: {...event, eventName: undefined}, batches, participants: [], attendances: []});
  assert.deepEqual(report.participants, []);
  assert.equal(report.programs.length, 3);
  assert.equal(report.eventName, "");
});
