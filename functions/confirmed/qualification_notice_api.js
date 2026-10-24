// Separate, manually invoked notification. Never creates a bulk send job or
// mutates historical deliveries/templates. One fenced claim per explicit attempt.
const {createHash, randomUUID} = require('node:crypto');
const {programTimeText} = require('./mail_view_model');
const {mappingFor} = require('./participation_types');
const {ApiError} = require('./api_error');
const {receptionQrPayload, webPassUrl, QR_CONTENT_ID} = require('./pass_urls');
const {createQualificationChangeApi} = require('./qualification_change_api');
const stamp = v => v?.toDate?.().toISOString() || v || null;
const hash = v => createHash('sha256').update(JSON.stringify(v)).digest('hex');
const escape = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fail = code => {throw new ApiError('failed-precondition', '変更通知の内容・配送状態を再確認してください。', {code});};
function createQualificationNoticeApi(deps) {
  const {getDb, serverTimestamp, getTransport, generateQrPng, getAppBaseUrl} = deps;
  const now = deps.now || Date.now;
  const leaseMs = 180000; // Longer than the 120s callable bound and 30s transport timeout.
  const heartbeatMs = deps.heartbeatMs || 15000;
  const countOf = v => v ? v.attemptCount || 1 : 0;
  const attemptRef = (ref, n) => ref.collection('attempts').doc(String(n));
  const qualifications = createQualificationChangeApi(deps);
  function validate(d) {
    if (!d || !/^[A-Za-z0-9_-]{20,100}$/.test(d.operationId || '') || Object.keys(d).some(k => !['eventId','participantId','operationId','fingerprint','retry','expectedAttempt'].includes(k))) fail('invalid-input');
    if (d.retry !== undefined && typeof d.retry !== 'boolean') fail('invalid-input');
    if (d.expectedAttempt !== undefined && (!Number.isInteger(d.expectedAttempt) || d.expectedAttempt < 0)) fail('invalid-input');
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(d.eventId || '') || !/^[A-Za-z0-9-]{1,64}$/.test(d.participantId || '')) fail('invalid-input');
  }
  async function compose(db, tx, d) {
    const s = await qualifications.state(db, tx, d);
    const op = await tx.get(db.collection('participants').doc(d.participantId).collection('qualificationChanges').doc(d.operationId));
    if (!op.exists || op.data().eventId !== d.eventId) fail('change-not-found');
    const audit = op.data();
    // Do not mail an obsolete change as the current participation information.
    const latest = s.as.docs.map(x => x.data());
    if (audit.after.length !== latest.length || audit.after.some(a => !latest.some(b =>
      a.programId === b.programId && a.startAt === stamp(b.startAt) && a.endAt === stamp(b.endAt) && a.plannedCount === b.plannedCount && a.slotLabel === (b.slotLabel || '') &&
      a.entitlementStatus === (b.entitlementStatus || 'active')))) fail('change-superseded');
    const ids = {appBaseUrl:getAppBaseUrl(), eventId:d.eventId, participantId:d.participantId, publicId:s.person.publicId};
    const qrPayload = receptionQrPayload(ids), pass = webPassUrl(ids);
    const summary = rows => rows.map(a => `${s.event.programs.find(p => p.programId === a.programId)?.name || a.programId}：${programTimeText(a, {...s.event.programs.find(p => p.programId === a.programId), ...(mappingFor(d.eventId,s.event)?.talkProgramId === a.programId ? {role:'talk',talkTimeText:s.event.confirmedMailSettings?.talkTimeText} : {})}) || '時間指定なし'} / ${a.plannedCount}名${a.entitlementStatus === 'revoked' ? '（取消）' : ''}`).join('\n');
    const hasActive = audit.after.some(a => a.entitlementStatus !== 'revoked');
    const guidance = hasActive ? `既存のQRコード・Web参加証をご利用ください。取消済みの資格では受付できません。\n${pass}` : '参加資格はすべて取り消されました。既存のQRコード・Web参加証では受付できません。';
    const text = `${s.person.name} 様\n\n参加内容を変更しました。\n\n【変更前】\n${summary(audit.before)}\n\n【変更後】\n${summary(audit.after)}\n\n${guidance}`;
    if (typeof s.person.email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.person.email)) fail('invalid-email');
    const message = {to:s.person.email, senderName:s.event.senderName || s.event.eventName || 'JM Quick', subject:`【参加内容の変更】${s.event.eventName || ''}`, text,
      html:`<html><body><p>${escape(text).replace(/\n/g,'<br>')}</p>${hasActive ? `<img src="cid:${QR_CONTENT_ID}" alt="受付QR">` : ''}</body></html>`};
    return {message, hasActive, qrPayload, webPassUrl:pass, fingerprint:hash([s.fingerprint, audit, message]), busy:s.busy};
  }
  async function preview({data:d}) {
    validate(d); const db = getDb();
    const {c, old} = await db.runTransaction(async tx => {
      const c = await compose(db,tx,d);
      const old = await tx.get(db.collection('qualificationNotices').doc(hash([d.eventId,d.participantId,d.operationId])));
      return {c,old:old.data()};
    }, {readOnly:true});
    return {...c.message, fingerprint:c.fingerprint, qrPayload:c.qrPayload, webPassUrl:c.webPassUrl,
      status:old?.status || null, expectedAttempt:countOf(old), canRetry:old?.status === 'failed'};
  }
  async function send({identity,data:d}) {
    validate(d); const db = getDb();
    const ref = db.collection('qualificationNotices').doc(hash([d.eventId,d.participantId,d.operationId]));
    const transport = getTransport();
    if (!(await transport.capabilities()).ok) fail('transport-not-ready');
    const claimId = randomUUID();
    const c = await db.runTransaction(async tx => {
      const old = await tx.get(ref), previous = old.data(), expected = d.expectedAttempt ?? 0;
      const n = countOf(previous);
      // A repeated request never creates a fresh attempt, even if the previous
      // call failed quickly before the second click reached this transaction.
      if (old.exists && !(previous.status === 'failed' && d.retry === true && expected === n))
        return {existing:true,status:previous.status,attemptCount:n};
      if (!old.exists && (d.retry === true || expected !== 0)) fail('attempt-changed');
      const c = await compose(db,tx,d);
      if (c.busy) fail('operation-in-progress');
      if (c.fingerprint !== d.fingerprint) fail('preview-changed');
      if (previous && Object.entries(c.message).some(([k,v]) => previous[k] !== v)) fail('notice-content-changed');
      const priorAttempt = old.exists ? await tx.get(attemptRef(ref,n)) : null;
      if (priorAttempt && !priorAttempt.exists) tx.create(attemptRef(ref,n),previous); // legacy failed attempt
      const record = {eventId:d.eventId,participantId:d.participantId,operationId:d.operationId,
        ...c.message,fingerprint:c.fingerprint,status:'sending',startedAt:serverTimestamp(),createdBy:identity.uid,
        attemptCount:n+1,claimId,leaseUntil:new Date(now()+leaseMs),completedAt:null,messageId:null,
        retryOf:old.exists ? n : null};
      tx.set(ref,record);
      tx.create(attemptRef(ref,n+1),record);
      return {...c,attemptCount:n+1};
    });
    if (c.existing) return {status:c.status,attemptCount:c.attemptCount};
    const owned = v => v?.status === 'sending' && v.claimId === claimId && v.leaseUntil?.toMillis?.() > now();
    // Renew only a still-valid claim. Never revive a recovered or expired claim.
    let heartbeatRunning = false;
    const timer = setInterval(async () => {
      if (heartbeatRunning) return;
      heartbeatRunning = true;
      try {
        await db.runTransaction(async tx => {
          const v = (await tx.get(ref)).data();
          if (owned(v)) tx.update(ref,{leaseUntil:new Date(now()+leaseMs)});
        });
      } catch (_) { /* A lost lease is checked again before dispatch and finish. */ }
      finally { heartbeatRunning = false; }
    },heartbeatMs);
    timer.unref?.();
    let result, dispatchStarted = false;
    try {
      const png = c.hasActive ? await generateQrPng(c.qrPayload) : null;
      const dispatch = await db.runTransaction(async tx => {
        const v = (await tx.get(ref)).data();
        if (!owned(v)) return false;
        const update = {dispatchStartedAt:serverTimestamp(),leaseUntil:new Date(now()+leaseMs)};
        tx.update(ref,update);tx.update(attemptRef(ref,c.attemptCount),update);
        return true;
      });
      if (!dispatch) result = {outcome:'unknown'};
      else {
        dispatchStarted = true;
        result = await transport.send({...c.message,attachments:c.hasActive ? [{filename:'reception-qr.png',contentType:'image/png',contentBase64:Buffer.isBuffer(png) ? png.toString('base64') : png,contentId:QR_CONTENT_ID,disposition:'inline'}] : [],metadata:{app:'jm-quick',type:'qualification-change',jobId:ref.id}});
      }
    } catch (_) { result = {outcome:dispatchStarted ? 'unknown' : 'failed'}; }
    finally { clearInterval(timer); }
    return db.runTransaction(async tx => {
      const v = (await tx.get(ref)).data();
      if (v.status !== 'sending' || v.claimId !== claimId) return {status:v.status,attemptCount:countOf(v)};
      const status = owned(v) && ['sent','failed','unknown'].includes(result?.outcome) ? result.outcome : 'unknown';
      const update = {status,messageId:result?.messageId || null,completedAt:serverTimestamp(),leaseUntil:null};
      tx.update(ref,update);tx.update(attemptRef(ref,c.attemptCount),update);
      return {status,attemptCount:c.attemptCount};
    });
  }
  return {preview,send};
}
module.exports = {createQualificationNoticeApi};
