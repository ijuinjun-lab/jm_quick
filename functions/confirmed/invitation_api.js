// イベント単位の権限(イベント管理者・スタッフ)への招待。JM Quickのアカウントをまだ持っていない人を、本人の操作で登録・任命する。
//
//   inviteEventRole        … 招待(対象イベントのevent_manager以上。managerはstaffだけ)。既存のAuthユーザーなら招待せず即任命(assignEventRoleと同じ)
//   revokeEventInvitation  … 招待の取消(adminは任意、managerは自イベントのstaffの招待だけ)
//   getEventInvitation     … 招待リンクを開いた人向け(ログイン不要・App Check・rate limit)。tokenを確認できた場合だけ最小限の情報を返す
//   acceptEventInvitation  … ログインした本人が招待を受ける(ログイン必須)。ここで初めてeventAssignmentsを有効にする
//
// ■ 本人確認: 招待tokenは招待先のメールアドレスにだけ届く。パスワードは本人のブラウザからFirebase Auth SDKへだけ渡す(このコードは扱わない)。
//   任命の有効化は、ログインしたAuthユーザーのメールアドレス(Firebase Authの正本)が招待のメールアドレスと一致したときだけ。
//   クライアントが送るeventId・role・uid・メールアドレスは使わない(招待の正本だけで決める)。
// ■ token: 32バイトの乱数(base64url)。Firestoreにはsha256のhashだけを保存する(平文は招待メールの中だけ)。有効期限は7日(expiresAtはミリ秒)。
//   再招待(同じイベント・同じメールアドレス)は同じ招待ドキュメントのtokenを作り直す(古いリンクは無効になる)。
// ■ 招待メールは当選メールの送信ジョブ(sendJobs)とは別の用途で、この招待1件だけを直接送る(QR・添付なし)。

const crypto = require("node:crypto");
const {ApiError} = require("./api_error");
const {
  EVENT_ASSIGNMENTS_COLLECTION, ROLE_EVENT_MANAGER, ROLE_EVENT_STAFF, assignmentDocId, normalizeAssignment,
  isValidEventId, isAssignableRole, isValidUid, loadGlobalRole, getEventAccess,
} = require("../event_access");
const {normalizeEmail} = require("./assignment_api");

const EVENT_INVITATIONS_COLLECTION = "eventInvitations";
const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const INVITATION_ID_PATTERN = /^ei[0-9a-f]{64}$/;
const ROLE_ADMIN = "admin";
const ROLE_LABELS = {[ROLE_EVENT_MANAGER]: "イベント管理者", [ROLE_EVENT_STAFF]: "スタッフ"};
const DENIED_MESSAGE = "この操作を行う権限がありません。";

const invalid = (code) => new ApiError("invalid-argument", "入力が正しくありません。", {code});
const denied = (code) => new ApiError("permission-denied", DENIED_MESSAGE, {code});
const sha256 = (value) => crypto.createHash("sha256").update(value).digest("hex");

// 招待ドキュメントのID(1イベント・1メールアドレスにつき1件)。assignmentDocIdと同じく改行区切りのsha256で決定的に作る。
function invitationDocId(eventId, email) {
  if (!isValidEventId(eventId) || typeof email !== "string" || email === "") return null;
  return `ei${sha256(`event-invitation\n${eventId}\n${email}`)}`;
}

const generateToken = () => crypto.randomBytes(32).toString("base64url");
const hashToken = (token) => sha256(`event-invitation-token\n${token}`);

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("invalid-request");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unexpected-key");
  for (const key of allowed) if (data[key] === undefined) throw invalid(`missing-${key}`);
  return data;
}

const millisOf = (value) => {
  if (value && typeof value.toMillis === "function") return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return typeof value === "number" ? value : null;
};
const isoOf = (ms) => (ms === null ? null : new Date(ms).toISOString());

// 画面に出すメールアドレス(招待リンクを開いた人向け)。ローカル部の先頭2文字とドメインだけ。
function maskEmail(email) {
  const [local, domain] = String(email).split("@");
  if (!domain) return "";
  return `${local.slice(0, Math.min(2, local.length))}***@${domain}`;
}

function formatJst(ms) {
  return new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo", year: "numeric", month: "long", day: "numeric", hour: "2-digit", minute: "2-digit",
  }).format(new Date(ms));
}

// 招待メール(件名・本文はサーバーが決める。パスワードは書かない)。
function composeInvitationMail({eventName, role, url, expiresAtMs}) {
  const roleLabel = ROLE_LABELS[role];
  const subject = "JM Quickへのご招待";
  const text = [
    "JM Quickへ招待されました。",
    "",
    `イベント: ${eventName}`,
    `役割: ${roleLabel}`,
    "",
    "以下のリンクから初期設定(パスワードの設定)を行い、JM Quickへログインしてください。",
    url,
    "",
    `このリンクの有効期限: ${formatJst(expiresAtMs)}`,
    "",
    "このメールに心当たりがない場合は、何も操作する必要はありません(このメールは破棄してください)。",
    "",
    "JM Quick",
  ].join("\n");
  return {subject, text};
}

// getEventAccess/loadGlobalRoleの読み取りを同じtransactionへ参加させる。
function transactionReader(db, tx) {
  return {collection: (name) => ({doc: (id) => ({get: () => tx.get(db.collection(name).doc(id))})})};
}

function createInvitationApi({getDb, serverTimestamp, authAdmin, assignmentApi, getTransport, getAppBaseUrl, now = () => Date.now(), logger}) {
  const log = logger || console;
  for (const [name, fn] of Object.entries({
    findUserByEmail: authAdmin && authAdmin.findUserByEmail, getUser: authAdmin && authAdmin.getUser,
  })) {
    if (typeof fn !== "function") throw new Error(`createInvitationApi: authAdmin.${name} required`);
  }
  function assertScope(identity, eventId) {
    if (!identity || typeof identity.uid !== "string") throw denied("no-identity");
    if (identity.systemAdmin !== true && identity.eventId !== eventId) throw denied("event-scope-mismatch");
  }

  async function loadConfirmedEvent(db, eventId) {
    const snapshot = await db.collection("events").doc(eventId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。", {code: "event-not-found"});
    const event = snapshot.data() || {};
    if (event.flow !== "confirmed") {
      throw new ApiError("failed-precondition", "このイベントでは招待できません(新方式のイベントだけが対象です)。", {code: "event-not-confirmed"});
    }
    return event;
  }

  async function findByToken(db, token) {
    if (typeof token !== "string" || !TOKEN_PATTERN.test(token)) return null;
    const snapshot = await db.collection(EVENT_INVITATIONS_COLLECTION).where("tokenHash", "==", hashToken(token)).limit(2).get();
    if (snapshot.size !== 1) return null;
    const doc = snapshot.docs[0];
    const data = doc.data() || {};
    // IDとフィールドの整合(正式な方式で作られた招待だけ)
    if (!INVITATION_ID_PATTERN.test(doc.id) || doc.id !== invitationDocId(data.eventId, data.email) || !isAssignableRole(data.role)) return null;
    return {id: doc.id, ref: doc.ref, data};
  }

  // 招待の状態。受諾ではtransaction内の最新snapshotで再判定する。
  async function stateOf(db, invitation) {
    if (invitation.data.status === "accepted") return "accepted";
    if (invitation.data.status === "revoked") return "revoked";
    if (invitation.data.status !== "pending") return "invalid";
    const expires = millisOf(invitation.data.expiresAt);
    if (expires === null || expires <= now()) return "expired";
    return "pending";
  }

  // ---- 招待(未登録なら招待メール、登録済みなら即任命) ----------------------------------------------------------
  async function invite({identity, data, request}) {
    const input = parseKeys(data, ["eventId", "email", "role"]);
    if (!isValidEventId(input.eventId)) throw invalid("invalid-event-id");
    if (!isAssignableRole(input.role)) throw invalid("invalid-role");
    const email = normalizeEmail(input.email);
    if (!email) throw invalid("invalid-email");
    assertScope(identity, input.eventId);
    if (identity.systemAdmin !== true && input.role !== ROLE_EVENT_STAFF) throw denied("manager-can-assign-staff-only");

    const db = getDb();
    const event = await loadConfirmedEvent(db, input.eventId);
    // 登録済み(Firebase Authに存在する)なら、招待ではなく従来どおりの任命(同じ確認をassignEventRoleの実装で行う)
    const existing = await authAdmin.findUserByEmail(email);
    if (existing && typeof existing.uid === "string") {
      const assigned = await assignmentApi.assign({identity, data: {eventId: input.eventId, email, role: input.role}, request});
      return {result: "assigned", eventId: assigned.eventId, email: assigned.email, role: assigned.role, changed: assigned.changed};
    }
    // 自分自身への招待は不可(招待者のメールアドレスはAuthの正本から)
    const inviter = await authAdmin.getUser(identity.uid);
    if (inviter && typeof inviter.email === "string" && inviter.email.trim().toLowerCase() === email) {
      throw new ApiError("failed-precondition", "自分自身の権限は変更できません。", {code: "self-assignment"});
    }

    const id = invitationDocId(input.eventId, email);
    const ref = db.collection(EVENT_INVITATIONS_COLLECTION).doc(id);
    const token = generateToken();
    const expiresAtMs = now() + INVITATION_TTL_MS;
    await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const current = snapshot.exists ? snapshot.data() || {} : null;
      // event_managerは、他の人のイベント管理者への招待を変更できない
      if (current && current.status === "pending" && current.role === ROLE_EVENT_MANAGER && identity.systemAdmin !== true) {
        throw denied("manager-cannot-change-manager");
      }
      const stamp = serverTimestamp();
      const cycleStarted = !current || current.status !== "pending";
      tx.set(ref, {
        eventId: input.eventId, email, role: input.role, status: "pending",
        tokenHash: hashToken(token), expiresAt: expiresAtMs,
        invitedBy: identity.uid, createdAt: cycleStarted ? stamp : (current.createdAt || stamp), updatedAt: stamp,
        acceptedAt: null, acceptedBy: null, revokedAt: null, revokedBy: null,
        mailStatus: "sending", sendCount: (current && Number.isInteger(current.sendCount) ? current.sendCount : 0) + 1,
      });
    });

    const url = `${String(getAppBaseUrl()).replace(/\/+$/, "")}/invite?token=${encodeURIComponent(token)}`;
    const mail = composeInvitationMail({eventName: String(event.eventName || "イベント"), role: input.role, url, expiresAtMs});
    let outcome;
    try {
      outcome = await getTransport().send({
        to: email, senderName: "JM Quick", subject: mail.subject, text: mail.text,
        metadata: {app: "jm-quick", type: "event-invitation", invitationId: id},
      });
    } catch (error) {
      outcome = {outcome: "unknown", errorCode: "transport-error"};
    }
    const mailStatus = outcome && outcome.outcome === "sent" ? "sent" : (outcome && outcome.outcome === "failed" ? "failed" : "unknown");
    // tokenHashが送信世代を識別する。遅れて完了した旧メールは新世代も取消/受諾済み状態も更新しない。
    await db.runTransaction(async (tx) => {
      const current = (await tx.get(ref)).data();
      if (current && current.status === "pending" && current.tokenHash === hashToken(token)) {
        tx.update(ref, {mailStatus, updatedAt: serverTimestamp()});
      }
    });
    log.info("event invitation", {eventId: input.eventId, role: input.role, by: identity.uid, mailStatus});
    if (mailStatus !== "sent") {
      throw new ApiError("unavailable", "招待メールを送信できませんでした。時間をおいて、もう一度招待してください。", {code: "invitation-mail-failed"});
    }
    return {result: "invited", eventId: input.eventId, email, role: input.role, expiresAt: isoOf(expiresAtMs)};
  }

  // ---- 招待の取消 ----------------------------------------------------------------------------------------
  async function revoke({identity, data}) {
    const input = parseKeys(data, ["eventId", "invitationId"]);
    if (!isValidEventId(input.eventId)) throw invalid("invalid-event-id");
    if (typeof input.invitationId !== "string" || !INVITATION_ID_PATTERN.test(input.invitationId)) throw invalid("invalid-invitation-id");
    assertScope(identity, input.eventId);
    const db = getDb();
    const ref = db.collection(EVENT_INVITATIONS_COLLECTION).doc(input.invitationId);
    const notFound = () => new ApiError("not-found", "招待が見つかりません。", {code: "invitation-not-found"});
    const result = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const current = snapshot.exists ? snapshot.data() || {} : null;
      if (!current || current.eventId !== input.eventId) throw notFound();
      if (identity.systemAdmin !== true && current.role !== ROLE_EVENT_STAFF) throw denied("manager-can-revoke-staff-only");
      if (current.status !== "pending") return {changed: false, status: current.status};
      tx.update(ref, {status: "revoked", revokedAt: serverTimestamp(), revokedBy: identity.uid, updatedAt: serverTimestamp()});
      return {changed: true, status: "revoked"};
    });
    log.info("event invitation revoked", {eventId: input.eventId, by: identity.uid, changed: result.changed});
    return {eventId: input.eventId, invitationId: input.invitationId, ...result};
  }

  // ---- 対象イベントの招待一覧(招待中・期限切れ。tokenのhash・招待者は返さない) --------------------------------
  async function listForEvent(db, eventId) {
    const snapshot = await db.collection(EVENT_INVITATIONS_COLLECTION).where("eventId", "==", eventId).get();
    const items = [];
    for (const doc of snapshot.docs) {
      const data = doc.data() || {};
      if (data.status !== "pending" || doc.id !== invitationDocId(data.eventId, data.email) || !isAssignableRole(data.role)) continue;
      const expires = millisOf(data.expiresAt);
      items.push({
        invitationId: doc.id, email: data.email, role: data.role,
        expiresAt: isoOf(expires), status: expires !== null && expires > now() ? "pending" : "expired",
        mailStatus: typeof data.mailStatus === "string" ? data.mailStatus : "unknown",
      });
    }
    return items.sort((a, b) => String(a.email).localeCompare(String(b.email)));
  }

  // ---- 招待リンクを開いた人向け(ログイン不要) ---------------------------------------------------------------
  async function getInvitation({data}) {
    const input = parseKeys(data, ["token"]);
    const db = getDb();
    const invitation = await findByToken(db, input.token);
    if (!invitation) return {status: "invalid"};
    const state = await stateOf(db, invitation);
    if (state !== "pending") return {status: state};
    const eventSnapshot = await db.collection("events").doc(invitation.data.eventId).get();
    const event = eventSnapshot.exists ? eventSnapshot.data() || {} : null;
    if (!event || event.flow !== "confirmed") return {status: "invalid"};
    const account = await authAdmin.findUserByEmail(invitation.data.email);
    return {
      status: "pending",
      eventName: String(event.eventName || ""),
      role: invitation.data.role,
      emailHint: maskEmail(invitation.data.email),
      email: invitation.data.email, // 有効な招待tokenを持つ本人の登録用。編集可能な入力値は受諾に使わない。
      expiresAt: isoOf(millisOf(invitation.data.expiresAt)),
      accountExists: Boolean(account && account.uid),
    };
  }

  // ---- ログインした本人が招待を受ける(ここで初めて任命を有効にする) ----------------------------------------------
  async function accept({identity, data}) {
    const input = parseKeys(data, ["token"]);
    const uid = identity && identity.uid;
    if (!isValidUid(uid)) throw denied("no-identity");
    const db = getDb();
    const invitation = await findByToken(db, input.token);
    if (!invitation) throw new ApiError("not-found", "招待を確認できませんでした。", {code: "invitation-invalid"});
    // AuthはFirestore transactionには含められない。本人のメールはAdmin SDKの正本で取得する。
    const user = await authAdmin.getUser(uid);
    const userEmail = user && !user.disabled && typeof user.email === "string" ? user.email.trim().toLowerCase() : null;
    const result = await db.runTransaction(async (tx) => {
      const invitationSnapshot = await tx.get(invitation.ref);
      const current = invitationSnapshot.data() || {};
      if (current.tokenHash !== hashToken(input.token) ||
          invitationSnapshot.id !== invitationDocId(current.eventId, current.email) ||
          !isAssignableRole(current.role) || !isValidUid(current.invitedBy)) {
        throw new ApiError("failed-precondition", "この招待は利用できません。", {code: "invitation-changed"});
      }
      const state = await stateOf(db, {data: current});
      if (state !== "pending") throw new ApiError("failed-precondition", "この招待は利用できません。", {code: `invitation-${state}`});
      const {eventId, role, email, invitedBy} = current;
      if (userEmail !== email) throw new ApiError("permission-denied", "招待されたメールアドレスでログインしてください。", {code: "invitation-email-mismatch"});
      // 既存の権限helperにtransactionのreadを渡す。権限解除・イベント変更と同時なら再試行して再評価する。
      const reader = transactionReader(db, tx);
      if ((await loadGlobalRole(reader, uid)) === ROLE_ADMIN) {
        throw new ApiError("failed-precondition", "システム管理者はイベントごとの任命が不要です。", {code: "target-is-system-admin"});
      }
      const inviterRank = (await getEventAccess(reader, invitedBy, eventId)).rank;
      if (inviterRank < (role === ROLE_EVENT_MANAGER ? 3 : 2)) {
        throw new ApiError("failed-precondition", "この招待は利用できません。", {code: "invitation-inviter-inactive"});
      }
      const event = await loadConfirmedEvent(reader, eventId);
      const assignmentId = assignmentDocId(eventId, uid);
      const assignmentRef = db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(assignmentId);
      const assignmentSnapshot = await tx.get(assignmentRef);
      // read待ちの間に期限を越えた場合も書かない。transaction再試行でも時計を再評価する。
      if (millisOf(current.expiresAt) <= now()) {
        throw new ApiError("failed-precondition", "この招待は利用できません。", {code: "invitation-expired"});
      }
      const existing = assignmentSnapshot.exists ? normalizeAssignment(assignmentId, assignmentSnapshot.data()) : null;
      const stamp = serverTimestamp();
      // 既に有効なevent_managerなら、staffへの招待で降格しない
      const finalRole = existing && existing.active && existing.role === ROLE_EVENT_MANAGER ? ROLE_EVENT_MANAGER : role;
      if (existing) {
        tx.update(assignmentRef, {role: finalRole, active: true, email, updatedAt: stamp, updatedBy: invitedBy});
      } else {
        tx.create(assignmentRef, {
          eventId, uid, role: finalRole, active: true, email,
          assignedBy: invitedBy, assignedAt: stamp, updatedAt: stamp, updatedBy: invitedBy,
        });
      }
      tx.update(invitation.ref, {status: "accepted", acceptedAt: stamp, acceptedBy: uid, updatedAt: stamp});
      return {eventId, eventName: String(event.eventName || ""), role: finalRole};
    });
    log.info("event invitation accepted", {eventId: result.eventId, role: result.role});
    return result;
  }

  // listEventAssignments: 有効な任命(assignment_api)に、招待中の一覧を加える(同じ認可・同じイベント)。
  async function listAssignmentsWithInvitations(context) {
    const result = await assignmentApi.list(context);
    return {...result, invitations: await listForEvent(getDb(), result.eventId)};
  }

  return {invite, revoke, listForEvent, listAssignmentsWithInvitations, getInvitation, accept};
}

module.exports = {
  createInvitationApi, invitationDocId, hashToken, maskEmail, composeInvitationMail,
  EVENT_INVITATIONS_COLLECTION, INVITATION_TTL_MS, TOKEN_PATTERN,
};
