// 新方式(flow=confirmed)の「Web参加証」と「program別受付」。
//
//   getPass          参加者本人(ログインなし)が自分の参加証を読む。participantId + publicId の組だけで閲覧できる。読み取り専用。
//   getReceptionView 受付スタッフ(staff/admin)が、QRのparticipantId/publicIdから受付画面の内容を読む。
//   checkIn          受付スタッフ(staff/admin)が、1つのprogramを受付する(transaction)。
//
// ■ 1 participant = 1 QR。programごとのQRは無い。受付状態の正本は programAttendances(program単位・独立)。
// ■ publicId は「参加証を閲覧できる」秘密トークンであって、受付権限ではない。受付操作(checkIn)は必ず
//   Firebase Auth + accessRoles の staff/admin(confirmedCallable("staffOrAdmin", ...))を要求する。
// ■ QRの文字列は Phase 6 の receptionQrPayload が唯一の正本(ここでは生成規則を持たず、その関数を呼ぶだけ)。
// ■ program名・時間・plannedCount・表示順は、当選メールと同じ buildProgramItems で決める(メールと参加証が食い違わない)。
// ■ 参加者へ返さない: メールアドレス・かな・sourceReference・importBatchId・監査情報・publicId以外の内部ID。
// ■ 有効な参加証の条件: participantが存在 / schemaVersion 2 / status active / publicId完全一致 / eventがflow=confirmed /
//   participant.eventId == 指定のeventId / importBatchIdがあるなら、そのbatchがcommittedで同じevent。
//   条件を満たさない理由は、参加者向けAPIでは常に同じ応答(存在・publicId・batch状態を推測させない)。
// ■ このファイルはFirebaseに依存しない(getDb・serverTimestamp・getAppBaseUrlを注入する)。

const crypto = require("node:crypto");
const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {isValidParticipantId, isValidProgramId, programAttendanceId, MAX_PLANNED_COUNT} = require("../programs");
const {loadAttendances} = require("./winner_mail_message");
const {receptionQrPayload, webPassUrl} = require("./pass_urls");
const {toDate, formatEventDateTime, normalizePrograms, buildProgramItems} = require("./mail_view_model");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const PUBLIC_ID_PATTERN = /^pub_[A-Za-z0-9_-]{20,128}$/;
const PARTICIPANT_SCHEMA_VERSION = 2;
const MAX_ATTENDED_COUNT = MAX_PLANNED_COUNT; // 実来場人数の上限(予定人数の上限と同じ)
const HISTORY_CHECK_IN_ID = "check-in-1"; // 初回受付の履歴の固定ID(1つのattendanceにつき初回受付は1回だけ)
const UNAVAILABLE_MESSAGE = "参加証を確認できませんでした。";
const STAFF_UNAVAILABLE_MESSAGE = "この参加証は受付できません。";

const optionalText = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null);
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

function safeEqual(left, right) {
  const a = Buffer.from(String(left));
  const b = Buffer.from(String(right));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// 想定外のキーを含む入力は拒否する(plannedCount等を送って上書きさせる余地を作らない)。不正なら null。
function parseInput(data, allowedKeys) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) return null;
  if (Object.keys(data).some((key) => !allowedKeys.includes(key))) return null;
  for (const key of allowedKeys) if (data[key] === undefined && key !== "eventId") return null;
  return data;
}

function validIds({participantId, publicId, eventId}) {
  return isValidParticipantId(participantId) && typeof publicId === "string" && PUBLIC_ID_PATTERN.test(publicId) &&
    (eventId === undefined || (typeof eventId === "string" && EVENT_ID_PATTERN.test(eventId)));
}

// participant・event・batchを検証する。戻り値は「無効な理由のコード」(有効ならnull)。コードは内部のログ用で、参加者へは返さない。
function passProblem({participant, event, batch, publicId, eventId}) {
  if (!participant) return "participant-missing";
  if (participant.schemaVersion !== PARTICIPANT_SCHEMA_VERSION) return "participant-not-confirmed-schema";
  if (participant.status !== "active") return "participant-not-active";
  if (typeof participant.publicId !== "string" || !safeEqual(participant.publicId, publicId)) return "public-id-mismatch";
  if (typeof participant.eventId !== "string") return "participant-event-missing";
  if (eventId !== undefined && participant.eventId !== eventId) return "event-mismatch";
  if (!event) return "event-missing";
  if (!isConfirmedFlow(event)) return "event-not-confirmed";
  const hasBatch = participant.importBatchId !== undefined && participant.importBatchId !== null;
  if (hasBatch) {
    if (typeof participant.importBatchId !== "string") return "batch-invalid";
    if (!batch) return "batch-missing";
    if (batch.eventId !== participant.eventId) return "batch-event-mismatch";
    // committing / failed のbatch由来の参加者は、参加証・受付の対象にしない(Phase 5の境界)
    if (batch.status !== "committed") return "batch-not-committed";
  }
  return null;
}

function createPassApi({getDb, serverTimestamp, getAppBaseUrl, checkRateLimit, logger}) {
  const log = logger || console;
  // Phase 10 TODO: 公開の参加証APIのrate limit。ここに実装(例: IP・participantId単位の回数制限)を渡す。
  const rateLimit = checkRateLimit || (async () => {});

  const participantRef = (db, id) => db.collection("participants").doc(id);
  const eventRef = (db, id) => db.collection("events").doc(id);
  const batchRefOf = (db, id) => db.collection("importBatches").doc(id);
  const dataOf = (snapshot) => (snapshot && snapshot.exists ? snapshot.data() : null);

  // 参加者・event・batchを読む(readerは db 直読み、または transaction)
  async function loadContext(db, reader, {participantId, publicId, eventId}) {
    const read = (ref) => (reader ? reader.get(ref) : ref.get());
    const participant = dataOf(await read(participantRef(db, participantId)));
    // 参加者が存在しない場合も、以降の判定に進まずに理由を返す
    const targetEventId = participant && typeof participant.eventId === "string" && EVENT_ID_PATTERN.test(participant.eventId) ?
      participant.eventId : null;
    const event = targetEventId ? dataOf(await read(eventRef(db, targetEventId))) : null;
    const batchId = participant && typeof participant.importBatchId === "string" ? participant.importBatchId : null;
    const batch = batchId ? dataOf(await read(batchRefOf(db, batchId))) : null;
    const problem = passProblem({participant, event, batch, publicId, eventId});
    return {problem, participant, event, targetEventId};
  }

  // 参加者のprogram一覧(表示順・時間・plannedCountはメールと同じ規則)。attendanceの件数と表示件数の一致も確認する。
  function buildProgramList({event, eventId, participantId, attendances}) {
    const built = buildProgramItems({programs: normalizePrograms(event.programs), attendances, eventId, participantId});
    if (built.problems.length > 0 || built.items.length !== attendances.length) return {problem: "program-data-invalid"};
    return {items: built.items};
  }

  const toEntry = (item, {withStaffFields}) => {
    const a = item.attendance;
    const checkedIn = a.checkedIn === true;
    const entry = {
      programId: item.programId,
      name: item.name,
      ...(item.timeText ? {timeText: item.timeText} : {}),
      plannedCount: item.plannedCount,
      checkedIn,
    };
    if (withStaffFields && checkedIn) {
      const at = iso(a.checkedInAt);
      if (at) entry.checkedInAt = at;
      if (Number.isInteger(a.attendedCount)) entry.attendedCount = a.attendedCount;
    }
    return entry;
  };

  // ---- 参加者本人の参加証(公開・読み取り専用) --------------------------------------------------
  async function getPass({data, request}) {
    const unavailable = () => new ApiError("not-found", UNAVAILABLE_MESSAGE);
    const input = parseInput(data, ["participantId", "publicId"]);
    await rateLimit({request, kind: "pass"});
    if (!input || !validIds(input)) throw unavailable();

    const db = getDb();
    const context = await loadContext(db, null, {participantId: input.participantId, publicId: input.publicId});
    if (context.problem) {
      // 理由は内部ログにだけ残す(個人情報・ID・publicIdは出さない)。参加者へは常に同じ応答。
      log.info("pass unavailable", {reason: context.problem});
      throw unavailable();
    }
    const {participant, event, targetEventId} = context;
    const attendances = await loadAttendances(db, input.participantId, targetEventId);
    const list = buildProgramList({event, eventId: targetEventId, participantId: input.participantId, attendances});
    const name = optionalText(participant.name);
    const eventName = optionalText(event.eventName);
    let qrPayload;
    let passUrl;
    try {
      const ids = {appBaseUrl: getAppBaseUrl(), eventId: targetEventId, participantId: input.participantId, publicId: participant.publicId};
      qrPayload = receptionQrPayload(ids); // Phase 6と同一の関数。メールのQR・受付URLと同じ文字列になる
      passUrl = webPassUrl(ids);
    } catch (error) {
      log.info("pass unavailable", {reason: "qr-inputs-invalid"});
      throw unavailable();
    }
    if (list.problem || !name || !eventName) {
      log.info("pass unavailable", {reason: list.problem || "display-data-missing"});
      throw unavailable();
    }
    const start = toDate(event.startAt);
    const venueInfo = event.venueInfo || {};
    return {
      eventName,
      ...(start ? {dateTimeText: formatEventDateTime(start, toDate(event.endAt))} : {}),
      ...(optionalText(event.venue) ? {venue: optionalText(event.venue)} : {}),
      ...(optionalText(venueInfo.address) ? {address: optionalText(venueInfo.address)} : {}),
      ...(optionalText(venueInfo.access) ? {access: optionalText(venueInfo.access)} : {}),
      participantName: name,
      programs: list.items.map((item) => toEntry(item, {withStaffFields: false})),
      qrPayload,
      webPassUrl: passUrl,
    };
  }

  // ---- 受付スタッフ ---------------------------------------------------------------------------
  const staffProblem = (reason) => new ApiError("failed-precondition", STAFF_UNAVAILABLE_MESSAGE, {code: reason});
  const staffInvalid = (code) => new ApiError("invalid-argument", "リクエストが不正です。", {code});

  async function getReceptionView({identity, data}) {
    const input = parseInput(data, ["eventId", "participantId", "publicId"]);
    if (!input || input.eventId === undefined || !validIds(input)) throw staffInvalid("invalid-input");
    const db = getDb();
    const context = await loadContext(db, null, input);
    if (context.problem) {
      log.warn("reception view denied", {reason: context.problem, uid: identity.uid});
      throw staffProblem(context.problem);
    }
    const {participant, event, targetEventId} = context;
    const attendances = await loadAttendances(db, input.participantId, targetEventId);
    const list = buildProgramList({event, eventId: targetEventId, participantId: input.participantId, attendances});
    const name = optionalText(participant.name);
    const eventName = optionalText(event.eventName);
    if (list.problem || !name || !eventName) {
      log.warn("reception view denied", {reason: list.problem || "display-data-missing", uid: identity.uid});
      throw staffProblem(list.problem || "display-data-missing");
    }
    return {
      eventId: targetEventId,
      eventName,
      participantName: name,
      programs: list.items.map((item) => toEntry(item, {withStaffFields: true})),
    };
  }

  async function checkIn({identity, data}) {
    // plannedCount等の余計なキーは拒否する(実来場人数以外の値をクライアントから受け取らない)
    const input = parseInput(data, ["eventId", "participantId", "publicId", "programId", "attendedCount"]);
    if (!input || input.eventId === undefined || !validIds(input) || !isValidProgramId(input.programId)) throw staffInvalid("invalid-input");
    if (!Number.isInteger(input.attendedCount) || input.attendedCount < 1 || input.attendedCount > MAX_ATTENDED_COUNT) {
      throw staffInvalid("invalid-attended-count");
    }
    const db = getDb();
    const attendanceRef = db.collection("programAttendances").doc(programAttendanceId(input.participantId, input.programId));

    // 再読込と検証・書込みを1つのtransactionで行う。同じprogramを同時に受付しても、成立するのは1回だけ。
    const outcome = await db.runTransaction(async (tx) => {
      const context = await loadContext(db, tx, input);
      const attendance = dataOf(await tx.get(attendanceRef));
      if (context.problem) return {denied: context.problem};
      if (!attendance) return {denied: "attendance-missing"};
      if (attendance.eventId !== input.eventId || attendance.participantId !== input.participantId || attendance.programId !== input.programId) {
        return {denied: "attendance-mismatch"};
      }
      // event.programsに存在するprogramだけ(定義から消えたprogramは受付できない)
      if (!normalizePrograms(context.event.programs).some((p) => p.programId === input.programId)) return {denied: "program-not-in-event"};
      if (attendance.checkedIn === true) return {alreadyCheckedIn: true}; // 既存の受付情報は一切変更しない

      tx.update(attendanceRef, {
        checkedIn: true,
        checkedInAt: serverTimestamp(),
        attendedCount: input.attendedCount,
        checkedInBy: identity.uid,
        updatedAt: serverTimestamp(),
      });
      // 初回受付の履歴(誰が・いつ・どのprogramを・何名で)。メールアドレス・氏名は複製しない。
      tx.create(attendanceRef.collection("history").doc(HISTORY_CHECK_IN_ID), {
        action: "check-in",
        eventId: input.eventId,
        participantId: input.participantId,
        programId: input.programId,
        before: {checkedIn: false, attendedCount: null},
        after: {checkedIn: true, attendedCount: input.attendedCount},
        changedBy: identity.uid,
        changedAt: serverTimestamp(),
      });
      return {alreadyCheckedIn: false};
    });

    if (outcome.denied) {
      log.warn("check-in denied", {reason: outcome.denied, uid: identity.uid});
      throw staffProblem(outcome.denied);
    }
    // 確定後の状態を返す(checkedInAtはサーバー時刻。既に受付済みなら、既存の受付情報がそのまま返る)
    const current = dataOf(await attendanceRef.get());
    return {
      alreadyCheckedIn: outcome.alreadyCheckedIn,
      program: {
        programId: input.programId,
        plannedCount: current.plannedCount,
        checkedIn: current.checkedIn === true,
        ...(iso(current.checkedInAt) ? {checkedInAt: iso(current.checkedInAt)} : {}),
        ...(Number.isInteger(current.attendedCount) ? {attendedCount: current.attendedCount} : {}),
      },
    };
  }

  return {getPass, getReceptionView, checkIn};
}

module.exports = {createPassApi, passProblem, MAX_ATTENDED_COUNT, UNAVAILABLE_MESSAGE, STAFF_UNAVAILABLE_MESSAGE};
