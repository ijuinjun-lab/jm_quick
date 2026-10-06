// 受付スタッフ用QRの「受付キー」(アカウントを持たない受付スタッフの端末に、1イベントの受付だけを許可する)。
//
//   issue        … 正式ログインした対象イベントのstaff以上(PCの「受付」画面)が、受付スタッフ用QRに載せる受付キーを取得する。
//                  有効なキーがあればそれを返し(同じQRを何度でも・何台でも表示できる)、無い・期限切れなら新しく作る。
//   verify       … 受付キーつきcallable(auth.jsのconfirmedReceptionKeyCallable)が、ハンドラより前にサーバー側で検証する。
//   getSession   … 受付端末がQRを読んだ直後に、キーの有効性とイベント名・有効期限だけを確認する(参加者情報は返さない)。
//
// ■ 受付キーで許可するのは「対象イベントの受付(受付画面の表示・初回受付)」だけ。訂正・取消・管理機能・他イベントには使えない
//   (index.jsで、受付キーのcallableに渡すハンドラを固定している。構造テストで検査)。
// ■ キーはFirebase ID token・管理者のセッション・パスワード・Secretではなく、このイベント専用の32バイト乱数(base64url)。
//   正本は receptionStaffKeys/{eventId}(Admin SDKのみ。Rulesでクライアントからのread/writeは全拒否)。
//   PCで同じQRを再表示するため、キー本体をこの非公開ドキュメントに保存する(参加者のpublicIdと同じ扱い)。
// ■ one-time tokenではない: 検証は読み取りだけで、複数端末が同じキーで同時に受付できる。
// ■ 有効期限は発行から24時間(当日の受付業務の間は同じ端末で継続利用できる)。期限切れ後にPCで「受付」を開くと新しいキーになる。
// ■ このファイルはFirebaseに依存しない(getDb・serverTimestamp・nowを注入する)。

const crypto = require("node:crypto");
const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");

// 既存のeventIdの形式(pass_api.js等と同じ)。
const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const isValidEventId = (eventId) => typeof eventId === "string" && EVENT_ID_PATTERN.test(eventId);
const RECEPTION_STAFF_KEYS_COLLECTION = "receptionStaffKeys";
const RECEPTION_KEY_TTL_MS = 24 * 60 * 60 * 1000;
const RECEPTION_KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;
// 受付履歴(checkedInBy・changedBy)に残す、受付キー経由の操作者の表記。キー本体は残さず、キーごとの非秘密のIDだけを記録する。
const RECEPTION_KEY_ACTOR_PREFIX = "reception-key:";

const generateKey = () => crypto.randomBytes(32).toString("base64url");
const generateKeyId = () => `rk_${crypto.randomBytes(8).toString("hex")}`;
const isValidReceptionKey = (key) => typeof key === "string" && RECEPTION_KEY_PATTERN.test(key);

function safeEqual(left, right) {
  const a = Buffer.from(String(left));
  const b = Buffer.from(String(right));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// 保存されたキーが「このイベントの、期限内の、形式が正しいキー」か。
function isLiveKey(stored, eventId, nowMs) {
  return Boolean(stored) && stored.eventId === eventId && isValidReceptionKey(stored.key) &&
    typeof stored.keyId === "string" && Number.isInteger(stored.expiresAt) && stored.expiresAt > nowMs;
}

// 受付キーを検証する。有効なら {eventId, keyId, expiresAt}、それ以外(形式不正・存在しない・不一致・期限切れ)はnull。
async function verifyReceptionKey(db, {eventId, key}, {now = () => Date.now()} = {}) {
  if (!isValidEventId(eventId) || !isValidReceptionKey(key)) return null;
  const snapshot = await db.collection(RECEPTION_STAFF_KEYS_COLLECTION).doc(eventId).get();
  const stored = snapshot.exists ? snapshot.data() : null;
  if (!isLiveKey(stored, eventId, now())) return null;
  if (!safeEqual(stored.key, key)) return null;
  return {eventId, keyId: stored.keyId, expiresAt: stored.expiresAt};
}

const parseKeys = (data, keys) => {
  if (data === null || typeof data !== "object" || Array.isArray(data)) return null;
  if (Object.keys(data).some((key) => !keys.includes(key))) return null;
  return data;
};
const invalid = () => new ApiError("invalid-argument", "リクエストが不正です。", {code: "invalid-input"});
const optionalText = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null);

function createReceptionKeyApi({getDb, serverTimestamp, now = () => Date.now()}) {
  // ---- PC(正式ログインしたstaff以上)が受付スタッフ用QRのキーを取得する -----------------------------------------
  async function issue({identity, data}) {
    const input = parseKeys(data, ["eventId"]);
    if (!input || !isValidEventId(input.eventId)) throw invalid();
    const db = getDb();
    const eventRef = db.collection("events").doc(input.eventId);
    const keyRef = db.collection(RECEPTION_STAFF_KEYS_COLLECTION).doc(input.eventId);
    // 同時に複数のPCで「受付」を開いても、有効なキーは1つだけ(transactionで作る)。
    return db.runTransaction(async (tx) => {
      const event = await tx.get(eventRef);
      if (!event.exists || !isConfirmedFlow(event.data())) {
        throw new ApiError("failed-precondition", "このイベントでは受付スタッフ用QRを利用できません。", {code: "event-not-confirmed"});
      }
      const nowMs = now();
      const current = await tx.get(keyRef);
      const stored = current.exists ? current.data() : null;
      if (isLiveKey(stored, input.eventId, nowMs)) return {eventId: input.eventId, key: stored.key, expiresAt: stored.expiresAt};
      const created = {eventId: input.eventId, key: generateKey(), keyId: generateKeyId(), expiresAt: nowMs + RECEPTION_KEY_TTL_MS};
      tx.set(keyRef, {...created, issuedBy: identity.uid, issuedAt: serverTimestamp()});
      return {eventId: input.eventId, key: created.key, expiresAt: created.expiresAt};
    });
  }

  // ---- 受付端末: QRを読んだ直後の確認(キーはguardで検証済み。イベント名と有効期限だけを返す) ----------------------------
  async function getSession({identity, data}) {
    const input = parseKeys(data, ["eventId"]);
    if (!input || input.eventId !== identity.eventId) throw invalid();
    const event = await getDb().collection("events").doc(identity.eventId).get();
    if (!event.exists || !isConfirmedFlow(event.data())) {
      throw new ApiError("failed-precondition", "このイベントの受付はできません。", {code: "event-not-confirmed"});
    }
    return {eventId: identity.eventId, eventName: optionalText(event.data().eventName) || "", expiresAt: identity.expiresAt};
  }

  return {issue, getSession};
}

module.exports = {
  createReceptionKeyApi,
  verifyReceptionKey,
  isValidReceptionKey,
  RECEPTION_STAFF_KEYS_COLLECTION,
  RECEPTION_KEY_TTL_MS,
  RECEPTION_KEY_PATTERN,
  RECEPTION_KEY_ACTOR_PREFIX,
};
