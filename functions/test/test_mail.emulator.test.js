const {test} = require('node:test');
const assert = require('node:assert/strict');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createTestMailApi, NOTICE} = require('../confirmed/test_mail_api');
const {generateQrPng} = require('../qr_png');
const f = require('../confirmed/test_support/participation_fixture');
const {createWinnerMailApi} = require('../confirmed/winner_mail_api');
const fs = require('node:fs');

test('test endpoints require existing event-manager authorization and App Check; policy is system-admin only', () => {
 const index = fs.readFileSync(require.resolve('../index'), 'utf8');
 for (const name of ['getConfirmedTestMailSettings', 'previewConfirmedTestMail', 'sendConfirmedTestMail']) {
  assert.match(index, new RegExp(`exports.${name} = confirmedEventCallable\\("eventManager", EVENT_SCOPES.dataEventId, .*enforceAppCheck: true`));
 }
 assert.match(index, /exports.updateConfirmedTestMailPolicy = confirmedCallable\("systemAdmin", .*enforceAppCheck: true/);
});

test('independent test delivery: all four kinds, seven types, formal preservation, duplicate/unknown/allowlist/limits', {skip: skipReason(), timeout: 120000}, async () => {
 const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
 const captured = []; let outcome = 'sent', clock = 10000000;
 const deps = {getDb: () => db, serverTimestamp: () => FieldValue.serverTimestamp(), generateQrPng, getAppBaseUrl: () => 'https://jm-quick.web.app', now: () => clock,
 getTransport: () => ({capabilities: async () => ({ok: true}), send: async (m) => { captured.push(m); return {outcome}; }})};
 const api = createTestMailApi(deps), identity = {uid: 'admin', systemAdmin: true};
 const eventId = 'testDelivery';
 const event = f.event({eventId, participationMapping: {catProgramId: 'program-1', dogProgramId: 'program-2', talkProgramId: 'program-3'}});
 event.waitlistWinnerMailTemplate = {...event.winnerMailTemplate, subject: '追加当選'};
 delete event.reminderMailTemplate;
 const draft = {subject: 'テスト送信・正式文面ではありません', introBody: 'テスト送信・正式文面ではありません', closingBody: '仮文面'};
 const req = {eventId, to: 'internal@example.invalid', kind: 'normal', syntheticProgramIds: ['program-1']};
 try {
  await db.doc(`events/${eventId}`).set(event);
  await assert.rejects(api.preview({data: req}), e => e.code === 'permission-denied');
  await api.setPolicy({identity, data: {eventId, addresses: [req.to]}});
  const before = (await db.doc(`events/${eventId}`).get()).data();
  const {loadIndex} = require('../test_support/load_index');
  const {assignmentDocId} = require('../event_access');
  const index = loadIndex(db, {FieldValue});
  await db.doc('accessRoles/admin').set({role: 'admin', active: true});
  for (const [uid, ev, role] of [['manager',eventId,'event_manager'],['staff',eventId,'staff'],['other','different','event_manager']]) {
    await db.doc(`eventAssignments/${assignmentDocId(ev, uid)}`).set({uid, eventId: ev, role, active: true});
  }
  for (const name of ['getConfirmedTestMailSettings','previewConfirmedTestMail','sendConfirmedTestMail']) {
    for (const uid of [null,'staff','other']) await assert.rejects(index[name].run({auth: uid ? {uid} : undefined, data: req}), e => ['permission-denied','unauthenticated'].includes(e.code));
  }
  await assert.rejects(index.updateConfirmedTestMailPolicy.run({auth: {uid: 'manager'}, data: {eventId, addresses: []}}), e => e.code === 'permission-denied');
  assert.equal((await index.getConfirmedTestMailSettings.run({auth: {uid: 'manager'}, data: {eventId}})).addresses.length, 1);

  for (const kind of ['normal','waitlistPromotion','reminder1','reminder2']) {
   for (let mask = 1; mask < 8; mask++) {
    const data = {...req, kind, syntheticProgramIds: [1,2,3].filter(i => mask & (1 << (i-1))).map(i => `program-${i}`), ...(kind.startsWith('reminder') ? {draft} : {})};
    const p = await api.preview({data});
    assert.ok(p.subject.startsWith('【テスト送信】')); assert.ok(p.text.startsWith(NOTICE)); assert.ok(p.html.includes(NOTICE));
    assert.equal(p.qrPayload, 'JM_QUICK_TEST_ONLY_NOT_A_RECEPTION_QR'); assert.ok(p.webPassUrl.startsWith('https://example.invalid/'));
    const result = await api.send({identity, data: {...data, fingerprint: p.fingerprint}});
    assert.equal(result.status, 'sent'); assert.equal(captured.at(-1).html, p.html); assert.equal(captured.at(-1).text, p.text);
    clock += 3600001;
   }
  }
  const p = await api.preview({data: req}); const count = captured.length;
  await Promise.all(Array.from({length: 20}, () => api.send({identity, data: {...req, fingerprint: p.fingerprint}})));
  assert.equal(captured.length, count);
  await assert.rejects(api.send({identity, data: {...req, fingerprint: 'stale'}}), e => e.details.code === 'preview-changed');
  await assert.rejects(api.preview({data: {...req, to: 'outside@example.invalid'}}), e => e.code === 'permission-denied');
  const person = {eventId, status: 'active', importBatchId: 'original', name: '架空参加者', publicId: 'pub_abcdefghijklmnopqrstuvwxyz', sourceRegisteredAt: '2026-10-01T09:00:00+09:00'};
  await db.doc('participants/realFixture').set(person); await db.doc('importBatches/original').set({eventId, status: 'committed'});
  await db.doc('programAttendances/fixture').set({eventId, participantId: 'realFixture', programId: 'program-1', plannedCount: 2, slotLabel: '10:00〜11:00'});
  const realReq = {eventId, kind: 'normal', to: req.to, participantId: 'realFixture'};
  await assert.rejects(api.preview({data: {...realReq, kind: 'waitlistPromotion'}}), e => e.details.code === 'notification-type-mismatch');
  const real = await api.preview({data: realReq}); const official = await createWinnerMailApi(deps).preview({data: {eventId, participantId: 'realFixture'}});
  assert.equal(real.qrPayload, official.qrPayload); assert.equal(real.webPassUrl, official.webPassUrl); assert.equal(real.qrPngBase64, official.qrPngBase64);
  assert.equal(real.text, NOTICE+'\n\n'+official.text);
  // Existing participant qualification addition: original QR and records stay intact.
  await db.doc('importBatches/promotion').set({eventId, status: 'committed', identityVersion: 1, notificationType: 'waitlistPromotion'});
  const addition = {eventId, participantId: 'realFixture', programId: 'program-2', plannedCount: 3, slotLabel: '14:00〜15:00'};
  await db.doc('programAttendances/addition').set(addition);
  await db.doc('qualificationGrants/promotion-realFixture').set({eventId, initial: false, programIds: ['program-2'], attendances: [addition]});
  const promotion = await api.preview({data: {...realReq, kind: 'waitlistPromotion', batchId: 'promotion'}});
  const officialPromotion = await createWinnerMailApi(deps).preview({data: {eventId, participantId: 'realFixture', notificationType: 'waitlistPromotion', batchId: 'promotion'}});
  assert.equal(promotion.text, NOTICE+'\n\n'+officialPromotion.text);
  assert.equal(promotion.qrPayload, real.qrPayload); assert.equal(promotion.qrPngBase64, real.qrPngBase64);
  // Re-preview the normal body after the deliberate emulator-only qualification fixture addition.
  const currentReal = await api.preview({data: realReq});
  outcome = 'unknown'; const beforeRace = captured.length;
  await Promise.all(Array.from({length: 20}, () => api.send({identity, data: {...realReq, fingerprint: currentReal.fingerprint}})));
  assert.equal(captured.length, beforeRace + 1, 'concurrent first attempts deliver exactly once');
  const calls = captured.length; await api.send({identity, data: {...realReq, fingerprint: currentReal.fingerprint}}); assert.equal(captured.length, calls);
  assert.deepEqual((await db.doc(`events/${eventId}`).get()).data(), before); assert.deepEqual((await db.doc('participants/realFixture').get()).data(), person);
  for (const col of ['sendJobs','mailDeliveries','checkIns']) assert.equal((await db.collection(col).get()).size, 0);
  assert.deepEqual((await db.doc('programAttendances/addition').get()).data(), addition);
  assert.equal((await db.collection('qualificationGrants').get()).size, 1);
  await db.doc(`testMailLimits/${eventId}`).set({times: Array(10).fill(clock)});
  await assert.rejects(api.send({identity, data: {...realReq, kind: 'waitlistPromotion', batchId: 'promotion', fingerprint: (await api.preview({data: {...realReq, kind: 'waitlistPromotion', batchId: 'promotion'}})).fingerprint}}), e => e.details.code === 'test-rate-limit');
 } finally { await emu.stop(); }
});
