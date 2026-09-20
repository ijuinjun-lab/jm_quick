// 旧機能(旧Scheduler・旧一括メール・個別案内メール・当日参加登録)が、
// legacyイベントでは従来どおり動き、confirmed(新方式)や未知のflowでは副作用ゼロで拒否/除外されることを、
// 実際のハンドラを呼び出して確認する。Firestoreはメモリ上のフェイク、メールAPIはfetchスタブ(実通信なし)。
const assert = require("node:assert/strict");
const {afterEach, describe, test} = require("node:test");
const {FakeFirestore, ts} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");

const HOUR = 3600 * 1000;
const now = Date.now();
const baseEvent = (id, extra = {}) => ({
  eventId: id,
  eventName: `イベント${id}`,
  senderName: `送信者${id}`,
  venue: "会場",
  contact: "問い合わせ",
  startAt: ts(new Date(now + HOUR)),
  registrationDeadline: ts(new Date(now - 24 * HOUR)),
  // 旧Schedulerの送信条件(confirmationSendAt <= now < startAt)に一致させる
  confirmationSendAt: ts(new Date(now - HOUR)),
  reconfirmEnabled: false,
  ...extra,
});
const participant = (id, eventId, extra = {}) => ({
  participantId: id,
  eventId,
  publicId: `pub_${id}_0123456789abcdef01234567`,
  name: `参加者${id}`,
  email: `${id}@example.com`,
  registeredCount: 1,
  registrationType: "preRegistered",
  invitationSent: false,
  participationConfirmed: true,
  reconfirmed: false,
  reconfirmationMailSent: false,
  attendanceResponse: null,
  ...extra,
});

const NON_LEGACY = [
  ["confirmed", {flow: "confirmed"}],
  ["未知のflow(タイプミス)", {flow: "confirmd"}],
];

let net;
afterEach(() => net?.restore());

function setup(seed) {
  const db = new FakeFirestore(seed);
  net = stubFetch();
  const index = loadIndex(db);
  return {db, index, mail: net.calls};
}

const rejectsPrecondition = (promise) =>
  assert.rejects(promise, (error) => error.code === "failed-precondition");

describe("旧Scheduler(sendScheduledConfirmationMail)", () => {
  test("legacyイベントは従来どおり参加予定確認メールを送る", async () => {
    const {db, index, mail} = setup({
      "events/e1": baseEvent("e1"),
      "participants/p1": participant("p1", "e1"),
    });
    await index.sendScheduledConfirmationMail.run({});
    assert.equal(mail.length, 1);
    assert.equal(mail[0].body.to, "p1@example.com");
    assert.equal(db.store.get("events/e1").reconfirmEnabled, true);
    assert.equal(db.store.get("participants/p1").reconfirmationMailSent, true);
  });

  for (const [label, flow] of NON_LEGACY) {
    test(`${label}イベントは旧条件に完全一致していても処理せず、何も書き込まない`, async () => {
      const {db, index, mail} = setup({
        "events/e1": baseEvent("e1", flow),
        "participants/p1": participant("p1", "e1"),
        "events/e2": baseEvent("e2"),
        "participants/p2": participant("p2", "e2"),
      });
      await index.sendScheduledConfirmationMail.run({});
      assert.deepEqual(mail.map((m) => m.body.to), ["p2@example.com"], "legacy側だけに送る");
      assert.equal(db.writesTo("events/e1").length, 0);
      assert.equal(db.writesTo("participants/p1").length, 0);
      assert.equal(db.store.get("events/e1").reconfirmEnabled, false);
    });
  }
});

describe("旧一括メール(startBulk*/processBulkMailJobs)", () => {
  test("legacyイベントは従来どおりジョブを作成し、対象者を積む", async () => {
    const {db, index} = setup({
      "events/e1": baseEvent("e1"),
      "participants/p1": participant("p1", "e1", {participationConfirmed: false}),
    });
    const result = await index.startBulkInvitationMail.run({data: {eventId: "e1"}});
    assert.equal(result.success, true);
    assert.equal(result.totalCount, 1);
    assert.equal(db.store.get("mailJobs/e1_invitation").status, "queued");
    assert.equal(db.store.get("mailJobs/e1_invitation/items/p1").status, "pending");
  });

  for (const [label, flow] of NON_LEGACY) {
    for (const start of ["startBulkInvitationMail", "startBulkReconfirmationMail"]) {
      test(`ジョブ作成: ${label}イベントは${start}を拒否し、何も書き込まない`, async () => {
        const {db, index} = setup({
          "events/e1": baseEvent("e1", flow),
          "participants/p1": participant("p1", "e1"),
        });
        await rejectsPrecondition(index[start].run({data: {eventId: "e1"}}));
        assert.equal(db.writes.length, 0);
      });
    }

    test(`ジョブ実行: ${label}イベントの既存ジョブは処理せずblockedにし、メールを送らない`, async () => {
      const {db, index, mail} = setup({
        "events/e1": baseEvent("e1", flow),
        "participants/p1": participant("p1", "e1", {participationConfirmed: false}),
        "mailJobs/e1_invitation": {eventId: "e1", type: "invitation", status: "queued"},
        "mailJobs/e1_invitation/items/p1": {participantId: "p1", eventId: "e1", status: "pending"},
      });
      await index.processBulkMailJobs.run({});
      assert.equal(mail.length, 0);
      assert.equal(db.store.get("mailJobs/e1_invitation").status, "blocked");
      assert.equal(db.store.get("mailJobs/e1_invitation/items/p1").status, "pending");
      assert.equal(db.writesTo("participants/").length, 0);
      assert.equal(db.writesTo("mailLogs").length, 0);
    });
  }

  test("ジョブ実行: legacyイベントは従来どおり送信して完了する", async () => {
    const {db, index, mail} = setup({
      "events/e1": baseEvent("e1"),
      "participants/p1": participant("p1", "e1", {participationConfirmed: false}),
      "mailJobs/e1_invitation": {eventId: "e1", type: "invitation", status: "queued",
        sentCount: 0, failedCount: 0, skippedCount: 0},
      "mailJobs/e1_invitation/items/p1": {participantId: "p1", eventId: "e1", status: "pending"},
    });
    await index.processBulkMailJobs.run({});
    assert.equal(mail.length, 1);
    assert.equal(mail[0].body.to, "p1@example.com");
    assert.equal(db.store.get("participants/p1").invitationSent, true);
    assert.equal(db.store.get("mailJobs/e1_invitation").status, "completed");
  });
});

describe("個別案内メール・旧再確認メール(sendParticipantMail)", () => {
  const call = (index, eventId, type) => index.sendParticipantMail.run({
    data: {participantId: "p1", publicId: participant("p1", eventId).publicId, eventId, type},
  });

  test("legacyイベントは従来どおり案内メールを送る", async () => {
    const {db, index, mail} = setup({
      "events/e1": baseEvent("e1"),
      "participants/p1": participant("p1", "e1", {participationConfirmed: false}),
    });
    const result = await call(index, "e1", "invitation");
    assert.equal(result.success, true);
    assert.equal(mail.length, 1);
    assert.equal(db.store.get("participants/p1").invitationSent, true);
  });

  for (const [label, flow] of NON_LEGACY) {
    for (const type of ["invitation", "reconfirmation", "walkIn"]) {
      test(`${label}イベントは種別${type}を拒否し、送信も書込みもしない`, async () => {
        const {db, index, mail} = setup({
          "events/e1": baseEvent("e1", flow),
          "participants/p1": participant("p1", "e1", {participationConfirmed: false}),
        });
        await rejectsPrecondition(call(index, "e1", type));
        assert.equal(mail.length, 0);
        assert.equal(db.writes.length, 0);
      });
    }
  }
});

describe("当日参加登録(registerWalkIn)", () => {
  const input = (eventId) => ({data: {eventId, name: "当日 太郎", email: "walkin@example.com", registeredCount: 1}});

  test("legacyイベントは従来どおり登録してメールを送る", async () => {
    const {db, index, mail} = setup({"events/e1": baseEvent("e1")});
    const result = await index.registerWalkIn.run(input("e1"));
    assert.equal(result.success, true);
    assert.equal(result.mailSent, true);
    assert.equal(mail.length, 1);
    assert.equal(db.writesTo("participants/").some((w) => w.op === "create"), true);
    assert.equal(db.writesTo("walkInRegistrations/").length, 1);
  });

  for (const [label, flow] of NON_LEGACY) {
    test(`${label}イベントは登録を拒否し、参加者・受付・一意キーを作らず、メールも送らない`, async () => {
      const {db, index, mail} = setup({"events/e1": baseEvent("e1", flow)});
      await rejectsPrecondition(index.registerWalkIn.run(input("e1")));
      assert.equal(mail.length, 0);
      assert.equal(db.writes.length, 0);
    });
  }
});

test("テスト中の外部通信は0件(メールAPIへの呼び出しはすべてスタブ経由)", async () => {
  const {index, mail} = setup({"events/e1": baseEvent("e1", {flow: "confirmed"})});
  await index.sendScheduledConfirmationMail.run({});
  assert.equal(mail.length, 0);
});
