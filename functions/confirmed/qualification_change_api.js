// Administrative changes preserve participant capabilities and all delivery records.
const {createHash} = require('node:crypto');
const {ApiError} = require('./api_error');
const {isConfirmedFlow} = require('../flow');
const {isValidParticipantId, programAttendanceId, isValidPlannedCount} = require('../programs');
const digest = (v) => createHash('sha256').update(JSON.stringify(v)).digest('hex');
const fail = (code) => { throw new ApiError('failed-precondition', '資格の状態を再確認してください。受付・取込・配送中は変更できません。', {code}); };
const stamp = (v) => v?.toDate?.().toISOString() || v || null;
const view = (a) => ({programId: a.programId, plannedCount: a.plannedCount, slotLabel: a.slotLabel || '', startAt: stamp(a.startAt), endAt: stamp(a.endAt), entitlementStatus: a.entitlementStatus || 'active', checkedIn: a.checkedIn === true});
function createQualificationChangeApi({getDb, serverTimestamp}) {
  function parse(d, changing = false) {
    const keys = ['eventId', 'participantId', ...(changing ? ['operationId', 'fingerprint', 'programId', 'targetProgramId', 'slotLabel', 'plannedCount', 'reason'] : [])];
    if (!d || typeof d !== 'object' || Array.isArray(d) || Object.keys(d).some(k => !keys.includes(k)) || !/^[A-Za-z0-9_-]{1,128}$/.test(d.eventId || '') || !isValidParticipantId(d.participantId)) fail('invalid-input');
    if (changing && d.targetProgramId !== undefined && (typeof d.targetProgramId !== 'string' || !d.targetProgramId)) fail('invalid-input');
    if (changing && (!/^[A-Za-z0-9_-]{20,100}$/.test(d.operationId || '') || !/^[a-f0-9]{64}$/.test(d.fingerprint || '') || typeof d.reason !== 'string' || !d.reason.trim() || d.reason.length > 200 || typeof d.programId !== 'string')) fail('invalid-input');
  }
  async function state(db, tx, d) {
    const e = db.collection('events').doc(d.eventId), p = db.collection('participants').doc(d.participantId);
    const [es, ps, as, bs, jobs, deliveries, tests] = await Promise.all([
      tx.get(e), tx.get(p), tx.get(db.collection('programAttendances').where('participantId', '==', d.participantId)),
      tx.get(db.collection('importBatches').where('eventId', '==', d.eventId)),
      tx.get(db.collection('sendJobs').where('eventId', '==', d.eventId)),
      tx.get(db.collection('mailDeliveries').where('participantId', '==', d.participantId)),
      tx.get(db.collection('testMailDeliveries').where('eventId', '==', d.eventId)),
    ]);
    if (!es.exists || !isConfirmedFlow(es.data()) || !ps.exists || ps.data().eventId !== d.eventId || ps.data().status !== 'active' || ps.data().schemaVersion !== 2) fail('participant-unavailable');
    const event = es.data(), person = ps.data(), batches = new Map(bs.docs.map(s => [s.id, s.data()]));
    if (person.importBatchId && batches.get(person.importBatchId)?.status !== 'committed') fail('batch-not-committed');
    if (as.docs.some(s => s.data().eventId !== d.eventId)) fail('event-mismatch');
    const busy = event.activeImportBatch || bs.docs.some(s => ['committing','failed'].includes(s.data().status)) ||
      jobs.docs.some(s => { const j = s.data(); return j.dispatchActive || j.dispatchWorkerId || (j.dispatchWorkerLeaseUntil?.toMillis?.() || 0) > Date.now() || j.status !== 'completed'; }) ||
      deliveries.docs.some(s => ['pending','sending','unknown'].includes(s.data().status)) ||
      tests.docs.some(s => ['sending','unknown'].includes(s.data().status));
    const fingerprint = digest([person, event.qualificationRevision || 0, event.participationMapping || {}, event.programs, as.docs.map(s => [s.id, s.data()]).sort((a,b)=>a[0].localeCompare(b[0]))]);
    return {e, event, person, as, batches, busy: !!busy, fingerprint};
  }
  async function get({data}) {
    parse(data); const db = getDb();
    return db.runTransaction(async tx => {
      const s = await state(db, tx, data);
      return {participantId: data.participantId, name: s.person.name, email: s.person.email, sourceReference: s.person.sourceReference || null,
        fingerprint: s.fingerprint, busy: s.busy, mapping: s.event.participationMapping || {},
        programs: s.event.programs, qualifications: s.as.docs.map(a => view(a.data()))};
    }, {readOnly: true});
  }
  async function change({identity, data: d}) {
    parse(d, true); const db = getDb();
    const op = db.collection('participants').doc(d.participantId).collection('qualificationChanges').doc(d.operationId);
    const requestHash = digest(d);
    return db.runTransaction(async tx => {
      const old = await tx.get(op);
      if (old.exists) {
        if (old.data().eventId !== d.eventId || old.data().requestHash !== requestHash) fail('operation-conflict');
        return {changed: true, operationId: d.operationId, replay: true};
      }
      const s = await state(db, tx, d);
      if (s.busy) fail('operation-in-progress');
      if (s.fingerprint !== d.fingerprint) fail('state-changed');
      const source = s.as.docs.find(a => a.data().programId === d.programId);
      if (!source || source.data().entitlementStatus === 'revoked') fail('qualification-unavailable');
      const a = source.data();
      if (a.identityVersion && s.batches.get(a.importBatchId)?.status !== 'committed') fail('batch-not-committed');
      if (a.checkedIn || a.checkedInAt || a.attendedCount != null) fail('already-checked-in');
      const targetId = d.targetProgramId || null;
      let target = null, targetRef = null;
      if (targetId) {
        const m = s.event.participationMapping || {};
        if (!((d.programId === m.catProgramId && targetId === m.dogProgramId) || (d.programId === m.dogProgramId && targetId === m.catProgramId)) || !s.event.programs.some(p => p.programId === targetId)) fail('invalid-program-change');
        if (!isValidPlannedCount(d.plannedCount) || typeof d.slotLabel !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$/.test(d.slotLabel) || d.slotLabel.slice(0,5) >= d.slotLabel.slice(6)) fail('invalid-slot');
        const previous = s.as.docs.find(x => x.data().programId === targetId);
        if (previous && (previous.data().entitlementStatus !== 'revoked' || previous.data().checkedIn || previous.data().checkedInAt || previous.data().attendedCount != null)) fail('target-exists');
        targetRef = db.collection('programAttendances').doc(programAttendanceId(d.participantId, targetId));
        target = {...(previous?.data() || {}), eventId: d.eventId, participantId: d.participantId, programId: targetId,
          plannedCount: d.plannedCount, slotLabel: d.slotLabel, startAt: null, endAt: null,
          importBatchId: s.person.importBatchId || null, entitlementStatus: 'active',
          checkedIn: false, checkedInAt: null, checkedInBy: null, attendedCount: null,
          qualificationSource: 'admin-change', qualificationChangeId: d.operationId, updatedAt: serverTimestamp()};
      } else if (d.plannedCount !== undefined || d.slotLabel !== undefined) fail('invalid-input');
      const before = s.as.docs.map(x => view(x.data()));
      const cancelled = {...a, entitlementStatus: 'revoked'};
      const after = before.filter(x => x.programId !== d.programId && (!target || x.programId !== targetId));
      after.push(view(cancelled)); if (target) after.push(view(target));
      tx.update(source.ref, {entitlementStatus: 'revoked', qualificationChangeId: d.operationId, updatedAt: serverTimestamp()});
      if (target) tx.set(targetRef, target);
      const audit = {eventId: d.eventId, participantId: d.participantId, operationId: d.operationId, requestHash, reason: d.reason.trim(), changedBy: identity.uid, changedAt: serverTimestamp(), before, after};
      tx.create(op, audit);
      tx.create(source.ref.collection('history').doc(`qualification-${d.operationId}`), audit);
      if (target) tx.create(targetRef.collection('history').doc(`qualification-${d.operationId}`), audit);
      // Existing import validation reads this document in its transaction.
      tx.update(s.e, {qualificationRevision: (s.event.qualificationRevision || 0) + 1});
      return {changed: true, operationId: d.operationId, replay: false};
    });
  }
  return {get, change};
}
module.exports = {createQualificationChangeApi};
