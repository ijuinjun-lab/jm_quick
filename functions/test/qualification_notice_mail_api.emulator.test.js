const assert = require('node:assert/strict');
const {test} = require('node:test');
const {once} = require('node:events');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createApp} = require('../../cloudrun/mail-api');
const {createMailApiTransport} = require('../mail_transport');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createQualificationNoticeApi} = require('../confirmed/qualification_notice_api');
const {generateQrPng} = require('../qr_png');
const f = require('../confirmed/test_support/participation_fixture');

// Run the real HTTP input validator and transport; replace only external delivery.
// Production jm-event-entry image 7dc4d2c9... uses this exact mail API source.
test('qualification notices satisfy the mail API contract, including cancellation and retry', {skip: skipReason(), timeout: 120000}, async () => {
  const emu = await startAdminEmulator(), {db, FieldValue} = emu;
  const messages = [], payloads = [], statuses = [];
  let legacyEmpty = false, providerStatus = null, sequence = 0;
  const server = createApp({env: {MAIL_API_KEY: 'synthetic-only'}, mailer: {send: async message => {
    assert.match(message.to, /@example\.invalid$/);
    if (providerStatus) throw Object.assign(new Error('synthetic rejection'), {code: providerStatus});
    messages.push(message); return 'synthetic-message-id';
  }}}).listen(0, '127.0.0.1');
  await once(server, 'listening');
  const transport = createMailApiTransport({endpoint: 'https://mail-api.example.invalid', apiKey: 'synthetic-only', fetchFn: async (url, options) => {
    const requested = new URL(url);
    assert.equal(requested.origin, 'https://mail-api.example.invalid');
    if (options.body) {
      const body = JSON.parse(options.body);
      if (legacyEmpty) body.attachments = []; // Reproduce the old 400 at the real validator.
      payloads.push(body); options = {...options, body: JSON.stringify(body)};
    }
    const response = await fetch(`http://127.0.0.1:${server.address().port}${requested.pathname}`, options);
    if (options.method === 'POST') statuses.push(response.status);
    return response;
  }});
  const deps = {getDb: () => db, serverTimestamp: () => FieldValue.serverTimestamp(), generateQrPng,
    getAppBaseUrl: () => 'https://example.invalid', getTransport: () => transport};
  const change = createQualificationChangeApi(deps), notice = createQualificationNoticeApi(deps), identity = {uid: 'synthetic-manager'};
  async function fixture(action) {
    const n = ++sequence, eventId = `contractEvent${n}`, participantId = `contractBatch${n}-000002`, input = {eventId, participantId};
    const batch = `contractBatch${n}`;
    const event = f.event({eventId, participationMapping: {catProgramId: 'program-1', dogProgramId: 'program-2', talkProgramId: 'program-3'}});
    const person = {...input, schemaVersion: 2, status: 'active', name: '架空参加者', email: 'only@example.invalid', publicId: 'pub_123456789012345678901234', importBatchId: batch};
    await db.doc(`events/${eventId}`).set(event);
    await db.doc(`participants/${participantId}`).set(person);
    await db.doc(`importBatches/${batch}`).set({eventId, status: 'committed'});
    for (const programId of ['program-1', 'program-3']) await db.doc(`programAttendances/${participantId}_${programId}`).set({...input, programId, plannedCount: 2, slotLabel: '10:00-11:00', checkedIn: false, importBatchId: batch});
    const historical = db.doc(`mailDeliveries/${participantId}_winner`), oldHistory = {...input, status: 'sent', messageId: 'original-winner'};
    await historical.set(oldHistory);
    const operationId = `contractNoticeOperation${n}`;
    await change.change({identity, data: {...input, operationId, action, fingerprint: (await change.get({data: input})).fingerprint, reason: '架空検証',
      ...(action === 'cancelAll' ? {} : {programId: 'program-1'}),
      ...(action === 'swap' ? {targetProgramId: 'program-2', slotLabel: '14:00-15:00', plannedCount: 3} : {})}});
    const request = {...input, operationId}, preview = await notice.preview({data: request});
    const saved = (await db.collection('programAttendances').where('participantId', '==', participantId).get()).docs.map(d => d.data());
    const preserved = async () => {
      assert.deepEqual((await historical.get()).data(), oldHistory);
      assert.deepEqual((await db.doc(`participants/${participantId}`).get()).data(), person);
      assert.deepEqual((await db.collection('programAttendances').where('participantId', '==', participantId).get()).docs.map(d => d.data()), saved);
      assert.equal((await db.collection('sendJobs').get()).size, 0);
    };
    return {request, preview, preserved};
  }
  const send = (x, extra = {}) => notice.send({identity, data: {...x.request, fingerprint: x.preview.fingerprint, ...extra}});
  const record = async x => (await db.collection('qualificationNotices').where('operationId', '==', x.request.operationId).get()).docs[0];
  try {
    assert.equal(db.projectId, 'demo-jm-quick');
    for (const action of ['cancelAll', 'cancel', 'swap']) {
      const x = await fixture(action), before = messages.length;
      await Promise.all([send(x), send(x)]);
      assert.equal(statuses.at(-1), 200);
      assert.equal(messages.length, before + 1);
      assert.equal(Object.hasOwn(payloads.at(-1), 'attachments'), action !== 'cancelAll');
      if (action === 'cancelAll') {
        assert.equal(Object.hasOwn(messages.at(-1), 'attachments'), false);
        assert.match(messages.at(-1).text, /参加資格はすべて取り消されました/);
        assert.ok(!messages.at(-1).html.includes('cid:'));
        assert.ok(!messages.at(-1).text.includes(x.preview.webPassUrl));
      } else assert.equal(payloads.at(-1).attachments.length, 1);
      assert.equal(messages.at(-1).html, x.preview.html);
      const r = await record(x);
      assert.equal(r.data().status, 'sent');
      assert.equal((await r.ref.collection('attempts').doc('1').get()).data().status, 'sent');
      assert.equal((await send(x)).status, 'sent'); assert.equal(messages.length, before + 1);
      await x.preserved();
    }
    const retry = await fixture('cancelAll'); legacyEmpty = true;
    assert.equal((await send(retry)).status, 'failed'); assert.equal(statuses.at(-1), 400);
    const failed = (await record(retry)).data(), before = messages.length;
    legacyEmpty = false;
    assert.equal((await send(retry)).status, 'failed'); assert.equal(messages.length, before);
    retry.preview = await notice.preview({data: retry.request}); assert.equal(retry.preview.canRetry, true);
    await Promise.all([send(retry, {retry: true, expectedAttempt: 1}), send(retry, {retry: true, expectedAttempt: 1})]);
    assert.equal(messages.length, before + 1); assert.equal(statuses.at(-1), 200);
    const retried = await record(retry);
    assert.equal(retried.data().attemptCount, 2); assert.equal(retried.data().status, 'sent');
    assert.deepEqual((await retried.ref.collection('attempts').doc('1').get()).data(), failed);
    await retry.preserved();
    const unknown = await fixture('cancelAll'); providerStatus = 500;
    assert.equal((await send(unknown)).status, 'unknown'); assert.equal(statuses.at(-1), 502);
    const posts = payloads.length;
    unknown.preview = await notice.preview({data: unknown.request}); assert.equal(unknown.preview.canRetry, false);
    providerStatus = null;
    await Promise.all([send(unknown), send(unknown, {retry: true, expectedAttempt: 1})]);
    assert.equal(payloads.length, posts); assert.equal((await record(unknown)).data().status, 'unknown');
    await unknown.preserved();
  } finally {
    await new Promise(resolve => server.close(resolve)); await emu.stop();
  }
});
