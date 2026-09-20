// 当選メール(将来のリマインドも)が共通で使う「メールのview model」と、送信時点の内容の固定(snapshot)。純粋関数のみ。
//
// view model = participant + programAttendances + event(snapshot) + QR + Web参加証URL から作る、表示用の正確なデータ。
// 文章(件名・冒頭文・締め文・注意事項)は含まず、テキスト版とHTML版が同じview modelから生成される(内容が食い違わない)。
// 人数の正本はprogramAttendancesのplannedCountだけ(旧参加者の人数フィールドは扱わない)。
//
// ■ 必須情報が欠けていればメールを作らない(problemsを返す): イベント名・開催日時・会場・宛名・参加program
// ■ 任意情報(住所・アクセス・注意事項・問い合わせ先・終了時刻)は、未設定ならそのセクション自体を出さない。
//   「未設定」「null」等の文字を参加者へ見せない。

const {isValidPlannedCount} = require("../programs");
const {templateProblems} = require("./winner_mail_template");
const {receptionQrPayload, webPassUrl} = require("./pass_urls");

const JST_OFFSET_MS = 9 * 3600 * 1000;
const WEEKDAYS = ["日", "月", "火", "水", "木", "金", "土"];
const pad2 = (n) => String(n).padStart(2, "0");

// Date / ISO文字列 / Firestore Timestamp → Date(不正ならnull)
function toDate(value) {
  if (value === null || value === undefined) return null;
  const date = typeof value.toDate === "function" ? value.toDate() : value instanceof Date ? value : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}
const toIso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

function jstParts(date) {
  const d = new Date(date.getTime() + JST_OFFSET_MS);
  return {y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate(), wd: d.getUTCDay(), hh: d.getUTCHours(), mm: d.getUTCMinutes()};
}
const formatDate = (date) => { const p = jstParts(date); return `${p.y}年${p.m}月${p.d}日(${WEEKDAYS[p.wd]})`; };
const formatTime = (date) => { const p = jstParts(date); return `${pad2(p.hh)}:${pad2(p.mm)}`; };
const sameDay = (a, b) => formatDate(a) === formatDate(b);

// 開催日時: 「2026年11月30日(月) 10:00〜16:00」。終了が無い/開始以前なら開始だけ。
function formatEventDateTime(start, end) {
  if (!end || end.getTime() <= start.getTime()) return `${formatDate(start)} ${formatTime(start)}`;
  return sameDay(start, end)
    ? `${formatDate(start)} ${formatTime(start)}〜${formatTime(end)}`
    : `${formatDate(start)} ${formatTime(start)}〜${formatDate(end)} ${formatTime(end)}`;
}

function timeRangeText(start, end) {
  if (start && end && end.getTime() > start.getTime()) return `${formatTime(start)}〜${formatTime(end)}`;
  if (start && !end) return `${formatTime(start)}〜`;
  return null;
}

// programの時間表示: 参加者別のslotLabel → 参加者別のstartAt/endAt → programの共通時間 → 表示しない(null)
function programTimeText(attendance, program) {
  const label = typeof attendance.slotLabel === "string" ? attendance.slotLabel.trim() : "";
  if (label !== "") return label;
  return timeRangeText(toDate(attendance.startAt), toDate(attendance.endAt)) ||
    timeRangeText(toDate(program.startAt), toDate(program.endAt));
}

const optionalText = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null);

// eventの現在の内容とテンプレートから、送信内容の固定(snapshot)を作る。個人情報は含まない。
// ジョブ作成時にジョブへ保存し、以後そのジョブの全メールはこのsnapshotで生成する(途中で文章・会場が変わらない)。
// プレビューも同じ関数でsnapshotを作るため、プレビューと実送信は同じ材料から生成される。
function buildMailSnapshot(eventId, event) {
  const problems = [...templateProblems(event && event.winnerMailTemplate)];
  const template = (event && event.winnerMailTemplate) || {};
  const start = toDate(event && event.startAt);
  if (!optionalText(event && event.eventName)) problems.push("event-name-missing");
  if (!start) problems.push("event-start-missing");
  if (!optionalText(event && event.venue)) problems.push("event-venue-missing");
  if (problems.length > 0) return {ok: false, problems};
  const venueInfo = event.venueInfo || {};
  const programs = (Array.isArray(event.programs) ? event.programs : [])
    .filter((p) => p && typeof p.programId === "string")
    .map((p) => ({
      programId: p.programId,
      name: optionalText(p.name) || p.programId,
      order: Number.isInteger(p.order) ? p.order : 0,
      startAt: toIso(p.startAt),
      endAt: toIso(p.endAt),
    }));
  return {
    ok: true,
    snapshot: {
      template: {
        subject: template.subject.trim(), introBody: template.introBody, closingBody: template.closingBody,
        notesBody: optionalText(template.notesBody), version: template.version,
      },
      event: {
        eventId, eventName: event.eventName.trim(), senderName: optionalText(event.senderName) || event.eventName.trim(),
        startAt: start.toISOString(), endAt: toIso(event.endAt), venue: event.venue.trim(),
        contact: optionalText(event.contact), address: optionalText(venueInfo.address), access: optionalText(venueInfo.access),
      },
      programs,
    },
  };
}

// 任意項目のうち、未設定のもの(管理者への参考。参加者メールには出さない)。
function missingOptionalFields(snapshot) {
  const missing = [];
  if (!snapshot.event.contact) missing.push("contact");
  if (!snapshot.event.address) missing.push("address");
  if (!snapshot.event.access) missing.push("access");
  if (!snapshot.template.notesBody) missing.push("notesBody");
  return missing;
}

// view modelを作る。{ok:true, viewModel} | {ok:false, problems}
function buildMailViewModel({snapshot, participant, attendances, appBaseUrl}) {
  const problems = [];
  const {event} = snapshot;
  const name = optionalText(participant && participant.name);
  if (!name) problems.push("participant-name-missing");

  const programById = new Map(snapshot.programs.map((p) => [p.programId, p]));
  const items = [];
  for (const attendance of attendances || []) {
    const program = programById.get(attendance.programId);
    if (!program) { problems.push("attendance-program-unknown"); continue; }
    if (attendance.eventId !== event.eventId || attendance.participantId !== (participant && participant.participantId)) {
      problems.push("attendance-owner-mismatch");
      continue;
    }
    if (!isValidPlannedCount(attendance.plannedCount)) { problems.push("attendance-planned-count-invalid"); continue; }
    items.push({
      programId: program.programId, name: program.name, order: program.order,
      timeText: programTimeText(attendance, program), plannedCount: attendance.plannedCount,
    });
  }
  // 表示順はevent.programsのorder(同順ならprogramId)。Firestoreからの取得順には依存しない。
  items.sort((a, b) => (a.order - b.order) || (a.programId < b.programId ? -1 : a.programId > b.programId ? 1 : 0));
  if (items.length === 0) problems.push("no-attendance");

  let qrPayload = null;
  let passUrl = null;
  try {
    const ids = {appBaseUrl, eventId: event.eventId, participantId: participant && participant.participantId, publicId: participant && participant.publicId};
    qrPayload = receptionQrPayload(ids);
    passUrl = webPassUrl(ids);
  } catch (error) {
    problems.push("qr-inputs-invalid");
  }
  if (problems.length > 0) return {ok: false, problems: [...new Set(problems)]};

  const start = toDate(event.startAt);
  return {
    ok: true,
    viewModel: {
      recipientName: name,
      eventName: event.eventName,
      dateTimeText: formatEventDateTime(start, toDate(event.endAt)),
      venue: event.venue,
      address: event.address,
      access: event.access,
      contact: event.contact,
      notes: snapshot.template.notesBody,
      programs: items.map((i) => ({programId: i.programId, name: i.name, timeText: i.timeText, plannedCount: i.plannedCount})),
      qrPayload,
      webPassUrl: passUrl,
    },
  };
}

module.exports = {toDate, formatEventDateTime, programTimeText, buildMailSnapshot, missingOptionalFields, buildMailViewModel};
