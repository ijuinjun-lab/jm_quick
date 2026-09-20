// 新方式(flow=confirmed)のprogram / programAttendanceの検証とID生成。
// 純粋関数のみ。Dart側(lib/models/program_models.dart)と同じ規則・同じエラーコードを持ち、
// functions/test/fixtures/program_cases.json を両側のテストが共有して一致を保つ。
//
// 人数の正本は programAttendances の plannedCount のみ。
// このファイル(および新方式のファイル全般)は旧参加者ドキュメントの人数フィールドを参照しない
// (functions/test/confirmed_flow_sources.test.js が検査する)。

const PROGRAM_ID_PATTERN = /^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$/;
const PARTICIPANT_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const MAX_PLANNED_COUNT = 999;
const MAX_NAME_LENGTH = 100;
const MAX_NOTE_LENGTH = 500;
const MAX_SLOT_LABEL_LENGTH = 60;

function isValidProgramId(value) {
  return typeof value === "string" && PROGRAM_ID_PATTERN.test(value);
}

// participantIdにも "_" を許さないため、区切りの "_" は1つだけとなり、
// (participantId, programId) の組と文書IDが1対1に対応する(衝突しない)。
function isValidParticipantId(value) {
  return typeof value === "string" && PARTICIPANT_ID_PATTERN.test(value);
}

function programAttendanceId(participantId, programId) {
  if (!isValidParticipantId(participantId)) throw new Error("invalid participantId");
  if (!isValidProgramId(programId)) throw new Error("invalid programId");
  return `${participantId}_${programId}`;
}

// 0は「参加しない」を意味するため不正。参加しないprogramのattendanceは作らない。
function isValidPlannedCount(value) {
  return Number.isInteger(value) && value >= 1 && value <= MAX_PLANNED_COUNT;
}

function toMillis(value) {
  if (value === undefined || value === null) return null;
  if (value instanceof Date) return value.getTime();
  if (typeof value?.toDate === "function") return value.toDate().getTime();
  const parsed = new Date(value).getTime();
  return Number.isNaN(parsed) ? NaN : parsed;
}

function timeRangeInvalid(startAt, endAt) {
  const start = toMillis(startAt);
  const end = toMillis(endAt);
  if (Number.isNaN(start) || Number.isNaN(end)) return true;
  return start !== null && end !== null && end <= start;
}

function isBlank(value) {
  return typeof value !== "string" || value.trim() === "";
}

// エラーコードの配列を返す(空なら有効)。順序は固定。
function validateProgram(program) {
  const errors = [];
  const p = program || {};
  if (!isValidProgramId(p.programId)) errors.push("programId");
  if (isBlank(p.name) || p.name.trim().length > MAX_NAME_LENGTH) errors.push("name");
  if (p.order !== undefined && p.order !== null &&
      !(Number.isInteger(p.order) && p.order >= 0)) errors.push("order");
  if (timeRangeInvalid(p.startAt, p.endAt)) errors.push("timeRange");
  if (p.note !== undefined && p.note !== null &&
      (typeof p.note !== "string" || p.note.length > MAX_NOTE_LENGTH)) errors.push("note");
  return errors;
}

function validateProgramAttendance(attendance) {
  const errors = [];
  const a = attendance || {};
  if (isBlank(a.eventId)) errors.push("eventId");
  if (!isValidParticipantId(a.participantId)) errors.push("participantId");
  if (!isValidProgramId(a.programId)) errors.push("programId");
  if (!isValidPlannedCount(a.plannedCount)) errors.push("plannedCount");
  if (a.slotLabel !== undefined && a.slotLabel !== null &&
      (isBlank(a.slotLabel) || a.slotLabel.length > MAX_SLOT_LABEL_LENGTH)) errors.push("slotLabel");
  if (timeRangeInvalid(a.startAt, a.endAt)) errors.push("timeRange");
  const attended = a.attendedCount;
  const attendedPresent = attended !== undefined && attended !== null;
  if ((attendedPresent && !(Number.isInteger(attended) && attended >= 0)) ||
      (a.checkedIn === true && !attendedPresent)) errors.push("attendedCount");
  return errors;
}

module.exports = {
  MAX_PLANNED_COUNT,
  MAX_SLOT_LABEL_LENGTH,
  isValidProgramId,
  isValidParticipantId,
  programAttendanceId,
  isValidPlannedCount,
  validateProgram,
  validateProgramAttendance,
};
