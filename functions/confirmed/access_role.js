// getMyAccessRole: ログイン中のユーザー自身の権限を返す認証callableのハンドラ。副作用はない(読み取りのみ)。
//
// 返す値(Phase 1Aで拡張。従来のキーはそのまま):
//   authenticated: true
//   role:        accessRolesの有効な全体role("admin"|"staff")。無ければnull(従来のクライアントは権限なしとして扱う)
//   systemAdmin: role === "admin"(既存のadminが概念上のsystem_admin)
//   assignments: 有効なイベント単位の権限 [{eventId, role("event_manager"|"staff")}]。本人の分だけ
// uid・メールアドレス・任命者など不要な情報は返さない。
//
// ■ 認可: confirmedCallable("authenticated")でログイン済みだけを確認し、権限の有無はこのハンドラがFirestoreの正本で判定する。
//   イベント単位の権限だけを持つユーザー(accessRolesなし)も自分の権限を確認できるようにするため。
//   全体roleもイベント単位の権限も無い(accessRolesなし・active=false・未知のrole、かつ有効なassignmentなし)場合は、
//   従来と同じpermission-deniedを返す(理由は応答に含めず、サーバーログにだけ残す)。
// ■ 従来のクライアント(role=admin/staffで画面を出し分ける)との互換: admin・staffのroleは従来どおり返る。
//   イベント単位の権限だけのユーザーはrole=nullで、従来のクライアントでは権限なしの表示のまま(新しい情報はまだ使わない)。

const {ApiError} = require("./api_error");
const {getAccessSummary, isValidUid} = require("../event_access");

const DENIED_MESSAGE = "この操作を行う権限がありません。";

function createGetMyAccessRoleHandler({getDb, logger}) {
  const log = logger || console;
  return async function getMyAccessRoleHandler({identity}) {
    const uid = identity && identity.uid;
    if (!isValidUid(uid)) {
      log.warn("access denied", {uid: typeof uid === "string" ? uid.slice(0, 128) : null, reason: "invalid-uid-format"});
      throw new ApiError("permission-denied", DENIED_MESSAGE);
    }
    const summary = await getAccessSummary(getDb(), uid);
    if (summary.globalRole === null && summary.assignments.length === 0) {
      log.warn("access denied", {uid, reason: "no-access"});
      throw new ApiError("permission-denied", DENIED_MESSAGE);
    }
    return {
      authenticated: true,
      role: summary.globalRole,
      systemAdmin: summary.systemAdmin,
      assignments: summary.assignments,
    };
  };
}

module.exports = {createGetMyAccessRoleHandler};
