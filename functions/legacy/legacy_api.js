// 従来方式(legacy)の管理・受付・参加者本人向けAPI(Phase 10C)。旧Flutterが直接Firestoreを読み書きしていた経路を、
// 認証つき(または参加者capabilityつき)のサーバーAPIへ移したもの。Firestoreクライアントの直接read/writeはRulesで閉じる。
//
// ■ 認可の境界(index.jsで付与。このファイルはFirebaseに依存しない):
//     admin        : confirmedCallable("admin", …)        イベント・参加者の管理(一覧・詳細・作成・更新・参加者登録)
//     staffOrAdmin : confirmedCallable("staffOrAdmin", …) 受付(表示・実行・人数修正)。メールアドレスは返さない
//     参加者本人    : publicCapabilityCallable(…)          participantId + publicId(本人用の秘密トークン)をサーバーで照合。Firebase Authは要求しない
//   認可の根拠は request.auth.uid → accessRoles/{uid} だけ。bodyのrole・uid・emailは一切信用しない(auth.js)。
// ■ legacy判定はfail-closed: イベントが存在し、かつ flow が 未設定/null/空/"legacy" のときだけlegacy。イベント不存在(孤児)・confirmed・
//   未知のflow・型が不正な値は、すべて拒否する。confirmedのイベント・参加者・受付には一切書込まない(legacy専用API)。
// ■ 参加者capability APIは、存在しない・publicId不一致・イベント不一致・legacyでない・無効な状態を、すべて同じ応答にする(存在を推測させない)。
//   返すのは画面に必要な最小限の項目だけ(メールアドレス・内部状態・他の参加者の情報は返さない)。
// ■ ログには reason code・UID・eventId・participantId だけを出す(メール・publicId・本文は出さない)。

const crypto = require("node:crypto");
const {ApiError} = require("../confirmed/api_error");
const {isLegacyFlow} = require("../flow");

const ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const PARTICIPANT_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const PUBLIC_ID_PATTERN = /^pub_[A-Za-z0-9_-]{20,128}$/;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const CONTROL_CHARS = /[\u0000-\u001F\u007F]/;
const LIMITS = Object.freeze({
  eventName: 200, senderName: 100, venue: 300, contact: 500, name: 100, email: 254, furigana: 100,
  registeredCountMax: 999, walkInCountMax: 50, walkInNameMax: 60,
});
const UNAVAILABLE = "ページを確認できませんでした。";
const invalid = (code, extra) => new ApiError("invalid-argument", "リクエストが不正です。", {code, ...extra});

const toDate = (value) => {
  if (value === null || value === undefined) return null;
  const date = typeof value.toDate === "function" ? value.toDate() : value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
};
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };
const num = (value) => (Number.isInteger(value) ? value : 0);
const publicIdOk = (stored, given) => {
  if (typeof stored !== "string" || typeof given !== "string") return false;
  const a = Buffer.from(stored);
  const b = Buffer.from(given);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
};

function parseKeys(data, allowed, required = []) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("body-not-object");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unknown-key", {path: key});
  for (const key of required) if (data[key] === undefined) throw invalid("missing-key", {path: key});
  return data;
}
const eventIdOf = (data) => {
  if (typeof data.eventId !== "string" || !ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id");
  return data.eventId;
};

function text(value, {name, max, required = true, singleLine = true}) {
  if (value === undefined || value === null) {
    if (required) throw invalid("required", {path: name});
    return "";
  }
  if (typeof value !== "string") throw invalid("invalid-type", {path: name});
  const trimmed = value.trim();
  if (trimmed === "" && required) throw invalid("required", {path: name});
  if (trimmed.length > max) throw invalid("too-long", {path: name});
  if (singleLine ? CONTROL_CHARS.test(trimmed) : /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(trimmed)) throw invalid("invalid-character", {path: name});
  return trimmed;
}
function dateField(value, name, {required = true} = {}) {
  if (value === undefined || value === null) {
    if (required) throw invalid("required", {path: name});
    return null;
  }
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) throw invalid("invalid-date", {path: name});
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw invalid("invalid-date", {path: name});
  return date;
}
function emailField(value) {
  const email = text(value, {name: "email", max: LIMITS.email}).toLowerCase();
  if (!EMAIL_PATTERN.test(email)) throw invalid("invalid-email", {path: "email"});
  return email;
}
function countField(value, max, name = "registeredCount") {
  if (!Number.isInteger(value) || value < 1 || value > max) throw invalid("invalid-count", {path: name});
  return value;
}

// イベント設定(作成・更新で共通)。クライアントが決めてよいのはこれらの項目だけ(flow・eventId・作成者等は受け取らない)。
const EVENT_KEYS = ["eventName", "senderName", "startAt", "endAt", "venue", "registrationDeadline", "confirmationSendAt", "contact"];
function parseEventSettings(data) {
  const eventName = text(data.eventName, {name: "eventName", max: LIMITS.eventName});
  const startAt = dateField(data.startAt, "startAt");
  const endAt = dateField(data.endAt, "endAt", {required: false});
  if (endAt && endAt.getTime() <= startAt.getTime()) throw invalid("invalid-time-range", {path: "endAt"});
  return {
    eventName,
    senderName: text(data.senderName, {name: "senderName", max: LIMITS.senderName, required: false}),
    startAt, endAt,
    venue: text(data.venue, {name: "venue", max: LIMITS.venue, required: false}),
    registrationDeadline: dateField(data.registrationDeadline, "registrationDeadline"),
    confirmationSendAt: dateField(data.confirmationSendAt, "confirmationSendAt"),
    contact: text(data.contact, {name: "contact", max: LIMITS.contact, required: false, singleLine: false}),
  };
}

function createLegacyApi({getDb, serverTimestamp, logger, now = () => Date.now()}) {
  const log = logger || console;
  const dataOf = (snapshot) => (snapshot && snapshot.exists ? snapshot.data() : null);
  // legacyと明確に判定できるイベントだけ(イベントが存在し、flowが未設定/null/空/"legacy")
  const isLegacyEvent = (event) => Boolean(event) && isLegacyFlow(event);
  const notLegacy = (reason) => new ApiError("failed-precondition", "従来方式のイベントではないため、この操作はできません。", {code: reason});

  // ---- DTO ------------------------------------------------------------------------------------------
  const eventDto = (id, e) => ({
    eventId: id, flow: typeof e.flow === "string" ? e.flow : null, eventName: typeof e.eventName === "string" ? e.eventName : "",
    senderName: typeof e.senderName === "string" ? e.senderName : "", venue: typeof e.venue === "string" ? e.venue : "",
    contact: typeof e.contact === "string" ? e.contact : "", startAt: iso(e.startAt), endAt: iso(e.endAt),
    registrationDeadline: iso(e.registrationDeadline), confirmationSendAt: iso(e.confirmationSendAt), reconfirmEnabled: e.reconfirmEnabled === true,
  });
  // 管理者向けの参加者(管理業務に必要な項目。publicIdは管理者がマイページURLを案内するために含める)
  const adminParticipantDto = (id, p) => ({
    participantId: id, eventId: p.eventId, publicId: p.publicId, name: p.name, email: p.email,
    furiganaLastName: p.furiganaLastName || null, furiganaFirstName: p.furiganaFirstName || null,
    registeredCount: num(p.registeredCount), registrationType: p.registrationType || "preRegistered",
    invitationSent: p.invitationSent === true, invitationMailStatus: p.invitationMailStatus || null, invitationSentAt: iso(p.invitationSentAt),
    invitationMessageId: p.invitationMessageId || null, participationConfirmed: p.participationConfirmed === true,
    participationConfirmedAt: iso(p.participationConfirmedAt), reconfirmed: p.reconfirmed === true,
    attendanceResponse: p.attendanceResponse === "attending" || p.attendanceResponse === "notAttending" ? p.attendanceResponse : null,
    reconfirmationMailSent: p.reconfirmationMailSent === true, reconfirmedAt: iso(p.reconfirmedAt),
  });
  const checkInDto = (id, c) => ({
    participantId: c.participantId || id, eventId: c.eventId, checkedIn: c.checkedIn === true,
    attendedCount: Number.isInteger(c.attendedCount) ? c.attendedCount : null, checkedInAt: iso(c.checkedInAt), updatedAt: iso(c.updatedAt),
  });
  const jobDto = (id, j) => ({
    jobId: id, eventId: j.eventId, type: j.type, status: j.status, totalCount: num(j.totalCount), sentCount: num(j.sentCount),
    failedCount: num(j.failedCount), skippedCount: num(j.skippedCount),
  });

  // 「参加者の集計」(イベント一覧の表示用。旧画面がクライアントで計算していたものと同じ定義)
  function summarize(participants, checkIns) {
    const confirmedOnes = participants.filter((p) => p.participationConfirmed === true);
    const people = (list) => list.reduce((sum, p) => sum + num(p.registeredCount), 0);
    return {
      participantCount: participants.length,
      appliedCount: people(participants),
      registeredCount: confirmedOnes.length,
      formallyRegisteredCount: people(confirmedOnes),
      attendingCount: people(confirmedOnes.filter((p) => p.attendanceResponse === "attending")),
      notAttendingCount: people(confirmedOnes.filter((p) => p.attendanceResponse === "notAttending")),
      unansweredCount: people(confirmedOnes.filter((p) => p.attendanceResponse === undefined || p.attendanceResponse === null)),
      attendedCount: checkIns.filter((c) => c.checkedIn === true).reduce((sum, c) => sum + num(c.attendedCount), 0),
    };
  }

  // ---- 管理(admin) -----------------------------------------------------------------------------------
  // イベント一覧。legacyのイベントには集計を付ける。confirmed等には付けない(新方式は新しい管理画面を使う)。
  async function listEvents({data}) {
    parseKeys(data === undefined ? {} : data, []);
    const db = getDb();
    const events = (await db.collection("events").get()).docs;
    const result = [];
    for (const doc of events) {
      const e = doc.data();
      const dto = eventDto(doc.id, e);
      if (isLegacyEvent(e)) {
        const [participants, checkIns] = await Promise.all([
          db.collection("participants").where("eventId", "==", doc.id).get(),
          db.collection("checkIns").where("eventId", "==", doc.id).get(),
        ]);
        dto.summary = summarize(participants.docs.map((d) => d.data()), checkIns.docs.map((d) => d.data()));
      }
      result.push(dto);
    }
    return {events: result};
  }

  // イベント詳細(管理画面)。legacyなら参加者・受付・一括メールの進捗を返す。confirmed等は、イベント情報だけ(参加者は返さない)。
  async function getEventAdminView({data}) {
    const request = parseKeys(data, ["eventId"], ["eventId"]);
    const eventId = eventIdOf(request);
    const db = getDb();
    const event = dataOf(await db.collection("events").doc(eventId).get());
    if (!event) throw new ApiError("not-found", "イベントが見つかりません。");
    const dto = eventDto(eventId, event);
    if (!isLegacyEvent(event)) return {event: dto, legacy: false, participants: [], checkIns: [], jobs: {}};
    const [participants, checkIns, invitation, reconfirmation] = await Promise.all([
      db.collection("participants").where("eventId", "==", eventId).get(),
      db.collection("checkIns").where("eventId", "==", eventId).get(),
      db.collection("mailJobs").doc(`${eventId}_invitation`).get(),
      db.collection("mailJobs").doc(`${eventId}_reconfirmation`).get(),
    ]);
    return {
      event: dto, legacy: true,
      participants: participants.docs.map((d) => adminParticipantDto(d.id, d.data())),
      checkIns: checkIns.docs.map((d) => checkInDto(d.id, d.data())),
      jobs: {
        ...(invitation.exists ? {invitation: jobDto(invitation.id, invitation.data())} : {}),
        ...(reconfirmation.exists ? {reconfirmation: jobDto(reconfirmation.id, reconfirmation.data())} : {}),
      },
    };
  }

  async function createEvent({identity, data}) {
    const request = parseKeys(data, EVENT_KEYS, ["eventName", "startAt", "registrationDeadline", "confirmationSendAt"]);
    const s = parseEventSettings(request);
    const db = getDb();
    const ref = db.collection("events").doc();
    // flowは書かない(=従来方式)。confirmedイベントはこのAPIから作れない。
    await ref.set({
      eventId: ref.id, eventName: s.eventName, senderName: s.senderName, startAt: s.startAt, endAt: s.endAt, venue: s.venue,
      registrationDeadline: s.registrationDeadline, confirmationSendAt: s.confirmationSendAt, contact: s.contact,
      reconfirmEnabled: false, createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    });
    log.info("legacy event created", {eventId: ref.id, uid: identity.uid});
    return {eventId: ref.id};
  }

  // イベント設定の更新。legacyだけ。flow・eventIdは変更できない(受け取らない)。従来どおり reconfirmEnabled は false に戻る。
  async function updateEventSettings({identity, data}) {
    const request = parseKeys(data, ["eventId", ...EVENT_KEYS], ["eventId", "eventName", "startAt", "registrationDeadline", "confirmationSendAt"]);
    const eventId = eventIdOf(request);
    const s = parseEventSettings(request);
    const db = getDb();
    const ref = db.collection("events").doc(eventId);
    await db.runTransaction(async (tx) => {
      const event = dataOf(await tx.get(ref));
      if (!event) throw new ApiError("not-found", "イベントが見つかりません。");
      if (!isLegacyEvent(event)) throw notLegacy("event-not-legacy");
      tx.update(ref, {
        eventName: s.eventName, senderName: s.senderName, startAt: s.startAt, endAt: s.endAt, venue: s.venue,
        registrationDeadline: s.registrationDeadline, confirmationSendAt: s.confirmationSendAt, contact: s.contact,
        reconfirmEnabled: false, updatedAt: serverTimestamp(),
      });
    });
    log.info("legacy event updated", {eventId, uid: identity.uid});
    return {eventId};
  }

  // 参加者の手動登録(管理者)。participantId・publicIdはサーバーが生成する(クライアントは指定できない)。参加者と受付を同時に作る。
  async function createParticipant({identity, data}) {
    const request = parseKeys(data, ["eventId", "name", "email", "registeredCount", "registrationType", "furiganaLastName", "furiganaFirstName"],
      ["eventId", "name", "email", "registeredCount"]);
    const eventId = eventIdOf(request);
    const name = text(request.name, {name: "name", max: LIMITS.name});
    const email = emailField(request.email);
    const registeredCount = countField(request.registeredCount, LIMITS.registeredCountMax);
    const registrationType = request.registrationType === undefined ? "preRegistered" : request.registrationType;
    if (registrationType !== "preRegistered" && registrationType !== "walkIn") throw invalid("invalid-registration-type");
    const lastName = text(request.furiganaLastName, {name: "furiganaLastName", max: LIMITS.furigana, required: false});
    const firstName = text(request.furiganaFirstName, {name: "furiganaFirstName", max: LIMITS.furigana, required: false});
    const db = getDb();
    const ref = db.collection("participants").doc();
    const publicId = `pub_${crypto.randomBytes(24).toString("base64url")}`;
    const isWalkIn = registrationType === "walkIn";
    await db.runTransaction(async (tx) => {
      const event = dataOf(await tx.get(db.collection("events").doc(eventId)));
      if (!event) throw new ApiError("not-found", "イベントが見つかりません。");
      if (!isLegacyEvent(event)) throw notLegacy("event-not-legacy");
      tx.create(ref, {
        participantId: ref.id, eventId, publicId, name, email, registeredCount, registrationType,
        ...(lastName ? {furiganaLastName: lastName} : {}), ...(firstName ? {furiganaFirstName: firstName} : {}),
        invitationSent: false, invitationSentAt: null, participationConfirmed: isWalkIn,
        participationConfirmedAt: isWalkIn ? serverTimestamp() : null, reconfirmed: false, reconfirmedAt: null, attendanceResponse: null,
        reconfirmationMailSent: false, createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
      });
      tx.create(db.collection("checkIns").doc(ref.id), {
        participantId: ref.id, eventId, checkedIn: false, attendedCount: null, checkedInAt: null, updatedAt: serverTimestamp(),
      });
    });
    log.info("legacy participant created", {eventId, participantId: ref.id, uid: identity.uid});
    return {participant: adminParticipantDto(ref.id, dataOf(await ref.get()))};
  }

  // ---- 受付(staff / admin) ---------------------------------------------------------------------------
  // QRのeventId・participantId・publicIdを、サーバーで再検証して返す(legacyのイベントの、そのイベントの参加者だけ)。
  async function loadReceptionContext(db, reader, input) {
    const read = (ref) => (reader ? reader.get(ref) : ref.get());
    const participant = dataOf(await read(db.collection("participants").doc(input.participantId)));
    const event = dataOf(await read(db.collection("events").doc(input.eventId)));
    let problem = null;
    if (!participant) problem = "participant-missing";
    else if (!event) problem = "event-missing";
    else if (!isLegacyEvent(event)) problem = "event-not-legacy";
    else if (participant.eventId !== input.eventId) problem = "event-mismatch";
    else if (!publicIdOk(participant.publicId, input.publicId)) problem = "public-id-mismatch";
    else if (participant.schemaVersion !== undefined || (participant.status !== undefined && participant.status !== "active")) problem = "participant-not-legacy";
    return {problem, participant, event};
  }
  const receptionProblem = (reason) => new ApiError("failed-precondition", "この参加証は受付できません。", {code: reason});
  function parseReception(data, extra = []) {
    const request = parseKeys(data, ["eventId", "participantId", "publicId", ...extra], ["eventId", "participantId", "publicId"]);
    const eventId = eventIdOf(request);
    if (typeof request.participantId !== "string" || !PARTICIPANT_ID_PATTERN.test(request.participantId)) throw invalid("invalid-participant-id");
    if (typeof request.publicId !== "string" || !PUBLIC_ID_PATTERN.test(request.publicId)) throw invalid("invalid-public-id");
    return {request, input: {eventId, participantId: request.participantId, publicId: request.publicId}};
  }
  const receptionView = (event, participant, checkIn) => ({
    eventName: typeof event.eventName === "string" ? event.eventName : "", participantName: participant.name,
    registeredCount: num(participant.registeredCount), reconfirmed: participant.reconfirmed === true,
    checkedIn: Boolean(checkIn) && checkIn.checkedIn === true,
    attendedCount: checkIn && Number.isInteger(checkIn.attendedCount) ? checkIn.attendedCount : null, checkedInAt: checkIn ? iso(checkIn.checkedInAt) : null,
  });

  async function getReceptionView({identity, data}) {
    const {input} = parseReception(data);
    const db = getDb();
    const context = await loadReceptionContext(db, null, input);
    if (context.problem) {
      log.warn("legacy reception view denied", {reason: context.problem, uid: identity.uid, eventId: input.eventId});
      throw receptionProblem(context.problem);
    }
    const checkIn = dataOf(await db.collection("checkIns").doc(input.participantId).get());
    if (checkIn && checkIn.eventId !== input.eventId) throw receptionProblem("checkin-event-mismatch");
    return receptionView(context.event, context.participant, checkIn);
  }

  async function checkInParticipant({identity, data}) {
    const {request, input} = parseReception(data, ["attendedCount"]);
    if (!Number.isInteger(request.attendedCount) || request.attendedCount < 0 || request.attendedCount > LIMITS.registeredCountMax) throw invalid("invalid-attended-count");
    const db = getDb();
    const ref = db.collection("checkIns").doc(input.participantId);
    const outcome = await db.runTransaction(async (tx) => {
      const context = await loadReceptionContext(db, tx, input);
      const checkIn = dataOf(await tx.get(ref));
      if (context.problem) return {denied: context.problem};
      if (!checkIn || checkIn.eventId !== input.eventId) return {denied: "checkin-missing"};
      if (checkIn.checkedIn === true) return {alreadyCheckedIn: true};
      // 申込人数のスナップショットは、クライアントの値ではなくサーバーの参加者情報から取る
      tx.update(ref, {
        checkedIn: true, registeredCountSnapshot: num(context.participant.registeredCount), attendedCount: request.attendedCount,
        checkedInAt: serverTimestamp(), updatedAt: serverTimestamp(),
      });
      return {alreadyCheckedIn: false};
    });
    if (outcome.denied) {
      log.warn("legacy check-in denied", {reason: outcome.denied, uid: identity.uid, eventId: input.eventId});
      throw receptionProblem(outcome.denied);
    }
    const current = dataOf(await ref.get());
    return {alreadyCheckedIn: outcome.alreadyCheckedIn, checkIn: checkInDto(input.participantId, current)};
  }

  async function updateAttendedCount({identity, data}) {
    const {request, input} = parseReception(data, ["attendedCount"]);
    if (!Number.isInteger(request.attendedCount) || request.attendedCount < 0 || request.attendedCount > LIMITS.registeredCountMax) throw invalid("invalid-attended-count");
    const db = getDb();
    const ref = db.collection("checkIns").doc(input.participantId);
    const denied = await db.runTransaction(async (tx) => {
      const context = await loadReceptionContext(db, tx, input);
      const checkIn = dataOf(await tx.get(ref));
      if (context.problem) return context.problem;
      if (!checkIn || checkIn.eventId !== input.eventId) return "checkin-missing";
      if (checkIn.checkedIn !== true) return "not-checked-in"; // 未受付の人数を修正して受付済みにはしない
      tx.update(ref, {attendedCount: request.attendedCount, updatedAt: serverTimestamp()});
      return null;
    });
    if (denied) {
      log.warn("legacy attended-count update denied", {reason: denied, uid: identity.uid, eventId: input.eventId});
      throw receptionProblem(denied);
    }
    return {checkIn: checkInDto(input.participantId, dataOf(await ref.get()))};
  }

  // ---- 参加者本人(publicId capability。Firebase Authは要求しない) ----------------------------------------------
  const unavailable = () => new ApiError("not-found", UNAVAILABLE);
  function parseCapability(data, extra = []) {
    let request;
    try {
      request = parseKeys(data, ["participantId", "publicId", ...extra], ["participantId", "publicId"]);
    } catch (error) {
      throw unavailable();
    }
    if (typeof request.participantId !== "string" || !PARTICIPANT_ID_PATTERN.test(request.participantId) ||
        typeof request.publicId !== "string" || !PUBLIC_ID_PATTERN.test(request.publicId)) throw unavailable();
    return request;
  }
  // 参加者・イベントを検証する。無効な理由は内部ログにだけ残し、外部へは常に同じ応答(unavailable)にする。
  async function loadCapability(db, reader, request) {
    const read = (ref) => (reader ? reader.get(ref) : ref.get());
    const participant = dataOf(await read(db.collection("participants").doc(request.participantId)));
    const event = participant && typeof participant.eventId === "string" && ID_PATTERN.test(participant.eventId) ?
      dataOf(await read(db.collection("events").doc(participant.eventId))) : null;
    let reason = null;
    if (!participant) reason = "participant-missing";
    else if (!publicIdOk(participant.publicId, request.publicId)) reason = "public-id-mismatch";
    else if (!event) reason = "event-missing";
    else if (!isLegacyEvent(event)) reason = "event-not-legacy";
    else if (participant.schemaVersion !== undefined || (participant.status !== undefined && participant.status !== "active")) reason = "participant-not-legacy";
    if (reason) log.info("legacy participant page unavailable", {reason, participantId: request.participantId});
    return {reason, participant, event};
  }
  // 画面に必要な最小限の項目(メールアドレス・内部ID・他の参加者・管理用状態は返さない)
  function participantPageDto(event, participant, checkIn) {
    return {
      event: {
        // 受付用QRのURLを組み立てるために、本人のイベントIDだけ返す
        eventId: participant.eventId, eventName: typeof event.eventName === "string" ? event.eventName : "", startAt: iso(event.startAt),
        venue: typeof event.venue === "string" ? event.venue : "", reconfirmEnabled: event.reconfirmEnabled === true,
      },
      participant: {
        name: participant.name, registeredCount: num(participant.registeredCount), participationConfirmed: participant.participationConfirmed === true,
        attendanceResponse: participant.attendanceResponse === "attending" || participant.attendanceResponse === "notAttending" ? participant.attendanceResponse : null,
      },
      checkIn: {checkedIn: Boolean(checkIn) && checkIn.checkedIn === true, attendedCount: checkIn && Number.isInteger(checkIn.attendedCount) ? checkIn.attendedCount : null},
    };
  }
  async function pageFor(db, request, loaded) {
    const checkIn = dataOf(await db.collection("checkIns").doc(request.participantId).get());
    return participantPageDto(loaded.event, loaded.participant, checkIn && checkIn.eventId === loaded.participant.eventId ? checkIn : null);
  }

  async function getParticipantPage({data}) {
    const request = parseCapability(data);
    const db = getDb();
    const loaded = await loadCapability(db, null, request);
    if (loaded.reason) throw unavailable();
    return pageFor(db, request, loaded);
  }

  // 正式登録(本人)。既に登録済みなら何も変えない。
  async function confirmParticipation({data}) {
    const request = parseCapability(data);
    const db = getDb();
    const ref = db.collection("participants").doc(request.participantId);
    const denied = await db.runTransaction(async (tx) => {
      const loaded = await loadCapability(db, tx, request);
      if (loaded.reason) return true;
      if (loaded.participant.participationConfirmed !== true) {
        tx.update(ref, {participationConfirmed: true, participationConfirmedAt: serverTimestamp(), updatedAt: serverTimestamp()});
      }
      return false;
    });
    if (denied) throw unavailable();
    return pageFor(db, request, await loadCapability(db, null, request));
  }

  // 参加予定の回答(本人)。従来の画面と同じ条件: 正式登録済み・確認が有効・未回答のときだけ。回答済みなら上書きしない。
  async function answerReconfirmation({data}) {
    const request = parseCapability(data, ["response"]);
    if (request.response !== "attending" && request.response !== "notAttending") throw unavailable();
    const db = getDb();
    const ref = db.collection("participants").doc(request.participantId);
    const denied = await db.runTransaction(async (tx) => {
      const loaded = await loadCapability(db, tx, request);
      if (loaded.reason) return true;
      const p = loaded.participant;
      if (p.participationConfirmed === true && loaded.event.reconfirmEnabled === true && (p.attendanceResponse === undefined || p.attendanceResponse === null)) {
        tx.update(ref, {reconfirmed: true, reconfirmedAt: serverTimestamp(), attendanceResponse: request.response, updatedAt: serverTimestamp()});
      }
      return false;
    });
    if (denied) throw unavailable();
    return pageFor(db, request, await loadCapability(db, null, request));
  }

  // ---- 当日参加登録(公開API)の入力検証・受付可否 --------------------------------------------------------------
  // クライアントが決めてよいのは eventId・氏名・メール・人数だけ(件名・本文・senderName・宛先以外はサーバー固定)。
  function parseWalkIn(data) {
    let request;
    try {
      request = parseKeys(data, ["eventId", "name", "email", "registeredCount"], ["eventId", "name", "email", "registeredCount"]);
    } catch (error) {
      throw new ApiError("invalid-argument", "入力内容を確認してください。");
    }
    try {
      const name = text(request.name, {name: "name", max: LIMITS.walkInNameMax});
      // 氏名はメール本文に入る。URL・メールアドレス様の文字列は受け付けない(本文を乗っ取る用途を避ける)
      if (/:\/\/|@|https?:/i.test(name)) throw invalid("invalid-name");
      return {
        eventId: eventIdOf(request), name, email: emailField(request.email),
        registeredCount: countField(request.registeredCount, LIMITS.walkInCountMax),
      };
    } catch (error) {
      throw new ApiError("invalid-argument", "入力内容を確認してください。");
    }
  }
  // 当日参加登録を受け付けられる状態か: legacyのイベントで、開催日時が設定され、イベントがまだ終わっていない(終了時刻、無ければ開始から24時間)
  function walkInOpen(event) {
    if (!isLegacyEvent(event)) return false;
    const start = toDate(event.startAt);
    if (!start) return false;
    const end = toDate(event.endAt) || new Date(start.getTime() + 24 * 3600 * 1000);
    return now() < end.getTime();
  }

  return {
    listEvents, getEventAdminView, createEvent, updateEventSettings, createParticipant,
    getReceptionView, checkInParticipant, updateAttendedCount,
    getParticipantPage, confirmParticipation, answerReconfirmation,
    parseWalkIn, walkInOpen, isLegacyEvent, LIMITS,
  };
}

module.exports = {createLegacyApi, LIMITS};
