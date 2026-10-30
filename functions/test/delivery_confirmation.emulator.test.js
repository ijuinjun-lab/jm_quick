const assert = require('node:assert/strict');
const {test,before,after,beforeEach,describe} = require('node:test');
const {startAdminEmulator,skipReason} = require('../test_support/emulator_admin');
const {createDeliveryConfirmationApi,reportIdFor} = require('../confirmed/delivery_confirmation');
const {RENDERER_VERSION,evidenceFor,SENTINEL} = require('../confirmed/delivery_confirmation_render');
const {buildMailSnapshot} = require('../confirmed/mail_view_model');
const {renderWinnerMail} = require('../confirmed/mail_render');
const f = require('../confirmed/test_support/mail_fixtures');
const {confirmedCallable,confirmedEventCallable} = require('../auth');
const {EVENT_SCOPES} = require('../event_scope');
const {assignmentDocId} = require('../event_access');
const {readFileSync} = require('node:fs');
const {unsignedToken} = require('../test_support/rules_harness');

describe('delivery confirmations: isolated emulator and mocked transport', {skip:skipReason()},()=>{
 let emu,db,api,sends,behavior,clock;
 const admin={uid:'admin',systemAdmin:true};
 const recipient={email:'office@example.invalid',name:'事務局',enabled:true,kinds:['normal','waitlistPromotion','broadcast']};
 const createApi=()=>createDeliveryConfirmationApi({getDb:()=>db,serverTimestamp:()=>emu.FieldValue.serverTimestamp(),generateQrPng:f.fakeQrPng,now:()=>clock,
   getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{sends.push(m);return behavior(m);}})});
 const policy=async(enabled=true,recipients=[recipient])=>{const old=(await db.doc('deliveryConfirmationPolicies/event1').get()).data();return api.setPolicy({identity:admin,data:{eventId:'event1',enabled,recipients,expectedVersion:old?.version||0}});};
 async function seed(kind='normal',id='winner-fixture'){
   const p=(await db.doc('deliveryConfirmationPolicies/event1').get()).data();
   const snapshot=buildMailSnapshot('event1',f.makeEvent()).snapshot;
   if(kind==='broadcast')snapshot.broadcastOptions={includeDetails:true,includeQr:true};
   const job={eventId:'event1',type:kind==='broadcast'?'broadcast':'winner',notificationType:kind,status:'completed',snapshot,
     createdAt:new Date(p.activatedAt.toMillis()+1000),dispatchRequestedAt:new Date(clock-2000),completedAt:new Date(clock),
     batchSequence:kind==='broadcast'?null:3,targetCount:2,sentCount:1,failedCount:1,unknownCount:0};
   await db.doc('sendJobs/'+id).set(job);
   const rendered=await renderWinnerMail({snapshot,participant:f.participant(),attendances:f.attendances(),appBaseUrl:f.APP_BASE_URL,generateQrPng:f.fakeQrPng});
   await db.doc('sendJobs/'+id+'/items/person-secret').set({status:'sent',sentAt:new Date(clock-1000),confirmationEvidence:evidenceFor(rendered)});
   return {jobId:id,before:{status:'ready'},after:(await db.doc('sendJobs/'+id).get()).data()};
 }
 const report=async id=>api.getReport({data:{eventId:'event1',reportId:reportIdFor('event1',id)}});
 before(async()=>{emu=await startAdminEmulator();db=emu.db;});
 after(async()=>{await db.terminate();emu.stop();});
 beforeEach(async()=>{await emu.clear();clock=Date.now()+10000;sends=[];behavior=()=>({outcome:'sent',messageId:'mock'});api=createApi();await db.doc('events/event1').set(f.makeEvent());await policy();});
 for(const kind of ['normal','waitlistPromotion','broadcast'])test(`${kind}: one confirmation, safe sample, source untouched`,async()=>{
   const event=await seed(kind);const original=(await db.doc('sendJobs/'+event.jobId).get()).data();
   await db.doc('participants/person-secret').set({name:'秘密氏名',email:'private@example.invalid',publicId:'pub_PRIVATE_SECRET_00000000000'});
   await db.doc('programAttendances/private').set({plannedCount:7});
   const people=(await db.collection('participants').get()).docs.map(d=>d.data());
   await api.onCompleted(event);assert.equal(sends.length,1);
   const msg=sends[0], serialized=JSON.stringify(msg);
   for(const secret of ['秘密氏名','private@example.invalid','pub_PRIVATE_SECRET','person-secret',f.PUBLIC_ID,'confirmation-sample?','https://app.invalid'])assert(!serialized.includes(secret),secret);
   assert.match(msg.html,/個別参加者の情報は確認用サンプルです/);
   assert.match(msg.html,/aria-disabled="true"/);assert(!msg.html.includes('href='));
   assert(Buffer.from(msg.attachments[0].contentBase64,'base64').includes(Buffer.from(SENTINEL)));
   assert.deepEqual((await db.doc('sendJobs/'+event.jobId).get()).data(),original);
   assert.deepEqual((await db.collection('participants').get()).docs.map(d=>d.data()),people);
   assert.equal((await db.doc('programAttendances/private').get()).data().plannedCount,7);
   assert.equal((await db.collection('mailDeliveries').get()).size,0);
   const r=await report(event.jobId);assert.equal(r.deliveries[0].status,'sent');
   await api.onCompleted(event);await api.resume({identity:admin,data:{eventId:'event1',reportId:r.reportId}});assert.equal(sends.length,1);
 });
 test('real winner engine records evidence without changing outbound mail or participant totals',async()=>{
   const {createWinnerSendApi}=require('../confirmed/winner_send_api');
   const {composeWinnerMailFor,buildMailApiMessage}=require('../confirmed/winner_mail_message');
   const sourceMessages=[];
   const engineApi=createWinnerSendApi({getDb:()=>db,serverTimestamp:()=>emu.FieldValue.serverTimestamp(),generateQrPng:f.fakeQrPng,getAppBaseUrl:()=>f.APP_BASE_URL,
     getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{sourceMessages.push(m);return {outcome:'sent',messageId:'formal-mock'};}})});
   await db.doc('importBatches/enginebatch').set({eventId:'event1',status:'committed',sequence:1,createdCount:1});
   const person=f.participant({importBatchId:'enginebatch'});
   await db.doc('participants/'+person.participantId).set(person);
   for(const a of f.attendances())await db.doc('programAttendances/'+a.participantId+'_'+a.programId).set(a);
   await engineApi.createJob({identity:admin,data:{eventId:'event1',batchId:'enginebatch'}});
   const before=(await db.doc('sendJobs/winner-enginebatch').get()).data();
   const rendered=await composeWinnerMailFor({db,snapshot:before.snapshot,participantId:person.participantId,participant:person,appBaseUrl:f.APP_BASE_URL,generateQrPng:f.fakeQrPng});
   const expected=buildMailApiMessage({rendered,to:person.email,snapshot:before.snapshot,participantId:person.participantId,jobId:'winner-enginebatch'});
   await engineApi.processJob({data:{jobId:'winner-enginebatch'}});assert.deepEqual(sourceMessages,[expected]);
   const item=(await db.doc('sendJobs/winner-enginebatch/items/'+person.participantId).get()).data();assert.equal(item.confirmationEvidence.rendererVersion,RENDERER_VERSION);
   const after=(await db.doc('sendJobs/winner-enginebatch').get()).data();
   await api.onCompleted({jobId:'winner-enginebatch',before,after});assert.equal(sends.length,1);
   assert.equal(after.targetCount,1);assert.equal(after.sentCount,1);assert.equal((await db.collection('participants').get()).size,1);
   assert.deepEqual((await db.doc('participants/'+person.participantId).get()).data(),person);
 });
 test('zero success reports clearly identify the intended sample rather than claiming a sent copy',async()=>{
   const event=await seed();event.after.sentCount=0;event.after.failedCount=2;
   await db.doc('sendJobs/'+event.jobId+'/items/person-secret').update({status:'failed'});
   await api.onCompleted(event);assert.equal(sends.length,1);assert.match(sends[0].text,/送信成功0件/);
 });
 test('parallel completion events and a different job using same address',async()=>{
   const event=await seed();await Promise.all(Array.from({length:5},()=>api.onCompleted(event)));assert.equal(sends.length,1);
   await api.onCompleted(await seed('normal','winner-second'));assert.equal(sends.length,2);
 });
 test('disabled policies, recipients, kinds, default policy and old jobs do not send',async()=>{
   const event=await seed();await policy(false);await api.onCompleted(event);assert.equal(sends.length,0);
   await policy(true,[{...recipient,enabled:false}]);await api.onCompleted(await seed());assert.equal(sends.length,0);
   await policy(true,[{...recipient,kinds:['broadcast']}]);await api.onCompleted(await seed());assert.equal(sends.length,0);
   await policy();const old=await seed();old.after.createdAt=new Date(1);await api.onCompleted(old);assert.equal(sends.length,0);
   await db.doc('deliveryConfirmationPolicies/event1').delete();await api.onCompleted(old);assert.equal(sends.length,0);
   const settings=await api.settings({identity:admin,data:{eventId:'event1'}});assert.equal(settings.policy.enabled,false);
 });
 test('failed: explicit fenced retry; unknown and sent never retried',async()=>{
   const event=await seed();behavior=()=>({outcome:'failed',errorCode:'rejected'});await api.onCompleted(event);
   let r=await report(event.jobId);assert.equal(r.deliveries[0].status,'failed');await api.onCompleted(event);assert.equal(sends.length,1);
   behavior=()=>({outcome:'sent'});const data={eventId:'event1',reportId:r.reportId,recipientKey:r.deliveries[0].recipientKey,expectedAttempt:1};
   await Promise.all([api.retry({identity:admin,data}),api.retry({identity:admin,data})]);assert.equal(sends.length,2);
   await api.retry({identity:admin,data});assert.equal(sends.length,2);
   behavior=()=>({outcome:'unknown'});const other=await seed('normal','winner-unknown');await api.onCompleted(other);
   r=await report(other.jobId);await api.retry({identity:admin,data:{...data,reportId:r.reportId,recipientKey:r.deliveries[0].recipientKey}});assert.equal(sends.length,3);
   assert.equal((await db.doc('sendJobs/'+event.jobId).get()).data().sentCount,1);
 });
 test('failure retry rejected after policy disable; address changes cannot redirect a report',async()=>{
   const event=await seed();behavior=()=>({outcome:'failed'});await api.onCompleted(event);const r=await report(event.jobId);
   await policy(true,[{...recipient,email:'changed@example.invalid'}]);
   await api.retry({identity:admin,data:{eventId:'event1',reportId:r.reportId,recipientKey:r.deliveries[0].recipientKey,expectedAttempt:1}});assert.equal(sends.length,1);
 });
 test('expired pre-dispatch lease recovers; expired post-dispatch becomes unknown',async()=>{
   const event=await seed();behavior=()=>({outcome:'failed'});await api.onCompleted(event);let r=await report(event.jobId);
   const ref=db.doc(`deliveryConfirmationReports/${r.reportId}/deliveries/${r.deliveries[0].recipientKey}`);
   await ref.update({status:'sending',claimId:'crashed',leaseUntil:new Date(clock-1),dispatchStartedAt:null});behavior=()=>({outcome:'sent'});
   await api.resume({identity:admin,data:{eventId:'event1',reportId:r.reportId}});assert.equal(sends.length,2);
   await ref.update({status:'sending',claimId:'crashed',leaseUntil:new Date(clock-1),dispatchStartedAt:new Date(clock-1000)});
   await api.resume({identity:admin,data:{eventId:'event1',reportId:r.reportId}});assert.equal(sends.length,2);assert.equal((await ref.get()).data().status,'unknown');
 });
 test('crash after external send leaves an unknown result and never dispatches again',async()=>{
   const {failingDb}=require('../test_support/emulator_admin');
   const event=await seed();const original=(await db.doc('sendJobs/'+event.jobId).get()).data();
   const broken=failingDb(db,{failAtTransaction:4});
   const crashing=createDeliveryConfirmationApi({getDb:()=>broken,serverTimestamp:()=>emu.FieldValue.serverTimestamp(),generateQrPng:f.fakeQrPng,now:()=>clock,
     getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{sends.push(m);return {outcome:'sent'};}})});
   await assert.rejects(crashing.onCompleted(event),/injected failure/);assert.equal(sends.length,1);
   clock+=180001;await api.onCompleted(event);assert.equal(sends.length,1);
   assert.equal((await report(event.jobId)).deliveries[0].status,'unknown');
   assert.deepEqual((await db.doc('sendJobs/'+event.jobId).get()).data(),original);
 });
 test('disabling destination between claim and dispatch prevents the external send',async()=>{
   const event=await seed();
   const pausing=createDeliveryConfirmationApi({getDb:()=>db,serverTimestamp:()=>emu.FieldValue.serverTimestamp(),generateQrPng:f.fakeQrPng,now:()=>clock,
     getTransport:()=>({capabilities:async()=>{await policy(false);return {ok:true};},send:async m=>{sends.push(m);return {outcome:'sent'};}})});
   await pausing.onCompleted(event);assert.equal(sends.length,0);assert.equal((await report(event.jobId)).deliveries[0].status,'pending');
 });
 test('template changes do not alter frozen report; unavailable renderer fails closed',async()=>{
   const event=await seed();behavior=()=>({outcome:'failed'});await api.onCompleted(event);const first=sends[0].html;
   await db.doc('events/event1').update({'winnerMailTemplate.introBody':'変更後本文'});const r=await report(event.jobId);
   behavior=()=>({outcome:'sent'});await api.retry({identity:admin,data:{eventId:'event1',reportId:r.reportId,recipientKey:r.deliveries[0].recipientKey,expectedAttempt:1}});assert.equal(sends[1].html,first);
   const bad=await seed('normal','winner-old-renderer');await db.doc('sendJobs/winner-old-renderer/items/person-secret').update({'confirmationEvidence.rendererVersion':'old'});
   await api.onCompleted(bad);assert.equal(sends.length,2);assert.equal((await report(bad.jobId)).errorCode,'renderer-version-unavailable');
 });
 test('terminal retries do not overwrite completed report; unsupported kinds ignored',async()=>{
   const event=await seed();await api.onCompleted(event);const r=await report(event.jobId);
   await api.onCompleted({...event,after:{...event.after,sentCount:2,failedCount:0,completedAt:new Date(clock+1)}});
   assert.equal(sends.length,1);assert.match((await report(event.jobId)).text,/失敗件数：1/);
   assert.equal((await api.onCompleted({...event,after:{...event.after,type:'reminder'}})).skipped,true);
   await assert.rejects(api.getReport({data:{eventId:'other',reportId:r.reportId}}),e=>e.code==='permission-denied');
 });
 test('policy validation, stale edit, normalization and strict systemAdmin',async()=>{
   await assert.rejects(api.setPolicy({identity:{uid:'manager'},data:{eventId:'event1',enabled:true,recipients:[],expectedVersion:1}}),e=>e.code==='permission-denied');
   await assert.rejects(policy(true,[recipient,{...recipient,email:' OFFICE@example.invalid '}]),/配信確認/);
   await assert.rejects(api.setPolicy({identity:admin,data:{eventId:'event1',enabled:true,recipients:[],expectedVersion:0}}),/配信確認/);
 });
 test('real authorization wrappers: manager own event only; staff/anonymous denied; policy admin only',async()=>{
   await db.doc('accessRoles/admin').set({role:'admin',active:true});
   for(const [uid,ev,role] of [['manager','event1','event_manager'],['other','event2','event_manager'],['staff','event1','staff']])await db.doc('eventAssignments/'+assignmentDocId(ev,uid)).set({uid,eventId:ev,role,active:true});
   const wrap=handler=>confirmedEventCallable('eventManager',EVENT_SCOPES.dataEventId,handler,{db,logger:{warn(){}}}).run;
   const read=wrap(api.settings);
   assert.equal((await read({auth:{uid:'manager'},data:{eventId:'event1'}})).canManage,false);
   for(const uid of ['other','staff',null])await assert.rejects(read({...(uid?{auth:{uid}}:{}),data:{eventId:'event1'}}),e=>['permission-denied','unauthenticated'].includes(e.code));
   const write=confirmedCallable('systemAdmin',api.setPolicy,{db,logger:{warn(){}}}).run;
   await assert.rejects(write({auth:{uid:'manager'},data:{eventId:'event1',enabled:false,recipients:[],expectedVersion:1}}),e=>e.code==='permission-denied');
   for(const handler of [api.retry,api.resume,api.getReport])for(const uid of ['staff','other'])await assert.rejects(wrap(handler)({auth:{uid},data:{eventId:'event1',reportId:'a'.repeat(64)}}),e=>e.code==='permission-denied');
 });
 test('client direct access remains denied for policies, reports and deliveries, including admin',async()=>{
   await emu.emu.loadRules(readFileSync(require('node:path').join(__dirname,'../../firestore.rules'),'utf8'));
   for(const path of ['deliveryConfirmationPolicies/event1','deliveryConfirmationReports/report','deliveryConfirmationReports/report/deliveries/recipient']){
     await emu.emu.seed(path,{eventId:'event1'});
     for(const token of [undefined,unsignedToken('admin')]){
       assert.equal(await emu.emu.get(path,token),403);assert.equal(await emu.emu.update(path,{status:'sent'},token),403);
     }
   }
 });
});
