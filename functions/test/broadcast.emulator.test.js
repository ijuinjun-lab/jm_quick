const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason, failingDb} = require('../test_support/emulator_admin');
const {createImportApi} = require('../confirmed/import_api');
const {buildImportRequest} = require('../test_support/import_request_builder');
const {createWinnerSendApi} = require('../confirmed/winner_send_api');
const {createBroadcastApi} = require('../confirmed/broadcast_api');
const {createTestMailApi, marked} = require('../confirmed/test_mail_api');
const {generateQrPng} = require('../qr_png');
const f = require('../confirmed/test_support/participation_fixture');
const identity = {uid: 'synthetic-manager'};
test('broadcast: real imports, unlimited jobs, preservation, safety and server delivery', {skip: skipReason(), timeout: 240000}, async () => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
  const deps = {getDb: () => db, serverTimestamp: () => FieldValue.serverTimestamp(), generateQrPng, getAppBaseUrl: () => 'https://example.invalid'};
  const send = createWinnerSendApi(deps), api = createBroadcastApi({...deps, winnerSendApi: send}), imports = createImportApi(deps);
  const eventId = 'broadcastTest', captured = [];
  const transport = {capabilities: async () => ({ok: true}), send: async (m) => { assert.ok(m.to.endsWith('@example.invalid')); captured.push(m); return {outcome: 'sent', messageId: `fake-${captured.length}`}; }};
  const get = async (path) => (await db.doc(path).get()).data();
  const draft = (n, qr = true) => ({subject: `架空一斉メール${n}`, body: `案内文${n} <script>実行不可</script>`, includeDetails: qr, includeQr: qr});
  const preview = (pid, n, qr = true) => api.preview({data: {eventId, participantId: pid, draft: draft(n, qr)}});
  const start = (p, n, qr = true, operationId = `broadcast-operation-${n}`) => api.start({identity, data: {eventId, draft: draft(n, qr), operationId, confirmation: p.confirmation, recipientsConfirmed: true}});
  const protectedData = async () => Object.fromEntries(await Promise.all(['events', 'participants', 'programAttendances', 'importBatches', 'checkIns'].map(async (c) => [c, (await db.collection(c).get()).docs.map((d) => [d.id, d.data()])])));
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

    return {pid, batchId, result};
  }
  try {
    assert.equal(db.projectId, 'demo-jm-quick');
    await db.doc(`events/${eventId}`).set(f.event({eventId, participationMapping: {catProgramId: 'program-1', dogProgramId: 'program-2', talkProgramId: 'program-3'}}));
    const {loadIndex} = require('../test_support/load_index');
    const {assignmentDocId} = require('../event_access');
    const index = loadIndex(db, {FieldValue});
    for (const [uid, ev, role] of [['manager',eventId,'event_manager'],['staff',eventId,'staff'],['other','otherEvent','event_manager']]) {
      await db.doc(`eventAssignments/${assignmentDocId(ev, uid)}`).set({uid, eventId: ev, role, active: true});
    }
    for (const name of ['getConfirmedBroadcastSettings','previewConfirmedBroadcastMail','startConfirmedBroadcastDelivery','getConfirmedBroadcastJob','resumeConfirmedBroadcastDelivery','retryFailedConfirmedBroadcastMails','getConfirmedBroadcastRecovery','confirmConfirmedBroadcastRecovery']) {
      for (const uid of [null, 'staff', 'other']) await assert.rejects(index[name].run({auth: uid ? {uid} : undefined, data: {eventId}}), e => ['permission-denied','unauthenticated'].includes(e.code));
    }
    assert.equal((await index.getConfirmedBroadcastSettings.run({auth: {uid: 'manager'}, data: {eventId}})).targets.length, 0);
    const people = [];
    for (const [i, type] of ['dog','cat','dog_cat','talk','dog_talk','cat_talk','dog_cat_talk'].entries()) people.push(await importPerson(type, i));
    // Existing histories remain readable and unchanged, without migration.
    await db.doc(`sendJobs/reminder-${eventId}`).set({eventId, type: 'reminder', status: 'completed', snapshot: {template: {subject: '旧履歴', introBody: '旧本文'}}, targetCount: 0, sentCount: 0});
    const legacy = await get(`sendJobs/reminder-${eventId}`);
    const before = await protectedData();
    const initial = await api.settings({data: {eventId}});
    assert.equal(initial.targets.length, 7, 'unsent winner applications are broadcast targets');
    assert.deepEqual(initial.batchCounts, people.map((_, i) => ({sequence: i + 1, count: 1})));
    assert.deepEqual(await protectedData(), before, 'opening settings does not write participant data');
    assert.equal((await db.collection('sendJobs').get()).size, 1, 'opening settings creates no job');
    assert.equal((await db.collection('mailDeliveries').get()).size, 0);
    const canonical = await require('../confirmed/broadcast_message').collectBroadcastRecipients(db, eventId, (await db.doc(`events/${eventId}`).get()).data());
    for (const key of Object.keys(canonical)) assert.deepEqual(initial[key], canonical[key]);
    for (const p of people) {
      const v = await preview(p.pid, 1); assert.equal(v.targetCount, 7); assert.ok(v.html.includes('&lt;script&gt;'));
      const original = await require('../confirmed/winner_mail_api').createWinnerMailApi(deps).preview({data: {eventId, participantId: p.pid}});
      assert.equal(v.qrPayload, original.qrPayload); assert.equal(v.webPassUrl, original.webPassUrl);
      assert.equal(v.qrPngBase64, original.qrPngBase64);
      for (const program of v.recipients.find(r => r.participantId === p.pid).programs) {
        assert.ok(v.text.includes(program.name)); assert.ok(v.text.includes(`${program.plannedCount}名`));
        assert.ok(v.text.includes(program.timeText));
      }
      assert.equal(v.viewModel.programs.length, v.recipients.find(r => r.participantId === p.pid).programs.length);
    }
    const p1 = await preview(people[0].pid, 1);
    await assert.rejects(api.start({identity, data: {eventId, draft: draft(1), operationId: 'broadcast-operation-1', confirmation: p1.confirmation}}));
    const jobs = await Promise.all(Array.from({length: 4}, () => start(p1, 1)));
    assert.equal(new Set(jobs.map(j => j.jobId)).size, 1);
    await Promise.all([send.worker.sweep({db, getTransport: () => transport}), send.worker.sweep({db, getTransport: () => transport})]);
    assert.equal(captured.length, 7); assert.equal(new Set(captured.map(m => m.to)).size, 7);
    assert.equal(captured.find(m => m.metadata.participantId === people[0].pid).html, p1.html);
    await start(p1, 1); await send.worker.sweep({db, getTransport: () => transport}); assert.equal(captured.length, 7);
    for (const n of [2, 3]) {
      const p = await preview(people[0].pid, n, false);
      assert.equal(p.attachments.length, 0); assert.ok(!p.html.includes('cid:')); assert.ok(!p.text.includes('/p/'));
      await start(p, n, false); await send.worker.sweep({db, getTransport: () => transport});
      assert.equal(captured.length, n * 7);
    }
    assert.deepEqual(await protectedData(), before);
    assert.deepEqual(await get(`sendJobs/reminder-${eventId}`), legacy);
    assert.equal((await api.settings({data: {eventId}})).history.length, 4);
    // Independent test transport, no formal job/history modification; exact formal renderer + marker.
    const testApi = createTestMailApi({...deps, getTransport: () => transport});
    await testApi.setPolicy({identity, data: {eventId, addresses: ['internal@example.invalid']}});
    const formalCount = (await db.collection('mailDeliveries').get()).size;
    for (const qr of [true, false]) {
      const data = {eventId, kind: 'broadcast', participantId: people[0].pid, to: 'internal@example.invalid', draft: draft(9, qr)};
      const v = await testApi.preview({data}), formal = await preview(people[0].pid, 9, qr);
      assert.equal(v.html, marked(formal).html); assert.equal(v.text, marked(formal).text);
      await testApi.send({identity, data: {...data, fingerprint: v.fingerprint}});
      assert.equal(captured.at(-1).html, v.html);
      await assert.rejects(testApi.preview({data: {...data, to: 'outside@example.invalid'}}));
    }
    assert.equal((await db.collection('mailDeliveries').get()).size, formalCount);
    assert.deepEqual(await protectedData(), before);
    // Promotion to an existing application preserves QR and adds only the new qualification.
    const oldQR = (await preview(people[3].pid, 4)).qrPayload;
    const addition = await importPerson('dog', 3, true); assert.equal(addition.pid, people[3].pid);
    const newcomer = await importPerson('cat', 7, true);
    const updatedSettings = await api.settings({data: {eventId}});
    assert.equal(updatedSettings.batchCounts.reduce((sum, b) => sum + b.count, 0), 8);
    assert.equal(updatedSettings.batchCounts.find(b => b.sequence === 4).count, 1, 'added qualification stays with original import');
    assert.ok(!updatedSettings.batchCounts.some(b => b.sequence === 8), 'qualification addition is not a second recipient');
    const p4 = await preview(people[3].pid, 4); assert.equal(p4.qrPayload, oldQR); assert.equal(p4.targetCount, 8);
    // Cancel the newcomer's sole qualification: no invitation, no automatic re-registration.
    const attendance = (await db.collection('programAttendances').where('participantId','==',newcomer.pid).get()).docs[0];
    await attendance.ref.update({entitlementStatus: 'revoked'});
    await assert.rejects(start(p4, 4), e => e.details.code === 'targets-changed');
    const cancelledSettings = await api.settings({data: {eventId}});
    assert.equal(cancelledSettings.recipients.length, 7);
    assert.equal(cancelledSettings.batchCounts.reduce((sum, b) => sum + b.count, 0), 7);
    assert.ok(!cancelledSettings.recipients.some(r => r.participantId === newcomer.pid));
    const p5 = await preview(people[3].pid, 5); assert.equal(p5.targetCount, 7);
    const j5 = await start(p5, 5);
    await db.doc(`participants/${people[0].pid}`).update({email: 'changed@example.invalid'});
    await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, j5.jobId)).failedCount, 1);
    const recovery = await api.recovery({data: {eventId, jobId: j5.jobId}});
    assert.equal(recovery.recipients.length, 1);
    await api.confirmRecovery({identity, data: {eventId, jobId: j5.jobId, participantId: people[0].pid, fingerprint: recovery.recipients[0].fingerprint, reason: '架空宛先変更確認'}});
    await api.resume({identity, data: {eventId, jobId: j5.jobId}}); await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, j5.jobId)).sentCount, 7);
    // Qualification changes stop the original job; frozen settings are not a reason to stop delivery.
    const qPreview = await preview(people[0].pid, 8); const qJob = await start(qPreview, 8);
    const q = (await db.collection('programAttendances').where('participantId','==',people[0].pid).get()).docs[0];
    await q.ref.update({plannedCount: 6});
    await db.doc(`events/${eventId}`).update({contact: '変更後問い合わせ先', 'reminderMailTemplate.subject': '変更後の旧文面'});
    await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, qJob.jobId)).sentCount, 6);
    assert.ok(!captured.at(-1).text.includes('変更後問い合わせ先'));
    assert.equal(captured.at(-1).subject, draft(8).subject);
    assert.equal((await send.engine.summarize(db, qJob.jobId)).failedCount, 1);
    const rc = await api.recovery({data: {eventId, jobId: qJob.jobId}});
    assert.equal(rc.recipients.length, 1); assert.ok(rc.recipients[0].text.includes('6名'));
    await api.confirmRecovery({identity, data: {eventId, jobId: qJob.jobId, participantId: people[0].pid, fingerprint: rc.recipients[0].fingerprint, reason: '架空人数訂正確認'}});
    await api.resume({identity, data: {eventId, jobId: qJob.jobId}}); await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, qJob.jobId)).sentCount, 7);
    // Definitely-failed delivery can resume; already sent recipients are never resent.
    const failedP = await preview(people[0].pid, 10); const failedJ = await start(failedP, 10);
    await send.worker.sweep({db, getTransport: () => ({capabilities: transport.capabilities, send: async () => ({outcome: 'failed'})})});
    assert.equal((await send.engine.summarize(db, failedJ.jobId)).failedCount, 7);
    await api.retry({data: {eventId, jobId: failedJ.jobId}}); await api.resume({identity, data: {eventId, jobId: failedJ.jobId}});
    await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, failedJ.jobId)).sentCount, 7);
    // Unknown transport outcomes are held across retry and resume.
    const p6 = await preview(people[0].pid, 6); const j6 = await start(p6, 6);
    await send.worker.sweep({db, getTransport: () => ({capabilities: transport.capabilities, send: async () => ({outcome: 'unknown'})})});
    await api.retry({data: {eventId, jobId: j6.jobId}}); await api.resume({identity, data: {eventId, jobId: j6.jobId}});
    assert.equal((await send.engine.summarize(db, j6.jobId)).unknownCount, 7);
    assert.equal((await api.recovery({data: {eventId, jobId: j6.jobId}})).recipients.length, 0);
    // Interrupt item preparation, then resume the same frozen operation.
    const brokenDb = failingDb(db, {failAtTransaction: 4});
    const brokenSend = createWinnerSendApi({...deps, getDb: () => brokenDb});
    const brokenApi = createBroadcastApi({...deps, getDb: () => brokenDb, winnerSendApi: brokenSend});
    const p7 = await preview(people[0].pid, 7);
    await assert.rejects(brokenApi.start({identity, data: {eventId, draft: draft(7), operationId: 'broadcast-operation-7', confirmation: p7.confirmation, recipientsConfirmed: true}}));
    const j7 = await start(p7, 7); await send.worker.sweep({db, getTransport: () => transport});
    assert.equal((await send.engine.summarize(db, j7.jobId)).sentCount, 7);
    assert.deepEqual(await get(`sendJobs/reminder-${eventId}`), legacy);
  } finally { await emu.stop(); }
});
