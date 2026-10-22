// Round 1 keeps all legacy keys/IDs. Round 2 never aliases an existing round-1 job.
const {ApiError} = require('./api_error');
const invalid = (code) => new ApiError('invalid-argument', 'リマインドの回・送信予定日時を確認してください。', {code});
function roundOf(value) {
  if (value === undefined) return 1;
  if (value !== 1 && value !== 2) throw invalid('invalid-reminder-round');
  return value;
}
const fieldFor = (field, round) => roundOf(round) === 1 ? field : field.replace(/^reminder/, 'reminder2');
const jobIdForReminder = (eventId, round = 1) => `${roundOf(round) === 2 ? 'reminder2' : 'reminder'}-${eventId}`;
const deliveryIdForReminder = (participantId, round = 1) => `${participantId}_${roundOf(round) === 2 ? 'reminder2' : 'reminder'}`;
function schedule(date, time) {
  if (date !== null && (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date) ||
    !Number.isFinite(Date.parse(date + 'T00:00:00Z')) || new Date(date + 'T00:00:00Z').toISOString().slice(0, 10) !== date)) throw invalid('invalid-planned-date');
  if (time !== null && (typeof time !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(time))) throw invalid('invalid-planned-time');
  return date && time ? new Date(`${date}T${time}:00+09:00`) : null;
}
function roundEvent(event, round = 1) {
  round = roundOf(round);
  const view = {...event, reminderRound: round, reminderScheduleVersion: event.reminderScheduleVersion ??
    (Object.hasOwn(event, fieldFor("reminderPlannedDate", round)) ? 1 : 0)};
  for (const key of ['reminderMailTemplate', 'reminderSendAt', 'reminderPlannedDate', 'reminderPlannedTime']) view[key] = event[fieldFor(key, round)] ?? null;
  // Legacy absolute timestamp is already a complete schedule; never invent a missing time.
  const raw = view.reminderSendAt;
  const date = raw?.toDate ? raw.toDate() : raw instanceof Date ? raw : typeof raw === 'string' ? new Date(raw) : null;
  if (date && Number.isFinite(date.getTime()) && event[fieldFor('reminderPlannedDate', round)] === undefined) {
    const jst = new Date(date.getTime() + 9 * 3600000).toISOString();
    view.reminderPlannedDate = jst.slice(0, 10); view.reminderPlannedTime = jst.slice(11, 16);
  }
  return view;
}
module.exports = {roundOf, fieldFor, roundEvent, schedule, jobIdForReminder, deliveryIdForReminder};
