const {loadConfirmedEvent} = require('./winner_mail_api');
const {broadcastSnapshot, collectBroadcastRecipients, composeBroadcastMailFor, digest, fail} = require('./broadcast_message');
const {JOB} = require('./send_jobs');
const {transactionalReader} = require('./reminder_recovery');
const iso = (v) => v?.toDate?.().toISOString() || null;
function createBroadcastApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl, winnerSendApi}) {
  const {engine, worker} = winnerSendApi;
  function parse(data, keys = []) {
    if (!data || typeof data !== 'object' || Array.isArray(data) || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId || '') ||
        Object.keys(data).some((k) => !['eventId', ...keys].includes(k))) fail('invalid-request');
  }
  async function owned(db, data, legacy = false) {
    if (typeof data.jobId !== 'string' || !(/^broadcast-[a-f0-9]{64}$/.test(data.jobId) || legacy && /^reminder2?-[A-Za-z0-9_-]{1,128}$/.test(data.jobId))) fail('invalid-job-id');
    const ref = db.collection('sendJobs').doc(data.jobId);
    const s = await ref.get();
    if (!s.exists || s.data().eventId !== data.eventId || !['broadcast', ...(legacy ? ['reminder'] : [])].includes(s.data().type)) fail('job-conflict');
    return {ref, job: s.data()};
  }
  async function settings({data}) {
    parse(data); const db = getDb(); const {event} = await loadConfirmedEvent(db, data.eventId);
    const targets = await collectBroadcastRecipients(db, data.eventId, event);
    // Display metadata only: count the exact collected recipients by their original import.
    // Do not add fields to recipients or change the delivery fingerprint.
    const [participants, batches] = await Promise.all([
      db.collection('participants').where('eventId', '==', data.eventId).get(),
      db.collection('importBatches').where('eventId', '==', data.eventId).get(),
    ]);
    const originalBatch = new Map(participants.docs.map((d) => [d.id, d.data().importBatchId]));
    const sequences = new Map(batches.docs.map((d) => [d.id, d.data().sequence]));
    const counts = new Map();
    for (const recipient of targets.recipients) {
      const sequence = sequences.get(originalBatch.get(recipient.participantId));
      const key = Number.isInteger(sequence) && sequence > 0 ? sequence : null;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
    const batchCounts = [...counts].map(([sequence, count]) => ({sequence, count}))
      .sort((a, b) => (a.sequence ?? Infinity) - (b.sequence ?? Infinity));
    const jobs = await db.collection('sendJobs').where('eventId', '==', data.eventId).get();
    const history = jobs.docs.filter((d) => ['broadcast', 'reminder'].includes(d.data().type)).map((d) => {
      const j = d.data();
      return {jobId: d.id, type: j.type, subject: j.snapshot?.template?.subject || '', body: j.snapshot?.template?.introBody || '',
        createdBy: j.createdBy, createdAt: iso(j.createdAt), startedAt: iso(j.broadcastStartedAt || j.dispatchRequestedAt),
        targetCount: j.targetCount, sentCount: j.sentCount, failedCount: j.failedCount, unknownCount: j.unknownCount, status: j.status};
    }).sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''));
    return {...targets, batchCounts, history};
  }
  async function prepare(db, data) {
    const {event} = await loadConfirmedEvent(db, data.eventId);
    const snapshot = broadcastSnapshot(data.eventId, event, data.draft);
    const targets = await collectBroadcastRecipients(db, data.eventId, event);
    return {snapshot, ...targets, confirmation: digest([snapshot, targets.fingerprint])};
  }
  async function preview({data}) {
    parse(data, ['draft', 'participantId']); const db = getDb();
    const p = await prepare(db, data);
    if (!p.targets.includes(data.participantId)) fail('participant-not-target');
    const participant = (await db.collection('participants').doc(data.participantId).get()).data();
    const rendered = await composeBroadcastMailFor({db, snapshot: p.snapshot, participantId: data.participantId, participant, appBaseUrl: getAppBaseUrl(), generateQrPng});
    if (!rendered.ok) fail('mail-not-ready');
    return {...rendered, ready: true, qrPngBase64: rendered.attachments[0]?.contentBase64 || '',
      recipients: p.recipients, targetCount: p.targets.length, confirmation: p.confirmation};
  }
  async function start({identity, data}) {
    parse(data, ['draft', 'operationId', 'confirmation', 'recipientsConfirmed']);
    if (!/^[A-Za-z0-9_-]{20,100}$/.test(data.operationId || '') || data.recipientsConfirmed !== true || typeof data.confirmation !== 'string') fail('confirmation-required');
    const db = getDb(), jobId = `broadcast-${digest([data.eventId, data.operationId])}`;
    const ref = db.collection('sendJobs').doc(jobId);
    // Freeze the acknowledged population and content in a single consistent transaction.
    // The same operation ID always reaches the same snapshot, including interrupted preparation.
    const job = await db.runTransaction(async (tx) => {
      const old = await tx.get(ref);
      if (old.exists) {
        if (old.data().snapshot.broadcastConfirmation !== data.confirmation || old.data().eventId !== data.eventId) fail('operation-conflict');
        return old.data();
      }
      const p = await prepare(transactionalReader(db, tx), data);
      if (p.confirmation !== data.confirmation || !p.targets.length || p.recipients.some((r) => !r.valid)) fail('targets-changed');
      const snapshot = {...p.snapshot, broadcastJobId: jobId, broadcastConfirmation: p.confirmation, broadcastTargets: p.targets,
        recipientSafetyFingerprints: Object.fromEntries(p.recipients.map((r) => [r.participantId, r.safetyFingerprint]))};
      const j = {eventId: data.eventId, batchId: null, batchSequence: null, type: 'broadcast', status: JOB.PREPARING,
        targetCount: p.targets.length, excludedInactiveCount: p.excludedCount, sentCount: 0, failedCount: 0, unknownCount: 0,
        batchCreatedCount: null, templateVersion: 1, snapshot, createdBy: identity.uid, createdAt: serverTimestamp(), broadcastStartedAt: serverTimestamp(), completedAt: null};
      tx.create(ref, j); return j;
    });
    await engine.openJob({db, identity, type: 'broadcast', jobId, eventId: data.eventId,
      targets: job.snapshot.broadcastTargets, excludedInactiveCount: job.excludedInactiveCount, snapshot: job.snapshot});
    return worker.requestDelivery({db, identity, jobId});
  }
  async function getJob({data}) {
    parse(data, ['jobId', 'itemStatus', 'limit', 'after']); const {job} = await owned(getDb(), data, true);
    const result = await winnerSendApi.readJob({...winnerSendApi.parseReadOptions(data), jobId: data.jobId});
    return {...result, job: {...result.job, subject: job.snapshot?.template?.subject || '', body: job.snapshot?.template?.introBody || ''}};
  }
  async function resume({identity, data}) {
    parse(data, ['jobId']); const db = getDb(); const {job} = await owned(db, data);
    await engine.openJob({db, identity, type: 'broadcast', jobId: data.jobId, eventId: data.eventId,
      targets: job.snapshot.broadcastTargets, excludedInactiveCount: job.excludedInactiveCount, snapshot: job.snapshot});
    return worker.requestDelivery({db, identity, jobId: data.jobId});
  }
  async function retry({data}) {
    parse(data, ['jobId']); const db = getDb(); await owned(db, data);
    return engine.retryFailed({db, jobId: data.jobId});
  }
  const busy = (j) => j.dispatchActive === true || (j.dispatchWorkerLeaseUntil?.toMillis?.() || 0) > Date.now() || !['ready', 'completed'].includes(j.status);
  const recoveryToken = (j, i, r) => digest([j.snapshot, i.status, i.attemptCount, r.safetyFingerprint]);
  async function recovery({data}) {
    parse(data, ['jobId']); const db = getDb(); const {ref, job} = await owned(db, data);
    if (busy(job)) return {recipients: []};
    const {event} = await loadConfirmedEvent(db, data.eventId);
    const current = await collectBroadcastRecipients(db, data.eventId, event);
    const failed = await ref.collection('items').where('status', '==', 'failed').get();
    const recipients = [];
    for (const item of failed.docs) {
      const r = current.recipients.find((r) => r.participantId === item.id && r.valid);
      if (!r) continue;
      const participant = (await db.collection('participants').doc(item.id).get()).data();
      const rendered = await composeBroadcastMailFor({db, snapshot: {...job.snapshot, broadcastJobId: null}, participantId: item.id, participant, appBaseUrl: getAppBaseUrl(), generateQrPng});
      if (rendered.ok) recipients.push({...r, text: rendered.text, fingerprint: recoveryToken(job, item.data(), r)});
    }
    return {recipients};
  }
  async function confirmRecovery({identity, data}) {
    parse(data, ['jobId', 'participantId', 'fingerprint', 'reason']);
    if (!/^[A-Za-z0-9-]{1,64}$/.test(data.participantId || '') || typeof data.reason !== 'string' || !data.reason.trim() || data.reason.length > 200) fail('invalid-recovery');
    const db = getDb(); const {ref} = await owned(db, data);
    return db.runTransaction(async (tx) => {
      const itemRef = ref.collection('items').doc(data.participantId), deliveryRef = db.collection('mailDeliveries').doc(`${data.jobId}_${data.participantId}`);
      const [j, i, d] = await tx.getAll(ref, itemRef, deliveryRef);
      if (busy(j.data()) || i.data()?.status !== 'failed' || d.data()?.status !== 'failed' || d.data()?.jobId !== data.jobId) fail('recovery-not-failed');
      const reader = transactionalReader(db, tx), {event} = await loadConfirmedEvent(reader, data.eventId);
      const current = await collectBroadcastRecipients(reader, data.eventId, event, data.participantId);
      const r = current.recipients[0];
      if (!r?.valid || recoveryToken(j.data(), i.data(), r) !== data.fingerprint) fail('recovery-state-changed');
      const reset = {status: 'pending', leaseUntil: null, dispatchStartedAt: null, updatedAt: serverTimestamp()};
      tx.update(deliveryRef, {...reset, claimId: null});
      tx.update(itemRef, {...reset, approvedSafetyFingerprint: r.safetyFingerprint, recoveryReason: data.reason.trim(), recoveryBy: identity.uid, recoveryAt: serverTimestamp()});
      tx.update(ref, {status: 'ready', completedAt: null});
      return {status: 'pending'};
    });
  }
  return {settings, preview, start, getJob, resume, retry, recovery, confirmRecovery};
}
module.exports = {createBroadcastApi};
