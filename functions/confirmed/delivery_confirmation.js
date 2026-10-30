const {createHash, randomUUID} = require('node:crypto');
const {ApiError} = require('./api_error');
const {loadConfirmedEvent} = require('./winner_mail_api');
const {renderConfirmation, ms, LABELS} = require('./delivery_confirmation_render');
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const fail = code => { throw new ApiError('failed-precondition', '配信確認の設定・配送状態を再確認してください。', {code}); };
const emailOf = value => typeof value === 'string' && value.trim().length <= 254 && /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(value.trim()) ? value.trim().toLowerCase() : null;
const reportIdFor = (eventId, jobId) => hash([eventId, jobId]);
const kindOf = job => job.type === 'broadcast' ? 'broadcast' : job.type === 'winner' && ['normal','waitlistPromotion'].includes(job.notificationType || 'normal') ? job.notificationType || 'normal' : null;
function request(data, keys = []) {
  if (!data || typeof data !== 'object' || Array.isArray(data) || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId || '') ||
    Object.keys(data).some(k => !['eventId', ...keys].includes(k))) fail('invalid-request');
}
function createDeliveryConfirmationApi({getDb, serverTimestamp, getTransport, generateQrPng, now = Date.now, leaseMs = 180000}) {
  const policyRef = (db,id) => db.collection('deliveryConfirmationPolicies').doc(id);
  const reports = db => db.collection('deliveryConfirmationReports');
  const iso = v => ms(v) ? new Date(ms(v)).toISOString() : null;
  const eligible = (policy, job) => policy?.enabled === true && ms(policy.activatedAt) > 0 && ms(job.createdAt) > ms(policy.activatedAt);
  const allowed = (policy, report, address) => eligible(policy, {createdAt: report.sourceCreatedAt}) &&
    policy.recipients?.some(r => r.email === address && r.enabled && r.kinds.includes(report.kind));
  async function settings({identity, data}) {
    request(data, ['after']); const db = getDb(); await loadConfirmedEvent(db, data.eventId);
    if (data.after !== undefined && !/^[a-f0-9]{64}$/.test(data.after)) fail('invalid-cursor');
    const p = await policyRef(db,data.eventId).get();
    // The ID is only a tie-breaker; completion time determines every page's order.
    let query = reports(db).where('eventId','==',data.eventId)
      .orderBy('sourceCompletedAt','desc').orderBy('__name__','desc').limit(21);
    if (data.after) {
      const cursor = await reports(db).doc(data.after).get();
      if (!cursor.exists || cursor.data().eventId !== data.eventId || !ms(cursor.data().sourceCompletedAt)) fail('invalid-cursor');
      query = query.startAfter(cursor);
    }
    const found = await query.get();
    return {canManage: identity?.systemAdmin === true, policy: p.exists ? {...p.data(), activatedAt:iso(p.data().activatedAt), updatedAt:iso(p.data().updatedAt)} : {enabled:false,version:0,recipients:[]},
      reports: found.docs.slice(0,20).map(d => {const r=d.data();return {reportId:d.id,jobId:r.sourceJobId,kind:r.kind,status:r.status,subject:r.message?.subject || '',completedAt:iso(r.sourceCompletedAt),errorCode:r.errorCode || null};}),
      nextAfter:found.size>20?found.docs[19].id:null};
  }
  async function setPolicy({identity,data}) {
    request(data,['enabled','recipients','expectedVersion']);
    if (identity?.systemAdmin !== true) throw new ApiError('permission-denied','システム管理者のみ変更できます。');
    if (typeof data.enabled !== 'boolean' || !Number.isInteger(data.expectedVersion) || !Array.isArray(data.recipients) || data.recipients.length > 10) fail('invalid-policy');
    const recipients = data.recipients.map(r => {
      if (!r || Object.keys(r).some(k=>!['email','name','enabled','kinds'].includes(k)) || typeof r.name !== 'string' || r.name.length>100 || typeof r.enabled !== 'boolean' || !Array.isArray(r.kinds) || r.kinds.some(k=>typeof k !== 'string' || !Object.hasOwn(LABELS,k))) fail('invalid-recipient');
      if (!emailOf(r.email)) fail('invalid-address');
      if (!r.kinds.length) fail('mail-kind-required');
      return {email:emailOf(r.email),name:r.name.trim(),enabled:r.enabled,kinds:[...new Set(r.kinds)].sort()};
    });
    if (new Set(recipients.map(r=>r.email)).size!==recipients.length) fail('duplicate-address');
    const db=getDb();await loadConfirmedEvent(db,data.eventId);
    const ref=policyRef(db,data.eventId);
    await db.runTransaction(async tx=>{
      const old=(await tx.get(ref)).data();if ((old?.version||0)!==data.expectedVersion) fail('policy-changed');
      tx.set(ref,{eventId:data.eventId,enabled:data.enabled,recipients,version:data.expectedVersion+1,
        activatedAt:data.enabled ? old?.enabled ? old.activatedAt : serverTimestamp() : null,
        updatedAt:serverTimestamp(),updatedBy:identity.uid});
    });
    return {saved:true};
  }
  // The report is immutable once prepared. Only independent deliveries change.
  async function prepare(jobId, job) {
    const db=getDb(), ref=reports(db).doc(reportIdFor(job.eventId,jobId));
    const old=await ref.get();if(old.exists)return ref;
    const p=(await policyRef(db,job.eventId).get()).data(), kind=kindOf(job);
    if (!kind || !eligible(p,job) || !p.recipients.some(r=>r.enabled&&r.kinds.includes(kind))) return null;
    await loadConfirmedEvent(db,job.eventId);
    if (![job.targetCount,job.sentCount,job.failedCount,job.unknownCount].every(n=>Number.isInteger(n)&&n>=0) || job.sentCount+job.failedCount+job.unknownCount!==job.targetCount || !ms(job.completedAt)) fail('source-counts-invalid');
    // One bounded read: never fetch participant records or an entire recipient list.
    const sample=await db.collection('sendJobs').doc(jobId).collection('items').where('status','in',job.sentCount > 0 ? ['sent'] : ['failed','unknown']).limit(1).get();
    let message=null,errorCode=null;
    const item = sample.docs[0]?.data();
    // Never guess a pattern, or use evidence from an earlier delivery attempt.
    const evidence = item?.confirmationEvidence?.attemptCount === item?.attemptCount && Number.isInteger(item?.attemptCount)
      ? item.confirmationEvidence : null;
    if (!evidence) errorCode='no-successful-sample';
    else {
      try {message=await renderConfirmation({job:{...job,jobId},kind,evidence,generateQrPng});}
      catch(e){errorCode=['renderer-version-unavailable','sample-unavailable','sample-render-failed','confirmation-too-large'].includes(e.message)?e.message:'sample-render-failed';}
    }
    await db.runTransaction(async tx=>{
      const [existing,current]=await tx.getAll(ref,policyRef(db,job.eventId));
      if(existing.exists)return;
      const policy=current.data();if(!eligible(policy,job)||policy.version!==p.version) fail('policy-changed');
      const recipients=policy.recipients.filter(r=>r.enabled&&r.kinds.includes(kind));
      if(!recipients.length)return;
      tx.create(ref,{eventId:job.eventId,sourceJobId:jobId,sourceCreatedAt:job.createdAt,sourceCompletedAt:job.completedAt,
        sourceStartedAt:job.dispatchRequestedAt||job.broadcastStartedAt||null,kind,batchSequence:job.batchSequence||null,
        targetCount:job.targetCount,sentCount:job.sentCount,failedCount:job.failedCount,unknownCount:job.unknownCount,
        policyVersion:policy.version,createdAt:serverTimestamp(),status:message?'ready':'unavailable',errorCode,message});
      for(const r of recipients)tx.create(ref.collection('deliveries').doc(hash(r.email)),{eventId:job.eventId,email:r.email,name:r.name,status:'pending',attemptCount:0,createdAt:serverTimestamp()});
    });
    return (await ref.get()).exists?ref:null;
  }
  async function deliver(ref,key,{retry=false,expectedAttempt=0,actor='automatic'}={}) {
    const db=getDb(),delivery=ref.collection('deliveries').doc(key),claimId=randomUUID();
    const claimed=await db.runTransaction(async tx=>{
      const [rs,ds]=await tx.getAll(ref,delivery);if(!rs.exists||!ds.exists)fail('delivery-missing');
      const r=rs.data(),d=ds.data(),p=(await tx.get(policyRef(db,r.eventId))).data();
      if(r.status!=='ready'||!allowed(p,r,d.email))return {status:d.status,blocked:'disabled-or-unavailable'};
      if(d.status==='sending'){
        if(ms(d.leaseUntil)>now())return {status:'sending'};
        if(d.dispatchStartedAt){tx.update(delivery,{status:'unknown',errorCode:'expired-after-dispatch',leaseUntil:null});return {status:'unknown'};}
        // Only an expired pre-dispatch lease is safe to reclaim automatically.
      } else if(d.status==='failed') {
        if(!retry||expectedAttempt!==d.attemptCount)return {status:'failed'};
      } else if(d.status!=='pending')return {status:d.status};
      if(retry && (d.status!=='failed'||expectedAttempt!==d.attemptCount))fail('attempt-changed');
      tx.update(delivery,{status:'sending',claimId,leaseUntil:new Date(now()+leaseMs),dispatchStartedAt:null,
        attemptCount:d.attemptCount+1,requestedBy:actor,startedAt:serverTimestamp(),errorCode:null});
      return {claimed:true,report:r,to:d.email};
    });
    if(!claimed.claimed)return claimed;
    let outcome={outcome:'failed',errorCode:'transport-not-ready'};
    let dispatched=false;
    try {
      const transport=getTransport();
      if((await transport.capabilities()).ok){
        dispatched=await db.runTransaction(async tx=>{
          const [ds,ps]=await tx.getAll(delivery,policyRef(db,claimed.report.eventId));const d=ds.data();
          if(d.status!=='sending'||d.claimId!==claimId||ms(d.leaseUntil)<=now())return false;
          if(!allowed(ps.data(),claimed.report,claimed.to)){tx.update(delivery,{status:'pending',claimId:null,leaseUntil:null});return false;}
          tx.update(delivery,{dispatchStartedAt:serverTimestamp()});return true;
        });
        if(dispatched)outcome=await transport.send({...claimed.report.message,to:claimed.to,metadata:{app:'jm-quick',type:'delivery-confirmation',jobId:ref.id}});
      }
    }catch(_){outcome={outcome:dispatched?'unknown':'failed',errorCode:dispatched?'transport-exception':'transport-unavailable'};}
    return db.runTransaction(async tx=>{
      const d=(await tx.get(delivery)).data();
      // Late results from this claim may resolve a previously expired unknown.
      if(d.claimId!==claimId||!['sending','unknown'].includes(d.status))return {status:d.status};
      const status=['sent','failed','unknown'].includes(outcome?.outcome)?outcome.outcome:'unknown';
      tx.update(delivery,{status,claimId:null,leaseUntil:null,completedAt:serverTimestamp(),sentAt:status==='sent'?serverTimestamp():null,
        messageId:outcome?.messageId||null,errorCode:outcome?.errorCode||null});return {status};
    });
  }
  async function onCompleted({jobId,before,after}) {
    if(!after || after.status!=='completed' || before?.status==='completed' || !kindOf(after))return {skipped:true};
    const ref=await prepare(jobId,after);if(!ref)return {skipped:true};
    const ds=await ref.collection('deliveries').get();
    // At most ten small messages, isolated from the participant worker.
    const results=[];for(const d of ds.docs)results.push(await deliver(ref,d.id));
    return {reportId:ref.id,results};
  }
  async function owned(data,extra=[]) {
    request(data,['reportId',...extra]);if(!/^[a-f0-9]{64}$/.test(data.reportId||''))fail('invalid-report');
    const ref=reports(getDb()).doc(data.reportId),s=await ref.get();
    if(!s.exists||s.data().eventId!==data.eventId)throw new ApiError('permission-denied','このイベントの配信確認ではありません。');
    return {ref,report:s.data()};
  }
  function deliveryView(d) {
    const v=d.data();return {recipientKey:d.id,email:v.email,name:v.name,status:v.status==='sending'&&ms(v.leaseUntil)<=now()&&v.dispatchStartedAt?'unknown':v.status,
      attemptCount:v.attemptCount,startedAt:iso(v.startedAt),sentAt:iso(v.sentAt),completedAt:iso(v.completedAt),errorCode:v.errorCode||null};
  }
  async function getReport({data}) {
    const {ref,report:r}=await owned(data);const ds=await ref.collection('deliveries').get();
    return {reportId:ref.id,sourceJobId:r.sourceJobId,kind:r.kind,status:r.status,errorCode:r.errorCode,subject:r.message?.subject||'',html:r.message?.html||'',text:r.message?.text||'',
      qrPngBase64:r.message?.attachments?.[0]?.contentBase64||'',completedAt:iso(r.sourceCompletedAt),deliveries:ds.docs.map(deliveryView)};
  }
  async function retry({identity,data}) {
    const {ref}=await owned(data,['recipientKey','expectedAttempt']);
    if(!/^[a-f0-9]{64}$/.test(data.recipientKey||'')||!Number.isInteger(data.expectedAttempt))fail('invalid-retry');
    return deliver(ref,data.recipientKey,{retry:true,expectedAttempt:data.expectedAttempt,actor:identity.uid});
  }
  // Resume only pending/pre-dispatch interruptions, never failed/sent/unknown.
  async function resume({identity,data}) {
    const {ref}=await owned(data);const ds=await ref.collection('deliveries').get();const results=[];
    for(const d of ds.docs)results.push(await deliver(ref,d.id,{actor:identity.uid}));return {results};
  }
  return {settings,setPolicy,onCompleted,getReport,retry,resume};
}
module.exports={createDeliveryConfirmationApi,reportIdFor,kindOf,emailOf};
