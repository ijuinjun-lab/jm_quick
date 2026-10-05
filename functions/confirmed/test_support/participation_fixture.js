// 完全な架空データ。sampleLIST.csvの個人情報は使用しない。
const {EVENT_ID, ROLES, TYPES} = require("../participation_types");
const {makeEvent, participant} = require("./mail_fixtures");
const preset = require("../sippo_mail_preset");
const headers = ["氏名", "かな", "メールアドレス", "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数", "トークショー", "トークショー人数"];
const mapping = {
  version: 1, participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス"},
  programs: [
    {programId: "program-1", participationColumn: "午前参加時間", slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数", notAttendingValues: ["参加を希望しない"], emptyMeans: "notAttending", ignoreCountWhenNotAttending: true},
    {programId: "program-2", participationColumn: "午後参加時間", slotColumn: "午後参加時間", slotFormat: "label", countColumn: "午後参加人数", notAttendingValues: ["参加を希望しない"], emptyMeans: "notAttending", ignoreCountWhenNotAttending: true},
    {programId: "program-3", participationColumn: "トークショー", countColumn: "トークショー人数", attendingValues: ["参加を希望する"], notAttendingValues: ["参加を希望しない"], emptyMeans: "notAttending", ignoreCountWhenNotAttending: true},
  ],
};
function cells(type, overrides = {}) {
  const roles = type.split("_");
  return {"氏名": "架空参加者", "かな": "かくう", "メールアドレス": "fixture@example.invalid",
    "午前参加時間": roles.includes("cat") ? "10:10〜10:50" : "参加を希望しない", "午前参加人数": "2",
    "午後参加時間": roles.includes("dog") ? "14:10〜14:50" : "参加を希望しない", "午後参加人数": "3",
    "トークショー": roles.includes("talk") ? "参加を希望する" : "参加を希望しない", "トークショー人数": "4", ...overrides};
}
function event(overrides = {}) {
  const template = {subject: preset.subject, introBody: preset.introBody, closingBody: preset.closingBody,
    notesBody: preset.notesBody, adoptionNotesBody: preset.adoptionNotesBody, version: 1};
  return makeEvent({eventId: EVENT_ID, programs: Object.keys(ROLES).map((programId, order) => ({programId, name: `架空program${order}`, order})),
    confirmedMailSettings: {talkTimeText: "16:00〜17:00"}, winnerMailTemplate: template,
    reminderMailTemplate: {...template, subject: "リマインド"}, ...overrides});
}
function table() { return {headers, records: TYPES.map(({value}) => headers.map((h) => cells(value)[h]))}; }
const person = () => participant({eventId: EVENT_ID});
module.exports = {mapping, cells, event, table, person};
