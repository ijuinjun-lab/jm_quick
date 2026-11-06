const assert=require('node:assert/strict');
const {test}=require('node:test');
const {readFileSync}=require('node:fs');
const {startAdminEmulator,skipReason}=require('../test_support/emulator_admin');
const {createDeliveryConfirmationApi}=require('../confirmed/delivery_confirmation');
const {RENDERER_VERSION}=require('../confirmed/delivery_confirmation_render');
const {buildMailSnapshot}=require('../confirmed/mail_view_model');
const {confirmedEventCallable}=require('../auth');
const {EVENT_SCOPES}=require('../event_scope');
const {assignmentDocId}=require('../event_access');
const f=require('../confirmed/test_support/mail_fixtures');
const proposal=require('../../docs/delivery-confirmation-policy-request.json');
const production=process.env.JM_PRODUCTION_CONFIG ? JSON.parse(readFileSync(process.env.JM_PRODUCTION_CONFIG,'utf8')) : null;

test('manual office notification acceptance with production configuration and isolated transport', {skip:skipReason(),timeout:180000},async t=>{
 const emu=await startAdminEmulator(),{db,FieldValue}=emu;
 const eventId='manualEvent',identity={uid:'manager'},admin={uid:'admin',systemAdmin:true};
 const event=f.makeEvent({...production?.event,eventId});
 if(!production)event.waitlistWinnerMailTemplate={...event.winnerMailTemplate};
 const messages=[];let outcome='sent';
 const api=createDeliveryConfirmationApi({getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),generateQrPng:f.fakeQrPng,
  getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{messages.push(m);return {outcome,messageId:'mock'};}})});
 const wrap=handler=>confirmedEventCallable('eventManager',EVENT_SCOPES.dataEventId,handler,{db,logger:{warn(){}}}).run;
 let sequence=0;
 async function seed(kind, historical=false) {
  const jobId=`winner-manual${++sequence}`,snapshot=buildMailSnapshot(eventId,event,{templateField:kind==='waitlistPromotion'?'waitlistWinnerMailTemplate':'winnerMailTemplate'}).snapshot;
  if(kind==='broadcast')snapshot.broadcastOptions={includeDetails:true,includeQr:true};
  const job={eventId,type:kind==='broadcast'?'broadcast':'winner',notificationType:kind,status:'completed',snapshot,
   targetCount:2,sentCount:1,failedCount:1,unknownCount:0,createdAt:new Date(historical?1:Date.now()+1000),completedAt:new Date(Date.now()+2000)};
  await db.doc(`sendJobs/${jobId}`).set(job);
  await db.doc(`sendJobs/${jobId}/items/synthetic`).set({status:'sent',attemptCount:1,confirmationEvidence:{rendererVersion:RENDERER_VERSION,programIds:snapshot.programs.map(p=>p.programId),attemptCount:1}});
  return {data:{eventId,jobId},after:(await db.doc(`sendJobs/${jobId}`).get()).data(),jobId,before:{status:'ready'}};
 }
 const preview=x=>api.previewManual({identity,data:x.data});
 const send=(x,p,extra={})=>api.sendManual({identity,data:{...x.data,fingerprint:p.fingerprint,...extra}});
 try {
  assert.equal(db.projectId,'demo-jm-quick');
  if(production){assert.equal(event.winnerMailTemplate.version,2);assert.equal(event.waitlistWinnerMailTemplate.version,2);assert.equal(event.confirmedMailSettings.talkTimeText,'13:00～14:00（開場12:00）');assert.deepEqual(proposal.recipients.slice(0,2),production.policy.recipients);}
  await db.doc(`events/${eventId}`).set(event);
  await db.doc(`deliveryConfirmationPolicies/${eventId}`).set({...production?.policy,eventId,enabled:false,version:1,activatedAt:null,recipients:proposal.recipients.slice(0,2)});
  await api.setPolicy({identity:admin,data:{...proposal,eventId}});
  for(const [uid,ev,role] of [['manager',eventId,'event_manager'],['staff',eventId,'staff'],['foreign','other','event_manager']])await db.doc('eventAssignments/'+assignmentDocId(ev,uid)).set({uid,eventId:ev,role,active:true});
  const protectedPaths=[`events/${eventId}`,'participants/protected','programAttendances/protected','mailDeliveries/protected'];
  for(const p of protectedPaths.slice(1))await db.doc(p).set({eventId,sentinel:'unchanged'});
  const originals=await Promise.all(protectedPaths.map(async p=>[p,(await db.doc(p).get()).data()]));
  for(const kind of ['normal','waitlistPromotion','broadcast'])await t.test(kind,async()=>{
   const x=await seed(kind,true),initialReports=(await db.collection('deliveryConfirmationReports').get()).size;
   const p=await wrap(api.previewManual)({auth:{uid:'manager'},data:x.data});
   assert.equal((await db.collection('deliveryConfirmationReports').get()).size,initialReports,'preview must not write');
   assert.equal(p.deliveries.length,5);assert.equal(p.counts.sentCount,1);assert(p.canSend);assert(p.subject&&p.text&&p.html);
   const before=messages.length;await api.onCompleted(x);assert.equal(messages.length,before,'no automatic historical dispatch');
   await Promise.allSettled([send(x,p),send(x,p)]);
   assert.equal(messages.length,before+5);assert.equal(new Set(messages.slice(before).map(m=>m.to)).size,5);
   assert.deepEqual(messages.slice(before).map(m=>m.to).sort(),proposal.recipients.map(r=>r.email).sort());
   for(const m of messages.slice(before)){assert.equal(m.subject,p.subject);assert.equal(m.text,p.text);assert.equal(m.html,p.html);}
   const done=await preview(x);assert(!done.canSend);assert(done.deliveries.every(d=>d.status==='sent'));
   await send(x,done);await api.onCompleted(x);assert.equal(messages.length,before+5);
   assert.deepEqual((await db.doc(`sendJobs/${x.jobId}`).get()).data(),x.after);
   for(const d of done.deliveries){const a=(await db.doc(`deliveryConfirmationReports/${done.reportId}/deliveries/${d.recipientKey}/attempts/1`).get()).data();assert.equal(a.status,'sent');assert.equal(a.requestedBy,'manager');}
   const auto=await seed(kind),autoStart=messages.length;await api.onCompleted(auto);
   const ap=await preview(auto);assert(!ap.canSend);await send(auto,ap);assert.equal(messages.length,autoStart+5);
  });
  await t.test('failed retry, unknown rejection, stale preview and role boundary',async()=>{
   const x=await seed('normal');outcome='failed';await send(x,await preview(x));
   const p=await preview(x),d=p.deliveries[0];assert.equal(d.status,'failed');
   outcome='sent';const before=messages.length;
   await Promise.allSettled([send(x,p,{recipientKey:d.recipientKey,expectedAttempt:d.attemptCount}),send(x,p,{recipientKey:d.recipientKey,expectedAttempt:d.attemptCount})]);
   assert.equal(messages.length,before+1);
   const after=await preview(x),unknown=after.deliveries.find(d=>d.status==='failed');outcome='unknown';
   await send(x,after,{recipientKey:unknown.recipientKey,expectedAttempt:unknown.attemptCount});
   const up=await preview(x),ud=up.deliveries.find(d=>d.status==='unknown'),count=messages.length;
   await assert.rejects(send(x,up,{recipientKey:ud.recipientKey,expectedAttempt:ud.attemptCount}),e=>e.details.code==='attempt-changed');
   await send(x,up);assert.equal(messages.length,count);
   const stale=await seed('normal'),sp=await preview(stale);
   const policy=(await db.doc(`deliveryConfirmationPolicies/${eventId}`).get()).data();
   await api.setPolicy({identity:admin,data:{...proposal,eventId,expectedVersion:policy.version}});
   await assert.rejects(send(stale,sp),e=>e.details.code==='preview-changed');
   for(const handler of [api.previewManual,api.sendManual])for(const uid of ['staff','foreign',null])await assert.rejects(wrap(handler)({...(uid?{auth:{uid}}:{}),data:stale.data}),e=>['permission-denied','unauthenticated'].includes(e.code));
   await assert.rejects(api.previewManual({data:{...stale.data,eventId:'other'}}),e=>e.code==='permission-denied');
   const missing=await seed('normal');await db.doc(`sendJobs/${missing.jobId}/items/synthetic`).delete();
   const mp=await preview(missing);assert(!mp.canSend);await assert.rejects(send(missing,mp),e=>e.details.code==='sample-unavailable');
  });
  await t.test('automatic/manual race and source/policy changes never bypass review',async()=>{
   outcome='sent';
   const x=await seed('normal'),p=await preview(x),before=messages.length;
   await Promise.allSettled([send(x,p),api.onCompleted(x)]);
   const final=await preview(x);await send(x,final);
   assert.equal(messages.length,before+5);
   assert.equal(new Set(messages.slice(before).map(m=>m.to)).size,5);
   const unfinished=await seed('normal');await db.doc(`sendJobs/${unfinished.jobId}`).update({status:'ready'});
   await assert.rejects(preview(unfinished),e=>e.details.code==='job-not-completed');
   const changed=await seed('normal'),cp=await preview(changed);
   const policy=(await db.doc(`deliveryConfirmationPolicies/${eventId}`).get()).data();
   await api.setPolicy({identity:admin,data:{...proposal,eventId,enabled:false,expectedVersion:policy.version}});
   const disabled=await preview(changed);assert(!disabled.canSend);assert.equal(disabled.errorCode,'notification-disabled');
   await assert.rejects(send(changed,cp),e=>e.details.code==='preview-changed');
   await assert.rejects(send(changed,disabled),e=>e.details.code==='notification-disabled');
   assert.equal(messages.length,before+5);
  });
  for(const [path,value] of originals)assert.deepEqual((await db.doc(path).get()).data(),value);
  console.log(production?'ACCEPTANCE: production event configuration and v2 templates used; mocked transport only':'ACCEPTANCE: synthetic fallback configuration');
 }finally{await db.terminate();emu.stop();}
});
