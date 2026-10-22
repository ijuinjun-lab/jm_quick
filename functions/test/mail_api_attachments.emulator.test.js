// Real local HTTP API + production transport/renderers; only the external SendGrid client is replaced.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createApp, createMailer} = require('../../cloudrun/mail-api');
const {createMailApiTransport} = require('../mail_transport');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {buildMailApiMessage} = require('../confirmed/winner_mail_message');
const {buildMailSnapshot} = require('../confirmed/mail_view_model');
const {broadcastSnapshot} = require('../confirmed/broadcast_message');
const {renderBroadcastMail, renderWinnerMail, renderReminderMail} = require('../confirmed/mail_render');
const {createTestMailApi} = require('../confirmed/test_mail_api');
const {generateQrPng} = require('../qr_png');
const f = require('../confirmed/test_support/mail_fixtures');

test('production mail API accepts QR/no-QR payloads from formal and test delivery', {skip: skipReason(), timeout: 120000}, async (t) => {
  const emu = await startAdminEmulator(); const {db, FieldValue} = emu;
  const captured = [], requests = [];
  const mailer = createMailer({SENDGRID_API_KEY: 'local-only', MAIL_FROM: 'sender@example.invalid'}, {
    setApiKey() {}, async send(m) { captured.push(m); return [{headers: {'x-message-id': `local-${captured.length}`}}]; },
  });
  const server = createApp({env: {MAIL_API_KEY: 'local-key'}, mailer}).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  const local = `http://127.0.0.1:${server.address().port}`;
  const transport = createMailApiTransport({endpoint: 'https://mail-api.invalid', apiKey: 'local-key', fetchFn: async (url, init) => {
    assert.ok(url.startsWith('https://mail-api.invalid/'));
    const response = await fetch(url.replace('https://mail-api.invalid', local), init);
    if (init.method === 'POST') requests.push({body: JSON.parse(init.body), status: response.status});
    return response;
  }});
  const eventId = 'event1', person = f.participant({schemaVersion: 2, importBatchId: 'batchA', sourceRegisteredAt: '2026-10-01T09:00:00+09:00'});
  const event = f.makeEvent();
  event.waitlistWinnerMailTemplate = {...event.winnerMailTemplate, subject: '繰り上げ当選'};
  event.reminderMailTemplate = {...event.winnerMailTemplate, subject: '旧リマインド'};
  const draft = qr => ({subject: '一斉メール', body: '架空の案内本文', includeDetails: true, includeQr: qr});
  const args = {participant: person, attendances: f.attendances(), appBaseUrl: f.APP_BASE_URL, generateQrPng};
  try {
    assert.equal(db.projectId, 'demo-jm-quick');
    await db.doc('events/event1').set(event);
    await db.doc(`participants/${person.participantId}`).set(person);
    await db.doc('importBatches/batchA').set({eventId, status: 'committed'});
    for (const a of f.attendances()) await db.doc(`programAttendances/${person.participantId}_${a.programId}`).set(a);
    await db.doc('testMailPolicies/event1').set({addresses: [person.email]});
    const api = createTestMailApi({getDb: () => db, serverTimestamp: () => FieldValue.serverTimestamp(), generateQrPng,
      getAppBaseUrl: () => f.APP_BASE_URL, getTransport: () => transport});
    for (const qr of [true, false]) {
      await t.test(`broadcast QR=${qr}`, async () => {
        const snapshot = broadcastSnapshot(eventId, event, draft(qr));
        const rendered = await renderBroadcastMail({...args, snapshot}); assert.equal(rendered.ok, true);
        const message = buildMailApiMessage({rendered, snapshot, to: person.email, participantId: person.participantId, jobId: 'local', type: 'broadcast'});
        assert.equal((await transport.send(message)).outcome, 'sent');
        assert.equal(requests.at(-1).status, 200);
        assert.equal(Object.hasOwn(requests.at(-1).body, 'attachments'), qr);
        assert.equal(captured.at(-1).html, rendered.html);
        if (qr) assert.deepEqual(message.attachments, rendered.attachments);
      });
      await t.test(`test broadcast QR=${qr}`, async () => {
        const data = {eventId, kind: 'broadcast', participantId: person.participantId, to: person.email, draft: draft(qr)};
        const preview = await api.preview({data});
        const result = await api.send({identity: {uid: 'local-admin'}, data: {...data, fingerprint: preview.fingerprint}});
        assert.equal(result.status, 'sent'); assert.equal(requests.at(-1).status, 200);
        assert.equal(Object.hasOwn(requests.at(-1).body, 'attachments'), qr);
        assert.equal(captured.at(-1).html, preview.html);
        assert.equal(captured.at(-1).text, preview.text.trim());
      });
    }
    for (const templateField of ['winnerMailTemplate', 'waitlistWinnerMailTemplate', 'reminderMailTemplate']) {
      await t.test(templateField, async () => {
        const built = buildMailSnapshot(eventId, event, {templateField}); assert.equal(built.ok, true);
        const render = templateField === 'reminderMailTemplate' ? renderReminderMail : renderWinnerMail;
        const rendered = await render({...args, snapshot: built.snapshot}); assert.equal(rendered.ok, true);
        const message = buildMailApiMessage({rendered, snapshot: built.snapshot, to: person.email, participantId: person.participantId, jobId: 'legacy'});
        assert.deepEqual(message.attachments, rendered.attachments); assert.equal(message.attachments.length, 1);
        assert.equal((await transport.send(message)).outcome, 'sent'); assert.equal(requests.at(-1).status, 200);
        assert.equal(captured.at(-1).html, rendered.html); assert.equal(captured.at(-1).text, rendered.text.trim());
      });
    }
    // Preserve the API's strict validation: callers must omit an empty attachment list.
    const response = await fetch(`${local}/v1/mail/send`, {method: 'POST', headers: {Authorization: 'Bearer local-key', 'Content-Type': 'application/json'},
      body: JSON.stringify({to: person.email, subject: 'invalid', text: 'invalid', html: '<p>invalid</p>', attachments: []})});
    assert.equal(response.status, 400);
    assert.equal(captured.length, 7);
    assert.equal((await db.collection('sendJobs').get()).size, 0);
    assert.equal((await db.collection('mailDeliveries').get()).size, 0);
  } finally {
    await new Promise(resolve => server.close(resolve)); await db.terminate(); emu.stop();
  }
});
