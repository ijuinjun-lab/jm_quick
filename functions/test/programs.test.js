const assert = require("node:assert/strict");
const {test} = require("node:test");
const fixture = require("./fixtures/program_cases.json");
const {
  isValidProgramId, isValidParticipantId, programAttendanceId, isValidPlannedCount,
  validateProgram, validateProgramAttendance,
} = require("../programs");

test("有効なprogramIdを受け付け、不正なprogramId(/ _ . 空白 大文字 等)を拒否する", () => {
  for (const id of fixture.validProgramIds) assert.equal(isValidProgramId(id), true, id);
  for (const id of fixture.invalidProgramIds) assert.equal(isValidProgramId(id), false, JSON.stringify(id));
  assert.equal(isValidProgramId(undefined), false);
  assert.equal(isValidProgramId(null), false);
  assert.equal(isValidProgramId(1), false);
});

test("participantIdの検証(区切りの_を含めない)", () => {
  for (const id of fixture.validParticipantIds) assert.equal(isValidParticipantId(id), true, id);
  for (const id of fixture.invalidParticipantIds) assert.equal(isValidParticipantId(id), false, JSON.stringify(id));
});

test("programAttendanceのIDはparticipantId×programIdから決定的に生成される", () => {
  for (const c of fixture.attendanceIds) {
    assert.equal(programAttendanceId(c.participantId, c.programId), c.id);
    assert.equal(programAttendanceId(c.participantId, c.programId), c.id);
  }
});

test("programAttendanceのIDは衝突せず、不正なIDでは生成を拒否する", () => {
  const ids = new Set();
  for (const p of ["p1", "p2", "a-b"]) {
    for (const g of ["cat", "dog", "talk", "b"]) ids.add(programAttendanceId(p, g));
  }
  assert.equal(ids.size, 12);
  for (const id of fixture.invalidProgramIds) {
    assert.throws(() => programAttendanceId("p1", id), /programId/, JSON.stringify(id));
  }
  for (const id of fixture.invalidParticipantIds) {
    assert.throws(() => programAttendanceId(id, "cat"), /participantId/, JSON.stringify(id));
  }
  assert.ok(![...ids].some((id) => id.includes("/")), "文書パスを壊す/を含まない");
});

test("plannedCountは1以上の整数のみ(0は参加しない=attendanceを作らない)", () => {
  for (const n of fixture.plannedCounts.valid) assert.equal(isValidPlannedCount(n), true, String(n));
  for (const n of fixture.plannedCounts.invalid) assert.equal(isValidPlannedCount(n), false, String(n));
});

test("programの検証ケース(Dartと共有)", () => {
  for (const c of fixture.programCases) assert.deepEqual(validateProgram(c.input), c.errors, c.name);
});

test("programAttendanceの検証ケース(Dartと共有)", () => {
  for (const c of fixture.attendanceCases) assert.deepEqual(validateProgramAttendance(c.input), c.errors, c.name);
});
