// 旧削除callable(deleteParticipant / deleteEvent)は、新方式(confirmed)のデータを黙って孤児にしないよう拒否し、
// 従来方式(legacy)は従来どおり削除できることを確認する。Firestoreはメモリ上のフェイク、外部通信なし。
const assert = require("node:assert/strict");
const {afterEach, describe, test} = require("node:test");
const {FakeFirestore} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");

let net;
afterEach(() => net?.restore());
// Phase 10C: 削除はadmin専用になった(以前は認証なし)。従来の検証はadminが呼んだ場合として維持し、認証なし・権限なしの拒否は legacy_auth_boundary.test.js が検証する。
const ADMIN = {uid: "admin1"};
const setup = (seed) => {
  const db = new FakeFirestore({"accessRoles/admin1": {role: "admin", active: true}, ...seed});
  net = stubFetch();
  return {db, index: loadIndex(db), mail: net.calls};
};
const participant = (id, eventId) => ({participantId: id, eventId, publicId: `pub_${id}`, name: "架空", email: `${id}@example.invalid`});

describe("旧削除callable", () => {
  for (const [label, flow] of [["confirmed", {flow: "confirmed"}], ["未知のflow", {flow: "confirmd"}]]) {
    test(`deleteParticipant: ${label}イベントの参加者は削除を拒否し、何も書き込まない`, async () => {
      const {db, index} = setup({"events/e1": {eventId: "e1", ...flow}, "participants/p1": participant("p1", "e1"),
        "programAttendances/p1_alpha": {eventId: "e1", participantId: "p1", programId: "alpha", plannedCount: 2}, "checkIns/p1": {eventId: "e1"}});
      await assert.rejects(index.deleteParticipant.run({auth: ADMIN, data: {eventId: "e1", participantId: "p1"}}), (e) => e.code === "failed-precondition");
      assert.equal(db.writes.length, 0);
      assert.ok(db.store.has("participants/p1"));
      assert.ok(db.store.has("programAttendances/p1_alpha"));
    });
    test(`deleteEvent: ${label}イベントは削除を拒否し、参加者・attendance・取込の記録を含め何も書き込まない`, async () => {
      const {db, index} = setup({"events/e1": {eventId: "e1", ...flow}, "participants/p1": participant("p1", "e1"),
        "programAttendances/p1_alpha": {eventId: "e1"}, "importBatches/b1": {eventId: "e1"}, "importBatches/b1/rows/2": {sourceRowNumber: 2}});
      await assert.rejects(index.deleteEvent.run({auth: ADMIN, data: {eventId: "e1"}}), (e) => e.code === "failed-precondition");
      assert.equal(db.writes.length, 0);
      for (const path of ["events/e1", "participants/p1", "programAttendances/p1_alpha", "importBatches/b1", "importBatches/b1/rows/2"]) {
        assert.ok(db.store.has(path), path);
      }
    });
  }

  test("deleteParticipant: legacyイベントは従来どおり削除できる(旧受付・旧ジョブ項目も掃除される)", async () => {
    const {db, index} = setup({"events/e1": {eventId: "e1"}, "participants/p1": participant("p1", "e1"), "checkIns/p1": {eventId: "e1"}});
    const result = await index.deleteParticipant.run({auth: ADMIN, data: {eventId: "e1", participantId: "p1"}});
    assert.deepEqual(result, {success: true});
    assert.ok(!db.store.has("participants/p1"));
    assert.ok(!db.store.has("checkIns/p1"));
  });

  test("deleteEvent: legacyイベントは従来どおり削除できる", async () => {
    const {db, index} = setup({"events/e1": {eventId: "e1"}, "participants/p1": participant("p1", "e1"), "checkIns/p1": {eventId: "e1"}});
    const result = await index.deleteEvent.run({auth: ADMIN, data: {eventId: "e1"}});
    assert.equal(result.success, true);
    assert.equal(result.participantCount, 1);
    assert.ok(!db.store.has("events/e1"));
    assert.ok(!db.store.has("participants/p1"));
  });

  test("deleteParticipant: eventが既に存在しない孤児participantの削除は従来どおり(guardの対象外)", async () => {
    const {db, index} = setup({"participants/p9": participant("p9", "gone")});
    assert.deepEqual(await index.deleteParticipant.run({auth: ADMIN, data: {eventId: "gone", participantId: "p9"}}), {success: true});
    assert.ok(!db.store.has("participants/p9"));
  });
});
