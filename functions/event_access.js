// イベント単位の権限(3階層)の正本と、その読み取り専用の判定helper(Phase 1A)。
//
// 権限の階層(上位は下位を包含する。上位roleを下位roleとして重複登録しない):
//   admin(accessRoles/{uid}.role="admin"。概念上のsystem_admin) … 全イベント・全機能。eventAssignmentsには保存しない
//   event_manager(eventAssignments) … 任命されたeventIdについて、イベント管理+スタッフ業務
//   staff(eventAssignments)         … 任命されたeventIdについて、受付業務
//
// 正本:
//   - accessRoles/{uid}(既存・変更しない): 全体に対する権限。role="admin"かつactive===trueだけを最上位として扱う。
//     DB上の値を"system_admin"へ移行しない(既存のadminをそのまま最上位として認識する)。
//   - eventAssignments/{assignmentDocId(eventId, uid)}: イベント単位の権限。1イベント・1ユーザーにつき1ドキュメント。
//     フィールド: eventId, uid, role("event_manager"|"staff"), active(真偽値), email, assignedBy, assignedAt, updatedAt。
//     昇格・降格は同じドキュメントのroleを書き換えて表す(event_managerとstaffを同時に登録できない構造)。
//
// 信用しないもの: クライアントが送るrole・eventId・uid。判定はFirestoreの正本と、呼び出し側がサーバーで確定したuid/eventIdだけで行う。
// accessRoles.role="staff"(従来の全体staff)は、このhelperではどのイベントの権限にもならない(fail-closed)。
// 従来のstaffOrAdmin callableの判定(auth.js)は変更しない。
//
// このモジュールは読み取り専用(Firestoreへ書き込まない)。任命・解除のAPIは次のPhaseで、このhelperを使って作る。

const crypto = require("node:crypto");
const {UID_PATTERN, ROLE_ADMIN, ROLE_STAFF, ACCESS_ROLES_COLLECTION} = require("./auth");

const EVENT_ASSIGNMENTS_COLLECTION = "eventAssignments";
const ROLE_EVENT_MANAGER = "event_manager";
// イベント単位のstaffは、従来のaccessRolesのstaffと同じ文字列だが、保存先(eventAssignments)とイベントの範囲が異なる。
const ROLE_EVENT_STAFF = ROLE_STAFF;
// eventAssignmentsに保存できるroleは、この2つだけ(admin・system_adminは保存しない)。
const ASSIGNABLE_ROLES = Object.freeze([ROLE_EVENT_MANAGER, ROLE_EVENT_STAFF]);
// 権限の順位。未知のroleは0(=権限なし)。
const ROLE_RANK = Object.freeze({[ROLE_ADMIN]: 3, [ROLE_EVENT_MANAGER]: 2, [ROLE_EVENT_STAFF]: 1});
// 既存のeventIdの形式(confirmed/pass_api.js・winner_mail_api.js等と同じ)。
const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

const isValidEventId = (eventId) => typeof eventId === "string" && EVENT_ID_PATTERN.test(eventId);
const isValidUid = (uid) => typeof uid === "string" && UID_PATTERN.test(uid);

function rankOf(role) {
  return typeof role === "string" && Object.prototype.hasOwnProperty.call(ROLE_RANK, role) ? ROLE_RANK[role] : 0;
}

function isAssignableRole(role) {
  return ASSIGNABLE_ROLES.includes(role);
}

// eventAssignmentsのドキュメントID。eventIdとuidはどちらも"_"を含み得るため、単純な連結({eventId}_{uid})では
// 別の組が同じIDになり得る。既存のderiveEventIdと同じく、改行区切り(どちらの形式にも含まれない)のSHA-256で決定的に作る。
// 不正なeventId・uidでは作らない(null)。
function assignmentDocId(eventId, uid) {
  if (!isValidEventId(eventId) || !isValidUid(uid)) return null;
  return `ea${crypto.createHash("sha256").update(`event-assignment\n${eventId}\n${uid}`).digest("hex")}`;
}

// 保存されたassignmentを検証して、判定に使う最小の形({eventId, uid, role, active})にする。
// ドキュメントIDとフィールドのeventId・uidが一致しない、roleが保存できない値、activeが真偽値でない等は無効(null)。
function normalizeAssignment(docId, data) {
  if (!data || typeof data !== "object") return null;
  const {eventId, uid, role, active} = data;
  if (!isValidEventId(eventId) || !isValidUid(uid)) return null;
  if (docId !== assignmentDocId(eventId, uid)) return null;
  if (!isAssignableRole(role) || typeof active !== "boolean") return null;
  return {eventId, uid, role, active};
}

const byEventThenUid = (a, b) => (a.eventId === b.eventId ? (a.uid < b.uid ? -1 : a.uid > b.uid ? 1 : 0) : (a.eventId < b.eventId ? -1 : 1));

// 1件の取得。存在しない・無効ならnull。activeの判定は呼び出し側(includeInactiveの考え方と同じく、値として返す)。
async function getAssignment(db, eventId, uid) {
  const id = assignmentDocId(eventId, uid);
  if (!id) return null;
  const snapshot = await db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(id).get();
  if (!snapshot.exists) return null;
  const assignment = normalizeAssignment(id, snapshot.data());
  if (!assignment || assignment.eventId !== eventId || assignment.uid !== uid) return null;
  return assignment;
}

async function listAssignments(db, field, value, {includeInactive = false} = {}) {
  const snapshot = await db.collection(EVENT_ASSIGNMENTS_COLLECTION).where(field, "==", value).get();
  return snapshot.docs
    .map((doc) => normalizeAssignment(doc.id, doc.data()))
    .filter((a) => a && a[field] === value && (includeInactive || a.active === true))
    .sort(byEventThenUid);
}

// uid別の一覧(既定は有効なものだけ)。
async function listAssignmentsForUser(db, uid, options) {
  if (!isValidUid(uid)) return [];
  return listAssignments(db, "uid", uid, options);
}

// eventId別の一覧(既定は有効なものだけ)。
async function listAssignmentsForEvent(db, eventId, options) {
  if (!isValidEventId(eventId)) return [];
  return listAssignments(db, "eventId", eventId, options);
}

// accessRoles/{uid}の全体権限。active===trueで、roleがadmin/staffのときだけその値。それ以外はnull。
async function loadGlobalRole(db, uid) {
  if (!isValidUid(uid)) return null;
  const snapshot = await db.collection(ACCESS_ROLES_COLLECTION).doc(uid).get();
  if (!snapshot.exists) return null;
  const data = snapshot.data() || {};
  if (data.active !== true) return null;
  return data.role === ROLE_ADMIN || data.role === ROLE_STAFF ? data.role : null;
}

const NO_ACCESS = Object.freeze({rank: 0, role: null, systemAdmin: false});

// あるユーザーの、あるイベントに対する権限。{rank, role, systemAdmin}。権限なしはrank 0。
//   accessRoles: active===true かつ role="admin" → 全イベントでrank 3(eventAssignmentsは見ない・不要)
//   それ以外    : eventAssignmentsの該当ドキュメントがactive===true → event_manager=2 / staff=1
async function getEventAccess(db, uid, eventId) {
  if (!isValidUid(uid) || !isValidEventId(eventId)) return NO_ACCESS;
  if ((await loadGlobalRole(db, uid)) === ROLE_ADMIN) return {rank: ROLE_RANK[ROLE_ADMIN], role: ROLE_ADMIN, systemAdmin: true};
  const assignment = await getAssignment(db, eventId, uid);
  if (!assignment || assignment.active !== true) return NO_ACCESS;
  return {rank: rankOf(assignment.role), role: assignment.role, systemAdmin: false};
}

// 要求するroleは admin / event_manager / staff のいずれか。それ以外は呼び出し側の誤りなので例外にする(黙って許可も拒否もしない)。
async function hasEventRole(db, uid, eventId, minimumRole) {
  const required = rankOf(minimumRole);
  if (required === 0) throw new Error(`hasEventRole: unknown minimum role: ${String(minimumRole)}`);
  const access = await getEventAccess(db, uid, eventId);
  return access.rank >= required;
}

// ログイン中のユーザー自身の権限の概要(getMyAccessRole用)。
//   globalRole : accessRolesの有効な全体role("admin"|"staff")。無ければnull
//   systemAdmin: globalRole === "admin"
//   assignments: 有効なイベント単位の権限 [{eventId, role}](email・assignedBy等は含めない)
async function getAccessSummary(db, uid) {
  if (!isValidUid(uid)) return {globalRole: null, systemAdmin: false, assignments: []};
  const [globalRole, assignments] = await Promise.all([loadGlobalRole(db, uid), listAssignmentsForUser(db, uid)]);
  return {
    globalRole,
    systemAdmin: globalRole === ROLE_ADMIN,
    assignments: assignments.map(({eventId, role}) => ({eventId, role})),
  };
}

module.exports = {
  EVENT_ASSIGNMENTS_COLLECTION,
  ROLE_EVENT_MANAGER,
  ROLE_EVENT_STAFF,
  ASSIGNABLE_ROLES,
  ROLE_RANK,
  EVENT_ID_PATTERN,
  isValidEventId,
  isValidUid,
  rankOf,
  isAssignableRole,
  assignmentDocId,
  normalizeAssignment,
  getAssignment,
  listAssignmentsForUser,
  listAssignmentsForEvent,
  loadGlobalRole,
  getEventAccess,
  hasEventRole,
  getAccessSummary,
};
