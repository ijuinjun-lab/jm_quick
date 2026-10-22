const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason, failingDb} = require('../test_support/emulator_admin');
const {createAttendanceReportApi} = require('../confirmed/attendance_report_api');
const {createPassApi} = require('../confirmed/pass_api');
const {createImportApi} = require('../confirmed/import_api');
const {createImportRecoveryApi} = require('../confirmed/import_recovery');
const {buildImportRequest} = require('../test_support/import_request_builder');
const f = require('../confirmed/test_support/participation_fixture');
const identity = {uid: 'synthetic-manager'};
const mapping = {...f.mapping, participant: {...f.mapping.participant, externalIdColumn: 'id', registeredAtColumn: '登録日時'}};

test('M1 abandoned reimport: actual import transactions A–F, preserve all historical records', {skip: skipReason(), timeout: 180000}, async (t) => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
  const stamp = () => FieldValue.serverTimestamp();
  const api = createImportApi({getDb: () => db, serverTimestamp: stamp, concurrency: 1});
  const pass = createPassApi({getDb: () => db, serverTimestamp: stamp, getAppBaseUrl: () => 'https://example.invalid'});
  const recovery = createImportRecoveryApi({getDb: () => db, serverTimestamp: stamp});
  function req(eventId, batch, type = 'dog', count = 2) {
    const cells = Array.from({length: count}, (_, i) => f.cells(type, {id: `source${i}`, 氏名: `架空${i}`, メールアドレス: `synthetic${i}@example.invalid`, 登録日時: '2026-10-01 12:00:00'}));
    const currentMapping = structuredClone(mapping), extra = {};
    if (type === 'dog') {
      currentMapping.waitlist = {optionsColumn: 'キャンセル待希望枠', countColumn: 'キャンセル待希望人数',
        options: [{label: '午後の部（犬）', programId: 'program-2', kind: '犬'}]};
      for (const c of cells) Object.assign(c, {キャンセル待希望枠: '午後の部（犬）14:10〜14:50', キャンセル待希望人数: '3'});
      Object.assign(extra, {notificationType: 'waitlistPromotion', sourceSheetName: '14:10〜14:50', sourceSheetCandidates: ['14:10〜14:50']});
    }
    return buildImportRequest({eventId, clientRequestId: batch, mapping: currentMapping, extra,
      sourceFileName: type === 'dog' ? '【犬】synthetic.xlsx' : 'synthetic.csv',
      table: {headers: Object.keys(cells[0]), records: cells.map(Object.values)}});
  }
  async function ready(data, targets = {}) {
    let v = await api.validate({data});
    data = {...data, clientRequestId: v.batchId, identityDecisions: v.identityRows.filter((r) => r.action === 'review').map((r) => ({
      sourceRowNumber: r.sourceRowNumber, kind: targets[r.sourceRowNumber] ? 'existing' : 'new',
      ...(targets[r.sourceRowNumber] ? {participantId: targets[r.sourceRowNumber]} : {}),
      reason: '隔離環境の架空原本で確認', decisionKey: r.decisionKey}))};
    v = await api.validate({data});
    return {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      approvedReviewRows: v.reviewRows, approvalKeys: v.rows.flatMap((r) => Object.values(r.approvalKeys || {}))};
  }
  async function abandonPartial(data, targets, failAtTransaction = 3) {
    const brokenDb = failingDb(db, {failAtTransaction});
    const broken = createImportApi({getDb: () => brokenDb, serverTimestamp: stamp, concurrency: 1});
    const confirmed = await ready(data, targets);
    await assert.rejects(broken.commit({identity, data: confirmed}), (e) => e.details?.code === 'commit-interrupted');
    const batch = (await recovery.list({data: {eventId: data.eventId}})).batches.find((b) => b.batchId === confirmed.clientRequestId);
    assert.equal(batch.persistedCount, failAtTransaction - 2);
    await recovery.abandon({identity, data: {eventId: data.eventId, batchId: batch.batchId, expectedFingerprint: batch.fingerprint, reason: '架空の恒久エラー'}});
    return confirmed;
  }
  try {
    await t.test('A: abandoned dog addition must be added again, not unchanged; existing QR and talk survive', async () => {
      const eventId = 'm1A'; await db.collection('events').doc(eventId).set(f.event({eventId}));
      await api.commit({identity, data: await ready(req(eventId, 'initialA', 'talk'))});
      const ids = {2: 'initialA-000002', 3: 'initialA-000003'};
      const person = (await db.collection('participants').doc(ids[2]).get()).data();
      const qrInput = {eventId, participantId: ids[2], publicId: person.publicId};
      const oldPass = await pass.getPass({data: {participantId: ids[2], publicId: person.publicId}});
      await pass.checkIn({identity, data: {...qrInput, programId: 'program-3', attendedCount: 2}});
      await db.collection('mailDeliveries').doc(`${ids[2]}_winner`).set({eventId, participantId: ids[2], status: 'sent'});
      const sent = (await db.collection('mailDeliveries').doc(`${ids[2]}_winner`).get()).data();
      const talkHistory = (await db.collection('programAttendances').doc(`${ids[2]}_program-3`).collection('history').get()).docs.map((d) => d.data());
      const talk = (await db.collection('programAttendances').doc(`${ids[2]}_program-3`).get()).data();
      const source = req(eventId, 'abandonA'); await abandonPartial(source, ids);
      const abandonedDog = (await db.collection('programAttendances').doc(`${ids[2]}_program-2`).get()).data();
      // A different client request also must not reuse the abandoned qualification.
      const v = await api.validate({data: {...source, clientRequestId: 'retryA'}});
      assert.equal(v.identityRows[0].action, 'added');
      const retry = await ready(source, ids); assert.notEqual(retry.clientRequestId, source.clientRequestId);
      assert.equal((await api.commit({identity, data: retry})).addedCount, 2);
      assert.deepEqual((await db.collection('participants').doc(ids[2]).get()).data(), person);
      assert.deepEqual((await db.collection('programAttendances').doc(`${ids[2]}_program-3`).get()).data(), talk);
      const dog = (await db.collection('programAttendances').doc(`${ids[2]}_program-2`).get()).data();
      assert.equal(dog.importBatchId, retry.clientRequestId); assert.equal(dog.plannedCount, 3); assert.equal(dog.slotLabel, '14:10〜14:50');
      assert.deepEqual((await db.collection('importBatches').doc('abandonA').collection('retiredRecords').doc(`attendance-${ids[2]}_program-2`).get()).data().record, abandonedDog);
      assert.deepEqual((await db.collection('mailDeliveries').doc(`${ids[2]}_winner`).get()).data(), sent);
      assert.deepEqual((await db.collection('programAttendances').doc(`${ids[2]}_program-3`).collection('history').get()).docs.map((d) => d.data()), talkHistory);
      const updatedPass = await pass.getPass({data: {participantId: ids[2], publicId: person.publicId}});
      assert.equal(updatedPass.qrPayload, oldPass.qrPayload);
      assert.equal(updatedPass.webPassUrl, oldPass.webPassUrl);
      await pass.checkIn({identity, data: {...qrInput, programId: 'program-2', attendedCount: 3}});
      assert.equal((await db.collection('programAttendances').doc(`${ids[2]}_program-2`).get()).data().checkedIn, true);
    });
    await t.test('B/E/F: same file after abandoned creation; concurrent retry, failure/resume and repeat are idempotent', async () => {
      const eventId = 'm1B'; await db.collection('events').doc(eventId).set(f.event({eventId}));
      const source = req(eventId, 'abandonB'); await abandonPartial(source);
      // Simulate the pre-fix link schema, which has no creating batch field.
      const oldLinks = await db.collection('applicationLinks').where('eventId', '==', eventId).get();
      await oldLinks.docs[0].ref.update({importBatchId: FieldValue.delete()});
      const originalLink = (await oldLinks.docs[0].ref.get()).data();
      const old = (await db.collection('participants').doc('abandonB-000002').get()).data();
      const v = await api.validate({data: source});
      assert.notEqual(v.batchId, source.clientRequestId);
      assert.ok(v.identityRows.every((r) => r.action === 'review' && r.bulkEligible && r.candidates.length === 0));
      const retry = await ready(source);
      const brokenDb = failingDb(db, {failAtTransaction: 3});
      await assert.rejects(createImportApi({getDb: () => brokenDb, serverTimestamp: stamp, concurrency: 1}).commit({identity, data: retry}));
      const results = await Promise.all([api.commit({identity, data: retry}), api.commit({identity, data: retry})]);
      assert.ok(results.every((r) => r.createdCount === 2));
      const before = (await db.collection('participants').where('eventId', '==', eventId).get()).docs.map((d) => [d.id, d.data().publicId]).sort();
      await api.commit({identity, data: await ready(source)});
      assert.deepEqual((await db.collection('participants').where('eventId', '==', eventId).get()).docs.map((d) => [d.id, d.data().publicId]).sort(), before);
      assert.deepEqual((await db.collection('importBatches').doc('abandonB').collection('retiredRecords').doc(`link-${oldLinks.docs[0].id}`).get()).data().record, originalLink);
      assert.equal(before.length, 3, 'two live applicants plus one preserved abandoned audit participant');
      assert.deepEqual((await db.collection('participants').doc('abandonB-000002').get()).data(), old);
      assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
      const fresh = await ready({...source, clientRequestId: 'repeatB'});
      assert.equal((await api.commit({identity, data: fresh})).unchangedCount, 2);
      const report = await createAttendanceReportApi({getDb: () => db}).getReport({data: {eventId}});
      assert.equal(report.participants.filter((p) => p.batchCommitted).length, 2);
      assert.equal(report.participants.filter((p) => !p.batchCommitted).length, 1, 'existing report keeps the abandoned audit row');
      assert.equal(report.participants.flatMap((p) => p.programs).reduce((n, a) => n + a.plannedCount, 0), 6);
      assert.equal((await db.collection('sendJobs').where('eventId', '==', eventId).get()).size, 0);
    });
    for (const mode of ['mail', 'history']) await t.test(`${mode === 'mail' ? 'C' : 'D'}: used abandoned participant requires review, no new QR or history mutation`, async () => {
      const eventId = `m1${mode}`; await db.collection('events').doc(eventId).set(f.event({eventId}));
      const source = req(eventId, `abandon${mode}`); await abandonPartial(source);
      const pid = `${source.clientRequestId}-000002`;
      const ref = mode === 'mail' ? db.collection('mailDeliveries').doc(`${pid}_winner`) : db.collection('programAttendances').doc(`${pid}_program-2`).collection('history').doc('check-in-1');
      const history = {eventId, participantId: pid, status: 'sent', action: 'check-in', synthetic: true};
      await ref.set(history); // Fixture only: no transport, job creation, or production connection.
      const before = (await db.collection('participants').doc(pid).get()).data();
      const v = await api.validate({data: source});
      assert.equal(v.identityRows[0].action, 'review'); assert.equal(v.identityRows[0].reason, 'abandoned-record-used');
      assert.equal(v.identityRows[0].bulkEligible, false);
      const forced = await ready(source);
      await assert.rejects(api.commit({identity, data: forced}));
      assert.deepEqual((await db.collection('participants').doc(pid).get()).data(), before);
      assert.deepEqual((await ref.get()).data(), history);
      assert.equal((await db.collection('participants').where('eventId', '==', eventId).get()).size, 1);
      assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
    });
    await t.test('F: default eight workers and simultaneous fresh reimport preserve one successor batch', async () => {
      const eventId = 'm1Concurrent'; await db.collection('events').doc(eventId).set(f.event({eventId}));
      const source = req(eventId, 'abandonConcurrent', 'dog', 12); await abandonPartial(source, undefined, 8);
      const retry = await ready(source);
      const parallel = createImportApi({getDb: () => db, serverTimestamp: stamp});
      const results = await Promise.all([parallel.commit({identity, data: retry}), parallel.commit({identity, data: retry})]);
      assert.ok(results.every((r) => r.createdCount === 12));
      const people = (await db.collection('participants').where('eventId', '==', eventId).get()).docs;
      assert.equal(people.filter((d) => d.data().importBatchId === retry.clientRequestId).length, 12);
      assert.equal(people.length, 18, 'six abandoned audit participants and twelve live applications');
      assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
      assert.equal((await db.collection('importBatches').where('eventId', '==', eventId).get()).size, 2);
      const snapshot = people.map((d) => [d.id, d.data().publicId]).sort();
      await parallel.commit({identity, data: retry});
      assert.deepEqual((await db.collection('participants').where('eventId', '==', eventId).get()).docs.map((d) => [d.id, d.data().publicId]).sort(), snapshot);
    });
    await t.test('F: usage appearing after allocation prevents the row write; abandon clears only its own lock', async () => {
      const eventId = 'm1LateUse'; await db.collection('events').doc(eventId).set(f.event({eventId}));
      const source = req(eventId, 'lateUse'); await abandonPartial(source);
      const retry = await ready(source);
      let transactions = 0;
      const racingDb = new Proxy(db, {get(target, key) {
        if (key === 'runTransaction') return async (fn, options) => {
          if (++transactions === 2) await db.collection('programAttendances').doc('lateUse-000002_program-2').collection('history').doc('legacy').set({action: 'cancel', eventId});
          return target.runTransaction(fn, options);
        };
        const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
      }});
      const racing = createImportApi({getDb: () => racingDb, serverTimestamp: stamp, concurrency: 1});
      await assert.rejects(racing.commit({identity, data: retry}), (e) => e.details?.code === 'abandoned-record-used');
      assert.equal((await db.collection('participants').where('eventId', '==', eventId).get()).size, 1);
      const batch = (await recovery.list({data: {eventId}})).batches.find((b) => b.batchId === retry.clientRequestId);
      assert.equal(batch.persistedCount, 0);
      await recovery.abandon({identity, data: {eventId, batchId: batch.batchId, expectedFingerprint: batch.fingerprint, reason: '利用実績を再調査'}});
      assert.equal((await db.collection('events').doc(eventId).get()).data().activeImportBatch, null);
      const next = await api.validate({data: source});
      assert.notEqual(next.batchId, source.clientRequestId); assert.notEqual(next.batchId, retry.clientRequestId);
      assert.equal(next.identityRows[0].reason, 'abandoned-record-used');
    });
    if (process.env.JM_M1_REPORT_FIXTURE) {
      const outputs = [];
      for (const eventId of ['m1A', 'm1B', 'm1mail', 'm1history']) {
        const output = await createAttendanceReportApi({getDb: () => db}).getReport({data: {eventId}});
        outputs.push({eventId, output});
      }
      require('node:fs').writeFileSync(process.env.JM_M1_REPORT_FIXTURE, JSON.stringify(outputs));
    }
  } finally { emu.stop(); }
});
