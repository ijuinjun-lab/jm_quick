// Administrative changes preserve participant capabilities and delivery outcomes.
const {createHash} = require('node:crypto');
const {mappingFor} = require('./participation_types');
const {programTimeText} = require('./mail_view_model');
const {parseTimeRange} = require('./waitlist_promotion');
const {ApiError} = require('./api_error');
const {isConfirmedFlow} = require('../flow');
const {isValidParticipantId, programAttendanceId, isValidPlannedCount} = require('../programs');
const digest = (v) => createHash('sha256').update(JSON.stringify(v)).digest('hex');
// Recovery can add a field before Firestore reorders map keys. Versioned,
// canonical fingerprints keep prior reviews compatible and new reviews stable.
const deliveryDigest = v => createHash('sha256').update(JSON.stringify(v, (_, value) =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? Object.fromEntries(Object.entries(value).sort(([a],[b]) => a.localeCompare(b))) : value)).digest('hex');
const fail = (code) => { throw new ApiError('failed-precondition', '資格の状態を再確認してください。受付・取込・配送中は変更できません。', {code}); };
const stamp = (v) => v?.toDate?.().toISOString() || v || null;
const view = (a) => ({programId: a.programId, plannedCount: a.plannedCount, slotLabel: a.slotLabel || '', startAt: stamp(a.startAt), endAt: stamp(a.endAt), entitlementStatus: a.entitlementStatus || 'active', checkedIn: a.checkedIn === true});
function createQualificationChangeApi({getDb, serverTimestamp, now = Date.now}) {
  function parse(d, changing = false) {
    const keys = ['eventId', 'participantId', ...(changing ? ['action', 'operationId', 'fingerprint', 'programId', 'targetProgramId', 'slotLabel', 'plannedCount', 'reason'] : [])];
    if (!d || typeof d !== 'object' || Array.isArray(d) || Object.keys(d).some(k => !keys.includes(k)) || !/^[A-Za-z0-9_-]{1,128}$/.test(d.eventId || '') || !isValidParticipantId(d.participantId)) fail('invalid-input');
    if (changing && d.targetProgramId !== undefined && (typeof d.targetProgramId !== 'string' || !d.targetProgramId)) fail('invalid-input');
    if (changing && (!/^[A-Za-z0-9_-]{20,100}$/.test(d.operationId || '') || !/^[a-f0-9]{64}$/.test(d.fingerprint || '') || typeof d.reason !== 'string' || !d.reason.trim() || d.reason.length > 200 || (d.action === 'cancelAll' ? d.programId !== undefined : typeof d.programId !== 'string'))) fail('invalid-input');
  }
  async function state(db, tx, d) {
    const e = db.collection('events').doc(d.eventId), p = db.collection('participants').doc(d.participantId);
    const [es, ps, as, bs, jobs, deliveries, notices, recoveries, inventory] = await Promise.all([
      tx.get(e), tx.get(p), tx.get(db.collection('programAttendances').where('participantId', '==', d.participantId)),
      tx.get(db.collection('importBatches').where('eventId', '==', d.eventId)),
      tx.get(db.collection('sendJobs').where('eventId', '==', d.eventId)),
      tx.get(db.collection('mailDeliveries').where('participantId', '==', d.participantId)),
      tx.get(db.collection('qualificationNotices').where('participantId', '==', d.participantId)),
      tx.get(p.collection('deliveryReviews')),
      tx.get(db.collection('programAttendances').where('eventId', '==', d.eventId)),
    ]);
    if (!es.exists || !isConfirmedFlow(es.data()) || !ps.exists || ps.data().eventId !== d.eventId || ps.data().status !== 'active' || ps.data().schemaVersion !== 2) fail('participant-unavailable');
    const event = es.data(), person = ps.data(), batches = new Map(bs.docs.map(s => [s.id, s.data()]));
    if (person.importBatchId && batches.get(person.importBatchId)?.status !== 'committed') fail('batch-not-committed');
    if (as.docs.some(s => s.data().eventId !== d.eventId)) fail('event-mismatch');
    // Failed/committing imports can still resume writing rows. Use existing
    // import recovery (resume or abandon); age alone is not proof of quiescence.
    let busyReason = event.activeImportBatch || bs.docs.some(s => ['committing','failed'].includes(s.data().status))
      ? '未完了の取込があります。既存の取込復旧画面で再開・完了、または放棄してから再取得してください。' : null;
    const reviewed = x => recoveries.docs.some(r => r.id === x.id && r.data().fingerprint === (r.data().fingerprintVersion === 2 ? deliveryDigest(x.data()) : digest(x.data())));
    const unresolved = x => ['pending', 'sending'].includes(x.data().status) ||
      (x.data().status === 'unknown' && !reviewed(x));
    const jobItems = new Map(), settledJobs = new Set();
    for (const job of jobs.docs) {
      const j = job.data();
      const own = await tx.get(job.ref.collection('items').doc(d.participantId));
      jobItems.set(job.id,own.data());
      // refreshJob does not persist pending/sending counts. Read the actual
      // items in this transaction so retries/worker updates conflict with recovery.
      if (deliveries.docs.some(x => x.data().jobId === job.id && x.data().status === 'unknown' && x.data().claimId)) {
        const items = await tx.get(job.ref.collection('items'));
        if (Number.isInteger(j.targetCount) && j.targetCount > 0 && items.size === j.targetCount &&
            items.docs.every(x => ['sent','failed','unknown'].includes(x.data().status) &&
              x.data().participantId === x.id && !(x.data().leaseUntil?.toMillis?.() > now()))) settledJobs.add(job.id);
      }
      // Preparing jobs can still grow their population. Terminal/ready jobs only
      // retry existing items; another person's worker never locks this person.
      if (j.status === 'preparing' || (own.exists &&
          (['pending', 'sending'].includes(own.data().status) ||
           (own.data().status === 'unknown' && !deliveries.docs.some(x => x.data().jobId === job.id && x.data().status === 'unknown' && reviewed(x))) ||
           (own.data().participantId && own.data().participantId !== d.participantId) ||
           (own.data().leaseUntil?.toMillis?.() || 0) > now()))) {
        busyReason ||= '本人の配送待ち・配送中、または送信対象の準備中です。送信管理で確認してください。';
      }
    }
    const millis = v => v?.toMillis?.() || 0;
    const deliveryStates = [...deliveries.docs, ...notices.docs].map(x => {
      const v = x.data(), notice = x.ref.parent.id === 'qualificationNotices';
      const job = jobs.docs.find(j => j.id === v.jobId)?.data(), item = jobItems.get(v.jobId);
      // An expired item lease alone is NOT completion evidence. The scheduler
      // must have settled the job, and the original 300s invocation plus margin
      // must have elapsed. Recovery then fences the old claim, retaining it in the audit.
      const interruptedMailEnded = !notice && v.claimId && v.lastErrorCode === 'lease-expired-after-dispatch' &&
        millis(v.dispatchStartedAt) > 0 && now() >= millis(v.dispatchStartedAt) + 360000 &&
        millis(v.updatedAt) >= millis(v.dispatchStartedAt) && job?.status === 'completed' &&
        job.dispatchActive === false && !job.dispatchWorkerId &&
        !(millis(job.dispatchWorkerLeaseUntil) > now()) &&
        settledJobs.has(v.jobId) && item?.status === 'unknown' &&
        millis(job.dispatchFinishedAt) >= millis(v.updatedAt);
      // New notices hold a renewable lease and fence before dispatch and finish.
      // Legacy notices have no fence: use their 120s invocation bound plus a
      // full extra minute; there is no automatic retry in either implementation.
      const interruptedNoticeEnded = notice && v.status === 'sending' &&
        millis(v.startedAt) > 0 && now() >= millis(v.startedAt) + 180000 &&
        (v.leaseUntil ? millis(v.leaseUntil) > 0 && millis(v.leaseUntil) <= now() : !v.claimId);
      const recoverable = !['pending','sending'].includes(item?.status) && !(millis(item?.leaseUntil) > now()) && !(millis(v.leaseUntil) > now()) &&
        ((v.status === 'unknown' && (notice ? !!v.completedAt : v.claimId === null || interruptedMailEnded)) || interruptedNoticeEnded);
      return {id:x.id, kind:x.ref.parent.id, status:v.status, to:v.to || person.email,
        startedAt:stamp(v.startedAt || v.createdAt), reviewed:reviewed(x), recoverable,
        attemptCount:v.attemptCount || 1, operationId:v.operationId || null, fingerprint:digest(v)};
    });
    if ([...deliveries.docs, ...notices.docs].some(unresolved))
      busyReason ||= '本人の未解決の配送があります。配送状態を確認してください。結果不明は再送しません。';
    // Independent test mails use a captured message and cannot write qualifications.
    const slots = Object.fromEntries(event.programs.map(p => {
      const values = [...(p.qualificationSlots || []), programTimeText({}, p),
        ...(mappingFor(d.eventId,event)?.talkProgramId === p.programId ? [event.confirmedMailSettings?.talkTimeText] : []),
        ...inventory.docs.filter(x => x.data().programId === p.programId && x.data().entitlementStatus !== 'revoked' &&
          (!x.data().importBatchId || batches.get(x.data().importBatchId)?.status === 'committed')).map(x => programTimeText(x.data(), p))];
      return [p.programId, [...new Set(values.filter(v => typeof v === 'string' && parseTimeRange(v)))].sort()];
    }));
    const busy = busyReason !== null;
    const activeQualificationCount = as.docs.filter(s => s.data().entitlementStatus !== 'revoked' &&
      (!s.data().identityVersion || batches.get(s.data().importBatchId)?.status === 'committed')).length;
    const fingerprint = digest([activeQualificationCount, person, event.qualificationRevision || 0, event.participationMapping || {}, event.programs, as.docs.map(s => [s.id, s.data()]).sort((a,b)=>a[0].localeCompare(b[0]))]);
    return {e, event, person, as, batches, busy, busyReason, activeQualificationCount, fingerprint, slots, deliveryStates};
  }
  async function get({data}) {
    parse(data); const db = getDb();
    return db.runTransaction(async tx => {
      const s = await state(db, tx, data);
      const history = await tx.get(db.collection('participants').doc(data.participantId).collection('qualificationChanges'));
      const display = a => ({...a, timeText: programTimeText(a, {...s.event.programs.find(p => p.programId === a.programId), ...(mappingFor(data.eventId,s.event)?.talkProgramId === a.programId ? {role:'talk',talkTimeText:s.event.confirmedMailSettings?.talkTimeText} : {})}) || ''});
      return {history: history.docs.map(x => ({...x.data(), before:x.data().before.map(display), after:x.data().after.map(display), changedAt: stamp(x.data().changedAt)})).sort((a,b) => String(b.changedAt).localeCompare(String(a.changedAt))), slots: s.slots, deliveries: s.deliveryStates, participantId: data.participantId, name: s.person.name, email: s.person.email, sourceReference: s.person.sourceReference || null,
        fingerprint: s.fingerprint, busy: s.busy, busyReason: s.busyReason, activeQualificationCount: s.activeQualificationCount, mapping: mappingFor(data.eventId, s.event) || {},
        programs: s.event.programs, qualifications: s.as.docs.map(a => display(view(a.data())))};
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
      const action = d.action || (d.targetProgramId ? 'swap' : 'cancel');
      if (!['add','edit','swap','cancel','cancelAll'].includes(action) || (action === 'swap' && !d.targetProgramId) || (['cancel','cancelAll'].includes(action) && d.targetProgramId)) fail('invalid-input');
      if (['add','edit'].includes(action)) return updateDetails(tx, db, s, d, identity, op, requestHash, action);
      // Both single and all cancellation use the same validation, transaction,
      // operation replay and audit writes. Validate every target before any write.
      const sources = action === 'cancelAll'
        ? s.as.docs.filter(a => a.data().entitlementStatus !== 'revoked')
        : s.as.docs.filter(a => a.data().programId === d.programId);
      if (!sources.length || sources.some(a => a.data().entitlementStatus === 'revoked')) fail('qualification-unavailable');
      for (const source of sources) {
        const a = source.data();
        if (a.identityVersion && s.batches.get(a.importBatchId)?.status !== 'committed') fail('batch-not-committed');
        if (a.checkedIn || a.checkedInAt || a.attendedCount != null) fail('already-checked-in');
      }
      const targetId = d.targetProgramId || null;
      let target = null, targetRef = null;
      if (targetId) {
        const m = mappingFor(d.eventId, s.event) || {};
        if (!((d.programId === m.catProgramId && targetId === m.dogProgramId) || (d.programId === m.dogProgramId && targetId === m.catProgramId)) || !s.event.programs.some(p => p.programId === targetId)) fail('invalid-program-change');
        if (!isValidPlannedCount(d.plannedCount) || typeof d.slotLabel !== 'string' || !parseTimeRange(d.slotLabel)) fail('invalid-slot');
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
      const cancelledIds = new Set(sources.map(a => a.data().programId));
      const after = before.filter(x => !cancelledIds.has(x.programId) && (!target || x.programId !== targetId));
      after.push(...sources.map(a => view({...a.data(), entitlementStatus:'revoked'})));
      if (target) after.push(view(target));
      for (const source of sources) tx.update(source.ref, {entitlementStatus: 'revoked', qualificationChangeId: d.operationId, updatedAt: serverTimestamp()});
      if (target) tx.set(targetRef, target);
      const audit = {eventId: d.eventId, participantId: d.participantId, operationId: d.operationId, requestHash, reason: d.reason.trim(), changedBy: identity.uid, changedAt: serverTimestamp(), before, after};
      tx.create(op, audit);
      for (const source of sources) tx.create(source.ref.collection('history').doc(`qualification-${d.operationId}`), audit);
      if (target) tx.create(targetRef.collection('history').doc(`qualification-${d.operationId}`), audit);
      // Existing import validation reads this document in its transaction.
      tx.update(s.e, {qualificationRevision: (s.event.qualificationRevision || 0) + 1});
      return {changed: true, operationId: d.operationId, replay: false};
    });
  }
  function updateDetails(tx, db, s, d, identity, op, requestHash, action) {
    if (d.targetProgramId || !s.event.programs.some(p => p.programId === d.programId)) fail('invalid-program-change');
    const existing = s.as.docs.find(x => x.data().programId === d.programId);
    const a = existing?.data();
    if (action === 'add' ? a && a.entitlementStatus !== 'revoked' : !a || a.entitlementStatus === 'revoked') fail('qualification-unavailable');
    if (a?.checkedIn || a?.checkedInAt || a?.attendedCount != null) fail('already-checked-in');
    if (a?.identityVersion && s.batches.get(a.importBatchId)?.status !== 'committed') fail('batch-not-committed');
    const program = s.event.programs.find(p => p.programId === d.programId);
    const currentTime = a ? programTimeText(a, {...program, ...(mappingFor(d.eventId,s.event)?.talkProgramId === d.programId ? {role:'talk',talkTimeText:s.event.confirmedMailSettings?.talkTimeText} : {})}) || '' : '';
    const sameTime = action === 'edit' && (d.slotLabel === (a.slotLabel || '') || d.slotLabel === currentTime);
    if (!isValidPlannedCount(d.plannedCount) || typeof d.slotLabel !== 'string' ||
        !(s.slots[d.programId].includes(d.slotLabel) || sameTime)) fail('invalid-slot');
    if (action === 'edit' && a.plannedCount === d.plannedCount && sameTime) fail('no-change');
    const ref = existing?.ref || db.collection('programAttendances').doc(programAttendanceId(d.participantId, d.programId));
    const next = {...(a || {}), eventId:d.eventId, participantId:d.participantId, programId:d.programId,
      plannedCount:d.plannedCount, slotLabel:sameTime ? a.slotLabel || '' : d.slotLabel, entitlementStatus:'active',
      ...(action === 'add' ? {importBatchId:s.person.importBatchId || null, checkedIn:false, checkedInAt:null, attendedCount:null, qualificationSource:'admin-change'} : {}),
      ...(!sameTime ? {startAt:null, endAt:null} : {}),
      qualificationChangeId:d.operationId, updatedAt:serverTimestamp()};
    const before = s.as.docs.map(x => view(x.data()));
    const after = [...before.filter(x => x.programId !== d.programId), view(next)];
    const audit = {eventId:d.eventId, participantId:d.participantId, operationId:d.operationId, requestHash, action,
      reason:d.reason.trim(), changedBy:identity.uid, changedAt:serverTimestamp(), before, after};
    tx.set(ref, next); tx.create(op, audit); tx.create(ref.collection('history').doc(`qualification-${d.operationId}`), audit);
    tx.update(s.e, {qualificationRevision:(s.event.qualificationRevision || 0)+1});
    return {changed:true, operationId:d.operationId, replay:false};
  }
  async function reviewDelivery({identity, data:d}) {
    if (!d || !['mailDeliveries','qualificationNotices'].includes(d.kind) || !/^[A-Za-z0-9_-]{1,200}$/.test(d.deliveryId || '') ||
        typeof d.reason !== 'string' || !d.reason.trim() || d.reason.length > 200) fail('invalid-input');
    parse({eventId:d.eventId,participantId:d.participantId});
    const db = getDb();
    return db.runTransaction(async tx => {
      const s = await state(db, tx, d);
      const x = await tx.get(db.collection(d.kind).doc(d.deliveryId));
      if (!x.exists || x.data().participantId !== d.participantId || x.data().eventId !== d.eventId ||
          !s.deliveryStates.some(v => v.id === d.deliveryId && v.kind === d.kind && v.recoverable)) fail('delivery-still-active');
      if (d.fingerprint !== undefined && d.fingerprint !== digest(x.data())) fail('delivery-state-changed');
      const attemptRef = x.ref.collection('attempts').doc(String(x.data().attemptCount || 1));
      const attempt = d.kind === 'qualificationNotices' ? await tx.get(attemptRef) : null;
      let reviewedData = x.data();
      if (d.kind === 'mailDeliveries' && reviewedData.claimId) {
        // finishItem accepts a late result for this unknown status only while
        // its claim matches. Fence it atomically with the review, without
        // changing the unknown outcome, error, timestamps or attempt count.
        reviewedData = {...reviewedData, claimId:null};
        tx.update(x.ref, {claimId:null});
      }
      if (d.kind === 'qualificationNotices' && reviewedData.status === 'sending') {
        // Fence the abandoned attempt; a delayed sender cannot dispatch or
        // overwrite this unknown result. Unknown can never be retried.
        reviewedData = {...reviewedData, status:'unknown', leaseUntil:null, recoveryReason:d.reason.trim()};
        tx.update(x.ref, {status:'unknown', leaseUntil:null, recoveryReason:d.reason.trim()});
        if (attempt.exists) tx.update(attemptRef,{status:'unknown',leaseUntil:null,recoveryReason:d.reason.trim(),recoveredBy:identity.uid,recoveredAt:serverTimestamp()});
        else tx.create(attemptRef,{...reviewedData,recoveredBy:identity.uid,recoveredAt:serverTimestamp()});
      }
      const review = {fingerprint:deliveryDigest(reviewedData), fingerprintVersion:2, reason:d.reason.trim(), reviewedBy:identity.uid,
        reviewedAt:serverTimestamp(), previousStatus:x.data().status, claimId:x.data().claimId || null,
        attemptCount:x.data().attemptCount || 1};
      const ref = db.collection('participants').doc(d.participantId).collection('deliveryReviews').doc(x.id);
      tx.set(ref, review);
      tx.create(ref.collection('history').doc(), review);
      return {reviewed:true};
    });
  }
  return {get, change, reviewDelivery, state};
}
module.exports = {createQualificationChangeApi};
