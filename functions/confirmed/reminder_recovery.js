// Reconfirm only a definitely-unsent recipient, inside the original job. No new job or transport.
const {roundOf, jobIdForReminder, deliveryIdForReminder} = require('./reminder_rounds');
const {ApiError} = require('./api_error');
const {collectReminderRecipients} = require('./reminder_targets');
const {loadAttendances} = require('./winner_mail_message');
const {renderReminderMail} = require('./mail_render');
const {digest} = require('./application_identity');
const fail = (code) => new ApiError('failed-precondition', '宛先と参加資格を更新して確認し直してください。', {code});
// Run existing read-only collectors in the transaction's consistent view.
function transactionalReader(db, tx) {
  const wrap = (ref) => new Proxy(ref, {get(target, key) {
    if (key === 'get') return () => tx.get(target);
    if (['collection', 'doc', 'where', 'limit'].includes(key)) return (...args) => wrap(target[key](...args));
    const value = target[key]; return typeof value === 'function' ? value.bind(target) : value;
  }});
  return {collection: (name) => wrap(db.collection(name)), getAll: (...refs) => tx.getAll(...refs)};
}
function createReminderRecoveryApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl}) {
  function parse(data, confirm) {
    const keys = confirm ? ['eventId', 'participantId', 'expectedFingerprint', 'reason'] : ['eventId'];
    if (!data || Object.keys(data).some((k) => k !== 'round' && !keys.includes(k)) || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId || '')) throw fail('invalid-request');
    roundOf(data.round);
    if (confirm && (!/^[A-Za-z0-9_-]{1,128}$/.test(data.participantId || '') || typeof data.reason !== 'string' || !data.reason.trim() || data.reason.length > 200)) throw fail('invalid-recovery');
  }
  const busy = (job) => job.dispatchActive === true ||
    (job.dispatchWorkerLeaseUntil?.toMillis?.() || 0) > Date.now() || !['ready', 'completed'].includes(job.status);
  const token = (job, item, r) => digest([job.snapshot, item.status, item.attemptCount || 0, r.safetyFingerprint]);
  async function preview({data}) {
    parse(data, false); const db = getDb(), ref = db.collection('sendJobs').doc(jobIdForReminder(data.eventId, data.round));
    const job = await ref.get(); if (!job.exists) return {recipients: []};
    if (job.data().eventId !== data.eventId) throw fail('job-conflict');
    if (busy(job.data())) return {recipients: []};
    const current = await collectReminderRecipients(db, data.eventId);
    const failed = await ref.collection('items').where('status', '==', 'failed').get();
    const recipients = [];
    for (const item of failed.docs) {
      const r = current.recipients.find((x) => x.participantId === item.id);
      if (!r?.target || r.duplicate === 'suspected-duplicate') continue;
      const delivery = await db.collection('mailDeliveries').doc(deliveryIdForReminder(item.id, data.round)).get();
      if (delivery.data()?.status !== 'failed' || delivery.data()?.jobId !== ref.id) continue;
      const person = await db.collection('participants').doc(item.id).get();
      const rendered = await renderReminderMail({snapshot: job.data().snapshot,
        participant: {...person.data(), participantId: item.id}, attendances: await loadAttendances(db, item.id, data.eventId),
        appBaseUrl: getAppBaseUrl(), generateQrPng});
      if (!rendered.ok) continue;
      recipients.push({participantId: item.id, name: r.name, email: r.email, text: rendered.text,
        fingerprint: token(job.data(), item.data(), r)});
    }
    return {recipients};
  }
  async function confirm({identity, data}) {
    parse(data, true); const db = getDb(), ref = db.collection('sendJobs').doc(jobIdForReminder(data.eventId, data.round));
    const itemRef = ref.collection('items').doc(data.participantId), deliveryRef = db.collection('mailDeliveries').doc(deliveryIdForReminder(data.participantId, data.round));
    return db.runTransaction(async (tx) => {
      const [job, item, delivery] = await tx.getAll(ref, itemRef, deliveryRef);
      if (!job.exists || job.data().eventId !== data.eventId || !item.exists || !delivery.exists ||
        item.data().status !== 'failed' || delivery.data().status !== 'failed' || delivery.data().jobId !== ref.id) throw fail('recovery-not-failed');
      if (busy(job.data())) throw fail('recovery-delivery-active');
      const current = await collectReminderRecipients(transactionalReader(db, tx), data.eventId);
      const r = current.recipients.find((x) => x.participantId === data.participantId);
      if (!r?.target || r.duplicate === 'suspected-duplicate' || token(job.data(), item.data(), r) !== data.expectedFingerprint) throw fail('recovery-state-changed');
      const reset = {status: 'pending', leaseUntil: null, dispatchStartedAt: null, updatedAt: serverTimestamp()};
      tx.update(deliveryRef, {...reset, claimId: null});
      tx.update(itemRef, {...reset, approvedSafetyFingerprint: r.safetyFingerprint, recoveryReason: data.reason.trim(), recoveryBy: identity.uid, recoveryAt: serverTimestamp()});
      tx.update(ref, {status: 'ready', completedAt: null});
      return {participantId: data.participantId, status: 'pending'};
    });
  }
  return {preview, confirm};
}
module.exports = {createReminderRecoveryApi, transactionalReader};
