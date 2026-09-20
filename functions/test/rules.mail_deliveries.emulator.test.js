// 当選メールの送信ジョブ(sendJobs・items)・配送記録(mailDeliveries)・テンプレート(events.winnerMailTemplate)が、
// クライアントSDKから直接読み書きできないことを、ローカルEmulator(localhostのみ)で検証する。
// 未認証・admin相当・staff相当のいずれでも、get/list/create/update/deleteが拒否される(Admin SDK・admin専用callableのみ)。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

describe("Firestore Rules: 当選メール(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const admin = unsignedToken("u-admin", {role: "admin", admin: true});
  const staff = unsignedToken("u-staff", {role: "staff"});
  const CLIENTS = [["未認証", undefined], ["admin相当", admin], ["staff相当", staff]];
  const template = {subject: "件名", introBody: "冒頭", closingBody: "締め", notesBody: null, version: 1, updatedBy: "u-admin"};

  before(async () => {
    emu = await startEmulator();
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    await emu.seed("events/e-conf", {eventId: "e-conf", eventName: "架空", flow: "confirmed", winnerMailTemplate: template, venueInfo: {address: "住所", access: "アクセス"}});
    await emu.seed("sendJobs/winner-b1", {eventId: "e-conf", batchId: "b1", type: "winner", status: "ready", targetCount: 1, templateVersion: 1});
    await emu.seed("sendJobs/winner-b1/items/b1-000002", {participantId: "b1-000002", status: "pending", attemptCount: 0});
    await emu.seed("mailDeliveries/b1-000002_winner", {participantId: "b1-000002", type: "winner", status: "pending", jobId: "winner-b1", attemptCount: 0});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(label, () => {
      test("sendJobs: get / list / create / update / delete がすべて拒否される", async () => {
        assert.equal(await emu.get("sendJobs/winner-b1", token), 403);
        assert.equal(await emu.get("sendJobs/none", token), 403);
        assert.equal(await emu.list("sendJobs", token), 403);
        assert.equal(await emu.create("sendJobs", "winner-b2", {eventId: "e-conf", status: "completed"}, token), 403);
        assert.equal(await emu.update("sendJobs/winner-b1", {status: "completed", sentCount: 99}, token), 403);
        assert.equal(await emu.update("sendJobs/winner-b1", {templateVersion: 2}, token), 403);
        assert.equal(await emu.remove("sendJobs/winner-b1", token), 403);
      });
      test("sendJobs/{id}/items: get / list / create / update / delete がすべて拒否される", async () => {
        assert.equal(await emu.get("sendJobs/winner-b1/items/b1-000002", token), 403);
        assert.equal(await emu.list("sendJobs/winner-b1/items", token), 403);
        assert.equal(await emu.create("sendJobs/winner-b1/items", "b1-000003", {participantId: "b1-000003", status: "sent"}, token), 403);
        assert.equal(await emu.update("sendJobs/winner-b1/items/b1-000002", {status: "sent"}, token), 403);
        assert.equal(await emu.remove("sendJobs/winner-b1/items/b1-000002", token), 403);
      });
      test("mailDeliveries: get / list / create / update / delete がすべて拒否される(配送の正本を書き換えられない)", async () => {
        assert.equal(await emu.get("mailDeliveries/b1-000002_winner", token), 403);
        assert.equal(await emu.list("mailDeliveries", token), 403);
        assert.equal(await emu.create("mailDeliveries", "b1-000009_winner", {participantId: "b1-000009", status: "sent"}, token), 403);
        assert.equal(await emu.update("mailDeliveries/b1-000002_winner", {status: "sent"}, token), 403, "pending→sentへの偽装");
        assert.equal(await emu.update("mailDeliveries/b1-000002_winner", {status: "pending", attemptCount: 0, claimId: null}, token), 403);
        assert.equal(await emu.remove("mailDeliveries/b1-000002_winner", token), 403);
      });
      test("confirmedイベントのテンプレート(winnerMailTemplate・venueInfo)は、クライアントから更新・削除できない(admin専用callable経由のみ)", async () => {
        assert.equal(await emu.update("events/e-conf", {winnerMailTemplate: {...template, subject: "改ざん", version: 2}}, token), 403);
        assert.equal(await emu.update("events/e-conf", {"winnerMailTemplate": null}, token), 403);
        assert.equal(await emu.update("events/e-conf", {venueInfo: {address: "改ざん"}}, token), 403);
        assert.equal(await emu.remove("events/e-conf", token), 403);
        assert.equal(await emu.create("events", "e-new", {eventId: "e-new", flow: "confirmed", winnerMailTemplate: template}, token), 403);
      });
    });
  }

  test("拒否された書込みは実際には反映されていない(オーナー権限で確認)", async () => {
    const read = async (path) => (await fetch(`${emu.base}/${path}`, {headers: {Authorization: "Bearer owner"}})).json();
    assert.equal((await read("sendJobs/winner-b1")).fields.status.stringValue, "ready");
    assert.equal((await read("sendJobs/winner-b1/items/b1-000002")).fields.status.stringValue, "pending");
    assert.equal((await read("mailDeliveries/b1-000002_winner")).fields.status.stringValue, "pending");
    const event = await read("events/e-conf");
    assert.equal(event.fields.winnerMailTemplate.mapValue.fields.subject.stringValue, "件名");
    for (const missing of ["sendJobs/winner-b2", "sendJobs/winner-b1/items/b1-000003", "mailDeliveries/b1-000009_winner", "events/e-new"]) {
      assert.equal((await fetch(`${emu.base}/${missing}`, {headers: {Authorization: "Bearer owner"}})).status, 404, missing);
    }
  });

  test("Rulesの静的検査: sendJobs(と配下のitems)・mailDeliveriesのallowは if false のみで、旧mailJobsは変更されていない", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const jobs = rules.match(/match \/sendJobs\/\{[^}]+\}\s*\{([\s\S]*?)\n    \}/);
    assert.ok(jobs, "sendJobsのmatchが必要");
    assert.deepEqual(jobs[1].match(/allow[^;]*;/g), ["allow read, write: if false;", "allow read, write: if false;"]);
    assert.ok(/match \/items\/\{[^}]+\}/.test(jobs[1]), "itemsのmatchが必要");
    const deliveries = rules.match(/match \/mailDeliveries\/\{[^}]+\}\s*\{([^}]*)\}/);
    assert.deepEqual(deliveries[1].match(/allow[^;]*;/g), ["allow read, write: if false;"]);
    assert.doesNotMatch(rules, /match\s+\/\{[^}]*=\*\*\}/);
    // 旧mailJobs(旧processor用)は従来のまま: 読取は限定的に許可・書込みは禁止(Phase 10まで変更しない)
    const legacy = rules.match(/match \/mailJobs\/\{jobId\}\s*\{([\s\S]*?)\n      match/);
    assert.ok(legacy && /allow create, update, delete: if false;/.test(legacy[1]));
  });
});
