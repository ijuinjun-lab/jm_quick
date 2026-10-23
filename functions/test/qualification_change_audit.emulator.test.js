const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const f = require('../confirmed/test_support/participation_fixture');

test('audit: stopped unrelated deliveries, existing recovery, and stale last-cancellation previews', {skip: skipReason(), timeout: 120000}, async () => {
  const env = await startAdminEmulator(); const {db, FieldValue, Timestamp} = env;
  const {createSendJobEngine} = require('../confirmed/send_jobs');
  const {createDeliveryWorker} = require('../confirmed/delivery_worker');
  const {createImportRecoveryApi} = require('../confirmed/import_recovery');
  const stamp = () => FieldValue.serverTimestamp();
  const api = createQualificationChangeApi({getDb:()=>db,serverTimestamp:stamp});
  const engine = createSendJobEngine({serverTimestamp:stamp});
  const worker = createDeliveryWorker({engine,serverTimestamp:stamp});
  const recovery = createImportRecoveryApi({getDb:()=>db,serverTimestamp:stamp});
  const eventId = 'auditChange', participantId = 'auditBatch-000002', other = 'otherBatch-000002';
  const input = {eventId,participantId}, identity = {uid:'manager'};
  const eventRef = db.collection('events').doc(eventId);
  const aRef = id => db.collection('programAttendances').doc(`${participantId}_${id}`);
  let serial = 0;
  async function req(programId='program-1') {
    const s = await api.get({data:input});
    return {...input,programId,fingerprint:s.fingerprint,operationId:`auditChangeOperation${++serial}`,reason:'架空の監査検証'};
  }
  const blocked = async () => {
    assert.equal((await api.get({data:input})).busy,true);
    await assert.rejects(api.change({identity,data:await req()}),e=>e.details.code==='operation-in-progress');
  };
  try {
    await eventRef.set(f.event({eventId,participationMapping:{catProgramId:'program-1',dogProgramId:'program-2',talkProgramId:'program-3'}}));
    const person = {...input,name:'架空監査参加者',email:'audit@example.invalid',schemaVersion:2,status:'active',publicId:'pub_123456789012345678901234',importBatchId:'auditBatch'};
    await db.collection('participants').doc(participantId).set(person);
    await db.collection('importBatches').doc('auditBatch').set({eventId,status:'committed'});
    for(const programId of ['program-1','program-3']) await aRef(programId).set({...input,programId,plannedCount:1,slotLabel:'10:10-10:50',checkedIn:false,importBatchId:'auditBatch'});
    const historical = db.collection('mailDeliveries').doc(`${participantId}_winner`);
    await historical.set({...input,status:'sent',messageId:'preserve-this'});
    const historyBefore = (await historical.get()).data();
    const jobId = 'winner-stoppedAudit', jobRef = db.collection('sendJobs').doc(jobId);
    await engine.openJob({db,identity,type:'winner',jobId,eventId,batchId:'stoppedAudit',targets:[other],excludedInactiveCount:0,snapshot:{template:{version:2}}});
    // A ready, stopped job has a fixed population. This participant is not in it.
    assert.equal((await api.get({data:input})).busy,false);
    const item = jobRef.collection('items').doc(other), delivery = db.collection('mailDeliveries').doc(`${other}_winner`);
    await item.update({status:'failed'}); await delivery.update({status:'failed'});
    await engine.refreshJob(db,jobId);
    assert.equal((await api.get({data:input})).busy,false);
    // Reuse existing recovery, without sending or resolving any unknown record.
    const retry = await engine.retryFailed({db,jobId}); assert.equal(retry.retried,1);
    assert.equal((await api.get({data:input})).busy,false);
    await worker.requestDelivery({db,identity,jobId});
    assert.equal((await api.get({data:input})).busy,false); // unrelated active worker
    await jobRef.update({dispatchActive:false}); // synthetic stopped worker fixture
    await jobRef.update({dispatchWorkerLeaseUntil:Timestamp.fromMillis(Date.now()+60000)}); assert.equal((await api.get({data:input})).busy,false);
    await jobRef.update({dispatchWorkerLeaseUntil:Timestamp.fromMillis(1),dispatchWorkerId:'stale-worker'}); assert.equal((await api.get({data:input})).busy,false);
    await jobRef.update({dispatchWorkerId:null});
    await item.update({status:'sending',leaseUntil:Timestamp.fromMillis(1)}); await delivery.update({status:'sending'}); assert.equal((await api.get({data:input})).busy,false);
    await item.update({status:'unknown'}); await delivery.update({status:'unknown'});
    await engine.refreshJob(db,jobId);
    await jobRef.update({dispatchWorkerId:'stale-terminal-worker'}); assert.equal((await api.get({data:input})).busy,false);
    await jobRef.update({dispatchWorkerId:null});
    assert.equal((await api.get({data:input})).busy,false);
    const stoppedBefore = (await jobRef.get()).data(), unknownBefore = (await delivery.get()).data();
    await jobRef.update({targetCount:2}); assert.equal((await api.get({data:input})).busy,false); await jobRef.update({targetCount:1});
    await jobRef.update({status:'preparing'}); await blocked();
    await jobRef.update({status:'failed'}); assert.equal((await api.get({data:input})).busy,false);
    await jobRef.update({status:'completed'});
    // Even with no active job, an unresolved delivery for THIS participant blocks.
    const unresolved = db.collection('mailDeliveries').doc('target-unknown');
    await unresolved.set({...input,status:'unknown'}); await blocked();
    await unresolved.delete(); // remove synthetic fixture only
    // Test mail persists a terminal unknown result only after transport returns.
    const testMail = db.collection('testMailDeliveries').doc('audit-test-mail');
    await testMail.set({eventId,status:'unknown'}); assert.equal((await api.get({data:input})).busy,false);
    await testMail.update({completedAt:stamp()});
    assert.equal((await api.get({data:input})).busy,false);
    const testMailBefore = (await testMail.get()).data();
    await testMail.update({status:'sending'}); assert.equal((await api.get({data:input})).busy,false); await testMail.update({status:'unknown'});
    // Failed imports remain unsafe until the EXISTING abandonment operation.
    const failedBatch = db.collection('importBatches').doc('failedAudit');
    await failedBatch.set({eventId,status:'failed',sequence:2,totalRecords:1,requestHash:'audit'});
    await eventRef.update({activeImportBatch:'failedAudit'}); await blocked();
    const recoverable = (await recovery.list({data:{eventId}})).batches.find(b=>b.batchId==='failedAudit');
    await recovery.abandon({identity,data:{eventId,batchId:'failedAudit',reason:'監査用の放棄',expectedFingerprint:recoverable.fingerprint}});
    assert.equal((await api.get({data:input})).busy,false);
    assert.equal((await failedBatch.get()).data().status,'abandoned');
    // Dialog originally shows two qualifications. Another confirmed cancellation
    // makes it the last one: the stale request must fail, not cancel without warning.
    const stale = await req('program-1');
    await api.change({identity,data:await req('program-3')});
    await assert.rejects(api.change({identity,data:stale}),e=>e.details.code==='state-changed');
    assert.equal((await aRef('program-1').get()).data().entitlementStatus,undefined);
    assert.equal((await api.get({data:input})).activeQualificationCount,1);
    const last = await req();
    const both = await Promise.all([api.change({identity,data:last}),api.change({identity,data:last})]);
    assert.equal(both.filter(x=>x.replay).length,1);
    assert.deepEqual((await db.collection('participants').doc(participantId).get()).data(),person);
    assert.deepEqual((await historical.get()).data(),historyBefore);
    assert.deepEqual((await delivery.get()).data(),unknownBefore);
    assert.deepEqual((await jobRef.get()).data(),stoppedBefore);
    assert.deepEqual((await testMail.get()).data(),testMailBefore);
    // Existing retries cannot convert or resend an unknown delivery.
    assert.equal((await engine.retryFailed({db,jobId})).retried,0);
    assert.equal((await delivery.get()).data().status,'unknown');
  } finally { env.stop(); }
});
