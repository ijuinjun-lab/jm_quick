// Broadcasts use application identity and valid qualifications, not past mail status.
const crypto = require('node:crypto');
const {ApiError} = require('./api_error');
const {collectReminderTargets} = require('./reminder_targets');
const {loadAttendances} = require('./winner_mail_message');
const {buildMailSnapshot, buildProgramItems, mailPrograms} = require('./mail_view_model');
const {renderBroadcastMail} = require('./mail_render');
const {qualification} = require('./application_identity');
const digest = (v) => crypto.createHash('sha256').update(JSON.stringify(v)).digest('hex');
const fail = (code) => { throw new ApiError('failed-precondition', '内容・宛先一覧を確認し直してください。', {code}); };
function broadcastSnapshot(eventId, event, draft) {
  if (!draft || Object.keys(draft).some((k) => !['subject', 'body', 'includeDetails', 'includeQr'].includes(k)) ||
      typeof draft.subject !== 'string' || !draft.subject.trim() || draft.subject.length > 150 || /[\r\n\x00-\x1f]/.test(draft.subject) ||
      typeof draft.body !== 'string' || !draft.body.trim() || draft.body.length > 10000 || /[\x00-\x08\x0b\x0c\x0e-\x1f]/.test(draft.body) ||
      typeof draft.includeDetails !== 'boolean' || typeof draft.includeQr !== 'boolean') fail('invalid-broadcast-draft');
  // Closing text is unused in broadcasts; keep legacy template validation unchanged.
  const built = buildMailSnapshot(eventId, {...event, broadcastTemplate: {subject: draft.subject.trim(), introBody: draft.body.trim(), closingBody: 'unused', version: 1}}, {templateField: 'broadcastTemplate'});
  if (!built.ok) fail('mail-not-ready');
  return {...built.snapshot, template: {...built.snapshot.template, closingBody: ''}, broadcastOptions: {includeDetails: draft.includeDetails, includeQr: draft.includeQr}};
}
async function collectBroadcastRecipients(db, eventId, event, participantId = null) {
  const eligible = await collectReminderTargets(db, eventId, participantId);
  const recipients = [];
  for (const id of eligible.targets.filter((id) => !participantId || id === participantId)) {
    const p = (await db.collection('participants').doc(id).get()).data();
    const attendances = await loadAttendances(db, id, eventId);
    if (!attendances.length) continue;
    const items = buildProgramItems({programs: mailPrograms(eventId, event), attendances, eventId, participantId: id});
    const safetyFingerprint = digest([id, p.status, p.name, p.email?.trim().toLowerCase(), p.publicId,
      attendances.map(qualification).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)))]);
    recipients.push({participantId: id, name: p.name || '', email: p.email || '',
      programs: items.items.map(({programId, name, timeText, plannedCount}) => ({programId, name, timeText, plannedCount})),
      safetyFingerprint, target: true, valid: items.problems.length === 0 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p.email || '')});
  }
  return {recipients, targets: recipients.map((r) => r.participantId), fingerprint: digest(recipients),
    excludedCount: eligible.totalParticipants - recipients.length};
}
async function composeBroadcastMailFor(args) {
  if (args.snapshot.broadcastJobId && args.db.runTransaction) {
    const {transactionalReader} = require('./reminder_recovery');
    return args.db.runTransaction((tx) => composeBroadcastMailFor({...args, db: transactionalReader(args.db, tx)}));
  }
  const {db, snapshot, participantId, participant, appBaseUrl, generateQrPng} = args;
  if (snapshot.broadcastJobId) {
    const event = (await db.collection('events').doc(snapshot.event.eventId).get()).data();
    const current = await collectBroadcastRecipients(db, snapshot.event.eventId, event, participantId);
    const item = await db.collection('sendJobs').doc(snapshot.broadcastJobId).collection('items').doc(participantId).get();
    const expected = item.data()?.approvedSafetyFingerprint || snapshot.recipientSafetyFingerprints[participantId];
    if (current.recipients[0]?.safetyFingerprint !== expected || !current.recipients[0]?.valid) return {ok: false, problems: ['broadcast-state-changed']};
    // The engine read the address before composing: reject a concurrent change to that copy too.
    if (current.recipients[0].email !== participant.email || current.recipients[0].name !== participant.name) return {ok: false, problems: ['broadcast-state-changed']};
  }
  return renderBroadcastMail({snapshot, participant: {...participant, participantId},
    attendances: await loadAttendances(db, participantId, snapshot.event.eventId), appBaseUrl, generateQrPng});
}
module.exports = {broadcastSnapshot, collectBroadcastRecipients, composeBroadcastMailFor, digest, fail};
