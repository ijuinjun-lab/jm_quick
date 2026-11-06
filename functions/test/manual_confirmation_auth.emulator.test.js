const assert=require('node:assert/strict');
const {test,mock}=require('node:test');
const {readFileSync}=require('node:fs');
const {startAdminEmulator,skipReason}=require('../test_support/emulator_admin');
const {createDeliveryConfirmationApi}=require('../confirmed/delivery_confirmation');
const {confirmedEventCallable}=require('../auth');
const {EVENT_SCOPES}=require('../event_scope');
const {assignmentDocId}=require('../event_access');

test('HTTP callable Auth + enforced App Check + event role with actual fifth-job snapshot',
 {skip:skipReason() || (!process.env.JM_AUTH_PREVIEW_FIXTURE && 'Set JM_AUTH_PREVIEW_FIXTURE to a read-only production snapshot'),timeout:120000},async()=>{
 const fixture=JSON.parse(readFileSync(process.env.JM_AUTH_PREVIEW_FIXTURE,'utf8'));
 const emu=await startAdminEmulator(),{db,FieldValue}=emu;
 const {initializeApp,deleteApp}=require('firebase-admin/app');
 const defaultApp=initializeApp({projectId:'demo-jm-quick'});
 const {getAuth}=require('firebase-admin/auth'),{getAppCheck}=require('firebase-admin/app-check');
 // Real callable HTTP verification gates; only external token verifiers are
 // replaced. No debug-token bypass and no real Auth/App Check credentials.
 const authMock=mock.method(getAuth(defaultApp),'verifyIdToken',async token=>{
  if(!['manager','staff','foreign'].includes(token))throw Error('invalid synthetic ID token');
  return {uid:token,sub:token};
 });
 const appMock=mock.method(getAppCheck(defaultApp),'verifyToken',async token=>{
  if(token!=='valid-app-token')throw Error('invalid synthetic App Check token');
  return {appId:'1:576531288403:web:b127cb70ae0f34a77811a6',token:{}};
 });
 const eventId=fixture.job.eventId,jobId=fixture.jobId;
 let sends=0,server;
 try {
  assert.equal(db.projectId,'demo-jm-quick');
  assert.equal(fixture.job.batchSequence,5);assert.equal(fixture.job.targetCount,29);assert.equal(fixture.job.sentCount,29);
  await db.doc('events/'+eventId).set(fixture.event);
  await db.doc('sendJobs/'+jobId).set(fixture.job);
  await db.doc('sendJobs/'+jobId+'/items/synthetic').set(fixture.item);
  await db.doc('deliveryConfirmationPolicies/'+eventId).set(fixture.policy);
  for(const [uid,id,role] of [['manager',eventId,'event_manager'],['staff',eventId,'staff'],['foreign','other','event_manager']])
   await db.doc('eventAssignments/'+assignmentDocId(id,uid)).set({uid,eventId:id,role,active:true});
  const api=createDeliveryConfirmationApi({getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),generateQrPng:async()=>Buffer.from('synthetic'),getTransport:()=>{sends++;throw Error('Mail forbidden');}});
  const handler=confirmedEventCallable('eventManager',EVENT_SCOPES.dataEventId,api.previewManual,{db,enforceAppCheck:true,logger:{warn(){}}});
  const express=require('express'),app=express();app.use(express.json());app.post('/previewManualDeliveryConfirmation',handler);
  server=await new Promise(resolve=>{const s=app.listen(0,'127.0.0.1',()=>resolve(s));});
  const call=async(auth,check)=>{
   const r=await fetch(`http://127.0.0.1:${server.address().port}/previewManualDeliveryConfirmation`,{method:'POST',headers:{'Content-Type':'application/json',...(auth?{Authorization:'Bearer '+auth}:{}),...(check?{'X-Firebase-AppCheck':check}:{})},body:JSON.stringify({data:{eventId,jobId}})});
   return {status:r.status,body:await r.json()};
  };
  for(const [auth,check,status,code] of [[null,'valid-app-token',401,'UNAUTHENTICATED'],['invalid','valid-app-token',401,'UNAUTHENTICATED'],['manager',null,401,'UNAUTHENTICATED'],['manager','invalid',401,'UNAUTHENTICATED'],['staff','valid-app-token',403,'PERMISSION_DENIED'],['foreign','valid-app-token',403,'PERMISSION_DENIED']]){
   const r=await call(auth,check);assert.equal(r.status,status);assert.equal(r.body.error.status,code);
  }
  const ok=await call('manager','valid-app-token');assert.equal(ok.status,200,JSON.stringify(ok.body));
  const result=ok.body.result;assert.equal(result.deliveries.length,5);assert.equal(result.counts.sentCount,29);assert(result.subject&&result.text&&result.html);assert.equal(result.canSend,true);
  assert(authMock.mock.callCount()>0);assert(appMock.mock.callCount()>0);
  assert.equal(sends,0);assert.equal((await db.collection('deliveryConfirmationReports').get()).size,0);
  assert.deepEqual((await db.doc('sendJobs/'+jobId).get()).data(),fixture.job);
  assert.deepEqual((await db.doc('sendJobs/'+jobId+'/items/synthetic').get()).data(),fixture.item);
  console.log('PASS actual fifth job: 29 sent, five office recipients; HTTP preview 200; no writes or mail');
 } finally {
  if(server)await new Promise(r=>server.close(r));mock.restoreAll();await deleteApp(defaultApp);await db.terminate();emu.stop();
 }
});
