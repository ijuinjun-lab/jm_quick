const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason, failingDb} = require('../test_support/emulator_admin');
const {createImportApi} = require('../confirmed/import_api');
const {createImportRecoveryApi} = require('../confirmed/import_recovery');
const {createReminderRecoveryApi} = require('../confirmed/reminder_recovery');
const {createWinnerSendApi} = require('../confirmed/winner_send_api');
const {createReminderApi} = require('../confirmed/reminder_api');
const {buildImportRequest} = require('../test_support/import_request_builder');
const f = require('../confirmed/test_support/participation_fixture');
const {fakeQrPng} = require('../confirmed/test_support/mail_fixtures');
const identity = {uid: 'synthetic-manager'};

test('H2: 120 rows one bulk confirmation; conflicts and stale evidence never auto-create; M1 resume/abandon are fenced', {skip: skipReason(), timeout: 180000}, async () => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
  const stamp = () => FieldValue.serverTimestamp();
  const api = createImportApi({getDb: () => db, serverTimestamp: stamp, concurrency: 1});
  const recovery = createImportRecoveryApi({getDb: () => db, serverTimestamp: stamp});
  const eventId = 'auditImport';
  const mapping = {...f.mapping, participant: {...f.mapping.participant, externalIdColumn: 'id', registeredAtColumn: '登録日時'}};
  function req(batch, n, mutate = (x) => x) {
    const records = Array.from({length: n}, (_, i) => mutate(f.cells('dog_cat_talk', {id: `${batch}-${i}`, 氏名: `架空${batch}${i}`, メールアドレス: `${batch}-${i}@example.invalid`, 登録日時: '2026-10-01 12:00:00'}), i));
    return buildImportRequest({eventId, clientRequestId: batch, mapping, table: {headers: Object.keys(records[0]), records: records.map(Object.values)}});
  }
  async function confirmed(data, useApi = api) {
    let v = await useApi.validate({data});
    data = {...data, identityDecisions: v.identityRows.filter((r) => r.bulkEligible).map((r) => ({sourceRowNumber: r.sourceRowNumber,
      kind: 'new', mode: 'bulk', reason: '架空原本120申込の一括確認', decisionKey: r.decisionKey}))};
    v = await useApi.validate({data});
    return {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      approvedReviewRows: v.reviewRows, approvalKeys: v.rows.flatMap((r) => Object.values(r.approvalKeys || {}))};
  }
  try {
    await db.collection('events').doc(eventId).set(f.event({eventId}));
    const data = req('bulk120', 120), v = await api.validate({data});
    assert.equal(v.identityRows.length, 120);
    assert.ok(v.identityRows.every((r) => r.action === 'review' && r.bulkEligible));
    assert.equal((await db.collection('participants').get()).size, 0);
    const result = await api.commit({identity, data: await confirmed(data)});
    assert.equal(result.createdCount, 120);
    assert.equal((await db.collection('programAttendances').get()).size, 360);
    const links = (await db.collection('applicationLinks').get()).docs;
    assert.equal(links.length, 120);
    assert.ok(links.every((d) => d.data().confirmedBy === identity.uid && d.data().confirmedAt && d.data().decision.mode === 'bulk'));
    const before = (await db.collection('participants').get()).docs.map((d) => [d.id, d.data().publicId]).sort();
    assert.equal((await api.commit({identity, data: await confirmed(data)})).createdCount, 120, 'same batch replays original result');
    assert.deepEqual((await db.collection('participants').get()).docs.map((d) => [d.id, d.data().publicId]).sort(), before);
    const conflicts = req('exceptions', 6, (x, i) => ({...x,
      ...(i < 2 ? {メールアドレス: 'shared@example.invalid'} : {}), ...(i === 2 || i === 3 ? {id: 'duplicate-id'} : {}),
      ...(i === 4 ? {id: ''} : {}), ...(i === 5 ? {メールアドレス: 'bulk120-0@example.invalid'} : {})}));
    const cv = await api.validate({data: conflicts});
    assert.ok(cv.identityRows.every((r) => !r.bulkEligible && r.action === 'review'));
    await assert.rejects(api.validate({data: {...conflicts, identityDecisions: [{sourceRowNumber: 2, kind: 'new', mode: 'bulk', reason: 'invalid', decisionKey: cv.identityRows[0].decisionKey}]}}), (e) => e.details?.code === 'bulk-identity-ineligible');
    const next = await confirmed(req('stale', 1));
    await db.collection('participants').doc(before[0][0]).update({name: '架空変更'});
    await assert.rejects(api.commit({identity, data: next}));
    const brokenDb = failingDb(db, {failAtTransaction: 3});
    const broken = createImportApi({getDb: () => brokenDb, serverTimestamp: stamp, concurrency: 1});
    const partial = await confirmed(req('partial', 3));
    await assert.rejects(broken.commit({identity, data: partial}));
    let batch = (await recovery.list({data: {eventId}})).batches.find((b) => b.batchId === 'partial');
    assert.equal(batch.persistedCount, 1); assert.equal(batch.pendingCount, 2);
    const saved = (await db.collection('participants').doc('partial-000002').get()).data();
    assert.equal((await api.commit({identity, data: partial})).createdCount, 3);
    assert.deepEqual((await db.collection('participants').doc('partial-000002').get()).data(), saved);

    // Keep a single fault-injecting instance for the commit.
    const abandonDb = failingDb(db, {failAtTransaction: 3});
    const abandonApi = createImportApi({getDb: () => abandonDb, serverTimestamp: stamp, concurrency: 1});
    const abandonData = await confirmed(req('abandon', 3));
    await assert.rejects(abandonApi.commit({identity, data: abandonData}));
    batch = (await recovery.list({data: {eventId}})).batches.find((b) => b.batchId === 'abandon');
    const preserved = (await db.collection('participants').doc('abandon-000002').get()).data();
    await Promise.all([1, 2].map(() => recovery.abandon({identity, data: {eventId, batchId: batch.batchId, expectedFingerprint: batch.fingerprint, reason: '架空の恒久エラー'}})));
    assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
    assert.equal((await db.collection('importBatches').doc('abandon').get()).data().abandonedBy, identity.uid);
    assert.deepEqual((await db.collection('participants').doc('abandon-000002').get()).data(), preserved);
    await assert.rejects(api.commit({identity, data: abandonData}), (e) => e.details?.code === 'batch-abandoned');
    assert.equal((await api.commit({identity, data: await confirmed(req('afterAbandon', 1))})).createdCount, 1);
    const send = createWinnerSendApi({getDb: () => db, serverTimestamp: stamp, generateQrPng: fakeQrPng, getAppBaseUrl: () => 'https://example.invalid'});
    await assert.rejects(send.createJob({identity, data: {eventId, batchId: 'abandon'}}));
    assert.equal((await db.collection('sendJobs').get()).size, 0);
  } finally { emu.stop(); }
});

test('H1: frozen templates/contact; qualification change stops; explicit same-job recovery; sent/unknown untouched', {skip: skipReason(), timeout: 120000}, async () => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu; const stamp = () => FieldValue.serverTimestamp();
  const eventId = 'auditReminder'; const jobId = `reminder-${eventId}`;
  const app = () => 'https://example.invalid';
  const send = createWinnerSendApi({getDb: () => db, serverTimestamp: stamp, generateQrPng: fakeQrPng, getAppBaseUrl: app});
  const reminder = createReminderApi({getDb: () => db, serverTimestamp: stamp, generateQrPng: fakeQrPng, getAppBaseUrl: app, winnerSendApi: send, now: () => 0});
  const recovery = createReminderRecoveryApi({getDb: () => db, serverTimestamp: stamp, generateQrPng: fakeQrPng, getAppBaseUrl: app});
  const mails = []; const transport = {send: async (m) => { mails.push(m); return {outcome: 'sent', messageId: `fake-${mails.length}`}; }};
  try {
    await db.collection('events').doc(eventId).set(f.event({eventId}));
    for (let i = 0; i < 5; i++) {
      await db.collection('participants').doc(`p${i}`).set({eventId, name: `架空${i}`, email: `p${i}@example.invalid`, publicId: `pub_${String(i).repeat(24)}`, schemaVersion: 2, status: 'active'});
      await db.collection('programAttendances').doc(`p${i}_program-3`).set({eventId, participantId: `p${i}`, programId: 'program-3', plannedCount: 2});
      await db.collection('mailDeliveries').doc(`p${i}_winner`).set({eventId, participantId: `p${i}`, status: 'sent'});
    }
    await db.collection('programAttendances').doc('p4_program-2').set({eventId, participantId: 'p4', programId: 'program-2', plannedCount: 3, slotLabel: '14:10〜14:50'});
    const settings = await reminder.getSettings({data: {eventId}});
    await reminder.startDelivery({identity, data: {eventId, expectedTargetsFingerprint: settings.targets.fingerprint, dispatch: false}});
    const original = (await db.collection('sendJobs').doc(jobId).get()).data().snapshot;
    await db.collection('events').doc(eventId).update({'reminderMailTemplate.version': 99, 'reminderMailTemplate.subject': '後から変更', 'confirmedMailSettings.contact': '変更先', contact: '変更後問い合わせ'});
    await db.collection('programAttendances').doc('p1_program-3').update({plannedCount: 3});
    await db.collection('programAttendances').doc('p3_program-2').set({eventId, participantId: 'p3', programId: 'program-2', plannedCount: 3, slotLabel: '14:10〜14:50'});
    await db.collection('importBatches').doc('extra').set({eventId, status: 'committed'});
    await db.collection('qualificationGrants').doc('extra-p3').set({eventId, additionalEventId: eventId, batchId: 'extra', participantId: 'p3', initial: false, programIds: ['program-2'], deliveryId: 'p3_winner_extra'});
    await db.collection('programAttendances').doc('p4_program-2').update({entitlementStatus: 'revoked'});
    // Unknown record is never reset, even by the recovery route.
    for (const ref of [db.collection('mailDeliveries').doc('p2_reminder'), db.collection('sendJobs').doc(jobId).collection('items').doc('p2')]) await ref.update({status: 'unknown'});
    await send.engine.processJob({db, jobId, transport, limit: 50});
    assert.equal(mails.length, 1, JSON.stringify((await db.collection('mailDeliveries').get()).docs.map((d) => [d.id, d.data().lastErrorCode]))); assert.equal(mails[0].subject, original.template.subject);
    assert.equal((await db.collection('mailDeliveries').doc('p1_reminder').get()).data().lastErrorCode, 'render-reminder-state-changed');
    const sentBefore = (await db.collection('mailDeliveries').doc('p0_reminder').get()).data();
    const unknownBefore = (await db.collection('mailDeliveries').doc('p2_reminder').get()).data();
    let preview = await recovery.preview({data: {eventId}}); assert.deepEqual(preview.recipients.map((r) => r.participantId).sort(), ['p1', 'p4']);
    await db.collection('mailDeliveries').doc('p3_winner_extra').set({eventId, status: 'sent'});
    preview = await recovery.preview({data: {eventId}}); assert.equal(preview.recipients.length, 3);
    await db.collection('participants').doc('p1').update({email: 'changed@example.invalid'});
    await assert.rejects(recovery.confirm({identity, data: {eventId, participantId: 'p1', expectedFingerprint: preview.recipients.find((r) => r.participantId === 'p1').fingerprint, reason: '確認'}}));
    preview = await recovery.preview({data: {eventId}});
    const confirmed = {identity, data: {eventId, participantId: 'p1', expectedFingerprint: preview.recipients.find((r) => r.participantId === 'p1').fingerprint, reason: '資格と宛先を原本で再確認'}};
    await db.collection('sendJobs').doc(jobId).update({dispatchActive: true});
    await assert.rejects(recovery.confirm(confirmed), (e) => e.details?.code === 'recovery-delivery-active');
    await db.collection('sendJobs').doc(jobId).update({dispatchActive: false});
    const concurrent = await Promise.allSettled([recovery.confirm(confirmed), recovery.confirm(confirmed)]);
    assert.equal(concurrent.filter((r) => r.status === 'fulfilled').length, 1);
    for (const r of preview.recipients.filter((r) => r.participantId !== 'p1')) await recovery.confirm({identity,
      data: {eventId, participantId: r.participantId, expectedFingerprint: r.fingerprint, reason: '追加・取消を原本で確認'}});
    await send.engine.processJob({db, jobId, transport, limit: 50});
    assert.equal(mails.length, 4); assert.ok(mails.some((m) => m.to === 'changed@example.invalid'));
    assert.equal(mails[1].subject, original.template.subject);
    assert.deepEqual((await db.collection('mailDeliveries').doc('p0_reminder').get()).data(), sentBefore);
    assert.deepEqual((await db.collection('mailDeliveries').doc('p2_reminder').get()).data(), unknownBefore);
    assert.deepEqual((await db.collection('sendJobs').doc(jobId).get()).data().snapshot, original);
    await reminder.retryFailed({data: {eventId}}); await send.engine.processJob({db, jobId, transport, limit: 50});
    assert.equal(mails.length, 4); assert.equal((await db.collection('sendJobs').get()).size, 1);
  } finally { emu.stop(); }
});

test('M1: abandonment wins against an in-flight row; no late write or status resurrection', {skip: skipReason(), timeout: 60000}, async () => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu; const stamp = () => FieldValue.serverTimestamp();
  let release, reached; const gate = new Promise((r) => { release = r; }), paused = new Promise((r) => { reached = r; });
  let transactions = 0;
  const racingDb = new Proxy(db, {get(target, key) {
    if (key === 'runTransaction') return async (fn, options) => {
      if (++transactions === 3) { reached(); await gate; }
      return target.runTransaction(fn, options);
    };
    const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
  }});
  const api = createImportApi({getDb: () => racingDb, serverTimestamp: stamp, concurrency: 1});
  const recovery = createImportRecoveryApi({getDb: () => db, serverTimestamp: stamp});
  try {
    const eventId = 'raceAbandon'; await db.collection('events').doc(eventId).set(f.event({eventId}));
    const cells = [1, 2].map((n) => f.cells('talk', {id: `race${n}`, 氏名: `架空${n}`, メールアドレス: `race${n}@example.invalid`, 登録日時: '2026-10-01 12:00:00'}));
    let data = buildImportRequest({eventId, clientRequestId: 'racing', mapping: {...f.mapping, participant: {...f.mapping.participant, externalIdColumn: 'id', registeredAtColumn: '登録日時'}},
      table: {headers: Object.keys(cells[0]), records: cells.map(Object.values)}});
    let v = await api.validate({data}); data.identityDecisions = v.identityRows.map((r) => ({sourceRowNumber: r.sourceRowNumber, kind: 'new', mode: 'bulk', reason: '架空原本', decisionKey: r.decisionKey}));
    v = await api.validate({data}); data = {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint};
    const pending = api.commit({identity, data}).then((result) => ({result}), (error) => ({error}));
    await paused;
    const batch = (await recovery.list({data: {eventId}})).batches[0];
    assert.equal(batch.persistedCount, 1); assert.deepEqual(batch.pendingRows, [3]);
    await recovery.abandon({identity, data: {eventId, batchId: 'racing', expectedFingerprint: batch.fingerprint, reason: '実行中の恒久エラーを確認'}});
    release();
    assert.equal((await pending).error?.details?.code, 'batch-abandoned');
    assert.equal((await db.collection('participants').get()).size, 1);
    assert.equal((await db.collection('importBatches').doc('racing').get()).data().status, 'abandoned');
    assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
  } finally { release(); emu.stop(); }
});
