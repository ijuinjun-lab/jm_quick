const {test} = require("node:test");
const assert = require("node:assert/strict");
const {EVENT_ID, ROLES, NAMES, TYPES, participationType, typeSummary} = require("../participation_types");
const {planImportRows} = require("../import_rows");
const {buildMailSnapshot} = require("../mail_view_model");
const {renderWinnerMail, renderReminderMail} = require("../mail_render");
const {receptionQrPayload} = require("../pass_urls");
const {mapping, cells, event, person} = require("../test_support/participation_fixture");
const {fakeQrPng, APP_BASE_URL} = require("../test_support/mail_fixtures");
const plan = (value, overrides) => planImportRows({rows: [{sourceRowNumber: 2, cells: cells(value, overrides)}], mapping}).results[0];
for (const type of TYPES) {
  test(`${type.label}: CSV分類・本文・人数・時間・不参加除外・単一QR・リマインド`, async () => {
    const row = plan(type.value);
    assert.equal(row.status, "ready");
    assert.equal(participationType(EVENT_ID, row.attendances), type.value);
    assert.equal(participationType(EVENT_ID, [...row.attendances].reverse()), type.value);
    const participant = person();
    const attendances = row.attendances.map((a) => ({...a, eventId: EVENT_ID, participantId: participant.participantId}));
    const payload = receptionQrPayload({appBaseUrl: APP_BASE_URL, ...participant});
    for (const [render, templateField] of [[renderWinnerMail, "winnerMailTemplate"], [renderReminderMail, "reminderMailTemplate"]]) {
      const {snapshot} = buildMailSnapshot(EVENT_ID, event(), {templateField});
      let qrCalls = 0;
      const result = await render({snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: async (p) => { qrCalls++; return fakeQrPng(p); }});
      assert.equal(result.ok, true);
      assert.equal(result.qrPayload, payload);
      assert.equal(qrCalls, 1);
      assert.equal(result.attachments.length, 1);
      assert.equal((result.html.match(/<img /g) || []).length, 1);
      assert.equal(result.viewModel.participationType, type.value);
      for (const [programId, role] of Object.entries(ROLES)) {
        const expected = type.value.split("_").includes(role);
        assert.equal(result.text.includes(`■${NAMES[role]}`), expected);
        assert.equal(result.html.includes(`■${NAMES[role]}`), expected);
        const item = result.viewModel.programs.find((p) => p.programId === programId);
        if (expected) {
          assert.equal(item.plannedCount, {cat: 2, dog: 3, talk: 4}[role]);
          assert.equal(item.timeText, {cat: "10:10〜10:50", dog: "14:10〜14:50", talk: "16:00〜17:00"}[role]);
          assert.ok(result.text.includes(`${role === "talk" ? "開催時間" : "参加時間"}：${item.timeText}\n参加人数：${item.plannedCount}名`));
        }
      }
      assert.equal(result.text.includes("1枠あたり約40分"), type.value !== "talk");
      assert.ok(result.text.indexOf("【開催情報】") < result.text.indexOf("＜お申し込み内容＞"));
      assert.ok(result.text.includes("2026年"));
      assert.ok(!result.text.includes("2025年"));
    }
  });
}
test("未設定・未知program・重複・不正人数はタイプを作らない。他イベントに対応を流用しない", () => {
  for (const attendances of [[], null, [{programId: "unknown", plannedCount: 1}], [{programId: "program-1", plannedCount: 0}], [{programId: "program-1", plannedCount: "2"}], [{programId: "program-1", plannedCount: 1}, {programId: "program-1", plannedCount: 1}]]) assert.equal(participationType(EVENT_ID, attendances), null);
  assert.equal(participationType("other", plan("cat").attendances), null);
});
test("CSV互換: 空欄は不参加、残存人数を参加としない。未知トーク・参加人数不足は従来のreview/error", () => {
  const blank = plan("cat", {"午前参加時間": ""});
  assert.equal(blank.status, "review");
  assert.equal(participationType(EVENT_ID, blank.attendances), null);
  const cat = plan("cat");
  assert.deepEqual(cat.attendances.map((a) => a.programId), ["program-1"]);
  assert.equal(plan("cat", {"トークショー": "不明"}).status, "review");
  assert.equal(plan("cat", {"午前参加人数": ""}).status, "review");
  assert.equal(plan("cat", {"午前参加人数": "不正"}).status, "error");
  assert.equal(plan("cat", {"午前参加人数": "0"}).status, "error");
  // 既存profileは表示用ラベルを保持する。今回、時刻範囲の厳格化はしない。
  assert.equal(plan("cat", {"午前参加時間": "22:20-21:20"}).attendances[0].slotLabel, "22:20-21:20");
  const records = [...TYPES.map((t) => plan(t.value)), plan("cat", {"トークショー": "不明"})];
  assert.deepEqual(typeSummary(EVENT_ID, records).map((t) => t.count), [1, 1, 1, 1, 1, 1, 1]);
});
test("トーク時刻を推測しない。program時刻はメール設定より優先", async () => {
  const participant = person();
  const attendances = plan("talk").attendances.map((a) => ({...a, eventId: EVENT_ID, participantId: participant.participantId}));
  const render = async (e) => renderWinnerMail({snapshot: buildMailSnapshot(EVENT_ID, e).snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
  assert.deepEqual((await render(event({confirmedMailSettings: {}}))).problems, ["attendance-time-missing"]);
  const e = event();
  Object.assign(e.programs[2], {startAt: new Date("2026-11-30T04:00:00Z"), endAt: new Date("2026-11-30T05:00:00Z")});
  assert.equal((await render(e)).viewModel.programs[0].timeText, "13:00〜14:00");
});

const {rolesFor, mappingFor} = require("../participation_types");
test("mapping validation / explicit override / legacy migration", () => {
  const e = event();
  assert.deepEqual(rolesFor(EVENT_ID, e), ROLES);
  assert.equal(rolesFor("arbitrary-event", e), null);
  e.participationMapping = {catProgramId: "program-2", dogProgramId: "program-1", talkProgramId: "program-3"};
  assert.equal(rolesFor(EVENT_ID, e)["program-2"], "cat");
  assert.deepEqual(mappingFor("arbitrary-event", e), e.participationMapping);
  for (const bad of [{}, [], "bad", {...e.participationMapping, extra: true}, {...e.participationMapping, dogProgramId: "program-2"}, {...e.participationMapping, dogProgramId: "unknown"}]) {
    assert.throws(() => rolesFor(EVENT_ID, {...e, participationMapping: bad}));
    assert.throws(() => buildMailSnapshot("any-event", {...e, participationMapping: bad}));
  }
  assert.equal(rolesFor(EVENT_ID, {...e, participationMapping: null}), null);
});
for (const type of TYPES) {
  test(`arbitrary event and program IDs: ${type.value} / mail / reminder / snapshot / QR`, async () => {
    const eventId = `event-${require("node:crypto").randomUUID()}`;
    const ids = {"program-1": "felines", "program-2": "canines", "program-3": "session"};
    const e = event({participationMapping: {catProgramId: "felines", dogProgramId: "canines", talkProgramId: "session"}});
    e.programs = e.programs.map((p) => ({...p, programId: ids[p.programId]}));
    const participant = {...person(), eventId};
    const attendances = plan(type.value).attendances.map((a) => ({...a, programId: ids[a.programId], eventId, participantId: participant.participantId}));
    assert.equal(participationType(eventId, attendances, e), type.value);
    for (const [render, templateField] of [[renderWinnerMail, "winnerMailTemplate"], [renderReminderMail, "reminderMailTemplate"]]) {
      const {snapshot} = buildMailSnapshot(eventId, e, {templateField});
      const saved = JSON.parse(JSON.stringify(snapshot));
      const result = await render({snapshot: saved, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
      assert.equal(result.ok, true);
      assert.equal(result.viewModel.participationType, type.value);
      assert.equal((result.html.match(/<img /g) || []).length, 1);
      for (const role of ["cat", "dog", "talk"]) assert.equal(result.text.includes(`■${NAMES[role]}`), type.value.split("_").includes(role));
      // A later edit cannot alter an already-created delivery snapshot.
      assert.deepEqual(saved.event.participationMapping, e.participationMapping);
    }
  });
}
test("HEBEL HAUS×sippo基準文案: 確定件名・送信専用文言・問い合わせ文言が当選メール・リマインドに含まれる", async () => {
  const preset = require("../sippo_mail_preset");
  const SUBJECT = "【ご参加予約確定のお知らせ】 HEBEL HAUS×sippo 保護犬猫譲渡会・トークセッション";
  const SEND_ONLY = "このメールは送信専用アドレスから配信されています。";
  const CONTACT = "お問い合わせの際は事務局メールアドレス（sippo-support@info-event-jimukyoku.jp）までお願いいたします。";
  assert.equal(preset.subject, SUBJECT);
  assert.ok(preset.introBody.includes(SEND_ONLY));
  assert.ok(preset.introBody.includes(CONTACT));
  const participant = person();
  const attendances = plan("talk").attendances.map((a) => ({...a, eventId: EVENT_ID, participantId: participant.participantId}));
  const {snapshot} = buildMailSnapshot(EVENT_ID, event());
  const result = await renderWinnerMail({snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
  assert.equal(result.ok, true);
  assert.equal(result.subject, SUBJECT);
  for (const body of [result.text, result.html]) for (const sentence of [SEND_ONLY, CONTACT]) assert.ok(body.includes(sentence));
  const reminder = await renderReminderMail({snapshot: buildMailSnapshot(EVENT_ID, event(), {templateField: "reminderMailTemplate"}).snapshot,
    participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
  for (const sentence of [SEND_ONLY, CONTACT]) assert.ok(reminder.text.includes(sentence));
});
