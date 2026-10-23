const assert = require('node:assert/strict');
const {test} = require('node:test');
const {startAdminEmulator, skipReason} = require('../test_support/emulator_admin');
const {createQualificationChangeApi} = require('../confirmed/qualification_change_api');
const {createPassApi} = require('../confirmed/pass_api');
const {createAttendanceReportApi} = require('../confirmed/attendance_report_api');
const {collectBroadcastRecipients} = require('../confirmed/broadcast_message');
const {loadIndex} = require('../test_support/load_index');
const {assignmentDocId} = require('../event_access');
const f = require('../confirmed/test_support/participation_fixture');

test('qualification changes: atomic swaps, replay, races, capabilities, reporting and authorization', {skip: skipReason(), timeout: 120000}, async () => {
  const env = await startAdminEmulator(); const {db, FieldValue} = env;
  const eventId = 'changeEvent', participantId = 'changeBatch-000002';
  const identity = {uid: 'manager'};
  const event = f.event({eventId, participationMapping: {catProgramId:'program-1', dogProgramId:'program-2', talkProgramId:'program-3'}});
  event.winnerMailTemplate = {...event.winnerMailTemplate, version:2};
  event.waitlistWinnerMailTemplate = {...event.winnerMailTemplate, subject:'架空の繰り上げ当選', version:2};
  const person = {eventId, participantId, schemaVersion:2, status:'active', name:'架空田中', email:'tanaka@example.invalid', publicId:'pub_123456789012345678901234', importBatchId:'changeBatch'};
  const stamp = () => FieldValue.serverTimestamp();
  const api = createQualificationChangeApi({getDb:()=>db, serverTimestamp:stamp});
  const pass = createPassApi({getDb:()=>db,serverTimestamp:stamp,getAppBaseUrl:()=> 'https://example.invalid'});
  const input = {eventId,participantId};
  const ref = id => db.collection('programAttendances').doc(`${participantId}_${id}`);
  let n = 0;
  async function request(programId, targetProgramId) {
    const current = await api.get({data:input});
    return {...input, programId, operationId:`qualificationChange${String(++n).padStart(5,'0')}`, fingerprint:current.fingerprint, reason:'本人の希望', ...(targetProgramId ? {targetProgramId, slotLabel:'14:10-14:50', plannedCount:2} : {})};
  }
  try {
    await db.collection('events').doc(eventId).set(event);
    await db.collection('events').doc('otherEvent').set(event);
    const otherBefore = (await db.collection('events').doc('otherEvent').get()).data();
    await db.collection('participants').doc(participantId).set(person);
    await db.collection('importBatches').doc('changeBatch').set({eventId,status:'committed'});
    for(const programId of ['program-1','program-3']) await ref(programId).set({...input,programId,plannedCount:2,slotLabel:'10:10-10:50',checkedIn:false,importBatchId:'changeBatch'});
    await db.collection('mailDeliveries').doc(`${participantId}_winner`).set({...input,status:'sent',messageId:'historical'});
    const deliveryBefore = (await db.collection('mailDeliveries').doc(`${participantId}_winner`).get()).data();
    const talkBefore = (await ref('program-3').get()).data();
    const oldPass = await pass.getPass({data:{participantId,publicId:person.publicId}});
    const d = await request('program-1','program-2');
    const beforeInvalid = (await ref('program-1').get()).data();
    await assert.rejects(api.change({identity,data:{...d,slotLabel:'15:00-14:00'}}),e=>e.details.code==='invalid-slot');
    assert.deepEqual((await ref('program-1').get()).data(),beforeInvalid);

    const repeated = await Promise.all([api.change({identity,data:d}),api.change({identity,data:d})]);
    assert.equal(repeated.filter(x=>x.replay).length,1);
    assert.equal((await db.collection(`participants/${participantId}/qualificationChanges`).get()).size,1);
    const changed = await pass.getPass({data:{participantId,publicId:person.publicId}});
    assert.deepEqual(changed.programs.map(p=>p.programId).sort(),['program-2','program-3']);
    assert.equal(changed.qrPayload,oldPass.qrPayload); assert.equal(changed.webPassUrl,oldPass.webPassUrl);
    assert.deepEqual((await db.collection('participants').doc(participantId).get()).data(),person);
    assert.deepEqual((await ref('program-3').get()).data(),talkBefore);
    await assert.rejects(pass.checkIn({identity,data:{...input,publicId:person.publicId,programId:'program-1',attendedCount:1}}), e=>e.details.code==='qualification-revoked');
    const report = await createAttendanceReportApi({getDb:()=>db}).getReport({data:{eventId}});
    assert.equal(report.participants[0].programs.find(p=>p.programId==='program-1').entitlementStatus,'revoked');
    assert.equal(report.participants[0].programs.filter(p=>p.entitlementStatus!=='revoked').length,2);
    const broadcast = await collectBroadcastRecipients(db,eventId,event);
    assert.deepEqual(broadcast.recipients[0].programs.map(p=>p.programId).sort(),['program-2','program-3']);
    await api.change({identity,data:await request('program-2','program-1')});
    assert.deepEqual((await pass.getPass({data:{participantId,publicId:person.publicId}})).programs.map(p=>p.programId).sort(),['program-1','program-3']);
    const cancel = await request('program-1');
    const race = await Promise.allSettled([api.change({identity,data:cancel}),api.change({identity,data:{...cancel,operationId:'otherOperation000000000000'}})]);
    assert.equal(race.filter(x=>x.status==='fulfilled').length,1);
    assert.equal((await pass.getPass({data:{participantId,publicId:person.publicId}})).programs.length,1);
    await assert.rejects(api.change({identity,data:{...d,reason:'異なる要求'}}),e=>e.details.code==='operation-conflict');
    await ref('program-3').update({checkedIn:true,attendedCount:1});
    await assert.rejects(api.change({identity,data:await request('program-3')}),e=>e.details.code==='already-checked-in');
    await ref('program-3').update({checkedIn:false,attendedCount:null});
    await db.collection('events').doc(eventId).update({activeImportBatch:'busy'});
    await assert.rejects(api.change({identity,data:await request('program-3')}),e=>e.details.code==='operation-in-progress');
    await db.collection('events').doc(eventId).update({activeImportBatch:null});
    await db.collection('sendJobs').doc('busy').set({eventId,status:'completed',dispatchActive:true});
    await db.collection('sendJobs').doc('busy').collection('items').doc(participantId).set({participantId,status:'sending'});
    await assert.rejects(api.change({identity,data:await request('program-3')}),e=>e.details.code==='operation-in-progress');
    await db.collection('sendJobs').doc('busy').delete();
    // Actual callable wrapper and Firestore-backed event assignment checks.
    const index = loadIndex(db,{FieldValue});
    for(const [uid,role] of [['manager','event_manager'],['staff','staff']]) await db.collection('eventAssignments').doc(assignmentDocId(eventId,uid)).set({eventId,uid,role,active:true});
    await db.collection('accessRoles').doc('admin').set({role:'admin',active:true});
    await assert.rejects(index.changeConfirmedQualification.run({data:input}),e=>e.code==='unauthenticated');
    for(const uid of ['admin','manager']) await index.getConfirmedQualificationChange.run({auth:{uid},data:input});
    for(const uid of ['staff','stranger']) for(const name of ['getConfirmedQualificationChange','changeConfirmedQualification'])
      await assert.rejects(index[name].run({auth:{uid},data:input}),e=>e.code==='permission-denied');
    await assert.rejects(index.getConfirmedQualificationChange.run({auth:{uid:'manager'},data:{...input,eventId:'otherEvent'}}),e=>e.code==='permission-denied');
    const managerRequest = await request('program-3');
    await index.changeConfirmedQualification.run({auth:{uid:'manager'},data:managerRequest});
    assert.equal((await index.changeConfirmedQualification.run({auth:{uid:'admin'},data:managerRequest})).replay,true);
    // Reception and cancellation race on the same qualification: only one can win.
    await ref('program-1').update({entitlementStatus:'active'});
    const simultaneous = await request('program-1');
    const receptionRace = await Promise.allSettled([
      api.change({identity,data:simultaneous}),
      pass.checkIn({identity,data:{...input,publicId:person.publicId,programId:'program-1',attendedCount:1}}),
    ]);
    assert.equal(receptionRace.filter(r=>r.status==='fulfilled').length,1);
    assert.deepEqual((await db.collection('events').doc('otherEvent').get()).data(),otherBefore);
    assert.deepEqual((await db.collection('mailDeliveries').doc(`${participantId}_winner`).get()).data(),deliveryBefore);
    const currentEvent = (await db.collection('events').doc(eventId).get()).data();
    assert.deepEqual(currentEvent.winnerMailTemplate,event.winnerMailTemplate);
    assert.deepEqual(currentEvent.waitlistWinnerMailTemplate,event.waitlistWinnerMailTemplate);
  } finally { env.stop(); }
});
