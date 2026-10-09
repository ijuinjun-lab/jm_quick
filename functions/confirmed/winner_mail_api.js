// 当選メールの設定(テンプレート)・プレビューのAPI(admin専用callableのハンドラ)。
// 認可(admin)は index.js の confirmedCallable("admin", ...) が済ませており、identity はサーバー側で確定した値。
//
// ■ テンプレートは必ずこのAPI経由(admin専用)で更新する。クライアントからのFirestore直接書込みはRulesで拒否している。
// ■ プレビューは、event・participant・programAttendances・テンプレートをすべてFirestoreの正本から読んで完成形を生成する。
//   クライアントが送るのは eventId と participantId だけ(氏名・人数・本文を偽装できない)。
// ■ 実メールは送らない。

const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {isValidParticipantId} = require("../programs");
const {validateTemplateInput, validateVenueInfo} = require("./winner_mail_template");
const {buildMailSnapshot, missingOptionalFields, toDate} = require("./mail_view_model");
const {composeWinnerMailFor} = require("./winner_mail_message");
// イベント全体で「有効(active)かつ取込(committed)済み」のparticipantを、既存の安定した並び順(participantId昇順)
// で集める既存関数を再利用する(前日リマインドのプレビュー対象選択と同じもの。新しいFunctionsは追加しない)。
const {collectReminderTargets} = require("./reminder_targets");

const {rolesFor, mappingFor, participationType, TYPES} = require("./participation_types");
const sippoPreset = require("./sippo_mail_preset");
const sippoWaitlistPreset = require("./sippo_waitlist_mail_preset");
const {NOTIFICATION_TYPES, NOTIFICATION_TYPE_VALUES, notificationTypeOf, templateFieldFor} = require("./notification_type");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("body-not-object");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unknown-key", {path: key});
  if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id");
  return data;
}

// eventを読み、存在・flow=confirmedを確認する(クライアントのeventは信用しない)。
async function loadConfirmedEvent(db, eventId) {
  const ref = db.collection("events").doc(eventId);
  const snapshot = await ref.get();
  if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
  if (!isConfirmedFlow(snapshot.data())) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
  return {ref, event: snapshot.data()};
}

const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

// テンプレートの表示用(管理画面)。未設定ならnull。
const templateView = (template) => (template ? {
  subject: template.subject || "", introBody: template.introBody || "", closingBody: template.closingBody || "",
  notesBody: template.notesBody || "", adoptionNotesBody: template.adoptionNotesBody || "", version: Number.isInteger(template.version) ? template.version : 0,
  updatedBy: template.updatedBy || null, updatedAt: iso(template.updatedAt),
} : null);

function parseNotificationType(value) {
  if (value === undefined) return undefined;
  if (!NOTIFICATION_TYPE_VALUES.includes(value)) throw invalid("invalid-notification-type");
  return value;
}

function createWinnerMailApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl}) {
  // 管理者専用。設定と、対象イベントのプレビュー選択用氏名・ID・導出タイプを返す。
  // 宛先メールアドレス・publicIdは一覧へ含めない。
  async function getSettings({data}) {
    const {eventId} = parseKeys(data, ["eventId"]);
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, eventId);
    const built = buildMailSnapshot(eventId, event);
    const template = event.winnerMailTemplate || null;
    // プレビュー用に、このイベントの有効(active)かつ取込(committed)済みのparticipantから1件だけ選ぶ。
    // 取込回(第1回・第2回…)は問わない(前日リマインドの対象選択と同じ既存ロジック・同じ安定した並び順)。
    // 0件ならnull(クライアントは「取込済みの参加者がありません」という案内だけを表示し、IDの入力は求めない)。
    const targets = await collectReminderTargets(db, eventId);
    let previewParticipants = [];
    if (rolesFor(eventId, event) && targets.targets.length) {
      const allowed = new Set(targets.targets);
      const [people, attendanceDocs] = await Promise.all([
        db.collection("participants").where("eventId", "==", eventId).get(),
        db.collection("programAttendances").where("eventId", "==", eventId).get(),
      ]);
      const byParticipant = new Map();
      for (const doc of attendanceDocs.docs) {
        const a = doc.data();
        if (!byParticipant.has(a.participantId)) byParticipant.set(a.participantId, []);
        byParticipant.get(a.participantId).push(a);
      }
      previewParticipants = people.docs.filter((doc) => allowed.has(doc.id) && typeof doc.data().importBatchId === "string")
        .map((doc) => ({participantId: doc.id, name: doc.data().name || "", participationType: participationType(eventId, byParticipant.get(doc.id), event)}))
        .sort((a, b) => a.participantId.localeCompare(b.participantId));
    }
    return {
      eventId,
      suggestedTemplate: sippoPreset,
      participationMapping: mappingFor(eventId, event),
      programs: (event.programs || []).map((p) => ({programId: p.programId, name: p.name || p.programId})),
      ...(rolesFor(eventId, event) ? {participationTypes: TYPES, previewParticipants} : {}),
      mailSettings: {senderName: event.senderName || "", contact: event.contact || "", talkTimeText: event.confirmedMailSettings?.talkTimeText || ""},
      template: templateView(template),
      // キャンセル待ち繰り上げ当選メール(繰り上げの取込回の送信に使う。通常当選メールとは別のテンプレート・別のversion)
      waitlistTemplate: templateView(event[templateFieldFor(NOTIFICATION_TYPES.WAITLIST_PROMOTION)] || null),
      suggestedWaitlistTemplate: sippoWaitlistPreset,
      ...(() => {
        const b = buildMailSnapshot(eventId, event, {templateField: templateFieldFor(NOTIFICATION_TYPES.WAITLIST_PROMOTION)});
        return {waitlistReady: b.ok, waitlistProblems: b.ok ? [] : b.problems};
      })(),
      venueInfo: {address: (event.venueInfo && event.venueInfo.address) || "", access: (event.venueInfo && event.venueInfo.access) || ""},
      event: {eventName: event.eventName || "", venue: event.venue || "", contact: event.contact || "", senderName: event.senderName || "", startAt: iso(event.startAt)},
      ready: built.ok,
      problems: built.ok ? [] : built.problems,
      missingOptional: built.ok ? missingOptionalFields(built.snapshot) : [],
      previewParticipantId: targets.targets.length > 0 ? targets.targets[0] : null,
    };
  }

  async function updateTemplate({identity, data}) {
    const request = parseKeys(data, ["eventId", "template", "venueInfo", "mailSettings", "participationMapping", "notificationType"]);
    const template = validateTemplateInput(request.template);
    if (!template.ok) throw invalid("invalid-template", {errors: template.errors});
    // キャンセル待ち繰り上げ当選メール: テンプレート本文だけを、通常当選メールとは別の項目・別のversionで保存する
    // (会場・送信者等のイベント共通の設定は、通常当選メールの画面で変更する)。
    if (parseNotificationType(request.notificationType) === NOTIFICATION_TYPES.WAITLIST_PROMOTION) {
      if (request.venueInfo !== undefined || request.mailSettings !== undefined || request.participationMapping !== undefined) {
        throw invalid("waitlist-template-only");
      }
      return updateWaitlistTemplate({identity, eventId: request.eventId, value: template.value});
    }
    let venue = null;
    if (request.venueInfo !== undefined) {
      venue = validateVenueInfo(request.venueInfo);
      if (!venue.ok) throw invalid("invalid-venue-info", {errors: venue.errors});
    }
    let mailSettings = null;
    if (request.mailSettings !== undefined) {
      const input = request.mailSettings;
      if (!input || typeof input !== "object" || Array.isArray(input) || Object.keys(input).some((k) => !["senderName", "contact", "talkTimeText"].includes(k))) throw invalid("invalid-mail-settings");
      mailSettings = {};
      for (const [key, max] of Object.entries({senderName: 100, contact: 500, talkTimeText: 100})) {
        const value = input[key];
        if (typeof value !== "string" || value.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value) || (key !== "contact" && /[\r\n]/.test(value))) throw invalid("invalid-mail-settings", {path: key});
        mailSettings[key] = value.trim();
      }
    }
    const db = getDb();
    const ref = db.collection("events").doc(request.eventId);
    return db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      const event = snapshot.data();
      if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      const hasMapping = request.participationMapping !== undefined;
      if (hasMapping) rolesFor(request.eventId, {...event, participationMapping: request.participationMapping});
      const sameMapping = !hasMapping || (event.participationMapping !== undefined && JSON.stringify(mappingFor(request.eventId, event)) ===
        JSON.stringify(mappingFor(request.eventId, {...event, participationMapping: request.participationMapping})));
      const current = event.winnerMailTemplate || null;
      const currentVenue = event.venueInfo || {};
      const nextVenue = venue ? venue.value : {address: currentVenue.address || null, access: currentVenue.access || null};
      const sameMailSettings = !mailSettings || (mailSettings.senderName === (event.senderName || "") &&
        mailSettings.contact === (event.contact || "") && mailSettings.talkTimeText === (event.confirmedMailSettings?.talkTimeText || ""));
      // Older clients omit the optional section; preserve it on their edits.
      if (request.template.adoptionNotesBody === undefined && current?.adoptionNotesBody) template.value.adoptionNotesBody = current.adoptionNotesBody;
      const same = sameMapping && sameMailSettings && current &&
        (current.adoptionNotesBody || null) === (template.value.adoptionNotesBody || null) && current.subject === template.value.subject && current.introBody === template.value.introBody &&
        current.closingBody === template.value.closingBody && (current.notesBody || null) === template.value.notesBody &&
        (currentVenue.address || null) === nextVenue.address && (currentVenue.access || null) === nextVenue.access;
      // 同じ内容の再送(ネットワーク再試行)ではversionを進めない。
      if (same) return {eventId: request.eventId, version: current.version, changed: false};
      const version = (current && Number.isInteger(current.version) ? current.version : 0) + 1;
      tx.update(ref, {
        ...(hasMapping ? {participationMapping: request.participationMapping} : {}),
        winnerMailTemplate: {...template.value, version, updatedAt: serverTimestamp(), updatedBy: identity.uid},
        venueInfo: nextVenue,
        ...(mailSettings ? {senderName: mailSettings.senderName, contact: mailSettings.contact,
          confirmedMailSettings: {...(event.confirmedMailSettings || {}), talkTimeText: mailSettings.talkTimeText}} : {}),
      });
      return {eventId: request.eventId, version, changed: true};
    });
  }

  async function updateWaitlistTemplate({identity, eventId, value}) {
    const field = templateFieldFor(NOTIFICATION_TYPES.WAITLIST_PROMOTION);
    const db = getDb();
    const ref = db.collection("events").doc(eventId);
    return db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      const event = snapshot.data();
      if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      const current = event[field] || null;
      const same = current && current.subject === value.subject && current.introBody === value.introBody &&
        current.closingBody === value.closingBody && (current.notesBody || null) === value.notesBody &&
        (current.adoptionNotesBody || null) === (value.adoptionNotesBody || null);
      // 同じ内容の再送ではversionを進めない。
      if (same) return {eventId, version: current.version, changed: false, notificationType: NOTIFICATION_TYPES.WAITLIST_PROMOTION};
      const version = (current && Number.isInteger(current.version) ? current.version : 0) + 1;
      tx.update(ref, {[field]: {...value, version, updatedAt: serverTimestamp(), updatedBy: identity.uid}});
      return {eventId, version, changed: true, notificationType: NOTIFICATION_TYPES.WAITLIST_PROMOTION};
    });
  }

  // 「実際にこの参加者へ届くメール」の完成形。実送信と同じ composeWinnerMailFor を使う。
  // テンプレートは、参加者の取込回の通知種別で決める(送信と同じ)。notificationTypeを指定した場合だけ、その種別のテンプレートで表示する
  // (送信には影響しない。繰り上げの取込回が無い段階でも、繰り上げ当選メールの文面を確認できるようにするため)。
  async function preview({data}) {
    const request = parseKeys(data, ["eventId", "participantId", "notificationType"]);
    if (!isValidParticipantId(request.participantId)) throw invalid("invalid-participant-id");
    const requestedType = parseNotificationType(request.notificationType);
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);

    const participantSnapshot = await db.collection("participants").doc(request.participantId).get();
    if (!participantSnapshot.exists) throw new ApiError("not-found", "参加者が見つかりません。");
    const participant = participantSnapshot.data();
    if (participant.eventId !== request.eventId) throw new ApiError("failed-precondition", "参加者がこのイベントのものではありません。", {code: "participant-event-mismatch"});
    if (participant.status !== "active") throw new ApiError("failed-precondition", "参加者は有効ではありません。", {code: "participant-not-active"});
    // 送信対象は「committedなimportBatch由来のparticipant」だけ。committing/failedのbatchの参加者はプレビューも対象外。
    if (typeof participant.importBatchId !== "string") throw new ApiError("failed-precondition", "取込由来の参加者ではありません。", {code: "participant-not-from-import"});
    const batchSnapshot = await db.collection("importBatches").doc(participant.importBatchId).get();
    if (!batchSnapshot.exists || batchSnapshot.data().eventId !== request.eventId || batchSnapshot.data().status !== "committed") {
      throw new ApiError("failed-precondition", "取込が完了(committed)していないため、この参加者のメールはプレビューできません。", {code: "batch-not-committed"});
    }
    const notificationType = requestedType || notificationTypeOf(batchSnapshot.data());
    const built = buildMailSnapshot(request.eventId, event, {templateField: templateFieldFor(notificationType)});
    if (!built.ok) return {ready: false, problems: built.problems};

    const rendered = await composeWinnerMailFor({
      db, snapshot: built.snapshot, participantId: request.participantId, participant, appBaseUrl: getAppBaseUrl(), generateQrPng,
    });
    if (!rendered.ok) return {ready: false, problems: rendered.problems};
    return {
      ready: true,
      eventId: request.eventId,
      participantId: request.participantId,
      notificationType,
      templateVersion: built.snapshot.template.version,
      senderName: built.snapshot.event.senderName,
      subject: rendered.subject,
      text: rendered.text,
      html: rendered.html,
      qrPayload: rendered.qrPayload,
      webPassUrl: rendered.webPassUrl,
      qrPngBase64: rendered.attachments[0].contentBase64,
      missingOptional: missingOptionalFields(built.snapshot),
    };
  }

  return {getSettings, updateTemplate, preview};
}

module.exports = {createWinnerMailApi, loadConfirmedEvent};
