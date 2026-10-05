const assert = require("node:assert/strict");
const {before, after, test, describe} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {composeReminderMailFor} = require("../confirmed/winner_mail_message");
const {buildMailSnapshot} = require("../confirmed/mail_view_model");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {EVENT_ID, TYPES} = require("../confirmed/participation_types");
const {mapping, table, event} = require("../confirmed/test_support/participation_fixture");
const {fakeQrPng, APP_BASE_URL} = require("../confirmed/test_support/mail_fixtures");
describe("7タイプ: CSV→正本保存→参加者別メール・リマインド (localhost Emulator only)", {skip: skipReason()}, () => {
  let env;
  before(async () => { env = await startAdminEmulator(); });
  after(() => env?.stop());
  test("全タイプのpreview/commit、設定保存、プレビュー対象、正本再読込", async () => {
    const {db, FieldValue} = env;
    const serverTimestamp = () => FieldValue.serverTimestamp();
    await db.doc(`events/${EVENT_ID}`).set(event());
    const imports = createImportApi({getDb: () => db, serverTimestamp});
    const request = buildImportRequest({table: table(), mapping, eventId: EVENT_ID});
    const preview = await imports.preview({data: request});
    assert.equal(preview.readyCount, 7);
    assert.equal(preview.reviewCount, 0);
    assert.deepEqual(preview.participationTypes.map((t) => t.count), [1, 1, 1, 1, 1, 1, 1]);
    assert.deepEqual(preview.rows.map((r) => r.participationType), TYPES.map((t) => t.value));
    const invalidTable = table();
    invalidTable.records[0][invalidTable.headers.indexOf("トークショー")] = "不明";
    invalidTable.records[1][invalidTable.headers.indexOf("午前参加人数")] = "不正";
    const invalidPreview = await imports.preview({data: buildImportRequest({table: invalidTable, mapping, eventId: EVENT_ID, clientRequestId: "invalidBatch"})});
    assert.equal(invalidPreview.reviewCount, 1);
    assert.equal(invalidPreview.errorCount, 1);
    assert.equal(invalidPreview.rows[0].participationType, null);
    assert.equal(invalidPreview.rows[1].participationType, null);
    assert.equal(invalidPreview.participationTypes.reduce((sum, t) => sum + t.count, 0), 5);
    await imports.commit({identity: {uid: "fixture-admin"}, data: {...request, approvedReviewRows: [], excludedRows: []}});
    const api = createWinnerMailApi({getDb: () => db, serverTimestamp, generateQrPng: fakeQrPng, getAppBaseUrl: () => APP_BASE_URL});
    const settings = await api.getSettings({data: {eventId: EVENT_ID}});
    assert.equal(settings.previewParticipants.length, 7);
    assert.deepEqual(settings.previewParticipants.map((p) => p.participationType), TYPES.map((t) => t.value));
    assert.ok(settings.suggestedTemplate.adoptionNotesBody);
    const e = (await db.doc(`events/${EVENT_ID}`).get()).data();
    const {version, ...template} = e.winnerMailTemplate;
    const data = {eventId: EVENT_ID, template, mailSettings: {senderName: "架空送信者", contact: "fixture@example.invalid", talkTimeText: "15:00〜16:00"}};
    assert.equal((await api.updateTemplate({identity: {uid: "fixture-admin"}, data})).changed, true);
    assert.equal((await api.updateTemplate({identity: {uid: "fixture-admin"}, data})).changed, false);
    for (const entry of settings.previewParticipants) {
      const p = (await db.doc(`participants/${entry.participantId}`).get()).data();
      assert.equal(p.participationType, undefined); // 正本を二重に保存しない
      const result = await api.preview({data: {eventId: EVENT_ID, participantId: entry.participantId}});
      assert.equal(result.ready, true);
      const fresh = (await db.doc(`events/${EVENT_ID}`).get()).data();
      const rendered = await composeReminderMailFor({db, snapshot: buildMailSnapshot(EVENT_ID, fresh, {templateField: "reminderMailTemplate"}).snapshot,
        participantId: entry.participantId, participant: p, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
      assert.equal(rendered.ok, true);
      assert.equal(rendered.qrPayload, result.qrPayload);
      assert.equal(rendered.viewModel.participationType, entry.participationType);
      if (entry.participationType.includes("talk")) assert.ok(result.text.includes("開催時間：15:00〜16:00"));
    }
    await assert.rejects(api.updateTemplate({identity: {uid: "fixture-admin"}, data: {...data, mailSettings: {...data.mailSettings, senderName: "bad\nheader"}}}));
    // 参加者別プレビューは既存のevent境界・active境界を維持する。
    await db.doc(`participants/${settings.previewParticipants[0].participantId}`).update({status: "cancelled"});
    assert.equal((await api.getSettings({data: {eventId: EVENT_ID}})).previewParticipants.length, 6);
    await assert.rejects(api.preview({data: {eventId: EVENT_ID, participantId: settings.previewParticipants[0].participantId}}));
  });
  test("new event: admin mapping save, CSV preview, mail and reminder, validation and opt-out", async () => {
    const eventId = `configured-${require("node:crypto").randomUUID()}`;
    const {db, FieldValue} = env;
    const serverTimestamp = () => FieldValue.serverTimestamp();
    const e = event();
    await db.doc(`events/${eventId}`).set(e);
    const api = createWinnerMailApi({getDb: () => db, serverTimestamp, generateQrPng: fakeQrPng, getAppBaseUrl: () => APP_BASE_URL});
    const imports = createImportApi({getDb: () => db, serverTimestamp});
    const request = buildImportRequest({table: table(), mapping, eventId, clientRequestId: require("node:crypto").randomBytes(16).toString("hex")});
    assert.equal((await imports.preview({data: request})).participationTypes, undefined);
    assert.equal((await api.getSettings({data: {eventId}})).participationMapping, null);
    const {version, ...template} = e.winnerMailTemplate;
    const participationMapping = {catProgramId: "program-1", dogProgramId: "program-2", talkProgramId: "program-3"};
    const update = (m) => api.updateTemplate({identity: {uid: "admin"}, data: {eventId, template, participationMapping: m}});
    for (const bad of [{}, {...participationMapping, dogProgramId: "program-1"}, {...participationMapping, catProgramId: "absent"}]) await assert.rejects(update(bad));
    assert.equal((await update(participationMapping)).changed, true);
    assert.equal((await update(participationMapping)).changed, false);
    const preview = await imports.preview({data: request});
    assert.deepEqual(preview.participationTypes.map((t) => t.count), [1, 1, 1, 1, 1, 1, 1]);
    assert.deepEqual(preview.rows.map((r) => r.participationType), TYPES.map((t) => t.value));
    await imports.commit({identity: {uid: "admin"}, data: {...request, approvedReviewRows: [], excludedRows: []}});
    const settings = await api.getSettings({data: {eventId}});
    assert.deepEqual(settings.participationMapping, participationMapping);
    assert.equal(settings.programs.length, 3);
    assert.equal(settings.previewParticipants.length, 7);
    for (const entry of settings.previewParticipants) {
      const mail = await api.preview({data: {eventId, participantId: entry.participantId}});
      assert.equal(mail.ready, true);
      const participant = (await db.doc(`participants/${entry.participantId}`).get()).data();
      const fresh = (await db.doc(`events/${eventId}`).get()).data();
      const reminder = await composeReminderMailFor({db, snapshot: buildMailSnapshot(eventId, fresh, {templateField: "reminderMailTemplate"}).snapshot,
        participantId: entry.participantId, participant, appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng});
      assert.equal(reminder.ok, true);
      assert.equal(reminder.viewModel.participationType, entry.participationType);
      assert.equal(reminder.qrPayload, mail.qrPayload);
    }
    // Older callers must not erase the saved mapping.
    await api.updateTemplate({identity: {uid: "admin"}, data: {eventId, template: {...template, subject: "changed"}}});
    assert.deepEqual((await db.doc(`events/${eventId}`).get()).data().participationMapping, participationMapping);
    await update(null);
    assert.equal((await imports.preview({data: request})).participationTypes, undefined);
    // Persisting the legacy effective mapping must not be mistaken for a no-op.
    const legacy = (await db.doc(`events/${EVENT_ID}`).get()).data();
    const {version: legacyVersion, updatedAt, updatedBy, ...legacyTemplate} = legacy.winnerMailTemplate;
    await api.updateTemplate({identity: {uid: "admin"}, data: {eventId: EVENT_ID, template: legacyTemplate, participationMapping}});
    assert.deepEqual((await db.doc(`events/${EVENT_ID}`).get()).data().participationMapping, participationMapping);
  });

});
