// 受付(programAttendances)とその履歴(history)が、クライアントSDKから直接読み書きできないことを、ローカルEmulatorで検証する。
// 受付スタッフ(staff相当)がFirestore SDKから直接受付を書き換えたり、参加者が受付済みに偽装したりできない。
// 参加証の閲覧・受付の表示・受付の実行は、すべてFunctions(callable)経由。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

describe("Firestore Rules: 受付・受付履歴(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const CLIENTS = [["未認証", undefined], ["admin相当", unsignedToken("u-admin", {role: "admin", admin: true})], ["staff相当", unsignedToken("u-staff", {role: "staff"})]];
  const ATT = "programAttendances/b1-000002_alpha";

  before(async () => {
    emu = await startEmulator();
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    await emu.seed("events/e-conf", {eventId: "e-conf", eventName: "架空", flow: "confirmed"});
    await emu.seed(ATT, {eventId: "e-conf", participantId: "b1-000002", programId: "alpha", plannedCount: 2, checkedIn: false, checkedInAt: null, attendedCount: null, checkedInBy: null});
    await emu.seed(`${ATT}/history/check-in-1`, {action: "check-in", changedBy: "u-staff", before: {checkedIn: false}, after: {checkedIn: true, attendedCount: 2}});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(label, () => {
      test("受付の偽装(checkedIn・attendedCount・checkedInBy・plannedCountの書換え)がすべて拒否される", async () => {
        assert.equal(await emu.get(ATT, token), 403);
        assert.equal(await emu.update(ATT, {checkedIn: true, attendedCount: 2, checkedInBy: "u-staff"}, token), 403);
        assert.equal(await emu.update(ATT, {checkedIn: true}, token), 403);
        assert.equal(await emu.update(ATT, {attendedCount: 99}, token), 403);
        assert.equal(await emu.update(ATT, {plannedCount: 99}, token), 403);
        assert.equal(await emu.remove(ATT, token), 403);
        assert.equal(await emu.create("programAttendances", "b1-000003_alpha", {eventId: "e-conf", participantId: "b1-000003", programId: "alpha", plannedCount: 1, checkedIn: true}, token), 403);
        assert.equal(await emu.list("programAttendances", token), 403);
      });
      test("受付履歴(history)の get / list / create / update / delete が拒否される", async () => {
        assert.equal(await emu.get(`${ATT}/history/check-in-1`, token), 403);
        assert.equal(await emu.list(`${ATT}/history`, token), 403);
        assert.equal(await emu.create(`${ATT}/history`, "forged", {action: "check-in", changedBy: "u-staff"}, token), 403);
        assert.equal(await emu.update(`${ATT}/history/check-in-1`, {changedBy: "u-other"}, token), 403);
        assert.equal(await emu.remove(`${ATT}/history/check-in-1`, token), 403);
      });
    });
  }

  test("拒否された書込みは反映されていない(オーナー権限で確認)", async () => {
    const read = async (path) => (await fetch(`${emu.base}/${path}`, {headers: {Authorization: "Bearer owner"}}));
    const attendance = (await (await read(ATT)).json()).fields;
    assert.equal(attendance.checkedIn.booleanValue, false);
    assert.equal(attendance.plannedCount.integerValue, "2");
    assert.equal((await (await read(`${ATT}/history/check-in-1`)).json()).fields.changedBy.stringValue, "u-staff");
    assert.equal((await read(`${ATT}/history/forged`)).status, 404);
    assert.equal((await read("programAttendances/b1-000003_alpha")).status, 404);
  });

  test("Rulesの静的検査: programAttendancesとhistoryのallowは if false のみ", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const block = rules.match(/match \/programAttendances\/\{[^}]+\}\s*\{([\s\S]*?)\n    \}/);
    assert.ok(block);
    assert.deepEqual(block[1].match(/allow[^;]*;/g), ["allow read, write: if false;", "allow read, write: if false;"]);
    assert.ok(/match \/history\/\{[^}]+\}/.test(block[1]));
  });
});
