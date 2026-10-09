// イベント終了後の最終実績(参加者全員の申込内容・HEBEL属性・programごとの予定と受付結果)を返す、読み取り専用のAPI。
// Excelはこの応答からブラウザ上で作る(サーバーはファイルを作らない・保存しない・公開URLを作らない)。
//
// ■ 対象: 対象イベント(flow=confirmed)の participants すべて。status・取込回で絞り込まない(未来場者・有効でない参加者も含む)。
//   人物単位の重複排除はしない(同じメールアドレスのparticipantも、participantの数だけ返す)。
// ■ 受付結果の正本は programAttendances の現在の値(受付・訂正・取消は同じdocを更新する。pass_api.js)。
//   取消済み = checkedIn:false(受付時刻・実来場人数はnull)。訂正済み = attendedCountが最新の値。
// ■ program名・表示順・予定時間は、受付画面・参加証と同じ関数(mail_view_model.js の normalizePrograms / programTimeText)で決める。
//   event.programsに無いprogramのattendance(定義から消えたprogram)も落とさず、programIdを名前として末尾に並べる。
// ■ HEBEL属性は受付画面と同じ表示(hebel_residence.js の hebelResidenceView)。フィールドの無いparticipantは返さない(空欄)。
// ■ ログに氏名・メール・HEBEL属性の原文を出さない(このファイルはログを出さない)。

const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {normalizePrograms, programTimeText, toDate} = require("./mail_view_model");
const {hebelResidenceView} = require("./hebel_residence");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
// 1回の応答に含める上限(取込の上限5,000行の数回分)。超える場合は分割せず、明示的に拒否する(一部だけの実績を作らない)。
const MAX_REPORT_PARTICIPANTS = 10000;
const MAX_REPORT_ATTENDANCES = 50000;

const invalid = (code) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code});
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };
const text = (value) => (typeof value === "string" ? value : "");
const count = (value) => (Number.isInteger(value) ? value : null);

// 純粋関数: Firestoreから読んだ値 → 応答。
//   participants: [{id, data}] / batches: Map(batchId → batchのdata|null) / attendances: [data]
function buildAttendanceReport({eventId, event, participants, batches, attendances}) {
  const programs = normalizePrograms(event.programs)
    .sort((a, b) => (a.order - b.order) || (a.programId < b.programId ? -1 : a.programId > b.programId ? 1 : 0));
  const programById = new Map(programs.map((p) => [p.programId, p]));
  const participantIds = new Set(participants.map((p) => p.id));
  const byParticipant = new Map();
  const extraProgramIds = [];
  for (const a of attendances) {
    if (a.eventId !== eventId || !participantIds.has(a.participantId) || typeof a.programId !== "string") continue;
    if (!programById.has(a.programId) && !extraProgramIds.includes(a.programId)) extraProgramIds.push(a.programId);
    if (!byParticipant.has(a.participantId)) byParticipant.set(a.participantId, []);
    byParticipant.get(a.participantId).push(a);
  }
  extraProgramIds.sort();
  const columns = [
    ...programs.map((p) => ({programId: p.programId, name: p.name, inEvent: true})),
    ...extraProgramIds.map((id) => ({programId: id, name: id, inEvent: false})),
  ];
  const rows = participants.map(({id, data: p}) => {
    const batchId = typeof p.importBatchId === "string" ? p.importBatchId : null;
    const batch = batchId ? batches.get(batchId) || null : null;
    const hebel = hebelResidenceView(p.hebelResidence);
    const programsOfRow = (byParticipant.get(id) || []).map((a) => {
      const checkedIn = a.checkedIn === true;
      return {
        programId: a.programId,
        plannedCount: count(a.plannedCount),
        timeText: programTimeText(a, programById.get(a.programId) || {}) || null,
        checkedIn,
        // 取消済み(checkedIn:false)の受付時刻・人数は使わない(取消後は正本でもnull)
        attendedCount: checkedIn ? count(a.attendedCount) : null,
        checkedInAt: checkedIn ? iso(a.checkedInAt) : null,
      };
    });
    return {
      participantId: id,
      importSequence: batch && batch.eventId === eventId && Number.isInteger(batch.sequence) ? batch.sequence : null,
      batchCommitted: batchId === null ? null : Boolean(batch) && batch.eventId === eventId && batch.status === "committed",
      importRow: count(p.importRow),
      name: text(p.name),
      kana: text(p.kana),
      email: text(p.email),
      status: text(p.status),
      ...(hebel ? {hebelResidence: hebel} : {}),
      programs: programsOfRow,
    };
  });
  // 取込回 → CSV/Excelの行番号 → participantId(取得順に依存しない)
  const key = (v) => (v === null ? Number.MAX_SAFE_INTEGER : v);
  rows.sort((a, b) => (key(a.importSequence) - key(b.importSequence)) || (key(a.importRow) - key(b.importRow)) ||
    (a.participantId < b.participantId ? -1 : a.participantId > b.participantId ? 1 : 0));
  return {
    eventId,
    eventName: text(event.eventName),
    startAt: iso(event.startAt),
    programs: columns,
    participants: rows,
  };
}

function createAttendanceReportApi({getDb}) {
  async function getReport({data}) {
    if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("not-object");
    if (Object.keys(data).some((key) => key !== "eventId")) throw invalid("unknown-key");
    if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id");
    const eventId = data.eventId;
    const db = getDb();
    const eventSnap = await db.collection("events").doc(eventId).get();
    const event = eventSnap.exists ? eventSnap.data() : null;
    if (!event || !isConfirmedFlow(event)) throw new ApiError("failed-precondition", "新方式のイベントを確認できませんでした。");

    const [participantSnap, attendanceSnap] = await Promise.all([
      db.collection("participants").where("eventId", "==", eventId).limit(MAX_REPORT_PARTICIPANTS + 1).get(),
      db.collection("programAttendances").where("eventId", "==", eventId).limit(MAX_REPORT_ATTENDANCES + 1).get(),
    ]);
    if (participantSnap.size > MAX_REPORT_PARTICIPANTS || attendanceSnap.size > MAX_REPORT_ATTENDANCES) {
      throw new ApiError("failed-precondition", "参加者が多すぎるため、最終実績を出力できません。", {code: "report-too-large"});
    }
    const participants = participantSnap.docs.map((doc) => ({id: doc.id, data: doc.data()}));
    const batchIds = [...new Set(participants.map((p) => p.data.importBatchId).filter((id) => typeof id === "string" && id !== ""))];
    const batches = new Map();
    if (batchIds.length > 0) {
      const snaps = await db.getAll(...batchIds.map((id) => db.collection("importBatches").doc(id)));
      snaps.forEach((snap, index) => batches.set(batchIds[index], snap.exists ? snap.data() : null));
    }
    return buildAttendanceReport({eventId, event, participants, batches, attendances: attendanceSnap.docs.map((doc) => doc.data())});
  }
  return {getReport};
}

module.exports = {createAttendanceReportApi, buildAttendanceReport, MAX_REPORT_PARTICIPANTS, MAX_REPORT_ATTENDANCES};
