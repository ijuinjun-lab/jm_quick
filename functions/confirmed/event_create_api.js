// 新方式(flow=confirmed)のイベントを、adminが正式に作成するAPI(admin専用callableのハンドラ)。Phase 11A。
// 認可(admin)は index.js の confirmedCallable("admin", ...) が済ませており、identity はサーバー側で確定したuid。
//
// ■ 作成するのは event ドキュメント1件だけ。メールに関わるもの(winnerMailTemplate・reminderMailTemplate・reminderSendAt・
//   sendJobs・mailDeliveries・mailLogs)は一切作らない。reminderEnabled は false で始める(作成しただけでは何も自動実行されない)。
//   winnerMailTemplate は「未設定」のまま(当選メール設定の既存経路 updateConfirmedWinnerMailTemplate で後から作る)。
// ■ flow は入力として受け取らず、サーバーが "confirmed" に固定する。eventId・createdBy・updatedBy もクライアントから受け取らない
//   (createdBy/updatedBy は認証UID)。想定外のキーは拒否する。
// ■ 冪等性: クライアントが生成する requestId(個人情報を含まない)と管理者UIDから eventId をサーバーが決定的に導出する(sha256)。
//   同じ要求の再試行(二重クリック・応答消失後の再送・同時実行)は同じ eventId になり、create は1回しか成功しない。
//     - 同じ requestId + 同じ内容 → 既存のイベントをそのまま返す(created:false)。何も書き換えない
//     - 同じ requestId + 異なる内容 → 拒否(already-exists / request-id-conflict)。既存のイベントは変更しない
//   create のみ(set/merge/update は使わない)なので、既存のイベント(legacy・confirmedとも)を上書き・変換することはない。
// ■ programは programs.js の validateProgram(programId・name・order・時間・note)を再利用し、programIdは任意の安全な文字列
//   (固有名のハードコードなし)。表示順の正本は order(未指定なら入力順)。programIdの重複・orderの重複は拒否する。

const crypto = require("node:crypto");
const {ApiError} = require("./api_error");
const {validateVenueInfo} = require("./winner_mail_template");
const {isValidProgramId, validateProgram} = require("../programs");

const REQUEST_ID_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const CONTROL_CHARS = /[\u0000-\u001F\u007F]/;
const LIMITS = Object.freeze({eventName: 200, venue: 300, senderName: 100, contact: 500, programName: 100, programNote: 500, programs: 30});
const TOP_KEYS = ["requestId", "eventName", "startAt", "endAt", "venue", "address", "access", "senderName", "contact", "programs"];
const PROGRAM_KEYS = ["programId", "name", "order", "startAt", "endAt", "note"];

const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});

function keysOf(value, allowed, path) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw invalid("not-object", {path});
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw invalid("unknown-key", {path: path ? `${path}.${key}` : key});
}

function text(value, {name, max, required, singleLine = true}) {
  if (value === undefined || value === null) {
    if (required) throw invalid("required", {path: name});
    return null;
  }
  if (typeof value !== "string") throw invalid("invalid-type", {path: name});
  const trimmed = value.trim();
  if (trimmed === "") {
    if (required) throw invalid("required", {path: name});
    return null;
  }
  if (trimmed.length > max) throw invalid("too-long", {path: name});
  if (singleLine ? CONTROL_CHARS.test(trimmed) : /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(trimmed)) throw invalid("invalid-character", {path: name});
  return trimmed;
}

// ISO 8601(オフセット付き)の文字列だけを受け付ける。
function date(value, name, {required}) {
  if (value === undefined || value === null || value === "") {
    if (required) throw invalid("required", {path: name});
    return null;
  }
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/.test(value)) throw invalid("invalid-date", {path: name});
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) throw invalid("invalid-date", {path: name});
  // 存在しない日付・時刻(2月30日・25時など)は、JavaScriptが繰り上げて解釈してしまうため、暦として成立するかを別に確認する
  const [, y, mo, d, h, mi] = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(value).map(Number);
  const calendar = new Date(Date.UTC(y, mo - 1, d));
  if (calendar.getUTCFullYear() !== y || calendar.getUTCMonth() !== mo - 1 || calendar.getUTCDate() !== d || h > 23 || mi > 59) throw invalid("invalid-date", {path: name});
  return parsed;
}

function parsePrograms(input) {
  if (!Array.isArray(input) || input.length === 0) throw invalid("programs-required", {path: "programs"});
  if (input.length > LIMITS.programs) throw invalid("too-many-programs", {path: "programs"});
  const seenIds = new Set();
  const seenOrders = new Set();
  return input.map((raw, index) => {
    const path = `programs[${index}]`;
    keysOf(raw, PROGRAM_KEYS, path);
    if (!isValidProgramId(raw.programId)) throw invalid("invalid-program-id", {path: `${path}.programId`});
    if (seenIds.has(raw.programId)) throw invalid("duplicate-program-id", {path: `${path}.programId`});
    seenIds.add(raw.programId);
    const name = text(raw.name, {name: `${path}.name`, max: LIMITS.programName, required: true});
    const order = raw.order === undefined || raw.order === null ? index : raw.order;
    if (!Number.isInteger(order) || order < 0 || order > 9999) throw invalid("invalid-order", {path: `${path}.order`});
    if (seenOrders.has(order)) throw invalid("duplicate-order", {path: `${path}.order`});
    seenOrders.add(order);
    const startAt = date(raw.startAt, `${path}.startAt`, {required: false});
    const endAt = date(raw.endAt, `${path}.endAt`, {required: false});
    const note = text(raw.note, {name: `${path}.note`, max: LIMITS.programNote, required: false, singleLine: false});
    const errors = validateProgram({programId: raw.programId, name, order, startAt, endAt, note});
    if (errors.length > 0) throw invalid("invalid-program", {path, errors});
    return {programId: raw.programId, name, order, ...(startAt ? {startAt} : {}), ...(endAt ? {endAt} : {}), ...(note ? {note} : {})};
  });
}

// 入力を検証・正規化する。{requestId, event(保存する内容の一部), fingerprint}
function parseCreateRequest(data, now = Date.now()) {
  keysOf(data, TOP_KEYS, "");
  if (typeof data.requestId !== "string" || !REQUEST_ID_PATTERN.test(data.requestId)) throw invalid("invalid-request-id", {path: "requestId"});
  const eventName = text(data.eventName, {name: "eventName", max: LIMITS.eventName, required: true});
  const startAt = date(data.startAt, "startAt", {required: true});
  const endAt = date(data.endAt, "endAt", {required: false});
  if (startAt.getTime() <= now) throw invalid("start-in-past", {path: "startAt"});
  if (endAt && endAt.getTime() <= startAt.getTime()) throw invalid("invalid-time-range", {path: "endAt"});
  const venue = text(data.venue, {name: "venue", max: LIMITS.venue, required: true});
  const venueInfo = validateVenueInfo({address: data.address, access: data.access});
  if (!venueInfo.ok) throw invalid("invalid-venue-info", {errors: venueInfo.errors});
  const senderName = text(data.senderName, {name: "senderName", max: LIMITS.senderName, required: false});
  const contact = text(data.contact, {name: "contact", max: LIMITS.contact, required: false, singleLine: false});
  const programs = parsePrograms(data.programs);
  const event = {eventName, startAt, endAt, venue, venueInfo: venueInfo.value, senderName, contact, programs};
  // 同じ内容かどうかの判定用(再試行の見分け)。個人情報は含まれない
  const canonical = JSON.stringify({
    eventName, startAt: startAt.getTime(), endAt: endAt ? endAt.getTime() : null, venue, address: venueInfo.value.address, access: venueInfo.value.access,
    senderName, contact,
    programs: programs.map((p) => [p.programId, p.name, p.order, p.startAt ? p.startAt.getTime() : null, p.endAt ? p.endAt.getTime() : null, p.note || null]),
  });
  return {requestId: data.requestId, event, fingerprint: crypto.createHash("sha256").update(canonical).digest("hex")};
}

// 管理者のUIDと requestId から決定的に導出する(Firestoreのdocument IDとして安全な英小文字・数字のみ)。
function deriveEventId(uid, requestId) {
  return `ev${crypto.createHash("sha256").update(`confirmed-event\n${uid}\n${requestId}`).digest("hex").slice(0, 30)}`;
}

function createEventCreateApi({getDb, serverTimestamp, logger, now = () => Date.now()}) {
  const log = logger || console;

  async function createEvent({identity, data}) {
    const request = parseCreateRequest(data, now());
    const eventId = deriveEventId(identity.uid, request.requestId);
    const db = getDb();
    const ref = db.collection("events").doc(eventId);
    const outcome = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      if (snapshot.exists) {
        const existing = snapshot.data();
        // 同じ要求(同じ管理者・同じrequestId・同じ内容)の再試行だけを、成功として扱う。既存のイベントは変更しない
        if (existing && existing.flow === "confirmed" && existing.createdBy === identity.uid && existing.createRequestHash === request.fingerprint) {
          return {created: false, name: existing.eventName};
        }
        return {conflict: true};
      }
      const {event} = request;
      tx.create(ref, {
        eventId, flow: "confirmed", eventName: event.eventName, startAt: event.startAt, endAt: event.endAt,
        venue: event.venue, venueInfo: event.venueInfo,
        ...(event.senderName ? {senderName: event.senderName} : {}), ...(event.contact ? {contact: event.contact} : {}),
        programs: event.programs,
        // メールは動かさない: reminderは無効で始め、テンプレート・送信予定・ジョブは作らない
        reminderEnabled: false,
        createRequestHash: request.fingerprint,
        createdAt: serverTimestamp(), createdBy: identity.uid, updatedAt: serverTimestamp(), updatedBy: identity.uid,
      });
      return {created: true, name: event.eventName};
    });
    if (outcome.conflict) {
      log.warn("confirmed event create conflict", {reason: "request-id-conflict", uid: identity.uid});
      throw new ApiError("already-exists", "同じ作成要求IDで、異なる内容のイベントは作成できません。", {code: "request-id-conflict"});
    }
    log.info("confirmed event create", {eventId, created: outcome.created, uid: identity.uid});
    return {eventId, eventName: outcome.name, kind: "confirmed", created: outcome.created};
  }

  return {createEvent};
}

module.exports = {createEventCreateApi, parseCreateRequest, deriveEventId, LIMITS, REQUEST_ID_PATTERN};
