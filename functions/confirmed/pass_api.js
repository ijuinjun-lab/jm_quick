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
// 受付履歴(programAttendances/{id}/history)は追記型。IDは `{action}-{sequence}`(sequenceは受付ごとに1ずつ増える連番)。
//   例: check-in-1 → correction-2 → cancellation-3 → check-in-4。IDの連番で操作順を復元でき、同じIDを奪い合わない。
//   連番の現在値は attendance.historySequence(同じtransactionで+1)。Phase 7のデータ(historySequenceなし・受付済みで check-in-1 が既にある)は、
//   migrationなしで「受付済みなら1、未受付なら0」を現在値として扱う(既存のcheck-in-1は上書き・削除しない)。
const HISTORY_ACTION = Object.freeze({CHECK_IN: "check-in", CORRECTION: "correction", CANCELLATION: "cancellation"});
const currentHistorySequence = (attendance) => (Number.isInteger(attendance.historySequence) && attendance.historySequence >= 0 ?
  attendance.historySequence : (attendance.checkedIn === true ? 1 : 0));
const historyId = (action, sequence) => `${action}-${sequence}`;
const UNAVAILABLE_MESSAGE = "参加証を確認できませんでした。";
const STAFF_UNAVAILABLE_MESSAGE = "この参加証は受付できません。";

const optionalText = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null);
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

// 同じprogramへの同時操作(transactionの競合・ロック待ちタイムアウト = ABORTED)は、少し待って再実行する。
// 再実行しても安全: 各実行はtransactionで現在状態を読み直して判断するため、二重に反映されない(no-opや拒否になる)。
const isContention = (error) => Boolean(error) && (error.code === 10 || /ABORTED|lock timeout|too much contention/i.test(String(error.message)));
async function retryOnContention(run, attempts = 10) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (!isContention(error) || attempt >= attempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, 20 + Math.random() * 60 * attempt));
    }
  }
}

// 同じattendanceへの操作は、同じFunctionsインスタンス内では順番に実行する(同時に読み書きして互いにロックを待つ競合を避ける)。
// これは競合を減らすための工夫で、正しさの根拠ではない。別インスタンスからの同時操作も、Firestoreのtransaction(と上の再実行)が整合を保つ。
const localLocks = new Map();
async function withLocalLock(key, run) {
  const previous = localLocks.get(key) || Promise.resolve();
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const tail = previous.then(() => gate);
  localLocks.set(key, tail);
  await previous;
  try {
    return await run();
  } finally {
    release();
    if (localLocks.get(key) === tail) localLocks.delete(key);
  }
}

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

function createPassApi({getDb, serverTimestamp, getAppBaseUrl, checkRateLimit, logger, serializeLocally = true}) {
  const log = logger || console;
  // Phase 10 TODO: 公開の参加証APIのrate limit。ここに実装(例: IP・participantId単位の回数制限)を渡す。
  const rateLimit = checkRateLimit || (async () => {});

  // インスタンス内の直列化(競合を減らす補助。テストでは切って、transaction単体での整合性も確認する)
  const lockFor = serializeLocally ? withLocalLock : (key, run) => run();

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
    const outcome = await lockFor(attendanceRef.path, () => retryOnContention(() => db.runTransaction(async (tx) => {
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

      // 受付の書込みと履歴(追記)を同じtransactionで行う。再受付(取消後)でも過去の履歴は上書きせず、次の連番で追記する。
      const sequence = currentHistorySequence(attendance) + 1;
      tx.update(attendanceRef, {
        checkedIn: true,
        checkedInAt: serverTimestamp(),
        attendedCount: input.attendedCount,
        checkedInBy: identity.uid,
        historySequence: sequence,
        updatedAt: serverTimestamp(),
      });
      // 受付の履歴(誰が・いつ・どのprogramを・何名で)。メールアドレス・氏名は複製しない。
      tx.create(attendanceRef.collection("history").doc(historyId(HISTORY_ACTION.CHECK_IN, sequence)), {
        action: HISTORY_ACTION.CHECK_IN,
        sequence,
        eventId: input.eventId,
        participantId: input.participantId,
        programId: input.programId,
        before: {checkedIn: false, attendedCount: null},
        after: {checkedIn: true, attendedCount: input.attendedCount},
        changedBy: identity.uid,
        changedAt: serverTimestamp(),
      });
      return {alreadyCheckedIn: false};
    })));

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

  // ---- 受付後の訂正・取消(adminのみ。index.jsで confirmedCallable("admin", ...) により認可) --------------------------------------
  // 受付状態の正本は programAttendances のまま。訂正は attendedCount だけ、取消は受付状態(checkedIn・checkedInAt・attendedCount・checkedInBy)だけを変える。
  // plannedCount・participant・publicId・QR・メール配送(sendJobs・mailDeliveries)には一切触れない。
  // 実変更ごとに history を1件だけ追記し(現在状態の更新と同じtransaction)、変更のない要求(no-op)では history を作らない。
  const stateOf = (a) => ({
    checkedIn: a.checkedIn === true, checkedInAt: a.checkedInAt || null,
    attendedCount: Number.isInteger(a.attendedCount) ? a.attendedCount : null, checkedInBy: a.checkedInBy || null,
  });
  const programView = (input, current) => ({
    programId: input.programId,
    plannedCount: current.plannedCount,
    checkedIn: current.checkedIn === true,
    ...(iso(current.checkedInAt) ? {checkedInAt: iso(current.checkedInAt)} : {}),
    ...(Number.isInteger(current.attendedCount) ? {attendedCount: current.attendedCount} : {}),
  });

  // transaction内で participant・event・batch・attendance を再読込・検証してから、decide(attendance)の結果を書く。
  //   decide → {noop:true, reason?} | {denied: 理由} | {action, update, after}
  async function mutateAttendance({identity, input, decide}) {
    const db = getDb();
    const attendanceRef = db.collection("programAttendances").doc(programAttendanceId(input.participantId, input.programId));
    const outcome = await lockFor(attendanceRef.path, () => retryOnContention(() => db.runTransaction(async (tx) => {
      const context = await loadContext(db, tx, input);
      const attendance = dataOf(await tx.get(attendanceRef));
      if (context.problem) return {denied: context.problem};
      if (!attendance) return {denied: "attendance-missing"};
      if (attendance.eventId !== input.eventId || attendance.participantId !== input.participantId || attendance.programId !== input.programId) {
        return {denied: "attendance-mismatch"};
      }
      if (!normalizePrograms(context.event.programs).some((p) => p.programId === input.programId)) return {denied: "program-not-in-event"};
      const decision = decide(attendance);
      if (decision.noop || decision.denied) return decision;
      const sequence = currentHistorySequence(attendance) + 1;
      tx.update(attendanceRef, {...decision.update, historySequence: sequence, updatedAt: serverTimestamp()});
      // 履歴は追記のみ(既存の履歴は変更・削除しない)。氏名・メール・publicId・QRは複製しない。changedByは認証UID、changedAtはサーバー時刻。
      tx.create(attendanceRef.collection("history").doc(historyId(decision.action, sequence)), {
        action: decision.action, sequence, eventId: input.eventId, participantId: input.participantId, programId: input.programId,
        before: stateOf(attendance), after: decision.after, changedBy: identity.uid, changedAt: serverTimestamp(),
      });
      return {changed: true, sequence};
    })));
    if (outcome.denied) {
      log.warn("attendance change denied", {reason: outcome.denied, uid: identity.uid});
      throw staffProblem(outcome.denied);
    }
    const current = dataOf(await attendanceRef.get());
    return {changed: outcome.changed === true, ...(outcome.noop ? {noop: outcome.reason || "no-change"} : {}), program: programView(input, current)};
  }

  // 実来場人数の訂正。受付済みのprogramだけ(未受付を受付済みにはしない)。plannedCount・checkedInAt・checkedInByは変えない。
  async function correct({identity, data}) {
    const input = parseInput(data, ["eventId", "participantId", "publicId", "programId", "attendedCount"]);
    if (!input || input.eventId === undefined || !validIds(input) || !isValidProgramId(input.programId)) throw staffInvalid("invalid-input");
    if (!Number.isInteger(input.attendedCount) || input.attendedCount < 1 || input.attendedCount > MAX_ATTENDED_COUNT) throw staffInvalid("invalid-attended-count");
    return mutateAttendance({identity, input, decide: (attendance) => {
      if (attendance.checkedIn !== true) return {denied: "attendance-not-checked-in"};
      // 同じ人数への訂正(応答が届かなかった再試行を含む)は、何も変えず、履歴も作らない。
      if (attendance.attendedCount === input.attendedCount) return {noop: true, reason: "no-change"};
      return {
        action: HISTORY_ACTION.CORRECTION,
        update: {attendedCount: input.attendedCount},
        after: {...stateOf(attendance), attendedCount: input.attendedCount},
      };
    }});
  }

  // 受付の取消(このprogramの受付記録を取り消す。参加者のキャンセルではない=participant.statusは変えない)。
  // 未受付のprogramへの取消は、何も変えず履歴も作らない明示的なno-op(二重取消・応答消失後の再試行でも取消履歴は1件だけ)。
  async function cancel({identity, data}) {
    const input = parseInput(data, ["eventId", "participantId", "publicId", "programId"]);
    if (!input || input.eventId === undefined || !validIds(input) || !isValidProgramId(input.programId)) throw staffInvalid("invalid-input");
    return mutateAttendance({identity, input, decide: (attendance) => {
      if (attendance.checkedIn !== true) return {noop: true, reason: "not-checked-in"};
      return {
        action: HISTORY_ACTION.CANCELLATION,
        update: {checkedIn: false, checkedInAt: null, attendedCount: null, checkedInBy: null},
        after: {checkedIn: false, checkedInAt: null, attendedCount: null, checkedInBy: null},
      };
    }});
  }

  return {getPass, getReceptionView, checkIn, correct, cancel};
}

module.exports = {createPassApi, passProblem, MAX_ATTENDED_COUNT, UNAVAILABLE_MESSAGE, STAFF_UNAVAILABLE_MESSAGE};
