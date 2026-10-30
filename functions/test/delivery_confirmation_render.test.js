const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createHash} = require('node:crypto');
const {buildMailSnapshot} = require('../confirmed/mail_view_model');
const {renderWinnerMail,renderBroadcastMail,renderReminderMail} = require('../confirmed/mail_render');
const {renderConfirmation,evidenceFor,RENDERER_VERSION,SENTINEL} = require('../confirmed/delivery_confirmation_render');
const {fakeQrPng} = require('../confirmed/test_support/mail_fixtures');
const fixture = require('../confirmed/test_support/participation_fixture');
const golden = require('./fixtures/formal_mail_before_confirmation.json');
const digest = result => createHash('sha256').update(JSON.stringify([result.subject,result.html,result.text])).digest('hex');
async function cases(){
 const result=[];
 for(const type of ['cat','dog','talk','cat_dog','cat_talk','dog_talk','cat_dog_talk']){
   const event=fixture.event();const snapshot=buildMailSnapshot(event.eventId,event).snapshot;
   const participant={participantId:'sample-000001',name:'正式比較用氏名',publicId:'pub_012345678901234567890123456789',sourceRegisteredAt:'2026-10-01T00:00:00Z'};
   const attendances=type.split('_').map(role=>({eventId:event.eventId,participantId:participant.participantId,programId:{cat:'program-1',dog:'program-2',talk:'program-3'}[role],plannedCount:2,slotLabel:'10:00～11:00'}));
   for(const kind of ['normal','waitlistPromotion','reminder','broadcast00','broadcast01','broadcast10','broadcast11']){
     const snap=structuredClone(snapshot);
     if(kind==='waitlistPromotion')snap.template.subject='繰り上げ当選のご案内';
     const broadcast=kind.startsWith('broadcast');if(broadcast)snap.broadcastOptions={includeDetails:kind[9]==='1',includeQr:kind[10]==='1'};
     const render=broadcast?renderBroadcastMail:kind==='reminder'?renderReminderMail:renderWinnerMail;
     const mail=await render({snapshot:snap,participant,attendances,appBaseUrl:'https://formal.example.invalid',generateQrPng:fakeQrPng});
     assert.equal(mail.ok,true);
     result.push({key:type+'/'+kind,mail,snapshot:snap,kind:broadcast?'broadcast':kind});
   }
 }
 return result;
}
test('49 formal subject/HTML/text outputs equal pre-change SHA256 baselines, including reminders',async()=>{
 const outputs=await cases();assert.equal(outputs.length,49);
 for(const c of outputs)assert.equal(digest(c.mail),golden[c.key],c.key);
});
test('safe copies reuse renderers for all patterns; no real identity, usable URL or QR',async()=>{
 for(const c of await cases()){
   if(c.kind==='reminder')continue;
   const evidence=evidenceFor(c.mail);assert.deepEqual(Object.keys(evidence).sort(),['hasRegisteredAt','programIds','rendererVersion']);
   const message=await renderConfirmation({job:{jobId:'winner-sample',snapshot:c.snapshot,batchSequence:1,targetCount:1,sentCount:1,failedCount:0,unknownCount:0},kind:c.kind,evidence,generateQrPng:fakeQrPng});
   const value=JSON.stringify(message);
   for(const secret of ['正式比較用氏名','pub_012345678901234567890123456789','formal.example.invalid','2026/10/1','/reception?','publicId='])assert(!value.includes(secret),secret);
   assert.match(message.html,/個別参加者の情報は確認用サンプルです/);
   if(c.kind==='broadcast' && !c.snapshot.broadcastOptions.includeQr)assert(!Object.hasOwn(message,'attachments'),'mail-api rejects an empty attachment array');
   for(const a of message.attachments || [])assert(Buffer.from(a.contentBase64,'base64').includes(Buffer.from(SENTINEL)));
 }
});
test('unknown version never silently renders using current code',async()=>{
 await assert.rejects(renderConfirmation({job:{},kind:'normal',evidence:{rendererVersion:'unknown'},generateQrPng:fakeQrPng}),/renderer-version/);
 assert.equal(RENDERER_VERSION.length,64);
});
module.exports={cases,digest};
test('real PNG contains only the non-reception sentinel; literal dollar signs and HTML text remain safe',async()=>{
 const {generateQrPng}=require('../qr_png');
 const c=(await cases())[0];c.snapshot.template.introBody='料金 $& / $\' / <script>alert(1)</script>';
 const message=await renderConfirmation({job:{jobId:'winner-safe',snapshot:c.snapshot,targetCount:1,sentCount:1,failedCount:0,unknownCount:0},kind:c.kind,evidence:evidenceFor(c.mail),generateQrPng});
 assert.deepEqual(Buffer.from(message.attachments[0].contentBase64,'base64'),await generateQrPng(SENTINEL));
 assert.equal((message.html.match(/<body\b/g)||[]).length,1);
 assert(!message.html.includes('<script>'));assert.match(message.html,/&lt;script&gt;/);
});
test('completion entry point is internal, event-scoped callables enforce App Check, no API/Rules changes required',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'../index.js'),'utf8');
 assert.match(source,/exports\.notifyDeliveryConfirmationCompleted = onDocumentUpdated\(\{document: "sendJobs\/\{jobId\}"/);
 assert.match(source,/onDocumentUpdated\(\{[^\n]*retry: true/);
 for(const name of ['getDeliveryConfirmationSettings','getDeliveryConfirmationReport','retryDeliveryConfirmation','resumeDeliveryConfirmation'])assert.match(source,new RegExp(`exports\\.${name} = confirmedEventCallable\\("eventManager", EVENT_SCOPES.dataEventId,[^\\n]+enforceAppCheck: true`));
 assert.match(source,/exports\.updateDeliveryConfirmationPolicy = confirmedCallable\("systemAdmin",[^\n]+enforceAppCheck: true/);
});
