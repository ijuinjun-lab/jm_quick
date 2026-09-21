// 公開callableのrate limit(サーバー側で強制。クライアントのボタン無効化等は補助にすぎない)。Phase 10D。
// このファイルはFirebaseに依存しない(Firestoreと時計とHMAC鍵は呼び出し側から注入する)。
//
// 方式: 固定時間窓のカウンタ。文書 rateLimits/{policy}_{識別子のHMAC}_{窓の番号} に count を持ち、Firestore transactionで
//   「読む → 上限未満なら+1して書く」を原子的に行う(同時リクエストでも上限を超えて成功しない。競合はFirestoreが再試行する)。
//   窓の境界をまたぐと最大で上限の2倍まで通り得る(固定窓の性質)。窓の番号はサーバー時刻から求める(クライアント時刻は使わない)。
// 個人情報: 保存するのは policy名・count・窓の開始/期限だけ。メール・氏名・publicId・participantId・IPの元値は保存せず、
//   識別子は HMAC-SHA256(鍵, "policy:scope:値") の先頭128bitだけを文書IDに使う(元値は復元できない)。ログにも元値・識別子を出さない。
// 制限超過は resource-exhausted(対象の存在を推測できる詳細・内部キーは返さない)。
// 保存先の障害時の方針は policy.onError("open" / "closed")。closedの場合は unavailable を返す(処理しない)。
const crypto = require("node:crypto");
const {ApiError} = require("./confirmed/api_error");

const COLLECTION = "rateLimits";
const EXHAUSTED_MESSAGE = "アクセスが集中しています。しばらく時間をおいて、もう一度お試しください。";
const UNAVAILABLE_MESSAGE = "ただいま処理できません。しばらく時間をおいて、もう一度お試しください。";

function createRateLimiter({getDb, getKey, now = () => Date.now(), retentionMs, logger}) {
  const log = logger || console;

  function subjectId(policy, value) {
    const key = getKey();
    if (typeof key !== "string" || key.length < 16) throw new Error("rate-limit-key-missing");
    return crypto.createHmac("sha256", key).update(`${policy.name}:${policy.scope}:${String(value)}`).digest("hex").slice(0, 32);
  }

  // 1つの識別子について、回数を数えて上限を確認する。超過なら ApiError(resource-exhausted)。
  async function check(policy, value) {
    const at = now();
    const window = Math.floor(at / policy.windowMs);
    let outcome;
    try {
      const db = getDb();
      const ref = db.collection(COLLECTION).doc(`${policy.name}_${subjectId(policy, value)}_${window}`);
      outcome = await db.runTransaction(async (tx) => {
        const snapshot = await tx.get(ref);
        const count = snapshot.exists && Number.isInteger(snapshot.data().count) ? snapshot.data().count : 0;
        if (count >= policy.limit) return {allowed: false};
        tx.set(ref, {
          policy: policy.name, count: count + 1, windowStart: new Date(window * policy.windowMs),
          expiresAt: new Date((window + 1) * policy.windowMs + retentionMs),
        });
        return {allowed: true};
      });
    } catch (error) {
      // 保存先の障害・鍵の未設定など。理由コードだけを残す(エラーオブジェクト全体・識別子は出さない)
      log.error("rate limit unavailable", {policy: policy.name, mode: policy.onError, reason: "storage-error"});
      if (policy.onError === "open") return;
      throw new ApiError("unavailable", UNAVAILABLE_MESSAGE);
    }
    if (!outcome.allowed) {
      log.warn("rate limit exceeded", {policy: policy.name});
      throw new ApiError("resource-exhausted", EXHAUSTED_MESSAGE);
    }
  }

  return {check};
}

// 接続元IP。Cloud Functions(Google Front End配下)ではX-Forwarded-Forの末尾がGFEの観測したクライアントIP(先頭側はクライアントが
// 偽装できる)。取得できないときは固定の値(全員で共有)になる。元値は保存・ログ出力しない(HMAC化して使う)。
function clientIpOf(request) {
  const raw = request && request.rawRequest;
  if (!raw) return "unknown";
  const header = raw.headers && (raw.headers["x-forwarded-for"] || raw.headers["X-Forwarded-For"]);
  if (typeof header === "string" && header.trim() !== "") {
    const parts = header.split(",").map((part) => part.trim()).filter(Boolean);
    if (parts.length > 0) return parts[parts.length - 1];
  }
  return typeof raw.ip === "string" && raw.ip !== "" ? raw.ip : "unknown";
}

module.exports = {createRateLimiter, clientIpOf, COLLECTION, EXHAUSTED_MESSAGE, UNAVAILABLE_MESSAGE};
