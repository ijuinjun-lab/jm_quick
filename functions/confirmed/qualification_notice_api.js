// Separate, manually invoked notification. Never creates a bulk send job or
// mutates historical deliveries/templates. One durable claim per change.
const {createHash} = require('node:crypto');
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
  const qualifications = createQualificationChangeApi(deps);
  function validate(d) {
    if (!d || !/^[A-Za-z0-9_-]{20,100}$/.test(d.operationId || '') || Object.keys(d).some(k => !['eventId','participantId','operationId','fingerprint'].includes(k))) fail('invalid-input');
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
    const text = `${s.person.name} 様\n\n参加内容を変更しました。\n\n【変更前】\n${summary(audit.before)}\n\n【変更後】\n${summary(audit.after)}\n\n既存のQRコード・Web参加証をご利用ください。取消済みの資格では受付できません。\n${pass}`;
    if (typeof s.person.email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s.person.email)) fail('invalid-email');
    const message = {to:s.person.email, senderName:s.event.senderName || s.event.eventName || 'JM Quick', subject:`【参加内容の変更】${s.event.eventName || ''}`, text,
      html:`<html><body><p>${escape(text).replace(/\n/g,'<br>')}</p><img src="cid:${QR_CONTENT_ID}" alt="受付QR"></body></html>`};
    return {message, qrPayload, webPassUrl:pass, fingerprint:hash([s.fingerprint, audit, message]), busy:s.busy};
  }
  async function preview({data:d}) {
    validate(d); const db = getDb();
    const c = await db.runTransaction(tx => compose(db,tx,d), {readOnly:true});
    return {...c.message, fingerprint:c.fingerprint, qrPayload:c.qrPayload, webPassUrl:c.webPassUrl};
  }
  async function send({identity,data:d}) {
    validate(d); const db = getDb();
    const ref = db.collection('qualificationNotices').doc(hash([d.eventId,d.participantId,d.operationId]));
    const transport = getTransport();
    if (!(await transport.capabilities()).ok) fail('transport-not-ready');
    const c = await db.runTransaction(async tx => {
      const old = await tx.get(ref);
      if (old.exists) return {existing:true,status:old.data().status};
      const c = await compose(db,tx,d);
      if (c.busy) fail('operation-in-progress');
      if (c.fingerprint !== d.fingerprint) fail('preview-changed');
      tx.create(ref,{eventId:d.eventId,participantId:d.participantId,operationId:d.operationId,
        ...c.message, fingerprint:c.fingerprint,status:'sending',startedAt:serverTimestamp(),createdBy:identity.uid});
      return c;
    });
    if (c.existing) return {status:c.status};
    let result, dispatchStarted = false;
    try {
      const png = await generateQrPng(c.qrPayload);
      dispatchStarted = true;
      result = await transport.send({...c.message,attachments:[{filename:'reception-qr.png',contentType:'image/png',contentBase64:Buffer.isBuffer(png) ? png.toString('base64') : png,contentId:QR_CONTENT_ID,disposition:'inline'}],metadata:{app:'jm-quick',type:'qualification-change',jobId:ref.id}});
    } catch (_) { result = {outcome:dispatchStarted ? 'unknown' : 'failed'}; }
    const status = ['sent','failed','unknown'].includes(result?.outcome) ? result.outcome : 'unknown';
    await ref.update({status,messageId:result?.messageId || null,completedAt:serverTimestamp()});
    return {status};
  }
  return {preview,send};
}
module.exports = {createQualificationNoticeApi};
