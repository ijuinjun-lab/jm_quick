// 新方式(flow=confirmed)の当選者CSV: 1行 → participant候補 / programAttendance候補 と ready|review|error の分類。
// 純粋関数のみ。Firestore・ネットワークには一切触れない。
//
// ■ 最優先の不変条件: 入力の全行が、必ず1件の結果として残る(欠落ゼロ)。
//   - 人物の同一性(同じメール・氏名・参照コード)は判定に使わない。他の行との比較は一切しない。
//   - 分類は「その1行だけで、正しくメール・参加証・受付データを作れるか」だけで決める。
//   - review/errorの行も結果に残る。例外が起きた行も errorとして残る。
//   - 件数の恒等式 ready + review + error === totalRows を assertRowConservation で強制する。
//
// ■ 人数の正本は programAttendance の plannedCount のみ(このファイルは旧参加者ドキュメントの人数フィールドを扱わない)。
// ■ 氏名・かなは原文を尊重し、前後の空白だけ除去する(姓名へ分割しない)。
//   メールはtrim+小文字化のみ(Gmailのドット・+の除去はしない)。

const {MAX_PLANNED_COUNT, MAX_SLOT_LABEL_LENGTH} = require("../programs");
const {normalizeImportMapping, mappedColumns} = require("./import_mapping");

const STATUS = Object.freeze({READY: "ready", REVIEW: "review", ERROR: "error"});
const SCHEMA_VERSION = 2;
const PARTICIPANT_STATUS_ACTIVE = "active";
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TIME_RANGE_PATTERN = /^(\d{1,2}):(\d{2})\s*[-~〜–—−]\s*(\d{1,2}):(\d{2})$/;
const EVENT_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const JST_OFFSET_HOURS = 9;

// エラー(そのままでは成立しない)。これ以外の指摘はreview。
const ERROR_CODES = new Set([
  "name-missing", "email-missing", "email-invalid", "count-invalid", "slot-too-long",
  "attendance-invalid", "internal-error",
]);

function trimText(value) {
  if (value === undefined || value === null) return "";
  return String(value).trim();
}

// メールはtrim+小文字化まで。
function normalizeEmail(value) {
  return trimText(value).toLowerCase();
}

function isValidEmail(email) {
  return EMAIL_PATTERN.test(email);
}

// {kind: 'empty'|'zero'|'invalid'|'ok', value?}。全角数字と末尾の「名」「人」を許す。補完はしない。
function parseCount(value) {
  const text = trimText(value);
  if (text === "") return {kind: "empty"};
  const match = /^(\d+)\s*(?:名|人)?$/.exec(text.normalize("NFKC"));
  if (!match) return {kind: "invalid"};
  const number = Number(match[1]);
  if (!Number.isSafeInteger(number)) return {kind: "invalid"};
  if (number === 0) return {kind: "zero"};
  if (number > MAX_PLANNED_COUNT) return {kind: "invalid"};
  return {kind: "ok", value: number};
}

function isoFromJst(year, month, day, hour, minute, second = 0) {
  const date = new Date(Date.UTC(year, month - 1, day, hour - JST_OFFSET_HOURS, minute, second));
  return date.toISOString();
}

function validCalendarDate(year, month, day) {
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
}

// 時間枠。slotLabelは元の表示文字列(前後空白のみ除去)をそのまま保持する。
// startAt/endAtは、format=timeRangeで「HH:MM-HH:MM」と安全に解釈でき、終了>開始のときだけ作る。
// 長さ0・逆転・未知形式は補正せず、problemとして返す。
// 戻り値: {slotLabel, startAt, endAt, problem: null|'zero-length'|'reversed'|'unparsed'|'too-long'}
function parseSlot(value, format, eventDate) {
  const slotLabel = trimText(value);
  const none = {slotLabel, startAt: null, endAt: null};
  if (slotLabel.length > MAX_SLOT_LABEL_LENGTH) return {...none, problem: "too-long"};
  if (format !== "timeRange") return {...none, problem: null};
  const match = TIME_RANGE_PATTERN.exec(slotLabel.normalize("NFKC"));
  if (!match) return {...none, problem: "unparsed"};
  const [startHour, startMinute, endHour, endMinute] = [match[1], match[2], match[3], match[4]].map(Number);
  if (startHour > 23 || endHour > 23 || startMinute > 59 || endMinute > 59) return {...none, problem: "unparsed"};
  const start = startHour * 60 + startMinute;
  const end = endHour * 60 + endMinute;
  if (end === start) return {...none, problem: "zero-length"};
  if (end < start) return {...none, problem: "reversed"};
  const date = EVENT_DATE_PATTERN.exec(eventDate || "");
  if (!date) return {...none, problem: "unparsed"};
  const [year, month, day] = [Number(date[1]), Number(date[2]), Number(date[3])];
  return {
    slotLabel,
    startAt: isoFromJst(year, month, day, startHour, startMinute),
    endAt: isoFromJst(year, month, day, endHour, endMinute),
    problem: null,
  };
}

// 申込日時(参照情報)。日本時間として解釈し、解釈できなければnull(行の分類には影響させない)。
function parseRegisteredAt(value) {
  const text = trimText(value).normalize("NFKC");
  if (text === "") return null;
  const patterns = [
    /^(\d{4})年(\d{1,2})月(\d{1,2})日\s*(\d{1,2})時(\d{1,2})分(?:(\d{1,2})秒)?$/,
    /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/,
  ];
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    if (!match) continue;
    const [year, month, day, hour, minute] = match.slice(1, 6).map(Number);
    const second = match[6] === undefined ? 0 : Number(match[6]);
    if (!validCalendarDate(year, month, day) || hour > 23 || minute > 59 || second > 59) return null;
    return isoFromJst(year, month, day, hour, minute, second);
  }
  return null;
}

// programの参加判定。戻り値の state:
//   'attending' | 'not-attending' | 'review-empty' | 'review-unknown'
function decideParticipation(program, cell, count) {
  if (!program.participationColumn) {
    // 参加列が無いときは人数だけで判定する。空・0は不参加、それ以外(不正値を含む)は参加の意思あり。
    return count.kind === "empty" || count.kind === "zero" ? "not-attending" : "attending";
  }
  const value = cell(program.participationColumn);
  const {attendingValues: attending, notAttendingValues: notAttending} = program;
  if (attending && attending.includes(value)) return "attending";
  if (notAttending && notAttending.includes(value)) return "not-attending";
  if (value === "") return program.emptyMeans === "notAttending" ? "not-attending" : "review-empty";
  if (attending) return "review-unknown";
  return "attending";
}

function makeIssue(code, extra = {}) {
  return {code, severity: ERROR_CODES.has(code) ? "error" : "review", ...extra};
}

function statusFromIssues(issues) {
  if (issues.some((issue) => issue.severity === "error")) return STATUS.ERROR;
  return issues.length > 0 ? STATUS.REVIEW : STATUS.READY;
}

// 1行を分類する。この関数はその行のデータだけを見る(他の行は参照しない)。
function planRow(row, mapping, eventDate) {
  const cells = row.cells || {};
  const cell = (column) => (column ? trimText(cells[column]) : "");
  const issues = [];
  const notices = [];
  const p = mapping.participant;

  const name = cell(p.nameColumn);
  const email = normalizeEmail(cells[p.emailColumn]);
  if (name === "") issues.push(makeIssue("name-missing", {column: p.nameColumn}));
  if (email === "") issues.push(makeIssue("email-missing", {column: p.emailColumn}));
  else if (!isValidEmail(email)) issues.push(makeIssue("email-invalid", {column: p.emailColumn}));

  for (const check of mapping.rowChecks) {
    if (!check.allowedValues.includes(cell(check.column))) {
      issues.push(makeIssue("row-check-failed", {column: check.column}));
    }
  }
  for (const code of row.structuralIssues || []) issues.push(makeIssue(code));

  const attendances = [];
  for (const program of mapping.programs) {
    const count = parseCount(cells[program.countColumn]);
    const at = {programId: program.programId};
    const state = decideParticipation(program, cell, count);
    if (state === "review-empty") issues.push(makeIssue("participation-empty", {...at, column: program.participationColumn}));
    else if (state === "review-unknown") issues.push(makeIssue("participation-unknown", {...at, column: program.participationColumn}));
    else if (state === "not-attending") {
      // 不参加なのに人数が入っている。既定(ignoreCountWhenNotAttendingを指定しないprofile)では、
      // どちらが正しいか決められないため自動判断しない(既存の安全チェック。変更していない)。
      // profileが明示的にignoreCountWhenNotAttending: trueを指定した場合だけ、参加意思の列を唯一の
      // 正本として扱い、不参加と判定したprogramの人数列は無視する(このprogramの矛盾チェック自体を行わない)。
      if (!program.ignoreCountWhenNotAttending && (count.kind === "ok" || count.kind === "invalid")) {
        issues.push(makeIssue("not-attending-count-present", {...at, column: program.countColumn}));
      }
    } else if (count.kind === "empty") {
      issues.push(makeIssue("attending-count-missing", {...at, column: program.countColumn}));
    } else if (count.kind !== "ok") {
      issues.push(makeIssue("count-invalid", {...at, column: program.countColumn}));
    } else {
      let slot = {slotLabel: null, startAt: null, endAt: null};
      let usable = true;
      if (program.slotColumn) {
        const raw = cell(program.slotColumn);
        if (raw === "") {
          issues.push(makeIssue("slot-missing", {...at, column: program.slotColumn}));
        } else {
          const parsed = parseSlot(raw, program.slotFormat, eventDate);
          slot = {slotLabel: parsed.slotLabel, startAt: parsed.startAt, endAt: parsed.endAt};
          if (parsed.problem === "too-long") usable = false;
          if (parsed.problem) issues.push(makeIssue(`slot-${parsed.problem}`, {...at, column: program.slotColumn}));
        }
      }
      if (usable) attendances.push({programId: program.programId, plannedCount: count.value, ...slot});
    }
  }
  if (attendances.length === 0 && issues.length === 0) issues.push(makeIssue("no-program"));

  const emailValid = email !== "" && isValidEmail(email);
  let participant = null;
  if (name !== "" && emailValid) {
    const registeredAt = p.registeredAtColumn ? cell(p.registeredAtColumn) : "";
    const sourceRegisteredAt = registeredAt === "" ? null : parseRegisteredAt(registeredAt);
    if (registeredAt !== "" && sourceRegisteredAt === null) notices.push({code: "registered-at-unparsed", column: p.registeredAtColumn});
    participant = {
      sourceRowNumber: row.sourceRowNumber,
      // 参照情報。同一性の判定には使わない。マッピングされ、値があるときだけ持つ。
      sourceReference: p.externalIdColumn && cell(p.externalIdColumn) !== "" ? cell(p.externalIdColumn) : null,
      name,
      kana: p.kanaColumn && cell(p.kanaColumn) !== "" ? cell(p.kanaColumn) : null,
      email,
      sourceRegisteredAt,
      schemaVersion: SCHEMA_VERSION,
      status: PARTICIPANT_STATUS_ACTIVE,
    };
  }
  return {sourceRowNumber: row.sourceRowNumber, status: statusFromIssues(issues), issues, notices, participant, attendances};
}

// 例外が起きても、その行をerrorとして結果に残す(行を落とさない)。
function planRowSafely(row, mapping, eventDate) {
  try {
    return planRow(row, mapping, eventDate);
  } catch (error) {
    return {
      sourceRowNumber: row && row.sourceRowNumber,
      status: STATUS.ERROR,
      issues: [makeIssue("internal-error")],
      notices: [],
      participant: null,
      attendances: [],
    };
  }
}

function assertRowInputs(rows, mapping, eventDate) {
  if (!Array.isArray(rows)) throw new TypeError("rows must be an array");
  const seen = new Set();
  for (const row of rows) {
    const number = row && row.sourceRowNumber;
    if (!Number.isInteger(number) || number < 1) throw new Error("invalid sourceRowNumber");
    // 行番号の重複は呼び出し側の不具合。後段のimportRecordIdが衝突して行が失われるため、ここで止める。
    if (seen.has(number)) throw new Error(`duplicate sourceRowNumber: ${number}`);
    seen.add(number);
  }
  const needsDate = mapping.programs.some((g) => g.slotColumn && g.slotFormat === "timeRange");
  if (needsDate && !validCalendarDateString(eventDate)) {
    throw new Error("eventDate (YYYY-MM-DD) is required when a program uses slotFormat=timeRange");
  }
}

function validCalendarDateString(value) {
  const match = EVENT_DATE_PATTERN.exec(value || "");
  return Boolean(match) && validCalendarDate(Number(match[1]), Number(match[2]), Number(match[3]));
}

// 結果の集計。ready + review + error === totalRows を返す前に検査する。
function summarizeResults(results) {
  const summary = {
    totalRows: results.length,
    readyCount: 0,
    reviewCount: 0,
    errorCount: 0,
    participantCandidateCount: 0,
    attendanceCandidateCount: 0,
    attendanceCandidateCountByStatus: {ready: 0, review: 0, error: 0},
    attendanceCandidateCountByProgram: {},
    issueCounts: {},
  };
  for (const result of results) {
    if (result.status === STATUS.READY) summary.readyCount += 1;
    else if (result.status === STATUS.REVIEW) summary.reviewCount += 1;
    else if (result.status === STATUS.ERROR) summary.errorCount += 1;
    if (result.participant) summary.participantCandidateCount += 1;
    for (const attendance of result.attendances) {
      summary.attendanceCandidateCount += 1;
      summary.attendanceCandidateCountByStatus[result.status] += 1;
      summary.attendanceCandidateCountByProgram[attendance.programId] =
        (summary.attendanceCandidateCountByProgram[attendance.programId] || 0) + 1;
    }
    for (const issue of result.issues) summary.issueCounts[issue.code] = (summary.issueCounts[issue.code] || 0) + 1;
  }
  return summary;
}

// 行の欠落を検出する最終防衛線。入力行数・結果件数・分類の合計がすべて一致しなければ例外にする。
function assertRowConservation(inputRowCount, results, summary = summarizeResults(results)) {
  const sum = summary.readyCount + summary.reviewCount + summary.errorCount;
  if (results.length !== inputRowCount || summary.totalRows !== inputRowCount || sum !== inputRowCount) {
    throw new Error(`row conservation violated: input=${inputRowCount} results=${results.length} ` +
      `ready+review+error=${sum}`);
  }
  return summary;
}

// rows: [{sourceRowNumber, cells: {列名: 値}, structuralIssues?: [code]}]
// 戻り値: {results(入力順・入力と同数), summary}
function planImportRows({rows, mapping, eventDate, eventProgramIds}) {
  const normalized = normalizeImportMapping(mapping, {eventProgramIds});
  assertRowInputs(rows, normalized, eventDate);
  const results = rows.map((row) => planRowSafely(row, normalized, eventDate));
  const summary = assertRowConservation(rows.length, results);
  return {results, summary};
}

// 全レコード(2次元配列)から、mappingが使う列だけを抽出する。
// sourceRowNumber = CSVのレコード番号(ヘッダー行=1、最初のデータ行=2)。人物の識別には使わない。
// 全項目が空のレコード(末尾の空行など)は行として数えず、blankRecordNumbersに必ず記録する(黙って捨てない)。
// 戻り値: {ok:true, rows, blankRecordNumbers, totalRecords} | {ok:false, errors:[{code, column}]}
function extractMappedRows({headers, records}, mapping) {
  const normalized = normalizeImportMapping(mapping);
  const names = mappedColumns(normalized);
  const headerNames = headers.map((header) => trimText(header).replace(/^﻿/, ""));
  const indexOf = new Map();
  const errors = [];
  for (const name of names) {
    const indexes = headerNames.flatMap((header, index) => (header === name ? [index] : []));
    if (indexes.length === 0) errors.push({code: "column-missing", column: name});
    else if (indexes.length > 1) errors.push({code: "column-ambiguous", column: name});
    else indexOf.set(name, indexes[0]);
  }
  if (errors.length > 0) return {ok: false, errors};

  const rows = [];
  const blankRecordNumbers = [];
  records.forEach((record, position) => {
    const sourceRowNumber = position + 2;
    if (record.every((value) => trimText(value) === "")) {
      blankRecordNumbers.push(sourceRowNumber);
      return;
    }
    const cells = {};
    for (const [name, index] of indexOf) cells[name] = index < record.length ? String(record[index]) : "";
    const row = {sourceRowNumber, cells};
    if (record.length !== headers.length) row.structuralIssues = ["row-length-mismatch"];
    rows.push(row);
  });
  if (rows.length + blankRecordNumbers.length !== records.length) {
    throw new Error("record conservation violated during extraction");
  }
  return {ok: true, rows, blankRecordNumbers, totalRecords: records.length};
}

module.exports = {
  STATUS,
  SCHEMA_VERSION,
  ERROR_CODES,
  trimText,
  normalizeEmail,
  isValidEmail,
  parseCount,
  parseSlot,
  parseRegisteredAt,
  planImportRows,
  planRowSafely,
  summarizeResults,
  assertRowConservation,
  extractMappedRows,
};
