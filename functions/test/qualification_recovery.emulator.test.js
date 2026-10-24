const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator,skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createQualificationNoticeApi} = require('../confirmed/qualification_notice_api');
const {createSendJobEngine} = require('../confirmed/send_jobs');
const {createDeliveryWorker} = require('../confirmed/delivery_worker');
const {createPassApi} = require('../confirmed/pass_api');
const f = require('../confirmed/test_support/participation_fixture');
const deferred = () => {let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};

async function fixture() {
  const env=await startAdminEmulator(), {db,FieldValue,Timestamp}=env;
  let time=Date.now();
  const input={eventId:'recoveryEvent',participantId:'recoveryBatch-000002'}, identity={uid:'manager'};
  const deps={getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),now:()=>time,
    getAppBaseUrl:()=> 'https://example.invalid',generateQrPng:async p=>Buffer.from(p)};
  const api=createQualificationChangeApi(deps), pass=createPassApi(deps);
  await db.collection('events').doc(input.eventId).set(f.event({eventId:input.eventId}));
  const person={...input,name:'架空復旧参加者',email:'only@example.invalid',publicId:'pub_123456789012345678901234',schemaVersion:2,status:'active',importBatchId:'recoveryBatch'};
  await db.collection('participants').doc(input.participantId).set(person);
  await db.collection('importBatches').doc('recoveryBatch').set({eventId:input.eventId,status:'committed'});
  for (const programId of ['program-1','program-3']) await db.collection('programAttendances').doc(`${input.participantId}_${programId}`).set({...input,programId,slotLabel:'10:00-11:00',plannedCount:2,importBatchId:'recoveryBatch',checkedIn:false});
  const historical=db.collection('mailDeliveries').doc('first-round');
  await historical.set({...input,status:'sent',messageId:'unchanged',sentAt:Timestamp.fromMillis(time-1000)});
  const before=(await historical.get()).data(), oldPass=await pass.getPass({data:{participantId:input.participantId,publicId:person.publicId}});
  let n=0;
  async function change() {
    const d={...input,operationId:`recoveryOperation${String(++n).padStart(8,'0')}`,programId:'program-1',action:'edit',slotLabel:'10:00-11:00',plannedCount:n+2,reason:'本人希望',fingerprint:(await api.get({data:input})).fingerprint};
    await api.change({identity,data:d});return {...input,operationId:d.operationId};
  }
  async function preserved() {
    assert.deepEqual((await historical.get()).data(),before);
    assert.deepEqual((await db.collection('participants').doc(input.participantId).get()).data(),person);
    const p=await pass.getPass({data:{participantId:input.participantId,publicId:person.publicId}});
    assert.equal(p.qrPayload,oldPass.qrPayload);assert.equal(p.webPassUrl,oldPass.webPassUrl);
  }
  return {env,db,Timestamp,input,identity,deps,api,change,preserved,advance:ms=>time+=ms,now:()=>time};
}

test('actual engine: interrupted dispatch recovery uses stored items and fences delayed completion', {skip:skipReason(),timeout:120000},async()=>{
  const f=await fixture();const {db,Timestamp,input,identity}=f;
  const gate=deferred(), reached=deferred();let running, calls=0;
  try {
    // Deterministic clock for actual engine/worker writes, including timestamps.
    const deps={...f.deps,serverTimestamp:()=>Timestamp.fromMillis(f.now())};
    const api=createQualificationChangeApi(deps);
    const engine=createSendJobEngine({...deps,concurrency:1,
      composeMail:async()=>({ok:true}),buildMessage:({to})=>({to})});
    const worker=createDeliveryWorker({...deps,engine});
    const other='zzOther-000002', jobId='winner-recoveryBatch';
    await db.collection('participants').doc(other).set({...input,participantId:other,status:'active',email:'other@example.invalid'});
    await engine.openJob({db,identity,type:'winner',jobId,eventId:input.eventId,
      targets:[input.participantId,other],excludedInactiveCount:0,snapshot:{template:{version:2}}});
    const job=db.collection('sendJobs').doc(jobId), delivery=db.collection('mailDeliveries').doc(`${input.participantId}_winner`);
    const item=job.collection('items').doc(input.participantId);
    const review={...input,kind:'mailDeliveries',deliveryId:delivery.id,reason:'ジョブ終了・配送結果不明を確認。再送しない'};
    const blocked=async()=>assert.rejects(api.reviewDelivery({identity,data:review}),e=>e.details.code==='delivery-still-active');
    const transport={capabilities:async()=>({ok:true}),send:async message=>{
      calls++;
      if(message.to==='only@example.invalid'){reached.resolve();await gate.promise;return {outcome:'sent',messageId:'late-result'};}
      return {outcome:'failed',errorCode:'mock-rejected'};
    }};
    await worker.requestDelivery({db,identity,jobId});
    running=worker.runJob({db,jobId,getTransport:()=>transport});await reached.promise;
    await blocked(); // actual live invocation, lease and sending item
    const claimId=(await delivery.get()).data().claimId;assert.ok(claimId);
    f.advance(130000);
    // Another engine invocation discovers the expired dispatch, retaining claimId.
    await engine.processJob({db,jobId,limit:1,transport});
    let unknown=(await delivery.get()).data();
    assert.equal(unknown.status,'unknown');assert.equal(unknown.claimId,claimId);
    assert.equal(unknown.lastErrorCode,'lease-expired-after-dispatch');assert.equal(calls,1);
    await blocked(); // original invocation bound and job worker are still live
    assert.equal((await worker.runJob({db,jobId,getTransport:()=>transport})).skipped,'worker-active');
    f.advance(270000);
    assert.equal((await worker.runJob({db,jobId,getTransport:()=>transport})).finished,true);
    const completed=(await job.get()).data();
    assert.equal(completed.status,'completed');assert.equal(completed.dispatchActive,false);
    assert.equal(Object.hasOwn(completed,'pendingCount'),false);
    assert.equal(Object.hasOwn(completed,'sendingCount'),false);
    assert.equal((await api.get({data:input})).deliveries.find(x=>x.id===delivery.id).recoverable,true);
    f.advance(-50000);await blocked();f.advance(50000); // original invocation bound, independently of job completion

    // Real retry/claim transitions in a different participant's item. Even a
    // stale completed job summary cannot authorize recovery over these items.
    await engine.retryFailed({db,jobId});
    await job.update({status:'completed'});
    assert.equal((await job.collection('items').doc(other).get()).data().status,'pending');await blocked();
    const otherClaim=await engine.claimItem({db,jobId,participantId:other});assert.equal(otherClaim.claimed,true);
    assert.equal((await job.collection('items').doc(other).get()).data().status,'sending');await blocked();
    await engine.finishItem({db,jobId,participantId:other,claimId:otherClaim.claimId,outcome:'failed',errorCode:'mock-rejected'});
    await engine.refreshJob(db,jobId);
    await job.update({dispatchActive:true});await blocked();await job.update({dispatchActive:false});
    await job.update({dispatchWorkerId:'running',dispatchWorkerLeaseUntil:Timestamp.fromMillis(f.now()+1000)});await blocked();
    await job.update({dispatchWorkerId:null,dispatchWorkerLeaseUntil:null});
    await job.update({dispatchFinishedAt:Timestamp.fromMillis(unknown.updatedAt.toMillis()-1)});await blocked();
    await job.update({dispatchFinishedAt:completed.dispatchFinishedAt});
    const jobBefore=(await job.get()).data(), itemBefore=(await item.get()).data();
    const state=await api.get({data:input}), row=state.deliveries.find(x=>x.id===delivery.id);
    assert.equal(state.busy,true);assert.equal(row.recoverable,true);
    await assert.rejects(api.reviewDelivery({identity,data:{...review,fingerprint:'stale'}}),e=>e.details.code==='delivery-state-changed');
    await api.reviewDelivery({identity,data:{...review,fingerprint:row.fingerprint}});
    assert.equal((await api.get({data:input})).busy,false);
    // Only the execution fence changes. Unknown evidence and job/item history remain.
    assert.deepEqual((await delivery.get()).data(),{...unknown,claimId:null});
    assert.deepEqual((await job.get()).data(),jobBefore);assert.deepEqual((await item.get()).data(),itemBefore);
    const r=db.collection('participants').doc(input.participantId).collection('deliveryReviews').doc(delivery.id);
    const audit=(await r.get()).data();
    assert.equal(audit.reason,review.reason);assert.equal(audit.claimId,claimId);
    assert.equal(audit.reviewedBy,identity.uid);assert.equal(audit.previousStatus,'unknown');assert.ok(audit.reviewedAt);
    assert.deepEqual((await r.collection('history').get()).docs.map(x=>x.data()),[audit]);
    await f.change();await f.preserved();
    // Resume the suspended real worker after recovery: its late success cannot
    // replace unknown or invalidate the review, and no transport is called again.
    gate.resolve();await running;
    assert.deepEqual((await delivery.get()).data(),{...unknown,claimId:null});
    assert.deepEqual((await item.get()).data(),itemBefore);
    await worker.sweep({db,getTransport:()=>transport});
    await engine.processJob({db,jobId,limit:20,transport});
    assert.equal(calls,2);assert.equal((await api.get({data:input})).busy,false);
    await f.preserved();
  } finally {gate.resolve();if(running) await running;f.env.stop();}
});

test('interrupted notices: live lease, pre-dispatch fencing, unknown preservation and late result fencing', {skip:skipReason(),timeout:120000},async()=>{
  const f=await fixture();const {db,input,identity,api}=f;
  let calls=0, lastGate, lastRunning;
  try {
    for(const stage of ['before-dispatch','after-dispatch']) {
      const request=await f.change(), gate=deferred(), reached=deferred();lastGate=gate;
      const notice=createQualificationNoticeApi({...f.deps,heartbeatMs:3600000,
        generateQrPng:async p=>{if(stage==='before-dispatch'){reached.resolve();await gate.promise;}return Buffer.from(p);},
        getTransport:()=>({capabilities:async()=>({ok:true}),send:async()=>{calls++;reached.resolve();await gate.promise;return {outcome:'sent'};}})});
      const preview=await notice.preview({data:request}), send={...request,fingerprint:preview.fingerprint,expectedAttempt:preview.expectedAttempt};
      const running=notice.send({identity,data:send});lastRunning=running;await reached.promise;
      let row=(await api.get({data:input})).deliveries.find(x=>x.operationId===request.operationId);
      const review={...input,kind:'qualificationNotices',deliveryId:row.id,reason:'実行期限・失効を確認し、結果不明のまま復旧'};
      assert.equal(row.recoverable,false);await assert.rejects(api.reviewDelivery({identity,data:review}));
      // Simulated process death: no heartbeat, invocation and lease expire.
      f.advance(240000);
      row=(await api.get({data:input})).deliveries.find(x=>x.id===row.id);assert.equal(row.recoverable,true);
      await api.reviewDelivery({identity,data:{...review,fingerprint:row.fingerprint}});
      assert.equal((await api.get({data:input})).busy,false);
      gate.resolve();assert.equal((await running).status,'unknown');
      const ref=db.collection('qualificationNotices').doc(row.id), record=(await ref.get()).data();
      assert.equal(record.status,'unknown');assert.equal(record.recoveryReason,review.reason);
      assert.equal((await ref.collection('attempts').doc('1').get()).data().status,'unknown');
      assert.equal((await notice.send({identity,data:{...send,retry:true,expectedAttempt:1}})).status,'unknown');
      assert.equal((await ref.collection('attempts').get()).size,1);
    }
    assert.equal(calls,1);await f.preserved();
    // Pre-fix sending record: use the legacy invocation bound, retain evidence.
    const legacy=db.collection('qualificationNotices').doc('legacy-stopped');
    await legacy.set({...input,status:'sending',startedAt:f.Timestamp.fromMillis(f.now()-180001)});
    await api.reviewDelivery({identity,data:{...input,kind:'qualificationNotices',deliveryId:legacy.id,reason:'旧処理の終了期限を確認'}});
    assert.equal((await legacy.get()).data().status,'unknown');
  } finally {lastGate?.resolve();if(lastRunning) await lastRunning;f.env.stop();}
});

test('manual retry only after definite failure: expected attempt fences double clicks and preserves every attempt', {skip:skipReason(),timeout:120000},async()=>{
  const f=await fixture();const {db,identity,input,api}=f;
  let calls=0,outcome='failed';
  try {
    const notice=createQualificationNoticeApi({...f.deps,getTransport:()=>({capabilities:async()=>({ok:true}),send:async()=>{calls++;return {outcome};}})});
    const request=await f.change();let preview=await notice.preview({data:request});
    const first={...request,fingerprint:preview.fingerprint,expectedAttempt:0};
    await Promise.all(Array.from({length:8},()=>notice.send({identity,data:first})));
    assert.equal(calls,1);
    // Pre-fix failure: preserve the original record as attempt 1 on retry.
    const legacyRef=(await db.collection('qualificationNotices').get()).docs[0].ref;
    await legacyRef.collection('attempts').doc('1').delete();
    const remove=f.env.FieldValue.delete();
    await legacyRef.update({attemptCount:remove,claimId:remove,leaseUntil:remove,retryOf:remove});
    const legacyFailure=(await legacyRef.get()).data();
    assert.equal((await notice.send({identity,data:first})).status,'failed');assert.equal(calls,1);
    preview=await notice.preview({data:request});assert.equal(preview.canRetry,true);assert.equal(preview.expectedAttempt,1);
    const retry={...request,fingerprint:preview.fingerprint,retry:true,expectedAttempt:1};
    await Promise.all(Array.from({length:8},()=>notice.send({identity:{uid:'retry-manager'},data:retry})));
    assert.equal(calls,2); // even an immediately failed retry is not retried by the other clicks
    outcome='sent';preview=await notice.preview({data:request});
    await Promise.all(Array.from({length:8},()=>notice.send({identity,data:{...retry,expectedAttempt:preview.expectedAttempt}})));
    assert.equal(calls,3);
    assert.equal((await notice.send({identity,data:{...retry,expectedAttempt:3}})).status,'sent');assert.equal(calls,3);
    const row=(await api.get({data:input})).deliveries.find(x=>x.operationId===request.operationId), ref=db.collection('qualificationNotices').doc(row.id);
    const attempts=(await ref.collection('attempts').get()).docs.map(d=>d.data());
    assert.deepEqual(attempts[0],legacyFailure);assert.deepEqual(attempts.map(x=>x.status),['failed','failed','sent']);assert.equal(attempts[1].createdBy,'retry-manager');assert.equal(attempts[1].retryOf,1);assert.equal(row.attemptCount,3);
    assert.equal((await notice.preview({data:request})).canRetry,false);
    const unknownRequest=await f.change();outcome='unknown';preview=await notice.preview({data:unknownRequest});
    const u={...unknownRequest,fingerprint:preview.fingerprint};await notice.send({identity,data:u});
    await Promise.all(Array.from({length:8},()=>notice.send({identity,data:{...u,retry:true,expectedAttempt:1}})));
    assert.equal(calls,4);assert.equal((await notice.preview({data:unknownRequest})).canRetry,false);
    await f.preserved();
  } finally {f.env.stop();}
});

test('a running notice renews its lease; recovery remains forbidden beyond its initial lease window', {skip:skipReason(),timeout:120000},async()=>{
  const f=await fixture();const {db,api,input,identity}=f, gate=deferred(), reached=deferred();let running;
  try {
    const notice=createQualificationNoticeApi({...f.deps,heartbeatMs:10,getTransport:()=>({capabilities:async()=>({ok:true}),send:async()=>{reached.resolve();await gate.promise;return {outcome:'failed'};}})});
    const r=await f.change(), p=await notice.preview({data:r});running=notice.send({identity,data:{...r,fingerprint:p.fingerprint}});await reached.promise;
    const row=(await api.get({data:input})).deliveries.find(x=>x.operationId===r.operationId), ref=db.collection('qualificationNotices').doc(row.id);
    const initial=(await ref.get()).data().leaseUntil.toMillis();f.advance(60000);
    for(let i=0;i<100 && (await ref.get()).data().leaseUntil.toMillis()<=initial;i++) await new Promise(r=>setTimeout(r,10));
    assert.ok((await ref.get()).data().leaseUntil.toMillis()>initial);
    f.advance(121000);
    await assert.rejects(api.reviewDelivery({identity,data:{...input,kind:'qualificationNotices',deliveryId:row.id,reason:'稼働中は不可'}}),e=>e.details.code==='delivery-still-active');
    gate.resolve();assert.equal((await running).status,'failed');await f.preserved();
  } finally {gate.resolve();if(running) await running;f.env.stop();}
});
