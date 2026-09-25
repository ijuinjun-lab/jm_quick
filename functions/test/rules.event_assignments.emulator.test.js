// Phase 1A: eventAssignments(イベント単位の権限の正本)は、クライアントSDKから一切read/writeできないことを、ローカルEmulatorで検証する。
// 未認証・admin相当・event_manager相当・staff相当のいずれからも、読めず、作成・更新・削除できない
// (本人も自分の任命を読めず、自分を昇格させられない)。読み書きはAdmin SDK(Functions)だけ。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");
const {assignmentDocId} = require("../event_access");

describe("Firestore Rules: eventAssignments(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const EV = "evFixtureA0123456789";
  const managerDoc = `eventAssignments/${assignmentDocId(EV, "u-manager")}`;
  const staffDoc = `eventAssignments/${assignmentDocId(EV, "u-staff")}`;
  const admin = unsignedToken("u-admin", {role: "admin", admin: true, email: "admin@example.invalid"});
  const manager = unsignedToken("u-manager", {role: "event_manager", eventId: EV, email: "manager@example.invalid"});
  const staff = unsignedToken("u-staff", {role: "staff", eventId: EV, email: "staff@example.invalid"});
  const CLIENTS = [["未認証", undefined], ["admin相当", admin], ["event_manager相当(本人)", manager], ["staff相当(本人)", staff]];

  before(async () => {
    emu = await startEmulator();
    // 対照実験: テスト用ルールで「署名なしJWTがrequest.authとして認識される」ことを先に確認する。
    await emu.loadRules(`rules_version = '2';
service cloud.firestore { match /databases/{database}/documents {
  match /probe/{id} { allow read: if request.auth != null && request.auth.uid == id; }
} }`);
    await emu.seed("probe/u-staff", {ok: true});
    assert.equal(await emu.get("probe/u-staff", staff), 200, "staffトークンが認識される");
    assert.equal(await emu.get("probe/u-staff", manager), 403, "別UIDのトークンは拒否される");
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    await emu.seed(managerDoc, {eventId: EV, uid: "u-manager", role: "event_manager", active: true, email: "manager@example.invalid", assignedBy: "u-admin"});
    await emu.seed(staffDoc, {eventId: EV, uid: "u-staff", role: "staff", active: true, email: "staff@example.invalid", assignedBy: "u-manager"});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(label, () => {
      test("get(自分の任命・他人の任命・存在しない任命)", async () => {
        assert.equal(await emu.get(managerDoc, token), 403);
        assert.equal(await emu.get(staffDoc, token), 403);
        assert.equal(await emu.get(`eventAssignments/${assignmentDocId(EV, "nobody")}`, token), 403);
      });
      test("list(全任命の列挙)", async () => assert.equal(await emu.list("eventAssignments", token), 403));
      test("create(自分を任命する)", async () => {
        const id = assignmentDocId("evOther0123456789", "u-staff");
        assert.equal(await emu.create("eventAssignments", id, {eventId: "evOther0123456789", uid: "u-staff", role: "event_manager", active: true}, token), 403);
      });
      test("update・set(自分の昇格・無効化の解除)", async () => {
        assert.equal(await emu.update(staffDoc, {role: "event_manager"}, token), 403);
        assert.equal(await emu.update(managerDoc, {active: false}, token), 403);
        assert.equal(await emu.set(staffDoc, {eventId: EV, uid: "u-staff", role: "event_manager", active: true}, token), 403);
      });
      test("delete", async () => {
        assert.equal(await emu.remove(managerDoc, token), 403);
        assert.equal(await emu.remove(staffDoc, token), 403);
      });
    });
  }

  test("拒否された書込みが実際には反映されていない(オーナー権限で確認)", async () => {
    const response = await fetch(`${emu.base}/${staffDoc}`, {headers: {Authorization: "Bearer owner"}});
    assert.equal(response.status, 200);
    const doc = await response.json();
    assert.equal(doc.fields.role.stringValue, "staff");
    assert.equal(doc.fields.active.booleanValue, true);
    assert.equal(await emu.get(`eventAssignments/${assignmentDocId("evOther0123456789", "u-staff")}`, "owner"), 404);
  });

  test("Rulesの静的検査: eventAssignments のブロックは allow read, write: if false のみ", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const block = rules.match(/match \/eventAssignments\/\{[^}]+\}\s*\{([^}]*)\}/);
    assert.ok(block, "eventAssignmentsのmatchが必要");
    assert.deepEqual(block[1].match(/allow[^;]*;/g), ["allow read, write: if false;"]);
  });
});
