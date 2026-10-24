const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createQualificationNoticeApi} = require('../confirmed/qualification_notice_api');
const {createPassApi} = require('../confirmed/pass_api');
const {createAttendanceReportApi} = require('../confirmed/attendance_report_api');
const {loadIndex} = require('../test_support/load_index');
const {assignmentDocId} = require('../event_access');
const f = require('../confirmed/test_support/participation_fixture');

test('single and atomic all cancellation: real transactions, slots, notice, immutable capabilities and history', {skip:skipReason(),timeout:120000}, async t => {
  const env=await startAdminEmulator(),{db,FieldValue}=env;
  let seq=0, sends=0;const messages=[];
  const deps={getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),getAppBaseUrl:()=> 'https://example.invalid',
    generateQrPng:async p=>Buffer.from(p),getTransport:()=>({capabilities:async()=>({ok:true}),send:async m=>{sends++;messages.push(m);return {outcome:'sent'};}})};
  const api=createQualificationChangeApi(deps),notice=createQualificationNoticeApi(deps),pass=createPassApi(deps),identity={uid:'manager'};
  async function fixture() {
    const eventId=`cancelEvent${++seq}`,participantId=`cancelBatch${seq}-000002`,input={eventId,participantId};
    const event=f.event({eventId,participationMapping:{catProgramId:'program-1',dogProgramId:'program-2',talkProgramId:'program-3'}});
    const person={...input,schemaVersion:2,status:'active',name:'架空参加者',email:'only@example.invalid',publicId:'pub_123456789012345678901234',importBatchId:`cancelBatch${seq}`};
    await db.collection('events').doc(eventId).set(event);
    await db.collection('participants').doc(participantId).set(person);
    await db.collection('importBatches').doc(person.importBatchId).set({eventId,status:'committed'});
    const refs=['program-1','program-2','program-3'].map(id=>db.collection('programAttendances').doc(`${participantId}_${id}`));
    for(const [i,ref] of refs.entries()) await ref.set({...input,programId:`program-${i+1}`,plannedCount:i+1,slotLabel:'10:00-11:00',checkedIn:false,importBatchId:person.importBatchId});
    const historical=db.collection('mailDeliveries').doc(`${participantId}_winner`);
    await historical.set({...input,status:'sent',messageId:'first-round'});
    const oldHistory=(await historical.get()).data();
    const oldPass=await pass.getPass({data:{participantId,publicId:person.publicId}});
    const audit=db.collection('participants').doc(participantId).collection('qualificationChanges');
    const legacy={eventId,reason:'旧履歴',before:[],after:[],operationId:'legacy'};
    await audit.doc('legacy').set(legacy);
    const external=db.collection('programAttendances').doc(`otherEvent-${seq}`);
    await external.set({eventId:'otherEvent',participantId:`otherPerson-${seq}`,programId:'program-1',plannedCount:9});
    const otherBefore=(await external.get()).data();
    const request=async(programId)=>({...input,action:programId?'cancel':'cancelAll',...(programId?{programId}:{}),
      operationId:`cancelOperation${String(++seq).padStart(10,'0')}`,fingerprint:(await api.get({data:input})).fingerprint,reason:'本人からのキャンセル'});
    const preserved=async()=>{
      assert.deepEqual((await historical.get()).data(),oldHistory);
      assert.deepEqual((await db.collection('participants').doc(participantId).get()).data(),person);
      assert.deepEqual((await audit.doc('legacy').get()).data(),legacy);
      assert.deepEqual((await external.get()).data(),otherBefore);
    };
    return {input,event,person,refs,request,preserved,oldPass,audit};
  }
  try {
    for(const target of ['program-1','program-2','program-3',null]) await t.test(target||'all',async()=>{
      const f=await fixture(),before=await Promise.all(f.refs.map(async r=>(await r.get()).data()));
      const d=await f.request(target),sentBefore=sends;
      await api.change({identity,data:d});assert.equal(sends,sentBefore);
      const after=await Promise.all(f.refs.map(async r=>(await r.get()).data()));
      for(const [i,a] of after.entries()) {
        const cancelled=!target||a.programId===target;
        assert.equal(a.entitlementStatus==='revoked',cancelled);
        if(!cancelled)assert.deepEqual(a,before[i]);
        if(cancelled)await assert.rejects(pass.checkIn({identity,data:{...f.input,publicId:f.person.publicId,programId:a.programId,attendedCount:1}}),e=>e.details.code==='qualification-revoked'||e.details.code==='no-active-qualification');
        assert.equal((await f.refs[i].collection('history').get()).size,cancelled?1:0);
      }
      const report=await createAttendanceReportApi({getDb:()=>db}).getReport({data:{eventId:f.input.eventId}});
      for(const [i,a] of report.participants[0].programs.entries()) {
        assert.equal(a.entitlementStatus==='revoked',!target||a.programId===target);
        const planned=report.participants.flatMap(p=>p.programs).filter(p=>p.programId===a.programId&&p.timeText===a.timeText&&p.entitlementStatus!=='revoked').reduce((n,p)=>n+p.plannedCount,0);
        assert.equal(planned,(!target||a.programId===target)?0:i+1);
      }
      if(target){const p=await pass.getPass({data:{participantId:f.input.participantId,publicId:f.person.publicId}});assert.equal(p.qrPayload,f.oldPass.qrPayload);assert.equal(p.webPassUrl,f.oldPass.webPassUrl);}
      if(!target) await assert.rejects(pass.getPass({data:{participantId:f.input.participantId,publicId:f.person.publicId}}),e=>e.code==='not-found');
      const r={...f.input,operationId:d.operationId},preview=await notice.preview({data:r});
      assert.equal(preview.to,f.person.email);assert.match(preview.text,/取消/);assert.match(preview.text,/変更前/);assert.match(preview.text,/変更後/);
      assert.equal(preview.qrPayload,f.oldPass.qrPayload);assert.equal(preview.webPassUrl,f.oldPass.webPassUrl);assert.equal(preview.text.includes(d.reason),false);
      await Promise.all([notice.send({identity,data:{...r,fingerprint:preview.fingerprint}}),notice.send({identity,data:{...r,fingerprint:preview.fingerprint}})]);
      assert.equal(sends,sentBefore+1);assert.equal(messages.at(-1).to,f.person.email);
      assert.equal(messages.at(-1).attachments.length,target ? 1 : 0);
      if (!target) {
        assert.match(preview.text,/参加資格はすべて取り消されました/);
        assert.equal(preview.text.includes(preview.webPassUrl),false);
        assert.equal(preview.html.includes('cid:'),false);
        assert.equal(preview.text.includes('ご利用ください'),false);
      } else {
        assert.ok(preview.text.includes(preview.webPassUrl));
        assert.ok(preview.html.includes('cid:'));
      }
      assert.equal((await f.audit.get()).size,2);await f.preserved();
    });
    await t.test('obsolete history is blocked and failed mail preserves saved qualifications',async()=>{
      const f=await fixture();
      const first=await f.request('program-1');await api.change({identity,data:first});
      const request={...f.input,operationId:first.operationId};
      const oldPreview=await notice.preview({data:request});
      const second=await f.request('program-2');await api.change({identity,data:second});
      const before=await Promise.all(f.refs.map(async ref=>(await ref.get()).data()));
      const sendsBefore=sends;
      await assert.rejects(notice.preview({data:request}),e=>e.details.code==='change-superseded');
      await assert.rejects(notice.send({identity,data:{...request,fingerprint:oldPreview.fingerprint}}),e=>e.details.code==='change-superseded');
      assert.equal(sends,sendsBefore);
      const failingNotice=createQualificationNoticeApi({...deps,getTransport:()=>({capabilities:async()=>({ok:true}),send:async()=>({outcome:'failed'})})});
      const latest={...f.input,operationId:second.operationId};
      const preview=await failingNotice.preview({data:latest});
      assert.equal((await failingNotice.send({identity,data:{...latest,fingerprint:preview.fingerprint}})).status,'failed');
      assert.deepEqual(await Promise.all(f.refs.map(async ref=>(await ref.get()).data())),before);
      assert.equal((await db.collection('sendJobs').get()).size,0);
      await f.preserved();
    });
    await t.test('all cancellation skips prior revocations and respects import/delivery locks',async()=>{
      const f=await fixture(),eventRef=db.collection('events').doc(f.input.eventId);
      await eventRef.update({activeImportBatch:'busy'});
      await assert.rejects(api.change({identity,data:await f.request()}),e=>e.details.code==='operation-in-progress');
      await eventRef.update({activeImportBatch:null});
      const pending=db.collection('qualificationNotices').doc(`pending-${f.input.eventId}`);
      await pending.set({...f.input,status:'sending'});
      await assert.rejects(api.change({identity,data:await f.request()}),e=>e.details.code==='operation-in-progress');
      await pending.delete();
      const one=await f.request('program-1');await api.change({identity,data:one});
      const cancelled=(await f.refs[0].get()).data(),oldAudit=(await f.audit.doc(one.operationId).get()).data();
      await api.change({identity,data:await f.request()});
      assert.deepEqual((await f.refs[0].get()).data(),cancelled);
      assert.deepEqual((await f.audit.doc(one.operationId).get()).data(),oldAudit);
      assert.equal((await f.refs[0].collection('history').get()).size,1);
      await assert.rejects(api.change({identity,data:await f.request()}),e=>e.details.code==='qualification-unavailable');
      await f.preserved();
    });
    await t.test('rollback, checked-in rejection, validation, races and authorization',async()=>{
      const f=await fixture(),snapshot=async()=>Promise.all(f.refs.map(async r=>(await r.get()).data())),before=await snapshot();
      const d=await f.request();
      const broken=new Proxy(db,{get(t,k){if(k==='runTransaction')return fn=>t.runTransaction(async tx=>{await fn(tx);throw Error('injected before commit');});const v=t[k];return typeof v==='function'?v.bind(t):v;}});
      await assert.rejects(createQualificationChangeApi({...deps,getDb:()=>broken}).change({identity,data:d}),/injected/);
      assert.deepEqual(await snapshot(),before);assert.equal((await f.audit.get()).size,1);
      for(const patch of [{programId:'program-1'},{targetProgramId:'program-2'},{plannedCount:1},{slotLabel:'10:00-11:00'}]) await assert.rejects(api.change({identity,data:{...d,...patch}}));
      for(const field of ['checkedIn','checkedInAt','attendedCount']) {
        await f.refs[2].update({[field]:field==='checkedIn'?true:field==='checkedInAt'?new Date():1});
        const b=await snapshot();await assert.rejects(api.change({identity,data:await f.request()}),e=>e.details.code==='already-checked-in');assert.deepEqual(await snapshot(),b);
        await f.refs[2].update({[field]:FieldValue.delete()});
      }
      const index=loadIndex(db,{FieldValue});
      await db.collection('eventAssignments').doc(assignmentDocId(f.input.eventId,'manager')).set({eventId:f.input.eventId,uid:'manager',role:'event_manager',active:true});
      const valid=await f.request();
      await assert.rejects(index.changeConfirmedQualification.run({data:valid}),e=>e.code==='unauthenticated');
      for(const uid of ['staff','stranger'])await assert.rejects(index.changeConfirmedQualification.run({auth:{uid},data:valid}),e=>e.code==='permission-denied');
      await assert.rejects(index.changeConfirmedQualification.run({auth:{uid:'manager'},data:{...valid,eventId:'otherEvent'}}),e=>e.code==='permission-denied');
      const replay=await Promise.all([index.changeConfirmedQualification.run({auth:{uid:'manager'},data:valid}),index.changeConfirmedQualification.run({auth:{uid:'manager'},data:valid})]);
      assert.equal(replay.filter(x=>x.replay).length,1);assert.equal((await f.audit.get()).size,2);
      await assert.rejects(api.change({identity,data:{...valid,reason:'different'}}),e=>e.details.code==='operation-conflict');await f.preserved();
      const g=await fixture(),all=await g.request(),one=await g.request('program-1');
      const race=await Promise.allSettled([api.change({identity,data:all}),api.change({identity,data:one})]);assert.equal(race.filter(r=>r.status==='fulfilled').length,1);
      const h=await fixture(),all2=await h.request();
      const checkRace=await Promise.allSettled([api.change({identity,data:all2}),pass.checkIn({identity,data:{...h.input,publicId:h.person.publicId,programId:'program-2',attendedCount:1}})]);
      assert.equal(checkRace.filter(r=>r.status==='fulfilled').length,1);
      const rows=await Promise.all(h.refs.map(async r=>(await r.get()).data()));
      assert.ok(rows.every(r=>r.entitlementStatus==='revoked')||rows.every(r=>r.entitlementStatus!=='revoked'));
    });
  } finally {env.stop();}
});
