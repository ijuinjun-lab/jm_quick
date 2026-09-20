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

function createWinnerMailApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl}) {
  // 現在のテンプレート・会場情報・不足している項目(送信できるか)を返す。個人情報は含まない。
  async function getSettings({data}) {
    const {eventId} = parseKeys(data, ["eventId"]);
    const {event} = await loadConfirmedEvent(getDb(), eventId);
    const built = buildMailSnapshot(eventId, event);
    const template = event.winnerMailTemplate || null;
    return {
      eventId,
      template: template ? {
        subject: template.subject || "", introBody: template.introBody || "", closingBody: template.closingBody || "",
        notesBody: template.notesBody || "", version: Number.isInteger(template.version) ? template.version : 0,
        updatedBy: template.updatedBy || null, updatedAt: iso(template.updatedAt),
      } : null,
      venueInfo: {address: (event.venueInfo && event.venueInfo.address) || "", access: (event.venueInfo && event.venueInfo.access) || ""},
      event: {eventName: event.eventName || "", venue: event.venue || "", contact: event.contact || "", senderName: event.senderName || "", startAt: iso(event.startAt)},
      ready: built.ok,
      problems: built.ok ? [] : built.problems,
      missingOptional: built.ok ? missingOptionalFields(built.snapshot) : [],
    };
  }

  async function updateTemplate({identity, data}) {
    const request = parseKeys(data, ["eventId", "template", "venueInfo"]);
    const template = validateTemplateInput(request.template);
    if (!template.ok) throw invalid("invalid-template", {errors: template.errors});
    let venue = null;
    if (request.venueInfo !== undefined) {
      venue = validateVenueInfo(request.venueInfo);
      if (!venue.ok) throw invalid("invalid-venue-info", {errors: venue.errors});
    }
    const db = getDb();
    const ref = db.collection("events").doc(request.eventId);
    return db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      const event = snapshot.data();
      if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      const current = event.winnerMailTemplate || null;
      const currentVenue = event.venueInfo || {};
      const nextVenue = venue ? venue.value : {address: currentVenue.address || null, access: currentVenue.access || null};
      const same = current && current.subject === template.value.subject && current.introBody === template.value.introBody &&
        current.closingBody === template.value.closingBody && (current.notesBody || null) === template.value.notesBody &&
        (currentVenue.address || null) === nextVenue.address && (currentVenue.access || null) === nextVenue.access;
      // 同じ内容の再送(ネットワーク再試行)ではversionを進めない。
      if (same) return {eventId: request.eventId, version: current.version, changed: false};
      const version = (current && Number.isInteger(current.version) ? current.version : 0) + 1;
      tx.update(ref, {
        winnerMailTemplate: {...template.value, version, updatedAt: serverTimestamp(), updatedBy: identity.uid},
        venueInfo: nextVenue,
      });
      return {eventId: request.eventId, version, changed: true};
    });
  }

  // 「実際にこの参加者へ届くメール」の完成形。実送信と同じ composeWinnerMailFor を使う。
  async function preview({data}) {
    const request = parseKeys(data, ["eventId", "participantId"]);
    if (!isValidParticipantId(request.participantId)) throw invalid("invalid-participant-id");
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event);
    if (!built.ok) return {ready: false, problems: built.problems};

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

    const rendered = await composeWinnerMailFor({
      db, snapshot: built.snapshot, participantId: request.participantId, participant, appBaseUrl: getAppBaseUrl(), generateQrPng,
    });
    if (!rendered.ok) return {ready: false, problems: rendered.problems};
    return {
      ready: true,
      eventId: request.eventId,
      participantId: request.participantId,
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
