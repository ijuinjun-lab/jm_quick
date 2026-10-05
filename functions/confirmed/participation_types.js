// ユーザー確認済みのイベント別対応。時刻・名称から犬猫を推測しない。
// 参加情報の正本は programAttendances。タイプは保存せず決定論的に導出する。
const EVENT_ID = "ev404dfc7a6ddb951db783225688ad63";
const ROLES = Object.freeze({"program-1": "cat", "program-2": "dog", "program-3": "talk"});
const NAMES = Object.freeze({cat: "譲渡会（ねこ）", dog: "譲渡会（いぬ）", talk: "トークセッション"});
const TYPES = Object.freeze([
  {value: "dog", label: "① 犬のみ"}, {value: "cat", label: "② 猫のみ"},
  {value: "dog_cat", label: "③ 犬＋猫"}, {value: "talk", label: "④ トークショーのみ"},
  {value: "dog_talk", label: "⑤ 犬＋トークショー"}, {value: "cat_talk", label: "⑥ 猫＋トークショー"},
  {value: "dog_cat_talk", label: "⑦ 犬＋猫＋トークショー"},
]);
const {isValidPlannedCount} = require("../programs");
const {ApiError} = require("./api_error");
// Temporary migration fallback: explicit persisted mapping always takes precedence.
function rolesFor(eventId, event = {}) {
  if (event.participationMapping === undefined) return eventId === EVENT_ID ? ROLES : null;
  const mapping = event.participationMapping;
  if (mapping === null) return null; // explicit opt-out, including the legacy event
  const keys = ["catProgramId", "dogProgramId", "talkProgramId"];
  const fail = (code) => { throw new ApiError("invalid-argument", `参加program設定が不正です: ${code}`, {code}); };
  if (!mapping || typeof mapping !== "object" || Array.isArray(mapping) ||
      Object.keys(mapping).length !== 3 || keys.some((k) => typeof mapping[k] !== "string" || !mapping[k].trim())) fail("invalid-participation-mapping");
  const ids = keys.map((k) => mapping[k]);
  if (new Set(ids).size !== 3) fail("duplicate-participation-program");
  if (ids.some((id) => !(Array.isArray(event.programs) ? event.programs : []).some((p) => p && p.programId === id))) fail("participation-program-not-in-event");
  return Object.fromEntries(keys.map((key, i) => [mapping[key], ["cat", "dog", "talk"][i]]));
}
function mappingFor(eventId, event) {
  const roles = rolesFor(eventId, event);
  return roles ? Object.fromEntries(Object.entries(roles).map(([id, role]) => [`${role}ProgramId`, id])) : null;
}
function participationType(eventId, attendances, event) {
  const roles = rolesFor(eventId, event);
  if (!roles || !Array.isArray(attendances) || attendances.length === 0) return null;
  const present = new Set();
  for (const a of attendances) {
    const role = roles[a.programId];
    if (!role || present.has(role) || !isValidPlannedCount(a.plannedCount)) return null;
    present.add(role);
  }
  return ["dog", "cat", "talk"].filter((role) => present.has(role)).join("_");
}
function typeSummary(eventId, records, event) {
  if (!rolesFor(eventId, event)) return null;
  return TYPES.map((type) => ({...type, count: records.filter((r) =>
    r.status === "ready" && participationType(eventId, r.attendances, event) === type.value).length}));
}
module.exports = {EVENT_ID, ROLES, NAMES, TYPES, mappingFor, rolesFor, participationType, typeSummary};
