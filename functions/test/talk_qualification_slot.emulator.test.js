const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createQualificationNoticeApi} = require('../confirmed/qualification_notice_api');
const {createPassApi} = require('../confirmed/pass_api');
const f = require('../confirmed/test_support/participation_fixture');

test('talk opening guidance: strict session candidates, addition and immutable existing data', {skip:skipReason(), timeout:120000}, async () => {
  const emu = await startAdminEmulator(), {db, FieldValue} = emu;
  const eventId='talkSlotEvent', participantId='talkSlotBatch-000001', input={eventId,participantId};
  const guidance='13:00～14:00（開場12:00）';
  const production=process.env.JM_PRODUCTION_CONFIG ? JSON.parse(require('node:fs').readFileSync(process.env.JM_PRODUCTION_CONFIG,'utf8')) : null;
  const event=f.event({...production?.event,eventId, participationMapping:{catProgramId:'program-1',dogProgramId:'program-2',talkProgramId:'program-3'}});
  if (production) assert.equal(event.confirmedMailSettings.talkTimeText,guidance);
  else event.confirmedMailSettings.talkTimeText=guidance;
  if (!production) {event.winnerMailTemplate.version=2;event.waitlistWinnerMailTemplate={...event.winnerMailTemplate};}
  else {assert.equal(event.winnerMailTemplate.version,2);assert.equal(event.waitlistWinnerMailTemplate.version,2);assert.equal(event.confirmedMailSettings.talkTimeText,guidance);}
  if (!production) event.programs=event.programs.map(p=>({programId:p.programId,name:p.name,
    ...(p.programId==='program-3' ? {} : {qualificationSlots:['10:00-11:00',guidance]})}));
  const person={...input,name:'架空参加者',email:'only@example.invalid',schemaVersion:2,status:'active',publicId:'pub_123456789012345678901234',importBatchId:'talkSlotBatch'};
  const deps={getDb:()=>db,serverTimestamp:()=>FieldValue.serverTimestamp(),getAppBaseUrl:()=> 'https://example.invalid',
    getTransport:()=>{throw Error('Transport must not be invoked');}};
  const api=createQualificationChangeApi(deps), notice=createQualificationNoticeApi(deps), pass=createPassApi(deps);
  try {
    await db.doc(`events/${eventId}`).set(event);
    const originalEvent=(await db.doc(`events/${eventId}`).get()).data();
    await db.doc(`participants/${participantId}`).set(person);
    await db.doc('importBatches/talkSlotBatch').set({eventId,status:'committed'});
    const preserved=[];
    for(const programId of ['program-1','program-2']) {
      const path=`programAttendances/${participantId}_${programId}`;
      const value={...input,programId,plannedCount:2,slotLabel:'10:00-11:00',checkedIn:false,importBatchId:'talkSlotBatch'};
      await db.doc(path).set(value);preserved.push([path,value]);
    }
    const batch=db.batch();
    for(let i=0;i<173;i++) {
      const path=`programAttendances/existing-talk-${i}`;
      const value={eventId,participantId:`existing-${i}`,programId:'program-3',slotLabel:'',plannedCount:1,importBatchId:'talkSlotBatch'};
      batch.set(db.doc(path),value);preserved.push([path,value]);
    }
    await batch.commit();
    const historyPath='mailDeliveries/previous';
    const history={...input,status:'sent',messageId:'unchanged'};
    await db.doc(historyPath).set(history);preserved.push([historyPath,history]);
    const oldPass=await pass.getPass({data:{participantId,publicId:person.publicId}});
    let sequence=0;
    const request=async(slotLabel,plannedCount=3)=>({...input,action:'add',programId:'program-3',slotLabel,plannedCount,
      operationId:`talkSlotOperation${String(++sequence).padStart(8,'0')}`,reason:'本人希望',fingerprint:(await api.get({data:input})).fingerprint});
    const state=await api.get({data:input});
    assert.deepEqual(state.slots['program-3'],['13:00～14:00']);
    for(const id of ['program-1','program-2'])assert.deepEqual(state.slots[id],['10:00-11:00']);
    for(const slot of ['12:00～14:00','13:00～15:00','99:00-99:30','14:00-13:00',guidance])
      await assert.rejects(api.change({identity:{uid:'manager'},data:await request(slot)}),e=>e.details.code==='invalid-slot');
    for(const count of [0,1000,1.5])await assert.rejects(api.change({identity:{uid:'manager'},data:await request('13:00～14:00',count)}),e=>e.details.code==='invalid-slot');
    // Malformed guidance must not contribute new candidates.
    for(const value of ['13:00～14:00（開場99:00）','13:00～14:00（開場15:00）','13:00～14:00（自由記述）','14:00～13:00（開場12:00）','13:00～14:00（開場12:00）追加']) {
      await db.doc(`events/${eventId}`).update({'confirmedMailSettings.talkTimeText':value});
      assert.deepEqual((await api.get({data:input})).slots['program-3'],[]);
    }
    await db.doc(`events/${eventId}`).update({'confirmedMailSettings.talkTimeText':guidance});
    const r=await request('13:00～14:00');await api.change({identity:{uid:'manager'},data:r});
    const added=(await db.doc(`programAttendances/${participantId}_program-3`).get()).data();
    assert.equal(added.slotLabel,'13:00～14:00');assert.equal(added.plannedCount,3);
    const preview=await notice.preview({data:{...input,operationId:r.operationId}});
    assert.equal(preview.to,person.email);assert.match(preview.text,/13:00～14:00 \/ 3名/);
    assert.match(preview.text,/変更前/);assert.match(preview.text,/変更後/);
    assert.equal(preview.qrPayload,oldPass.qrPayload);assert.equal(preview.webPassUrl,oldPass.webPassUrl);
    assert.deepEqual((await db.doc(`participants/${participantId}`).get()).data(),person);
    const savedEvent=(await db.doc(`events/${eventId}`).get()).data();delete savedEvent.qualificationRevision;
    assert.deepEqual(savedEvent,originalEvent);
    for(const [path,value] of preserved)assert.deepEqual((await db.doc(path).get()).data(),value);
    assert.equal((await db.collection('sendJobs').get()).size,0);
  } finally {await db.terminate();emu.stop();}
});
