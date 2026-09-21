// 新方式(flow=confirmed)の管理機能を保護する認証・権限基盤。
//
// 認可の正本は「Firebase Auth の UID → Firestore accessRoles/{uid}」であり、次の3点をすべて満たしたときだけ権限を与える:
//   1. Firebase Authでログイン済み(callableのrequest.auth.uid。ランタイムがIDトークンを検証して設定する)
//   2. accessRoles/{uid} が存在し、active === true(真偽値のtrueのみ。文字列"true"などは無効)
//   3. role が 'admin' または 'staff'(それ以外の値は無効)
//
// 信用しないもの:
//   - リクエスト本文(request.data)のuid・role・email(認可の判定では本文を一切読まない。ハンドラへは信用できない入力としてそのまま渡すだけ)
//   - IDトークン内のemail・カスタムクレーム(emailは認可キーにしない。roleもトークンからは取らない)
//   - クライアントSDKからのaccessRolesの読み書き(Rulesで全拒否。Admin SDK(このモジュール)だけが読む)
//
// 拒否の理由(未登録・無効・不明なrole)は、呼び出し側には常に同じ応答を返し(権限の有無を推測させない)、
// 詳細はサーバーログにだけ残す。
//
// 新方式の管理系callableは、必ず confirmedCallable() で定義する。アクセスレベルを指定しないと定義自体が失敗し、
// 認可を通らないハンドラは公開できない(functions/test/confirmed_callable_structure.test.js が構造を検査する)。

const {onCall, HttpsError} = require("firebase-functions/v2/https");

const ROLE_ADMIN = "admin";
const ROLE_STAFF = "staff";
const ACCESS_ROLES_COLLECTION = "accessRoles";
const ACCESS_LEVELS = Object.freeze({
  authenticated: "authenticated",
  staffOrAdmin: "staffOrAdmin",
  admin: "admin",
});
// Firebase UIDは英数字が基本。文書パスを壊す文字(/ など)を含むUIDでは、Firestoreを読む前に拒否する。
const UID_PATTERN = /^[A-Za-z0-9:_.-]{1,128}$/;
const DENIED_MESSAGE = "この操作を行う権限がありません。";

function unauthenticated() {
  return new HttpsError("unauthenticated", "ログインが必要です。");
}

function denied(logger, uid, reason) {
  (logger || console).warn("access denied", {uid: typeof uid === "string" ? uid.slice(0, 128) : null, reason});
  return new HttpsError("permission-denied", DENIED_MESSAGE);
}

function defaultDb() {
  // テストでFirebaseへ接続しないよう、必要になるまで読み込まない。
  return require("firebase-admin/firestore").getFirestore();
}

// ログイン済みであること。UIDはrequest.auth(検証済みIDトークン由来)からのみ取得する。
function requireAuthenticated(request) {
  const uid = request && request.auth && request.auth.uid;
  if (typeof uid !== "string" || uid === "") throw unauthenticated();
  return {uid};
}

// accessRoles/{uid} を読み、{uid, role} を返す。権限なしはpermission-denied。
async function loadAccessRole(request, {db, logger} = {}) {
  const {uid} = requireAuthenticated(request);
  if (!UID_PATTERN.test(uid)) throw denied(logger, uid, "invalid-uid-format");
  const snapshot = await (db || defaultDb()).collection(ACCESS_ROLES_COLLECTION).doc(uid).get();
  if (!snapshot.exists) throw denied(logger, uid, "no-access-role");
  const data = snapshot.data() || {};
  if (data.active !== true) throw denied(logger, uid, "inactive");
  if (data.role !== ROLE_ADMIN && data.role !== ROLE_STAFF) throw denied(logger, uid, "unknown-role");
  return {uid, role: data.role};
}

// staff または admin。adminはstaffの操作を包含する。
async function requireStaffOrAdmin(request, options) {
  return loadAccessRole(request, options);
}

// admin のみ。staffはadminの操作を実行できない。
async function requireAdmin(request, options) {
  const identity = await loadAccessRole(request, options);
  if (identity.role !== ROLE_ADMIN) throw denied(options && options.logger, identity.uid, "admin-required");
  return identity;
}

const GUARDS = {
  [ACCESS_LEVELS.authenticated]: async (request) => requireAuthenticated(request),
  [ACCESS_LEVELS.staffOrAdmin]: requireStaffOrAdmin,
  [ACCESS_LEVELS.admin]: requireAdmin,
};

// 新方式のcallableを定義する入口は、この defineCallable(=onCall)ただ1か所。
// 公開の入口は2種類だけ: confirmedCallable(認可つき) と confirmedPublicPassCallable(参加証の閲覧専用)。
// どちらも「認可(guard)がハンドラより前に実行される」構造を共有する。
function defineCallable(guard, handler, options) {
  const {db, logger, ...callableOptions} = options;
  return onCall({region: "asia-northeast1", timeoutSeconds: 60, ...callableOptions}, async (request) => {
    const identity = await guard(request, {db, logger});
    try {
      return await handler({identity, data: request.data, request});
    } catch (error) {
      // ハンドラが投げた「想定内のエラー」(ApiError)だけを、そのコードでクライアントへ返す。それ以外は内部エラー扱い。
      if (error && error.isApiError === true) throw new HttpsError(error.code, error.message, error.details);
      throw error;
    }
  });
}

// 新方式の管理系callableを定義する入口。
//   access: 'admin' | 'staffOrAdmin' | 'authenticated'(必須。未指定・不正なら定義時に例外)
//   handler({identity, data, request}): identityは認可を通過した「サーバー側で確定したuid/role」。
//     dataは信用できないクライアント入力(検証はハンドラの責務)。認可はdataの内容に一切依存しない。
function confirmedCallable(access, handler, options = {}) {
  const guard = Object.prototype.hasOwnProperty.call(GUARDS, access) ? GUARDS[access] : null;
  if (!guard) throw new Error(`confirmedCallable: invalid access level: ${String(access)}`);
  if (typeof handler !== "function") throw new Error("confirmedCallable: handler required");
  return defineCallable(guard, handler, options);
}

// 参加者本人が「ログインなしで、自分のWeb参加証を閲覧する」ためだけの公開callable。
// ここでの「公開」は、管理系の認可(staff/admin)を要求しないという意味に限る。閲覧の可否はハンドラが
// participantId+publicId の組で判定する(publicIdは閲覧用の秘密トークンで、受付・変更の権限ではない)。
// このcallableは読み取り専用でなければならない(書込みをするハンドラを渡してはならない)。
// Phase 10のTODO: 実データ投入前に App Check の強制(enforceAppCheck)とrate limitを有効にする。
//   - App Check: PUBLIC_PASS_CALLABLE_OPTIONS.enforceAppCheck を true にする(この公開callableだけに適用される)
//   - rate limit: createPassApi の checkRateLimit フックに実装を渡す
const PUBLIC_PASS_CALLABLE_OPTIONS = Object.freeze({
  timeoutSeconds: 30,
  maxInstances: 10, // 大量アクセスによる課金・負荷の上限(App Check導入までの暫定の歯止め)
  enforceAppCheck: false,
});
function confirmedPublicPassCallable(handler, options = {}) {
  if (typeof handler !== "function") throw new Error("confirmedPublicPassCallable: handler required");
  return defineCallable(async () => null, handler, {...PUBLIC_PASS_CALLABLE_OPTIONS, ...options});
}

module.exports = {
  ROLE_ADMIN,
  ROLE_STAFF,
  ACCESS_ROLES_COLLECTION,
  ACCESS_LEVELS,
  UID_PATTERN,
  requireAuthenticated,
  requireStaffOrAdmin,
  requireAdmin,
  confirmedCallable,
  confirmedPublicPassCallable,
  PUBLIC_PASS_CALLABLE_OPTIONS,
};
