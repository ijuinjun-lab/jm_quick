const assert = require("node:assert/strict");
const {test} = require("node:test");
const {ts} = require("../test_support/fake_firestore");
const {isLegacyFlow, isConfirmedFlow, legacyConfirmationDue} = require("../flow");

test("flow未設定・null・空・legacyは従来方式として扱う", () => {
  for (const event of [{}, {flow: undefined}, {flow: null}, {flow: ""}, {flow: "legacy"}, undefined, null]) {
    assert.equal(isLegacyFlow(event), true, JSON.stringify(event));
    assert.equal(isConfirmedFlow(event), false, JSON.stringify(event));
  }
});

test("flow=confirmedだけが新方式で、従来方式ではない", () => {
  assert.equal(isConfirmedFlow({flow: "confirmed"}), true);
  assert.equal(isLegacyFlow({flow: "confirmed"}), false);
});

test("未知のflow値(タイプミス等)は従来方式でも新方式でもなく、旧機能の対象外になる", () => {
  for (const flow of ["confirmd", "Confirmed", "CONFIRMED", "legacy ", " ", "v2", 1, true]) {
    assert.equal(isLegacyFlow({flow}), false, String(flow));
    assert.equal(isConfirmedFlow({flow}), false, String(flow));
  }
});

const NOW = new Date("2026-11-29T10:30:00Z");
const dueEvent = (extra = {}) => ({
  confirmationSendAt: ts(new Date("2026-11-29T10:00:00Z")),
  startAt: ts(new Date("2026-11-30T10:00:00Z")),
  ...extra,
});

test("旧Scheduler: legacyイベントは従来どおり送信期間内だけ対象になる", () => {
  assert.equal(legacyConfirmationDue(dueEvent(), NOW), true);
  assert.equal(legacyConfirmationDue(dueEvent({flow: "legacy"}), NOW), true);
  assert.equal(legacyConfirmationDue(dueEvent(), new Date("2026-11-29T09:59:59Z")), false);
  assert.equal(legacyConfirmationDue(dueEvent(), new Date("2026-11-30T10:00:00Z")), false);
  assert.equal(legacyConfirmationDue({startAt: dueEvent().startAt}, NOW), false);
  assert.equal(legacyConfirmationDue({confirmationSendAt: dueEvent().confirmationSendAt}, NOW), false);
});

test("旧Scheduler: confirmedイベントは旧条件に完全一致していても絶対に対象外", () => {
  assert.equal(legacyConfirmationDue(dueEvent({flow: "confirmed"}), NOW), false);
  assert.equal(legacyConfirmationDue(dueEvent({flow: "confirmed", reconfirmEnabled: true}), NOW), false);
  assert.equal(legacyConfirmationDue(dueEvent({flow: "confirmd"}), NOW), false);
});
