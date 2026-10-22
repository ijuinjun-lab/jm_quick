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

const {rolesFor, mappingFor, NAMES, participationType} = require("./participation_types");

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

// 元の申込日時だけを表示する。取込・送信日時へのフォールバックはしない。
function formatSourceRegisteredAt(value) {
  if (typeof value === "string" && !/T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
  if (!(value instanceof Date) && typeof value !== "string" && typeof value?.toDate !== "function") return null;
  const date = toDate(value);
  if (!date) return null;
  const p = jstParts(date);
  return `${p.y}年${pad2(p.m)}月${pad2(p.d)}日 ${pad2(p.hh)}:${pad2(p.mm)}`;
}

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

// 時間表示: 参加者別slotLabel → 参加者別startAt/endAt → 保存済みトーク時間 → program共通時間 → null
function programTimeText(attendance, program) {
  const label = typeof attendance.slotLabel === "string" ? attendance.slotLabel.trim() : "";
  if (label !== "") return label;
  return timeRangeText(toDate(attendance.startAt), toDate(attendance.endAt)) ||
    (program.role === "talk" ? program.talkTimeText || null : null) ||
    timeRangeText(toDate(program.startAt), toDate(program.endAt));
}

const optionalText = (value) => (typeof value === "string" && value.trim() !== "" ? value.trim() : null);

// event.programs(Firestoreの値)を、表示用の正規化された形にする。メール(snapshot)とWeb参加証・受付画面が同じ関数を使う。
function normalizePrograms(rawPrograms) {
  return (Array.isArray(rawPrograms) ? rawPrograms : [])
    .filter((p) => p && typeof p.programId === "string")
    .map((p) => ({
      programId: p.programId,
      name: optionalText(p.name) || p.programId,
      order: Number.isInteger(p.order) ? p.order : 0,
      startAt: toIso(p.startAt),
      endAt: toIso(p.endAt),
    }));
}

// メールに表示するprogram定義(参加形態の割当があるイベントではrole付き)。
// buildMailSnapshot と前日リマインドの宛先一覧(reminder_targets.js)が共通で使う(宛先一覧と本文が食い違わない)。
// 名称: 割当の無いprogramはイベントに登録された名称。割当のある犬・猫は役割別の名称(NAMES)。
//   トークはイベントに登録された名称(イベントごとに尊重する。Web参加証・受付と同じ)。登録名が空の場合だけ役割別の名称。
function displayPrograms(eventId, event) {
  const roles = rolesFor(eventId, event);
  return normalizePrograms(event && event.programs).map((p) => ({...p,
    role: roles && roles[p.programId], talkTimeText: talkTimeTextOf(event)}));
}

function mailPrograms(eventId, event) {
  const roles = rolesFor(eventId, event);
  const registered = new Map((Array.isArray(event && event.programs) ? event.programs : [])
    .filter((p) => p && typeof p.programId === "string").map((p) => [p.programId, optionalText(p.name)]));
  return normalizePrograms(event && event.programs).map((p) => {
    const role = roles && roles[p.programId];
    if (!role) return p;
    return {...p, talkTimeText: talkTimeTextOf(event), name: (role === "talk" && registered.get(p.programId)) || NAMES[role], role};
  });
}
// トークの共通時間(当選メール設定 confirmedMailSettings.talkTimeText)。未設定ならnull。
const talkTimeTextOf = (event) => optionalText(event && event.confirmedMailSettings && event.confirmedMailSettings.talkTimeText);
// メールに表示する時間: 参加者別の時間(programTimeText)が無いtalkだけ、トークの共通時間で補う。共通時間も未設定なら補完しない(null)。
const mailTimeText = (timeText, role, talkTimeText) => timeText || (role === "talk" ? talkTimeText || null : null);

// 参加者のprogramAttendancesから、表示するprogram一覧を作る。メール・Web参加証・受付画面で共通。
//   - 参加するprogram(attendanceがあるもの)だけ。1 attendance = 1 項目(重複排除しない)
//   - 表示順はevent.programsのorder(同順ならprogramId)。Firestoreからの取得順には依存しない
//   - program名・時間・plannedCountの解釈(時間はslotLabel → attendanceの時間 → programの時間 → 表示しない)を1か所に固定する
// 戻り値: {items:[{programId,name,order,timeText,plannedCount,attendance}], problems:[コード]}
function buildProgramItems({programs, attendances, eventId, participantId}) {
  const problems = [];
  const programById = new Map(programs.map((p) => [p.programId, p]));
  const items = [];
  for (const attendance of attendances || []) {
    const program = programById.get(attendance.programId);
    if (!program) { problems.push("attendance-program-unknown"); continue; }
    if (attendance.eventId !== eventId || attendance.participantId !== participantId) {
      problems.push("attendance-owner-mismatch");
      continue;
    }
    if (!isValidPlannedCount(attendance.plannedCount)) { problems.push("attendance-planned-count-invalid"); continue; }
    items.push({
      programId: program.programId, name: program.name, order: program.order,
      timeText: mailTimeText(programTimeText(attendance, program), program.role, program.talkTimeText), plannedCount: attendance.plannedCount, attendance,
    });
  }
  items.sort((a, b) => (a.order - b.order) || (a.programId < b.programId ? -1 : a.programId > b.programId ? 1 : 0));
  if (items.length === 0) problems.push("no-attendance");
  return {items, problems};
}

// eventの現在の内容とテンプレートから、送信内容の固定(snapshot)を作る。個人情報は含まない。
// ジョブ作成時にジョブへ保存し、以後そのジョブの全メールはこのsnapshotで生成する(途中で文章・会場が変わらない)。
// プレビューも同じ関数でsnapshotを作るため、プレビューと実送信は同じ材料から生成される。
// templateField: 使うテンプレートのフィールド名。当選メール(既定)は winnerMailTemplate、前日リマインドは reminderMailTemplate(別データ)。
// 会場・住所・アクセス・program・QRなどの正確なデータは、どちらのメールでも同じ正本(event・participant・programAttendances)から作る。
function buildMailSnapshot(eventId, event, {templateField = "winnerMailTemplate"} = {}) {
  const problems = [...templateProblems(event && event[templateField])];
  const template = (event && event[templateField]) || {};
  const start = toDate(event && event.startAt);
  if (!optionalText(event && event.eventName)) problems.push("event-name-missing");
  if (!start) problems.push("event-start-missing");
  if (!optionalText(event && event.venue)) problems.push("event-venue-missing");
  if (problems.length > 0) return {ok: false, problems};
  const venueInfo = event.venueInfo || {};
  const programs = mailPrograms(eventId, event);
  return {
    ok: true,
    snapshot: {
      template: {
        subject: template.subject.trim(), introBody: template.introBody, closingBody: template.closingBody,
        notesBody: optionalText(template.notesBody), version: template.version,
        adoptionNotesBody: optionalText(template.adoptionNotesBody),
      },
      event: {
        participationMapping: mappingFor(eventId, event),
        eventId, eventName: event.eventName.trim(), senderName: optionalText(event.senderName) || event.eventName.trim(),
        startAt: start.toISOString(), endAt: toIso(event.endAt), venue: event.venue.trim(),
        talkTimeText: talkTimeTextOf(event),
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

  const built = buildProgramItems({programs: snapshot.programs, attendances, eventId: event.eventId, participantId: participant && participant.participantId});
  problems.push(...built.problems);
  const items = built.items;
  const roles = rolesFor(event.eventId, {...event, programs: snapshot.programs});
  if (roles) {
    if (!participationType(event.eventId, attendances, {...event, programs: snapshot.programs})) problems.push("participation-type-invalid");
    for (const item of items) {
      const role = roles[item.programId];
      if (!role) problems.push("attendance-program-role-unknown");
      item.timeText = mailTimeText(item.timeText, role, event.talkTimeText);
      if (!item.timeText) problems.push("attendance-time-missing");
    }
  }

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
  const sourceRegisteredAtText = formatSourceRegisteredAt(participant.sourceRegisteredAt);
  return {
    ok: true,
    viewModel: {
      recipientName: name,
      ...(sourceRegisteredAtText ? {sourceRegisteredAtText} : {}),
      eventName: event.eventName,
      dateTimeText: formatEventDateTime(start, toDate(event.endAt)),
      venue: event.venue,
      address: event.address,
      access: event.access,
      contact: event.contact,
      notes: [
        ...(roles && items.some((i) => ["dog", "cat"].includes(roles[i.programId]))
          ? [snapshot.template.adoptionNotesBody] : []),
        snapshot.template.notesBody,
      ].filter(Boolean).join("\n") || null,
      ...(roles ? {participationType: participationType(event.eventId, attendances, {...event, programs: snapshot.programs}), participationLayout: true} : {}),
      programs: items.map((i) => ({programId: i.programId, name: i.name, timeText: i.timeText, plannedCount: i.plannedCount, ...(roles ? {role: roles[i.programId]} : {})})),
      qrPayload,
      webPassUrl: passUrl,
    },
  };
}

module.exports = {toDate, formatSourceRegisteredAt, formatEventDateTime, programTimeText, normalizePrograms, displayPrograms, mailPrograms, talkTimeTextOf, mailTimeText, buildProgramItems, buildMailSnapshot,
  missingOptionalFields, buildMailViewModel};
