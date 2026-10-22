const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason, failingDb} = require('../test_support/emulator_admin');
const {createImportApi} = require('../confirmed/import_api');
const {buildImportRequest} = require('../test_support/import_request_builder');
const {createWinnerSendApi} = require('../confirmed/winner_send_api');
const {createWinnerMailApi} = require('../confirmed/winner_mail_api');
const {createReminderApi} = require('../confirmed/reminder_api');
const {createReminderRecoveryApi} = require('../confirmed/reminder_recovery');
const {roundOf, schedule, roundEvent, jobIdForReminder} = require('../confirmed/reminder_rounds');
const {generateQrPng} = require('../qr_png');
const f = require('../confirmed/test_support/participation_fixture');
const identity = {uid: 'synthetic-manager'};
const template = (round) => ({subject: `テスト送信・正式文面ではありません 第${round}回`, introBody: 'テスト送信・正式文面ではありません', closingBody: '架空の検証です。'});

test('round/date validation and legacy schedule adapter', () => {
  for (const value of [0, 3, '2', null]) assert.throws(() => roundOf(value));
  assert.equal(schedule('2026-11-20', null), null);
  assert.equal(schedule('2026-11-27', '10:15').toISOString(), '2026-11-27T01:15:00.000Z');
  for (const args of [['2026-02-30', '10:00'], ['2026-11-20', '24:00'], ['2026-11-20', '1:00']]) assert.throws(() => schedule(...args));
  assert.equal(roundEvent({reminderSendAt: new Date('2026-11-20T01:00:00Z')}).reminderPlannedTime, '10:00');
  assert.notEqual(jobIdForReminder('round2-event'), jobIdForReminder('event', 2));
});

test('two manual rounds: real imports, seven types, promotion after round1, frozen jobs, recovery and legacy compatibility', {skip: skipReason(), timeout: 180000}, async () => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
  const realFetch = global.fetch;
  global.fetch = (url, options) => { assert.ok(String(url).startsWith(emu.origin), 'No external transport'); return realFetch(url, options); };
  const eventId = 'twoRounds'; const stamp = () => FieldValue.serverTimestamp();
  const deps = {getDb: () => db, serverTimestamp: stamp, generateQrPng, getAppBaseUrl: () => 'https://example.invalid'};
  const send = createWinnerSendApi(deps), api = createReminderApi({...deps, winnerSendApi: send, now: () => 0});
  const recovery = createReminderRecoveryApi(deps), imports = createImportApi(deps), winner = createWinnerMailApi(deps);
  const captured = []; const transport = {capabilities: async () => ({ok: true}), send: async (m) => { assert.ok(m.to.endsWith('@example.invalid')); captured.push(m); return {outcome: 'sent', messageId: `fake-${captured.length}`}; }};
  const get = async (path) => (await db.doc(path).get()).data();
  const settings = (round) => api.getSettings({data: {eventId, round}});
  const start = async (round, extra = {}) => { const s = await settings(round); return api.startDelivery({identity, data: {eventId, round, expectedTemplateVersion: s.template.version, expectedTargetsFingerprint: s.targets.fingerprint, expectedTargetCount: s.targets.targetCount, dispatch: false, ...extra}}); };
  let sequence = 0;
  async function importPerson(type, index, promotion = false) {
    const mapping = structuredClone(f.mapping); Object.assign(mapping.participant, {externalIdColumn: 'id', registeredAtColumn: '登録日時'});
    const cells = f.cells(type, {id: `source-${index}`, 氏名: `架空${index}`, メールアドレス: `case${index}@example.invalid`, 登録日時: '2026-10-01 12:00:00'});
    const extra = {};
    if (promotion) {
      const dog = type === 'dog', slot = dog ? '14:10-14:50' : '10:10-10:50';
      mapping.waitlist = {optionsColumn: 'キャンセル待希望枠', countColumn: 'キャンセル待希望人数', options: [{label: '午前の部（猫）', programId: 'program-1', kind: '猫'}, {label: '午後の部（犬）', programId: 'program-2', kind: '犬'}]};
      cells.キャンセル待希望枠 = (dog ? '午後の部（犬）' : '午前の部（猫）') + slot; cells.キャンセル待希望人数 = dog ? '3' : '2';
      Object.assign(extra, {notificationType: 'waitlistPromotion', sourceSheetName: slot, sourceSheetCandidates: [slot]});
    }
    const batchId = `roundImport${++sequence}`;
    let data = buildImportRequest({eventId, clientRequestId: batchId, mapping, sourceFileName: promotion ? `【${type === 'dog' ? '犬' : '猫'}】synthetic.xlsx` : 'synthetic.csv', table: {headers: Object.keys(cells), records: [Object.values(cells)]}, extra});
    let v = await imports.validate({data});
    data.identityDecisions = v.identityRows.filter((r) => r.bulkEligible).map((r) => ({sourceRowNumber: r.sourceRowNumber, kind: 'new', mode: 'bulk', decisionKey: r.decisionKey, reason: '架空原本で確認'}));
    v = await imports.validate({data});
    const result = await imports.commit({identity, data: {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint, approvedReviewRows: v.reviewRows, approvalKeys: v.rows.flatMap((r) => Object.values(r.approvalKeys || {}))}});
    const pid = result.rows[0].participantId;
    await send.createJob({identity, data: {eventId, batchId}});
    await send.engine.processJob({db, jobId: `winner-${batchId}`, transport, limit: 50});
    return {pid, batchId, result};
  }
  try {
    assert.equal(db.projectId, 'demo-jm-quick');
    const event = f.event({eventId, participationMapping: {catProgramId: 'program-1', dogProgramId: 'program-2', talkProgramId: 'program-3'}});
    event.waitlistWinnerMailTemplate = {...event.winnerMailTemplate, subject: '架空追加通知'};
    await db.doc(`events/${eventId}`).set(event);
    for (const round of [1, 2]) {
      await api.updateSettings({identity, data: {eventId, round, plannedDate: round === 1 ? '2026-11-20' : '2026-11-27', plannedTime: null, template: template(round)}});
      assert.equal((await settings(round)).plannedTime, null);
      await assert.rejects(start(round), (e) => e.details.code === 'send-at-required');
    }
    assert.equal((await db.collection('sendJobs').get()).size, 0);
    const people = [];
    for (const [i, type] of ['dog', 'cat', 'dog_cat', 'talk', 'dog_talk', 'cat_talk', 'dog_cat_talk'].entries()) people.push(await importPerson(type, i));
    const originals = await Promise.all(people.map((x) => get(`participants/${x.pid}`)));
    const winnerPreview = await winner.preview({data: {eventId, participantId: people[3].pid}});
    await api.updateSettings({identity, data: {eventId, round: 1, plannedTime: '10:00'}});
    assert.equal((await settings(1)).sendAt, '2026-11-20T01:00:00.000Z');
    assert.equal((await settings(2)).sendAt, null);
    const stale = await settings(1);
    await api.updateSettings({identity, data: {eventId, round: 1, plannedTime: '10:15'}});
    await assert.rejects(start(1, {expectedTargetsFingerprint: stale.targets.fingerprint}), (e) => e.details.code === 'targets-changed');
    const p1 = await api.preview({data: {eventId, round: 1, participantId: people[3].pid}});
    assert.equal(p1.qrPayload, winnerPreview.qrPayload); assert.equal(p1.webPassUrl, winnerPreview.webPassUrl);
    await Promise.all([start(1), start(1)]);
    await send.worker.requestDelivery({db, identity, jobId: jobIdForReminder(eventId)});
    // Browser no longer participates: existing worker continues delivery server-side.
    await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await settings(1)).job.counts.sent, 7);
    const legacyJob = await get(`sendJobs/reminder-${eventId}`);
    const legacyDeliveries = await Promise.all(people.map((x) => get(`mailDeliveries/${x.pid}_reminder`)));
    const addition = await importPerson('dog', 3, true); assert.equal(addition.pid, people[3].pid); assert.equal(addition.result.addedCount, 1);
    const newcomer = await importPerson('cat', 7, true); assert.equal(newcomer.result.createdCount, 1);
    await api.updateSettings({identity, data: {eventId, round: 2, plannedTime: '11:30'}});
    const s2 = await settings(2); assert.equal(s2.targets.targetCount, 8);
    const p2 = await api.preview({data: {eventId, round: 2, participantId: people[3].pid}});
    assert.equal(p2.qrPayload, winnerPreview.qrPayload); assert.equal(p2.qrPngBase64, winnerPreview.qrPngBase64); assert.equal(p2.webPassUrl, winnerPreview.webPassUrl);
    assert.ok(p2.text.includes('譲渡会（いぬ）')); assert.ok(p2.text.includes(event.programs.find((p) => p.programId === 'program-3').name));
    const job2 = jobIdForReminder(eventId, 2);
    // Interrupted creation reuses its frozen recipients/template, even after settings change.
    const broken = failingDb(db, {failAtTransaction: 3});
    const brokenSend = createWinnerSendApi({...deps, getDb: () => broken, engineOptions: {concurrency: 1}});
    const brokenApi = createReminderApi({...deps, getDb: () => broken, winnerSendApi: brokenSend, now: () => 0});
    await assert.rejects(brokenApi.startDelivery({identity, data: {eventId, round: 2, dispatch: false, expectedTargetsFingerprint: s2.targets.fingerprint}}));
    assert.equal((await get(`sendJobs/${job2}`)).status, 'preparing');
    await api.updateSettings({identity, data: {eventId, round: 2, template: {...template(2), subject: '後から変更した仮件名'}}});
    await start(2);
    assert.equal((await get(`sendJobs/${job2}`)).snapshot.template.subject, template(2).subject);
    // Changed qualifications halt only affected deliveries; unknown cannot be retried.
    await db.doc(`programAttendances/${people[0].pid}_program-2`).update({plannedCount: 4});
    for (const path of [`mailDeliveries/${people[1].pid}_reminder2`, `sendJobs/${job2}/items/${people[1].pid}`]) await db.doc(path).update({status: 'unknown'});
    await send.engine.processJob({db, jobId: job2, transport, limit: 50});
    assert.equal((await get(`mailDeliveries/${people[0].pid}_reminder2`)).status, 'failed');
    assert.equal((await get(`mailDeliveries/${people[1].pid}_reminder2`)).status, 'unknown');
    const recovering = await recovery.preview({data: {eventId, round: 2}});
    assert.deepEqual(recovering.recipients.map((x) => x.participantId), [people[0].pid]);
    const r = recovering.recipients[0];
    await recovery.confirm({identity, data: {eventId, round: 2, participantId: r.participantId, expectedFingerprint: r.fingerprint, reason: '架空訂正確認'}});
    await send.engine.processJob({db, jobId: job2, transport, limit: 50});
    await api.retryFailed({data: {eventId, round: 2}});
    await start(2); await send.engine.processJob({db, jobId: job2, transport, limit: 50});
    const all = captured.filter((m) => m.metadata.type === 'reminder');
    assert.equal(all.filter((m) => m.metadata.jobId === `reminder-${eventId}`).length, 7);
    assert.equal(all.filter((m) => m.metadata.jobId === job2).length, 7); // eighth is unknown, intentionally held
    assert.equal(new Set(all.map((m) => `${m.metadata.jobId}/${m.metadata.participantId}`)).size, 14);
    assert.deepEqual(all.filter((m) => m.metadata.jobId === job2).map((m) => m.metadata.participantId).sort(),
      [...people.filter((_, i) => i !== 1).map((p) => p.pid), newcomer.pid].sort());
    for (const m of all) {
      const originalMail = captured.find((x) => x.metadata.type === 'winner' && x.metadata.participantId === m.metadata.participantId);
      assert.equal(m.attachments[0].contentBase64, originalMail.attachments[0].contentBase64);
    }

    assert.deepEqual(await get(`sendJobs/reminder-${eventId}`), legacyJob);
    assert.deepEqual(await Promise.all(people.map((x) => get(`mailDeliveries/${x.pid}_reminder`))), legacyDeliveries);
    for (const [i, person] of people.entries()) assert.deepEqual(await get(`participants/${person.pid}`), originals[i]);
    assert.deepEqual(await api.reconcileDue({}), {created: [], autoSendDisabled: true});
    assert.equal((await api.getJob({data: {eventId, round: 2}})).job.jobId, job2);
  } finally { global.fetch = realFetch; emu.stop(); }
});
