// Test delivery owns only testMailPolicies/testMailDeliveries/testMailLimits.
// It never opens a formal job or changes an event, participant or qualification.
const crypto = require('node:crypto');
const {ApiError} = require('./api_error');
const {loadConfirmedEvent, createWinnerMailApi} = require('./winner_mail_api');
const {buildMailSnapshot} = require('./mail_view_model');
const {composeReminderMailFor} = require('./winner_mail_message');
const {renderWinnerMail, renderReminderMail} = require('./mail_render');
const {validateTemplateInput} = require('./winner_mail_template');
const {roundEvent} = require('./reminder_rounds');
const {collectReminderTargets} = require('./reminder_targets');
const {isValidParticipantId} = require('../programs');
const {broadcastSnapshot, composeBroadcastMailFor} = require('./broadcast_message');
const TYPES = ['broadcast', 'normal', 'waitlistPromotion', 'reminder1', 'reminder2'];
const NOTICE = 'これはテストメールです。正式な参加案内ではありません。';
const hash = (v) => crypto.createHash('sha256').update(JSON.stringify(v)).digest('hex');
const fail = (code, message = code) => { throw new ApiError('failed-precondition', message, {code}); };
function request(data, extras = []) {
  if (!data || typeof data !== 'object' || Array.isArray(data) || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId || '')) fail('invalid-request');
  const keys = ['eventId', ...extras];
  if (Object.keys(data).some((k) => !keys.includes(k))) fail('unknown-key');
  return data;
}
const address = (s) => typeof s === 'string' && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(s) && s.length <= 254 ? s.toLowerCase() : null;
const KEYS = ['kind', 'participantId', 'batchId', 'syntheticProgramIds', 'draft', 'to'];
function marked(r) {
  return {...r, subject: `【テスト送信】${r.subject}`, text: `${NOTICE}\n\n${r.text}`,
    html: r.html.replace(/(<body\b[^>]*>)/i, `$1<p>${NOTICE}</p>`)};
}
function createTestMailApi(deps) {
  const {getDb, serverTimestamp, generateQrPng, getAppBaseUrl, getTransport, now = Date.now} = deps;
  const winners = createWinnerMailApi(deps);
  const policyRef = (db, id) => db.collection('testMailPolicies').doc(id);
  async function settings({identity, data}) {
    const {eventId} = request(data); const db = getDb();
    const s = await winners.getSettings({data: {eventId}});
    const p = await policyRef(db, eventId).get();
    const targets = await collectReminderTargets(db, eventId);
    const people = await db.collection('participants').where('eventId', '==', eventId).get();
    const participants = people.docs.filter((d) => targets.targets.includes(d.id)).map((d) => ({participantId: d.id, name: d.data().name || ''}));
    const batches = await db.collection('importBatches').where('eventId', '==', eventId).get();
    const history = await db.collection('testMailDeliveries').where('eventId', '==', eventId).get();
    return {eventId, canManagePolicy: identity?.systemAdmin === true, addresses: p.exists ? p.data().addresses : [], participants, batches: batches.docs.filter((d) => d.data().status === 'committed').map((d) => ({batchId: d.id, sequence: d.data().sequence || 0, notificationType: d.data().notificationType || 'normal'})), programs: s.programs,
      history: history.docs.map((d) => view(d.id, d.data())).sort((a, b) => b.startedMs - a.startedMs).slice(0, 30)};
  }
  // Exported with systemAdmin authorization. Event managers cannot grant themselves new destinations.
  async function setPolicy({identity, data}) {
    request(data, ['addresses']); const db = getDb(); await loadConfirmedEvent(db, data.eventId);
    if (!Array.isArray(data.addresses) || data.addresses.length > 10 || data.addresses.some((s) => !address(s))) fail('invalid-allowlist');
    const addresses = [...new Set(data.addresses.map(address))].sort();
    await policyRef(db, data.eventId).set({addresses, updatedBy: identity.uid, updatedAt: serverTimestamp()});
    return {addresses};
  }
  async function compose(data) {
    const db = getDb();
    if (!TYPES.includes(data.kind) || !address(data.to)) fail('invalid-test-input');
    const p = await policyRef(db, data.eventId).get();
    if (!p.exists || !p.data().addresses.includes(address(data.to))) throw new ApiError('permission-denied', '承認済みのテスト送信先を選択してください。');
    let {event} = await loadConfirmedEvent(db, data.eventId);
    const reminder = data.kind.startsWith('reminder');
    if (reminder) event = roundEvent(event, data.kind === 'reminder2' ? 2 : 1);
    if (data.draft !== undefined && data.kind !== 'broadcast') {
      if (!reminder || event.reminderMailTemplate) fail('draft-only-for-unconfigured-reminder');
      const t = validateTemplateInput(data.draft);
      if (!t.ok || !t.value.subject.includes('テスト送信・正式文面ではありません') || !t.value.introBody.includes('テスト送信・正式文面ではありません')) fail('invalid-test-draft');
      event = {...event, reminderMailTemplate: {...t.value, version: 1}};
    }
    let r;
    if (data.kind === 'broadcast') {
      if (!isValidParticipantId(data.participantId) || data.syntheticProgramIds || data.batchId) fail('invalid-participant');
      const doc = await db.collection('participants').doc(data.participantId).get();
      const eligible = await collectReminderTargets(db, data.eventId);
      if (!doc.exists || !eligible.targets.includes(data.participantId)) fail('participant-not-active');
      const snapshot = broadcastSnapshot(data.eventId, event, data.draft);
      r = await composeBroadcastMailFor({db, snapshot, participantId: data.participantId, participant: doc.data(), appBaseUrl: getAppBaseUrl(), generateQrPng});
      r.senderName = snapshot.event.senderName;
    } else if (data.syntheticProgramIds !== undefined) {
      if (data.participantId || data.batchId || !Array.isArray(data.syntheticProgramIds) || !data.syntheticProgramIds.length || new Set(data.syntheticProgramIds).size !== data.syntheticProgramIds.length || data.syntheticProgramIds.some((id) => !event.programs?.some((p) => p.programId === id))) fail('invalid-synthetic-programs');
      const built = buildMailSnapshot(data.eventId, event, {templateField: reminder ? 'reminderMailTemplate' : data.kind === 'normal' ? 'winnerMailTemplate' : 'waitlistWinnerMailTemplate'});
      if (!built.ok) fail('mail-not-ready', built.problems.join(', '));
      // No DB creation, no real capability: QR decodes to a non-URL test sentinel.
      const participantId = 'synthetic-test-only';
      const participant = {participantId, name: '架空テスト申込（実在しません）', publicId: 'pub_synthetic_test_only_00000000', sourceRegisteredAt: '2000-01-01T00:00:00+09:00'};
      r = await (reminder ? renderReminderMail : renderWinnerMail)({snapshot: built.snapshot, participant,
        attendances: data.syntheticProgramIds.map((programId) => ({eventId: data.eventId, participantId, programId, plannedCount: 1, slotLabel: '架空テスト時間（予約ではありません）'})),
        appBaseUrl: 'https://example.invalid', generateQrPng: () => generateQrPng('JM_QUICK_TEST_ONLY_NOT_A_RECEPTION_QR')});
      r.qrPayload = 'JM_QUICK_TEST_ONLY_NOT_A_RECEPTION_QR';
      r.senderName = built.snapshot.event.senderName;
    } else if (!reminder) {
      if (!isValidParticipantId(data.participantId)) fail('invalid-participant');
      const person = await db.collection('participants').doc(data.participantId).get();
      if (!person.exists || person.data().eventId !== data.eventId) fail('participant-event-mismatch');
      const batchId = data.batchId || person.data().importBatchId;
      if (typeof batchId !== 'string' || !/^[A-Za-z0-9]{1,40}$/.test(batchId)) fail('invalid-batch-id');
      const batch = await db.collection('importBatches').doc(batchId).get();
      if (!batch.exists || batch.data().eventId !== data.eventId || (batch.data().notificationType || 'normal') !== data.kind) {
        fail('notification-type-mismatch', '指定した種類の当選がありません。該当する取込回または架空申込を選んでください。');
      }
      r = await winners.preview({data: {eventId: data.eventId, participantId: data.participantId, notificationType: data.kind, ...(data.batchId ? {batchId: data.batchId} : {})}});
      if (r.ready) r.attachments = [{filename: 'reception-qr.png', contentType: 'image/png', contentBase64: r.qrPngBase64, contentId: 'jm-quick-reception-qr', disposition: 'inline'}];
    } else {
      if (!isValidParticipantId(data.participantId) || data.batchId) fail('invalid-participant');
      const doc = await db.collection('participants').doc(data.participantId).get(); const person = doc.data();
      if (!doc.exists || person.eventId !== data.eventId || person.status !== 'active' || !person.importBatchId) fail('participant-not-active');
      const batch = await db.collection('importBatches').doc(person.importBatchId).get();
      if (!batch.exists || batch.data().eventId !== data.eventId || batch.data().status !== 'committed') fail('batch-not-committed');
      const built = buildMailSnapshot(data.eventId, event, {templateField: 'reminderMailTemplate'});
      if (!built.ok) fail('mail-not-ready', built.problems.join(', '));
      r = await composeReminderMailFor({db, snapshot: built.snapshot, participantId: data.participantId, participant: person, appBaseUrl: getAppBaseUrl(), generateQrPng});
      r.senderName = built.snapshot.event.senderName;
    }
    if (!r.ok && !r.ready) fail('mail-not-ready', (r.problems || []).join(', '));
    const result = marked(r);
    const message = {to: address(data.to), senderName: result.senderName, subject: result.subject, text: result.text, html: result.html, attachments: result.attachments};
    return {result, message, fingerprint: hash([data.eventId, data.kind, message])};
  }
  async function preview({data}) {
    request(data, KEYS); const {result, message, fingerprint} = await compose(data);
    return {ready: true, ...message, qrPngBase64: result.attachments[0]?.contentBase64 || '', qrPayload: result.qrPayload, webPassUrl: result.webPassUrl, fingerprint, synthetic: !!data.syntheticProgramIds};
  }
  function view(id, d) {
    return {id, kind: d.kind, to: d.to, startedMs: d.startedMs, status: d.status === 'sending' && now() - d.startedMs > 120000 ? 'unknown' : d.status};
  }
  async function send({identity, data}) {
    request(data, [...KEYS, 'fingerprint']);
    const {message, fingerprint} = await compose(data);
    if (data.fingerprint !== fingerprint) fail('preview-changed', '内容が変わりました。プレビューを確認し直してください。');
    const db = getDb(), ref = db.collection('testMailDeliveries').doc(fingerprint);
    const limit = db.collection('testMailLimits').doc(data.eventId);
    const transport = getTransport();
    if (!(await transport.capabilities()).ok) fail('transport-not-ready');
    const claimed = await db.runTransaction(async (tx) => {
      const old = await tx.get(ref), quota = await tx.get(limit), policy = await tx.get(policyRef(db, data.eventId));
      if (!policy.exists || !policy.data().addresses.includes(message.to)) throw new ApiError('permission-denied', '送信先の許可が取り消されました。');
      if (old.exists) return {existing: view(ref.id, old.data())};
      const time = now(), times = (quota.data()?.times || []).filter((t) => t > time - 3600000);
      if (times.length >= 10) fail('test-rate-limit', '1イベントのテスト送信は1時間に10通までです。');
      const record = {eventId: data.eventId, kind: data.kind, to: message.to, status: 'sending', startedMs: time, createdAt: serverTimestamp(), createdBy: identity.uid, fingerprint};
      tx.create(ref, record); tx.set(limit, {times: [...times, time]}); return {record};
    });
    if (claimed.existing) return claimed.existing;
    // Claim is durable before any external I/O. Crashes/connection loss never reclaim it.
    let result;
    try { result = await transport.send({...message, metadata: {app: 'jm-quick', type: 'test', jobId: fingerprint}}); } catch (_) { result = {outcome: 'unknown'}; }
    const status = ['sent', 'failed', 'unknown'].includes(result?.outcome) ? result.outcome : 'unknown';
    await ref.update({status, completedAt: serverTimestamp()});
    return view(ref.id, {...claimed.record, status});
  }
  return {settings, setPolicy, preview, send};
}
module.exports = {createTestMailApi, marked, NOTICE};
