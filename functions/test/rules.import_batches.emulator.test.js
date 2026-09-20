// 新方式の取込データ(importBatches・その rows・programAttendances)と、取込で作られたconfirmed participantが、
// クライアントSDKから直接書き換えられないことを、ローカルEmulator(localhostのみ)で検証する。
// 未認証・admin相当・staff相当のいずれでも、importBatches/rows/programAttendancesは読み書きとも不可、
// confirmed participantは作成・更新・削除とも不可(Admin SDK=callable経由のみ)。
// participantsのreadは、Phase 10(旧JM Quickの認証)まで従来どおりのため、ここでは検証対象にしない。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

describe("Firestore Rules: 取込データ(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const admin = unsignedToken("u-admin", {role: "admin", admin: true});
  const staff = unsignedToken("u-staff", {role: "staff"});
  const CLIENTS = [["未認証", undefined], ["admin相当", admin], ["staff相当", staff]];

  // 拒否は 403。ただしEmulatorのREST応答では、Rulesの評価中にエラー(存在しないフィールドの参照など)になった書込みは
  // 500で返る。どちらも書込みは実行されない(本番のFirestoreでは評価エラーも拒否として扱われる)。
  // 実際に書き込まれていないことは、最後のテストでオーナー権限により確認する。
  const denied = (status) => status === 403 || status === 500;

  const confirmedParticipant = {
    participantId: "b1-000002", eventId: "e-conf", publicId: "pub_0123456789abcdef0123456789abcdef", name: "架空", kana: null,
    email: "x@example.invalid", sourceReference: null, sourceRegisteredAt: null, schemaVersion: 2, status: "active",
    registrationType: "winner", importBatchId: "b1", importRow: 2,
  };

  before(async () => {
    emu = await startEmulator();
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    await emu.seed("events/e-conf", {eventId: "e-conf", eventName: "架空", flow: "confirmed", importSequence: 1});
    await emu.seed("importBatches/b1", {eventId: "e-conf", sequence: 1, status: "committed", totalRows: 1});
    await emu.seed("importBatches/b1/rows/2", {sourceRowNumber: 2, importRecordId: "b1-000002", result: "created"});
    await emu.seed("programAttendances/b1-000002_alpha", {eventId: "e-conf", participantId: "b1-000002", programId: "alpha", plannedCount: 2, checkedIn: false});
    await emu.seed("participants/b1-000002", confirmedParticipant);
    await emu.seed("checkIns/b1-000002", {participantId: "b1-000002", eventId: "e-conf", checkedIn: false});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(label, () => {
      test("importBatches: get / list / create / update / delete がすべて拒否される", async () => {
        assert.equal(await emu.get("importBatches/b1", token), 403);
        assert.equal(await emu.get("importBatches/none", token), 403);
        assert.equal(await emu.list("importBatches", token), 403);
        assert.equal(await emu.create("importBatches", "b2", {eventId: "e-conf", status: "committed"}, token), 403);
        assert.equal(await emu.update("importBatches/b1", {status: "failed"}, token), 403);
        assert.equal(await emu.update("importBatches/b1", {createdCount: 0}, token), 403);
        assert.equal(await emu.remove("importBatches/b1", token), 403);
      });
      test("importBatches/{id}/rows(行の監査): get / list / create / update / delete がすべて拒否される", async () => {
        assert.equal(await emu.get("importBatches/b1/rows/2", token), 403);
        assert.equal(await emu.list("importBatches/b1/rows", token), 403);
        assert.equal(await emu.create("importBatches/b1/rows", "3", {sourceRowNumber: 3, result: "created"}, token), 403);
        assert.equal(await emu.update("importBatches/b1/rows/2", {result: "excluded"}, token), 403);
        assert.equal(await emu.remove("importBatches/b1/rows/2", token), 403);
      });
      test("programAttendances: get / list / create / update / delete がすべて拒否される", async () => {
        assert.equal(await emu.get("programAttendances/b1-000002_alpha", token), 403);
        assert.equal(await emu.list("programAttendances", token), 403);
        assert.equal(await emu.create("programAttendances", "b1-000002_beta", {eventId: "e-conf", participantId: "b1-000002", programId: "beta", plannedCount: 1}, token), 403);
        assert.equal(await emu.update("programAttendances/b1-000002_alpha", {checkedIn: true, attendedCount: 2}, token), 403);
        assert.equal(await emu.update("programAttendances/b1-000002_alpha", {plannedCount: 99}, token), 403);
        assert.equal(await emu.remove("programAttendances/b1-000002_alpha", token), 403);
      });
      test("confirmed participant: 更新(本人情報・publicId・status・旧経路の項目)・作成・削除がすべて拒否される", async () => {
        for (const change of [{name: "改ざん"}, {email: "y@example.invalid"}, {publicId: "pub_forged"}, {status: "cancelled"}, {importBatchId: "b9"},
          {participationConfirmed: true, updatedAt: new Date()}, {reconfirmed: true, attendanceResponse: "attending", updatedAt: new Date()}]) {
          assert.equal(await emu.update("participants/b1-000002", change, token), 403, JSON.stringify(Object.keys(change)));
        }
        assert.equal(await emu.create("participants", "b1-000003", {...confirmedParticipant, participantId: "b1-000003", importRow: 3, registeredCount: 1, registrationType: "preRegistered"}, token), 403);
        assert.ok(denied(await emu.create("participants", "b1-000004", {...confirmedParticipant, participantId: "b1-000004"}, token)));
        assert.equal(await emu.remove("participants/b1-000002", token), 403);
      });
      test("confirmedイベントの旧受付(checkIns)・旧設定(events)への書込みも拒否される", async () => {
        assert.equal(await emu.update("checkIns/b1-000002", {checkedIn: true, attendedCount: 1, checkedInAt: new Date(), updatedAt: new Date()}, token), 403);
        assert.equal(await emu.update("events/e-conf", {importSequence: 0}, token), 403);
        assert.equal(await emu.update("events/e-conf", {venue: "書換え"}, token), 403);
      });
    });
  }

  test("拒否された書込みは実際には反映されていない(オーナー権限で確認)", async () => {
    const read = async (path) => (await fetch(`${emu.base}/${path}`, {headers: {Authorization: "Bearer owner"}})).json();
    assert.equal((await read("importBatches/b1")).fields.status.stringValue, "committed");
    assert.equal((await read("importBatches/b1/rows/2")).fields.result.stringValue, "created");
    assert.equal((await read("programAttendances/b1-000002_alpha")).fields.plannedCount.integerValue, "2");
    assert.equal((await read("participants/b1-000002")).fields.name.stringValue, "架空");
    assert.equal((await read("events/e-conf")).fields.importSequence.integerValue, "1");
    for (const missing of ["importBatches/b2", "importBatches/b1/rows/3", "programAttendances/b1-000002_beta", "participants/b1-000003", "participants/b1-000004"]) {
      assert.equal((await fetch(`${emu.base}/${missing}`, {headers: {Authorization: "Bearer owner"}})).status, 404, missing);
    }
  });

  test("Rulesの静的検査: importBatches(と配下のrows)・programAttendancesのallowは if false のみ", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const batches = rules.match(/match \/importBatches\/\{[^}]+\}\s*\{([\s\S]*?)\n    \}/);
    assert.ok(batches, "importBatchesのmatchが必要");
    const allows = batches[1].match(/allow[^;]*;/g);
    assert.deepEqual(allows, ["allow read, write: if false;", "allow read, write: if false;"]);
    assert.ok(/match \/rows\/\{[^}]+\}/.test(batches[1]), "rowsのmatchが必要");
    const attendances = rules.match(/match \/programAttendances\/\{[^}]+\}\s*\{([^}]*)\}/);
    assert.deepEqual(attendances[1].match(/allow[^;]*;/g), ["allow read, write: if false;"]);
    assert.doesNotMatch(rules, /match\s+\/\{[^}]*=\*\*\}/);
  });
});
