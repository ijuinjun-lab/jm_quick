const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createQualificationNoticeApi} = require('../confirmed/qualification_notice_api');
const {createPassApi} = require('../confirmed/pass_api');
const {collectBroadcastRecipients} = require('../confirmed/broadcast_message');
const {createAttendanceReportApi} = require('../confirmed/attendance_report_api');
const {loadIndex} = require('../test_support/load_index');
const {assignmentDocId} = require('../event_access');
const f = require('../confirmed/test_support/participation_fixture');

test('details/addition and manual change notice: atomicity, current values, recovery, immutable identities/history', {skip:skipReason(),timeout:120000}, async () => {
  const env = await startAdminEmulator(); const {db,FieldValue} = env;
  const eventId='detailsEvent', participantId='detailsBatch-000002', input={eventId,participantId}, identity={uid:'manager'};
  let outcome='sent', calls=0, release;
  const sent=[];
  const deps={getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),getAppBaseUrl:()=> 'https://example.invalid',
    generateQrPng:async payload => Buffer.from(payload),getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{calls++;sent.push(m);if(release) await release; return {outcome,messageId:'mock-id'};}})};
  const api=createQualificationChangeApi(deps), notice=createQualificationNoticeApi(deps), pass=createPassApi(deps);
  const a=id=>db.collection('programAttendances').doc(`${participantId}_${id}`);
  let sequence=0;
  async function req(action,programId,extra={}) {const s=await api.get({data:input});return {...input,action,programId,operationId:`detailsOperation${String(++sequence).padStart(8,'0')}`,fingerprint:s.fingerprint,reason:'本人希望',...extra};}
  async function change(action,programId,extra) {const d=await req(action,programId,extra);await api.change({identity,data:d});return d;}
  const event=f.event({eventId,participationMapping:{catProgramId:'program-1',dogProgramId:'program-2',talkProgramId:'program-3'}});
  event.programs=event.programs.map(p=>({...p,qualificationSlots:['10:00-11:00','11:00-12:00']}));
  event.winnerMailTemplate.version=2; event.waitlistWinnerMailTemplate={...event.winnerMailTemplate};
  const person={...input,name:'架空参加者',email:'only@example.invalid',schemaVersion:2,status:'active',publicId:'pub_123456789012345678901234',importBatchId:'detailsBatch'};
  try {
    await db.collection('events').doc(eventId).set(event);
    await db.collection('participants').doc(participantId).set(person);
    await db.collection('importBatches').doc('detailsBatch').set({eventId,status:'committed'});
    await a('program-1').set({...input,programId:'program-1',plannedCount:1,slotLabel:'10:00-11:00',checkedIn:false,importBatchId:'detailsBatch'});
    const history=db.collection('mailDeliveries').doc(`${participantId}_winner`);
    await history.set({...input,status:'sent',messageId:'first-delivery',sentAt:FieldValue.serverTimestamp()});
    const oldHistory=(await history.get()).data(), oldPass=await pass.getPass({data:{participantId,publicId:person.publicId}});
    let last=await change('edit','program-1',{slotLabel:'11:00-12:00',plannedCount:1}); // time only
    last=await change('edit','program-1',{slotLabel:'11:00-12:00',plannedCount:4}); // count only
    last=await change('edit','program-1',{slotLabel:'10:00-11:00',plannedCount:2}); // both
    const original=(await a('program-1').get()).data();
    await assert.rejects(api.change({identity,data:await req('edit','program-1',{slotLabel:'99:00-99:30',plannedCount:2})}));
    assert.deepEqual((await a('program-1').get()).data(),original);
    // Fail after queuing writes inside the real transaction: nothing commits.
    const brokenDb=new Proxy(db,{get(t,k){if(k==='runTransaction') return fn=>t.runTransaction(async tx=>{await fn(tx);throw Error('injected before commit');});const v=t[k];return typeof v==='function'?v.bind(t):v;}});
    await assert.rejects(createQualificationChangeApi({...deps,getDb:()=>brokenDb}).change({identity,data:await req('add','program-2',{slotLabel:'10:00-11:00',plannedCount:3})}),/injected/);
    assert.equal((await a('program-2').get()).exists,false);
    last=await change('add','program-2',{slotLabel:'10:00-11:00',plannedCount:3});
    await change('cancel','program-1'); // dog+cat -> dog
    last=await change('add','program-3',{slotLabel:'11:00-12:00',plannedCount:2});
    assert.deepEqual((await pass.getPass({data:{participantId,publicId:person.publicId}})).programs.map(p=>p.programId).sort(),['program-2','program-3']);
    const request={...input,operationId:last.operationId};
    const preview=await notice.preview({data:request});
    assert.equal(preview.to,person.email);assert.match(preview.text,/変更前/);assert.match(preview.text,/変更後/);assert.match(preview.text,/3名/);
    assert.equal(preview.qrPayload,oldPass.qrPayload);assert.equal(preview.webPassUrl,oldPass.webPassUrl);assert.equal(calls,0);
    const sendRequest={...request,fingerprint:preview.fingerprint};
    let done;release=new Promise(r=>done=r);
    const sending=notice.send({identity,data:sendRequest});
    while(calls===0) await new Promise(r=>setTimeout(r,10));
    assert.equal((await api.get({data:input})).busy,true);
    await assert.rejects(api.change({identity,data:await req('cancel','program-2')}),e=>e.details.code==='operation-in-progress');
    assert.equal((await notice.send({identity,data:sendRequest})).status,'sending');
    done();await sending;release=null;
    assert.equal((await notice.send({identity,data:sendRequest})).status,'sent');assert.equal(calls,1);
    assert.equal(sent[0].to,person.email);assert.equal(Buffer.from(sent[0].attachments[0].contentBase64,'base64').toString(),oldPass.qrPayload);
    // unknown remains unknown and cannot be automatically or manually resent.
    last=await change('edit','program-2',{slotLabel:'11:00-12:00',plannedCount:5});outcome='unknown';
    const r={...input,operationId:last.operationId};r.fingerprint=(await notice.preview({data:r})).fingerprint;
    assert.equal((await notice.send({identity,data:r})).status,'unknown');
    assert.equal((await notice.send({identity,data:r})).status,'unknown');assert.equal(calls,2);
    const state=await api.get({data:input}), unknown=state.deliveries.find(x=>x.status==='unknown');
    assert.equal(state.busy,true);assert.equal(unknown.recoverable,true);
    await api.reviewDelivery({identity,data:{...input,kind:unknown.kind,deliveryId:unknown.id,reason:'配送処理終了、再送せず内容を更新する'}});
    assert.equal((await api.get({data:input})).busy,false);
    assert.equal((await db.collection(unknown.kind).doc(unknown.id).get()).data().status,'unknown');
    last=await change('edit','program-2',{slotLabel:'10:00-11:00',plannedCount:6});outcome='failed';
    const failed={...input,operationId:last.operationId};failed.fingerprint=(await notice.preview({data:failed})).fingerprint;
    assert.equal((await notice.send({identity,data:failed})).status,'failed');assert.equal(calls,3);
    assert.equal((await api.get({data:input})).busy,false);
    const activeDelivery=db.collection('mailDeliveries').doc('active-own');
    await activeDelivery.set({...input,jobId:'review-job',status:'unknown',claimId:'live-worker'});
    const reviewJob=db.collection('sendJobs').doc('review-job');
    await reviewJob.set({eventId,status:'completed',targetCount:1});
    await reviewJob.collection('items').doc(participantId).set({participantId,status:'unknown'});
    await assert.rejects(api.reviewDelivery({identity,data:{...input,kind:'mailDeliveries',deliveryId:activeDelivery.id,reason:'解除不可'}}),e=>e.details.code==='delivery-still-active');
    await activeDelivery.update({claimId:null});
    await api.reviewDelivery({identity,data:{...input,kind:'mailDeliveries',deliveryId:activeDelivery.id,reason:'終了済み'}});
    assert.equal((await api.get({data:input})).busy,false);
    // Timestamp-backed current time is displayed and preserved on count-only edit.
    const startAt=env.Timestamp.fromDate(new Date('2026-10-24T01:00:00Z'));
    const endAt=env.Timestamp.fromDate(new Date('2026-10-24T02:00:00Z'));
    await a('program-3').update({slotLabel:'',startAt,endAt});
    const currentTalk=(await api.get({data:input})).qualifications.find(x=>x.programId==='program-3');
    assert.equal(currentTalk.timeText,'10:00〜11:00');
    await change('edit','program-3',{slotLabel:currentTalk.timeText,plannedCount:4});
    assert.deepEqual((await a('program-3').get()).data().startAt,startAt);
    assert.deepEqual((await a('program-3').get()).data().endAt,endAt);
    await assert.rejects(api.change({identity,data:await req('edit','program-3',{slotLabel:currentTalk.timeText,plannedCount:4})}),e=>e.details.code==='no-change');
    const report=await createAttendanceReportApi({getDb:()=>db}).getReport({data:{eventId}});
    assert.equal(report.participants[0].programs.find(x=>x.programId==='program-2').plannedCount,6);
    const broadcast=await collectBroadcastRecipients(db,eventId,event);
    assert.equal(broadcast.recipients[0].programs.find(x=>x.programId==='program-2').plannedCount,6);
    assert.deepEqual((await history.get()).data(),oldHistory);
    assert.deepEqual((await db.collection('participants').doc(participantId).get()).data(),person);
    assert.deepEqual((await db.collection('events').doc(eventId).get()).data().winnerMailTemplate,event.winnerMailTemplate);
    assert.deepEqual((await db.collection('events').doc(eventId).get()).data().waitlistWinnerMailTemplate,event.waitlistWinnerMailTemplate);
    assert.equal((await db.collection('sendJobs').get()).size,1); // only the synthetic review fixture; notices never create jobs
    assert.deepEqual((await reviewJob.get()).data(),{eventId,status:'completed',targetCount:1});
    const index=loadIndex(db,{FieldValue});
    await db.collection('eventAssignments').doc(assignmentDocId(eventId,'staff')).set({eventId,uid:'staff',role:'staff',active:true});
    for(const name of ['previewConfirmedQualificationNotice','sendConfirmedQualificationNotice','reviewConfirmedQualificationDelivery']) {
      await assert.rejects(index[name].run({data:request}),e=>e.code==='unauthenticated');
      await assert.rejects(index[name].run({auth:{uid:'staff'},data:request}),e=>e.code==='permission-denied');
    }
  } finally {env.stop();}
});
