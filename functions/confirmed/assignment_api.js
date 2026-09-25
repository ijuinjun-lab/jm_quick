// Phase 2: イベント単位の任命(event_manager / staff)と、担当イベントの取得。
//
//   assignEventRole      … 任命・role変更。admin: 任意イベントのevent_manager / staff。event_manager: 自分の担当イベントのstaffだけ
//   removeEventRole      … 解除(active=false。ドキュメントは消さず履歴として残す)。admin: 任意。event_manager: 自イベントのstaffだけ
//   listEventAssignments … 対象イベントの有効な任命(admin: 任意イベント / event_manager: 自イベント)
//   listMyEvents         … 本人が管理・受付できるconfirmedイベントだけ(admin: 全件 / それ以外: 有効な任命のあるイベントだけ)
//
// ■ 認可の入口(index.js): assign / remove / list は confirmedEventCallable("eventManager", EVENT_SCOPES.dataEventId)
//   (staff・未任命・他イベントのmanagerはハンドラに届かない)。このファイルでは、さらに「managerはstaffだけ」「自分自身は不可」
//   「対象がadminなら作らない」「confirmedイベントだけ」を正本(Firestore・Firebase Auth)で確認する。
// ■ 対象ユーザーはメールアドレスで指定し、Firebase Auth(Admin SDK)に既に登録されているユーザーへ解決する(ユーザーは作らない)。
//   クライアントはuidを知らなくてよい(応答にもuidを含めない)。解除は一覧が返すassignmentId(uidを含まないハッシュ)で指定する。
// ■ ドキュメントIDは必ずevent_access.jsのassignmentDocIdで作る(別方式で作らない)。
// ■ 監査: assignedAt・assignedByは最初の任命のまま保持し、role変更・解除・再任命ではupdatedAt・updatedByだけを更新する。
//   解除はactive=false(物理削除しない)。再任命は同じドキュメントをactive=trueへ戻す。

const {ApiError} = require("./api_error");
const {
  EVENT_ASSIGNMENTS_COLLECTION, ROLE_EVENT_MANAGER, ROLE_EVENT_STAFF, assignmentDocId, normalizeAssignment,
  isValidEventId, isAssignableRole, loadGlobalRole, getAccessSummary,
} = require("../event_access");

const ROLE_ADMIN = "admin";
const SYSTEM_ADMIN_LABEL = "system_admin";
// 実用上のメールアドレス形式(Firebase Authの検索に渡す前の最低限の検証)。
const EMAIL_PATTERN = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,63}$/;
const ASSIGNMENT_ID_PATTERN = /^ea[0-9a-f]{64}$/;
const DENIED_MESSAGE = "この操作を行う権限がありません。";

const invalid = (code) => new ApiError("invalid-argument", "入力が正しくありません。", {code});
const denied = (code) => new ApiError("permission-denied", DENIED_MESSAGE, {code});

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("invalid-request");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unexpected-key");
  for (const key of allowed) if (data[key] === undefined) throw invalid(`missing-${key}`);
  return data;
}

// 前後の空白を除き、小文字にする(Firebase Authはメールアドレスを小文字で扱う)。
function normalizeEmail(value) {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  return email.length <= 254 && EMAIL_PATTERN.test(email) ? email : null;
}

const iso = (value) => {
  if (value && typeof value.toDate === "function") return value.toDate().toISOString();
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "number" || typeof value === "string") {
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
  }
  return null;
};

function createAssignmentApi({getDb, serverTimestamp, findUserByEmail, logger}) {
  const log = logger || console;
  if (typeof findUserByEmail !== "function") throw new Error("createAssignmentApi: findUserByEmail required");

  // guardが確定した対象イベントと入力のeventIdが一致すること(guardを通った後の二重の確認)。
  function assertScope(identity, eventId) {
    if (!identity || typeof identity.uid !== "string") throw denied("no-identity");
    if (identity.systemAdmin !== true && identity.eventId !== eventId) throw denied("event-scope-mismatch");
  }

  async function loadConfirmedEvent(db, eventId) {
    const snapshot = await db.collection("events").doc(eventId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。", {code: "event-not-found"});
    const event = snapshot.data() || {};
    if (event.flow !== "confirmed") {
      throw new ApiError("failed-precondition", "このイベントでは任命できません(新方式のイベントだけが対象です)。", {code: "event-not-confirmed"});
    }
    return event;
  }

  // ---- 任命・role変更 -------------------------------------------------------------------------------
  async function assign({identity, data}) {
    const request = parseKeys(data, ["eventId", "email", "role"]);
    if (!isValidEventId(request.eventId)) throw invalid("invalid-event-id");
    if (!isAssignableRole(request.role)) throw invalid("invalid-role");
    const email = normalizeEmail(request.email);
    if (!email) throw invalid("invalid-email");
    assertScope(identity, request.eventId);
    // event_managerが任命できるのはstaffだけ(event_manager・adminは任命できない)
    if (identity.systemAdmin !== true && request.role !== ROLE_EVENT_STAFF) throw denied("manager-can-assign-staff-only");

    const db = getDb();
    await loadConfirmedEvent(db, request.eventId);
    const user = await findUserByEmail(email);
    if (!user || typeof user.uid !== "string") {
      throw new ApiError("not-found", "このメールアドレスのユーザーは登録されていません。", {code: "user-not-found"});
    }
    if (user.disabled === true) throw new ApiError("failed-precondition", "このユーザーは無効になっています。", {code: "user-disabled"});
    if (user.uid === identity.uid) throw new ApiError("failed-precondition", "自分自身の任命は変更できません。", {code: "self-assignment"});
    // 既存のadmin(system_admin)は全イベントの権限を持つため、下位roleの任命を作らない(拒否)
    if ((await loadGlobalRole(db, user.uid)) === ROLE_ADMIN) {
      throw new ApiError("failed-precondition", "システム管理者はイベントごとの任命が不要です。", {code: "target-is-system-admin"});
    }
    const id = assignmentDocId(request.eventId, user.uid);
    if (!id) throw invalid("invalid-target");
    const storedEmail = typeof user.email === "string" && user.email ? user.email.trim().toLowerCase() : email;
    const ref = db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(id);

    const result = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const existing = snapshot.exists ? normalizeAssignment(id, snapshot.data()) : null;
      if (snapshot.exists && !existing) throw new ApiError("failed-precondition", "既存の任命を確認できません。", {code: "assignment-invalid"});
      // event_managerは、他のevent_managerの任命を変更できない(staffへの降格も不可)
      if (existing && existing.active && existing.role === ROLE_EVENT_MANAGER && identity.systemAdmin !== true) {
        throw denied("manager-cannot-change-manager");
      }
      if (existing && existing.active && existing.role === request.role) return {changed: false};
      const now = serverTimestamp();
      if (existing) {
        tx.update(ref, {role: request.role, active: true, email: storedEmail, updatedAt: now, updatedBy: identity.uid});
      } else {
        tx.create(ref, {
          eventId: request.eventId, uid: user.uid, role: request.role, active: true, email: storedEmail,
          assignedBy: identity.uid, assignedAt: now, updatedAt: now, updatedBy: identity.uid,
        });
      }
      return {changed: true, previousRole: existing && existing.active ? existing.role : null};
    });
    log.info("event role assigned", {eventId: request.eventId, role: request.role, by: identity.uid, changed: result.changed});
    return {eventId: request.eventId, assignmentId: id, email: storedEmail, role: request.role, active: true, ...result};
  }

  // ---- 解除(active=false) -----------------------------------------------------------------------------
  async function remove({identity, data}) {
    const request = parseKeys(data, ["eventId", "assignmentId"]);
    if (!isValidEventId(request.eventId)) throw invalid("invalid-event-id");
    if (typeof request.assignmentId !== "string" || !ASSIGNMENT_ID_PATTERN.test(request.assignmentId)) throw invalid("invalid-assignment-id");
    assertScope(identity, request.eventId);
    const db = getDb();
    const ref = db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(request.assignmentId);
    const notFound = () => new ApiError("not-found", "任命が見つかりません。", {code: "assignment-not-found"});

    const result = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const existing = snapshot.exists ? normalizeAssignment(request.assignmentId, snapshot.data()) : null;
      // 他イベントの任命は、存在しないのと同じ応答(他イベントの任命の有無を推測させない)
      if (!existing || existing.eventId !== request.eventId) throw notFound();
      if (existing.uid === identity.uid) throw new ApiError("failed-precondition", "自分自身の任命は解除できません。", {code: "self-assignment"});
      if (identity.systemAdmin !== true && existing.role !== ROLE_EVENT_STAFF) throw denied("manager-can-remove-staff-only");
      if (!existing.active) return {changed: false, role: existing.role};
      tx.update(ref, {active: false, updatedAt: serverTimestamp(), updatedBy: identity.uid});
      return {changed: true, role: existing.role};
    });
    log.info("event role removed", {eventId: request.eventId, role: result.role, by: identity.uid, changed: result.changed});
    return {eventId: request.eventId, assignmentId: request.assignmentId, active: false, ...result};
  }

  // ---- 対象イベントの任命一覧(有効なものだけ。uid・任命者は返さない) ---------------------------------------
  async function list({identity, data}) {
    const request = parseKeys(data, ["eventId"]);
    if (!isValidEventId(request.eventId)) throw invalid("invalid-event-id");
    assertScope(identity, request.eventId);
    const db = getDb();
    await loadConfirmedEvent(db, request.eventId);
    const snapshot = await db.collection(EVENT_ASSIGNMENTS_COLLECTION).where("eventId", "==", request.eventId).get();
    const assignments = [];
    for (const doc of snapshot.docs) {
      const raw = doc.data() || {};
      const assignment = normalizeAssignment(doc.id, raw);
      if (!assignment || assignment.eventId !== request.eventId || !assignment.active) continue;
      assignments.push({
        assignmentId: doc.id, role: assignment.role, active: true,
        email: typeof raw.email === "string" ? raw.email : null, isSelf: assignment.uid === identity.uid,
      });
    }
    const order = {[ROLE_EVENT_MANAGER]: 0, [ROLE_EVENT_STAFF]: 1};
    assignments.sort((a, b) => (order[a.role] - order[b.role]) || String(a.email).localeCompare(String(b.email)) || (a.assignmentId < b.assignmentId ? -1 : 1));
    return {eventId: request.eventId, assignments};
  }

  // ---- 本人が管理・受付できるconfirmedイベント -------------------------------------------------------------
  const eventDto = (eventId, event, role) => ({
    eventId,
    eventName: typeof event.eventName === "string" ? event.eventName : "",
    startAt: iso(event.startAt),
    venue: typeof event.venue === "string" ? event.venue : "",
    role,
  });
  const byStartThenId = (a, b) => (String(a.startAt) < String(b.startAt) ? -1 : String(a.startAt) > String(b.startAt) ? 1 : (a.eventId < b.eventId ? -1 : 1));

  async function listMyEvents({identity}) {
    const uid = identity && identity.uid;
    const db = getDb();
    const summary = await getAccessSummary(db, uid);
    if (summary.systemAdmin) {
      const events = (await db.collection("events").where("flow", "==", "confirmed").get()).docs
        .map((doc) => eventDto(doc.id, doc.data() || {}, SYSTEM_ADMIN_LABEL));
      return {systemAdmin: true, events: events.sort(byStartThenId)};
    }
    if (summary.globalRole === null && summary.assignments.length === 0) {
      log.warn("access denied", {uid: typeof uid === "string" ? uid.slice(0, 128) : null, reason: "no-access"});
      throw new ApiError("permission-denied", DENIED_MESSAGE);
    }
    const events = [];
    for (const {eventId, role} of summary.assignments) {
      const snapshot = await db.collection("events").doc(eventId).get();
      const event = snapshot.exists ? snapshot.data() || {} : null;
      if (!event || event.flow !== "confirmed") continue;
      events.push(eventDto(eventId, event, role));
    }
    return {systemAdmin: false, events: events.sort(byStartThenId)};
  }

  return {assign, remove, list, listMyEvents};
}

module.exports = {createAssignmentApi, normalizeEmail, SYSTEM_ADMIN_LABEL};
