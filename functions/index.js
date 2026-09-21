const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret, defineString} = require("firebase-functions/params");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {createHash, randomBytes} = require("crypto");
const {isLegacyFlow, legacyConfirmationDue} = require("./flow");
const {confirmedCallable, confirmedPublicPassCallable} = require("./auth");
const {getMyAccessRoleHandler} = require("./confirmed/access_role");
const {createImportApi} = require("./confirmed/import_api");
const {createWinnerMailApi} = require("./confirmed/winner_mail_api");
const {createWinnerSendApi} = require("./confirmed/winner_send_api");
const {createPassApi} = require("./confirmed/pass_api");
const {createReminderApi} = require("./confirmed/reminder_api");
const {generateQrPng} = require("./qr_png");
const {createMailApiTransport} = require("./mail_transport");

initializeApp();

const mailApiKey = defineSecret("MAIL_API_KEY");
const mailApiUrl = defineString("MAIL_API_URL");
const appBaseUrl = defineString("APP_BASE_URL", {default: "https://jm-quick.web.app"});

function formatJapaneseDateTime(value) {
  const date = value?.toDate instanceof Function ? value.toDate() : new Date(value);
  if (Number.isNaN(date.getTime())) return "主催者からのご案内をご確認ください";
  return new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "long",
    day: "numeric",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

function formatJapaneseDate(value) {
  const date = value?.toDate instanceof Function ? value.toDate() : new Date(value);
  if (Number.isNaN(date.getTime())) return "主催者からのご案内をご確認ください";
  return new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(date);
}

function eventSenderName(event) {
  const senderName = typeof event?.senderName === "string" ? event.senderName.trim() : "";
  const eventName = typeof event?.eventName === "string" ? event.eventName.trim() : "";
  return (senderName || eventName || "イベント事務局").slice(0, 100);
}

// 旧機能(案内メール・一括メール・当日参加登録など)は従来方式(legacy)のイベント専用。
// flow=confirmed(新方式)や未知のflowでは、副作用を起こす前に必ず拒否する。
function assertLegacyEvent(event, operation) {
  if (!isLegacyFlow(event)) {
    throw new HttpsError("failed-precondition",
      `この操作(${operation})は従来方式のイベント専用です。新方式のイベントでは使用できません。`);
  }
}

// 新方式(flow=confirmed)のイベント・参加者は、programAttendances・importBatches等と結びついている。
// 従来のこの削除処理(認証なし)はそれらを掃除できず、孤児データを残すため、専用の削除機能(admin認証・
// カスケード削除)が提供されるまで拒否する。黙って孤児データを残さない。
function assertDeletableFlow(event) {
  if (!isLegacyFlow(event)) {
    throw new HttpsError("failed-precondition",
      "新方式のイベント・参加者は、この削除機能では削除できません(専用の削除機能の提供までお待ちください)。");
  }
}

async function assertDeletableEvent(db, eventId) {
  const snapshot = await db.collection("events").doc(eventId).get();
  if (snapshot.exists) assertDeletableFlow(snapshot.data());
}

exports.sendParticipantMail = onCall(
  {region: "asia-northeast1", secrets: [mailApiKey], timeoutSeconds: 30},
  async (request) => {
    const {participantId, publicId, eventId, type} = request.data || {};
    if (typeof participantId !== "string" || typeof publicId !== "string" ||
        typeof eventId !== "string" || !eventId ||
        !["invitation", "reconfirmation", "walkIn"].includes(type)) {
      throw new HttpsError("invalid-argument", "メール送信情報が不正です。");
    }

    const db = getFirestore();
    const participantRef = db.collection("participants").doc(participantId);
    const [participantSnapshot, eventSnapshot] = await Promise.all([
      participantRef.get(),
      db.collection("events").doc(eventId).get(),
    ]);
    if (!participantSnapshot.exists) throw new HttpsError("not-found", "参加者が見つかりません。");
    const participant = participantSnapshot.data();
    if (!eventSnapshot.exists || participant.publicId !== publicId ||
        participant.eventId !== eventId) {
      throw new HttpsError("permission-denied", "イベントまたは公開IDが一致しません。");
    }
    assertLegacyEvent(eventSnapshot.data(), "案内メール送信");
    if (type === "invitation") {
      await db.runTransaction(async (transaction) => {
        const current = await transaction.get(participantRef);
        const data = current.data() || {};
        if (data.invitationSent === true || data.invitationMailStatus === "sending") {
          throw new HttpsError("already-exists", "案内メールは送信済みです。");
        }
        transaction.update(participantRef, {
          invitationMailStatus: "sending",
          updatedAt: FieldValue.serverTimestamp(),
        });
      });
    }
    const event = eventSnapshot.data() || {eventName: "イベント参加受付"};
    const pageUrl = `${appBaseUrl.value().replace(/\/$/, "")}/p/${encodeURIComponent(participantId)}?publicId=${encodeURIComponent(publicId)}`;
    const isReconfirmation = type === "reconfirmation";
    const subject = type === "invitation"
      ? `【${event.eventName}】正式登録のお願い`
      : isReconfirmation
      ? `【${event.eventName}】参加予定の確認`
      : `【${event.eventName}】ご登録ありがとうございます`;
    const instruction = isReconfirmation ? "以下のマイページから参加予定をご回答ください。" : type === "walkIn" ? "当日参加登録が完了しました。以下があなたのマイページです。" : "";
    const eventDate = formatJapaneseDateTime(event.startAt);
    const registrationDeadline = formatJapaneseDate(event.registrationDeadline);
    const venue = String(event.venue || "主催者からのご案内をご確認ください");
    const contact = String(event.contact || "イベント事務局");
    const text = type === "invitation"
      ? `${participant.name}様\n\n` +
        `このたびは「${event.eventName}」へお申し込みいただき、ありがとうございます。\n\n` +
        "現在、お客様の参加枠を確保しております。\n\n" +
        "イベントへご参加いただくため、まずは以下の専用ページから正式登録をお願いいたします。\n\n" +
        "正式登録いただいた方には、開催前日にあらためて参加予定の確認をご案内いたします。\n\n" +
        "━━━━━━━━━━━━━━\n" +
        `正式登録はこちら\n${pageUrl}\n` +
        "━━━━━━━━━━━━━━\n\n" +
        `登録期限\n${registrationDeadline}\n\n` +
        `開催日時\n${eventDate}\n\n` +
        `会場\n${venue}\n\n` +
        `お問い合わせ先\n${contact}\n`
      : `${participant.name}様\n\n${event.eventName}\n${instruction}\n\n${pageUrl}\n`;

    const endpoint = mailApiUrl.value().replace(/\/$/, "");
    if (!endpoint.startsWith("https://")) {
      console.error("MAIL_API_URL must be an HTTPS URL");
      throw new HttpsError("failed-precondition", "メールサービスが設定されていません。");
    }
    let response;
    try {
      console.log("Mail API dispatch", {
        participantId,
        eventId,
        type,
        senderName: eventSenderName(event),
        endpoint,
      });
      response = await fetch(`${endpoint}/v1/mail/send`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${mailApiKey.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          to: participant.email,
          senderName: eventSenderName(event),
          subject,
          text,
          metadata: {app: "jm-quick", participantId, type},
        }),
      });
    } catch (error) {
      console.error("Mail API request failed", {participantId, type, error});
      if (type === "invitation") {
        await participantRef.update({
          invitationMailStatus: "failed",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      throw new HttpsError("unavailable", "メールサービスへ接続できませんでした。");
    }
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      console.error("Mail API error", {participantId, type, status: response.status, result});
      if (type === "invitation") {
        await participantRef.update({
          invitationMailStatus: "failed",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      throw new HttpsError("internal", `メールサービスエラー: ${result.error || response.status}`);
    }

    const now = FieldValue.serverTimestamp();
    const update = isReconfirmation
      ? {reconfirmationMailSent: true, reconfirmationMailSentAt: now, updatedAt: now}
      : {
          invitationSent: true,
          invitationSentAt: now,
          invitationMailStatus: "sent",
          invitationMessageId: result.messageId || "",
          updatedAt: now,
        };
    await Promise.all([
      participantRef.update(update),
      db.collection("mailLogs").add({participantId, eventId, type, providerMessageId: result.messageId || "", sentAt: now}),
    ]);
    return {success: true, messageId: result.messageId || ""};
  },
);

exports.registerWalkIn = onCall(
  {region: "asia-northeast1", secrets: [mailApiKey], timeoutSeconds: 30},
  async (request) => {
    const {eventId, name, email, registeredCount} = request.data || {};
    const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
    if (typeof eventId !== "string" || !eventId ||
        typeof name !== "string" || !name.trim() ||
        !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail) ||
        !Number.isInteger(registeredCount) || registeredCount < 1) {
      throw new HttpsError("invalid-argument", "入力内容を確認してください。");
    }
    const db = getFirestore();
    const eventRef = db.collection("events").doc(eventId);
    const participantRef = db.collection("participants").doc();
    const publicId = `pub_${randomBytes(24).toString("base64url")}`;
    const uniqueId = createHash("sha256")
      .update(`${eventId}\n${normalizedEmail}`).digest("hex");
    const uniqueRef = db.collection("walkInRegistrations").doc(uniqueId);
    let event;
    await db.runTransaction(async (transaction) => {
      const [eventSnapshot, existing] = await Promise.all([
        transaction.get(eventRef), transaction.get(uniqueRef),
      ]);
      if (!eventSnapshot.exists || eventSnapshot.data().eventId !== eventId) {
        throw new HttpsError("not-found", "イベントが見つかりません。");
      }
      assertLegacyEvent(eventSnapshot.data(), "当日参加登録");
      if (existing.exists) {
        throw new HttpsError("already-exists",
          "すでにこのイベントへ登録されています。受付スタッフへお声がけください。");
      }
      event = eventSnapshot.data();
      const now = FieldValue.serverTimestamp();
      transaction.create(uniqueRef, {
        eventId, participantId: participantRef.id, email: normalizedEmail,
        createdAt: now,
      });
      transaction.create(participantRef, {
        participantId: participantRef.id,
        eventId,
        publicId,
        name: name.trim(),
        email: normalizedEmail,
        registeredCount,
        registrationType: "walkIn",
        invitationSent: false,
        invitationSentAt: null,
        participationConfirmed: true,
        participationConfirmedAt: now,
        reconfirmed: false,
        reconfirmedAt: null,
        attendanceResponse: null,
        reconfirmationMailSent: false,
        walkInMailStatus: "sending",
        createdAt: now,
        updatedAt: now,
      });
      transaction.create(db.collection("checkIns").doc(participantRef.id), {
        participantId: participantRef.id,
        eventId,
        checkedIn: false,
        attendedCount: null,
        checkedInAt: null,
        updatedAt: now,
      });
    });

    const pageUrl = `${appBaseUrl.value().replace(/\/$/, "")}/p/${encodeURIComponent(participantRef.id)}?publicId=${encodeURIComponent(publicId)}`;
    const endpoint = mailApiUrl.value().replace(/\/$/, "");
    try {
      const response = await fetch(`${endpoint}/v1/mail/send`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${mailApiKey.value()}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          to: normalizedEmail,
          senderName: eventSenderName(event),
          subject: `【${event.eventName}】ご登録ありがとうございます`,
          text: `${name.trim()}様\n\n${event.eventName}の当日参加登録が完了しました。\n\n` +
            "以下はご本人様専用のマイページです。必要に応じて登録内容や受付情報をご確認いただけます。\n\n" +
            `${pageUrl}\n`,
          metadata: {app: "jm-quick", participantId: participantRef.id,
            type: "walkIn"},
        }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
      const now = FieldValue.serverTimestamp();
      await Promise.all([
        participantRef.update({walkInMailStatus: "sent",
          walkInMailSentAt: now, walkInMessageId: result.messageId || "",
          updatedAt: now}),
        db.collection("mailLogs").add({participantId: participantRef.id,
          eventId, type: "walkIn", providerMessageId: result.messageId || "",
          sentAt: now}),
      ]);
      return {success: true, participantId: participantRef.id, publicId,
        mailSent: true, messageId: result.messageId || ""};
    } catch (error) {
      console.error("Walk-in mail failed", {eventId,
        participantId: participantRef.id, error});
      await participantRef.update({walkInMailStatus: "failed",
        updatedAt: FieldValue.serverTimestamp()});
      return {success: true, participantId: participantRef.id, publicId,
        mailSent: false, mailError: "確認メールを送信できませんでした。"};
    }
  },
);

exports.sendScheduledConfirmationMail = onSchedule(
  {
    schedule: "every 1 minutes",
    timeZone: "Asia/Tokyo",
    region: "asia-northeast1",
    secrets: [mailApiKey],
    timeoutSeconds: 300,
  },
  async () => {
    const db = getFirestore();
    const now = new Date();
    const endpoint = mailApiUrl.value().replace(/\/$/, "");
    const events = await db.collection("events").get();
    for (const eventSnapshot of events.docs) {
      const eventId = eventSnapshot.id;
      const event = eventSnapshot.data();
      // flow=confirmed(新方式)は、confirmationSendAtが設定されていても対象外(flow.js)。
      if (!legacyConfirmationDue(event, now)) continue;
      await eventSnapshot.ref.update({
        reconfirmEnabled: true,
        updatedAt: FieldValue.serverTimestamp(),
      });
      const participants = await db.collection("participants")
        .where("eventId", "==", eventId)
        .where("participationConfirmed", "==", true)
        .get();
      for (const snapshot of participants.docs) {
      const participantRef = snapshot.ref;
      let participant;
      try {
        participant = await db.runTransaction(async (transaction) => {
          const current = await transaction.get(participantRef);
          const data = current.data() || {};
          if (data.reconfirmationMailSent === true ||
              data.reconfirmationMailStatus === "sending") return null;
          transaction.update(participantRef, {
            reconfirmationMailStatus: "sending",
            updatedAt: FieldValue.serverTimestamp(),
          });
          return data;
        });
        if (!participant) continue;
        const pageUrl = `${appBaseUrl.value().replace(/\/$/, "")}/p/` +
          `${encodeURIComponent(snapshot.id)}?publicId=` +
          `${encodeURIComponent(participant.publicId)}`;
        const response = await fetch(`${endpoint}/v1/mail/send`, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${mailApiKey.value()}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            to: participant.email,
            senderName: eventSenderName(event),
            subject: `【${event.eventName}】参加予定の確認`,
            text: `${participant.name}様\n\n${event.eventName}の開催前日の参加予定確認です。\n` +
              `以下のマイページからご回答ください。\n\n${pageUrl}\n`,
            metadata: {app: "jm-quick", participantId: snapshot.id,
              type: "reconfirmation"},
          }),
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
        const sentAt = FieldValue.serverTimestamp();
        await Promise.all([
          participantRef.update({
            reconfirmationMailSent: true,
            reconfirmationMailSentAt: sentAt,
            reconfirmationMailStatus: "sent",
            reconfirmationMessageId: result.messageId || "",
            updatedAt: sentAt,
          }),
          db.collection("mailLogs").add({
            participantId: snapshot.id,
            eventId,
            type: "reconfirmation",
            providerMessageId: result.messageId || "",
            sentAt,
            trigger: "scheduler",
          }),
        ]);
      } catch (error) {
        console.error("Scheduled confirmation mail failed", {
          eventId,
          participantId: snapshot.id,
          error: String(error),
        });
        await participantRef.update({
          reconfirmationMailStatus: "failed",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      }
    }
  },
);

function bulkJobId(eventId, type) {
  return `${eventId}_${type}`;
}

function invitationText(participantId, participant, event) {
  const pageUrl = `${appBaseUrl.value().replace(/\/$/, "")}/p/` +
    `${encodeURIComponent(participantId)}?publicId=` +
    `${encodeURIComponent(participant.publicId)}`;
  return `${participant.name}様\n\n` +
    `このたびは「${event.eventName}」へお申し込みいただき、ありがとうございます。\n\n` +
    "現在、お客様の参加枠を確保しております。\n\n" +
    "イベントへご参加いただくため、まずは以下の専用ページから正式登録をお願いいたします。\n\n" +
    "正式登録いただいた方には、開催前日にあらためて参加予定の確認をご案内いたします。\n\n" +
    "━━━━━━━━━━━━━━\n" +
    `正式登録はこちら\n${pageUrl}\n` +
    "━━━━━━━━━━━━━━\n\n" +
    `登録期限\n${formatJapaneseDate(event.registrationDeadline)}\n\n` +
    `開催日時\n${formatJapaneseDateTime(event.startAt)}\n\n` +
    `会場\n${String(event.venue || "主催者からのご案内をご確認ください")}\n\n` +
    `お問い合わせ先\n${String(event.contact || "イベント事務局")}\n`;
}

function reconfirmationText(participantId, participant, event) {
  const pageUrl = `${appBaseUrl.value().replace(/\/$/, "")}/p/` +
    `${encodeURIComponent(participantId)}?publicId=` +
    `${encodeURIComponent(participant.publicId)}`;
  return `${participant.name}様\n\n${event.eventName}の開催前日の参加予定確認です。\n` +
    `以下のマイページからご回答ください。\n\n${pageUrl}\n`;
}

async function sendBulkMail(participantId, participant, event, type, jobId) {
  const endpoint = mailApiUrl.value().replace(/\/$/, "");
  if (!endpoint.startsWith("https://")) throw new Error("MAIL_API_URL is invalid");
  const isInvitation = type === "invitation";
  const response = await fetch(`${endpoint}/v1/mail/send`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${mailApiKey.value()}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      to: participant.email,
      senderName: eventSenderName(event),
      subject: isInvitation
        ? `【${event.eventName}】正式登録のお願い`
        : `【${event.eventName}】参加予定の確認`,
      text: isInvitation
        ? invitationText(participantId, participant, event)
        : reconfirmationText(participantId, participant, event),
      metadata: {app: "jm-quick", participantId, type, jobId},
    }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
  return result;
}

async function startBulkJob(request, type) {
  const {eventId, mode = "unsent"} = request.data || {};
  if (typeof eventId !== "string" || !eventId ||
      !["invitation", "reconfirmation"].includes(type) ||
      !["unsent", "failed", "unanswered"].includes(mode)) {
    throw new HttpsError("invalid-argument", "一括送信条件が不正です。");
  }
  const db = getFirestore();
  const eventRef = db.collection("events").doc(eventId);
  const jobRef = db.collection("mailJobs").doc(bulkJobId(eventId, type));
  const eventSnapshot = await eventRef.get();
  if (!eventSnapshot.exists || eventSnapshot.data().eventId !== eventId) {
    throw new HttpsError("not-found", "イベントが見つかりません。");
  }
  assertLegacyEvent(eventSnapshot.data(), "旧一括メール");
  const active = await db.runTransaction(async (transaction) => {
    const current = await transaction.get(jobRef);
    if (current.exists && ["preparing", "queued", "running"].includes(current.data().status)) {
      return true;
    }
    transaction.set(jobRef, {
      eventId,
      type,
      mode,
      status: "preparing",
      totalCount: 0,
      sentCount: 0,
      failedCount: 0,
      skippedCount: 0,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return false;
  });
  if (active) return {success: true, alreadyRunning: true, jobId: jobRef.id};

  const oldItems = await jobRef.collection("items").get();
  let writer = db.bulkWriter();
  for (const item of oldItems.docs) writer.delete(item.ref);
  await writer.close();
  const participants = await db.collection("participants")
    .where("eventId", "==", eventId).get();
  const eligible = participants.docs.filter((snapshot) => {
    const data = snapshot.data();
    if (type === "invitation") {
      if (data.registrationType !== "preRegistered" || data.invitationSent === true) return false;
      return mode === "failed"
        ? data.invitationMailStatus === "failed"
        : data.invitationMailStatus !== "failed" &&
          data.invitationMailStatus !== "sending";
    }
    return data.participationConfirmed === true &&
      data.attendanceResponse == null && data.reconfirmationMailSent === true;
  });
  writer = db.bulkWriter();
  for (const participant of eligible) {
    writer.set(jobRef.collection("items").doc(participant.id), {
      participantId: participant.id,
      eventId,
      type,
      status: "pending",
      createdAt: FieldValue.serverTimestamp(),
    });
  }
  await writer.close();
  await jobRef.update({
    status: eligible.length === 0 ? "completed" : "queued",
    totalCount: eligible.length,
    updatedAt: FieldValue.serverTimestamp(),
    completedAt: eligible.length === 0 ? FieldValue.serverTimestamp() : null,
  });
  return {success: true, alreadyRunning: false, jobId: jobRef.id,
    totalCount: eligible.length};
}

exports.startBulkInvitationMail = onCall(
  {region: "asia-northeast1", timeoutSeconds: 60},
  (request) => startBulkJob(request, "invitation"),
);

exports.startBulkReconfirmationMail = onCall(
  {region: "asia-northeast1", timeoutSeconds: 60},
  (request) => startBulkJob(request, "reconfirmation"),
);

async function processBulkItem(db, jobSnapshot, itemSnapshot, event) {
  const job = jobSnapshot.data();
  // 多重防御(3層目): 旧一括メールはlegacyイベントの参加者にしか送らない。
  if (!isLegacyFlow(event)) {
    await itemSnapshot.ref.update({status: "skipped", error: "non-legacy-flow",
      updatedAt: FieldValue.serverTimestamp()});
    return "skipped";
  }
  const participantRef = db.collection("participants").doc(itemSnapshot.id);
  let participant;
  const claimed = await db.runTransaction(async (transaction) => {
    const [itemCurrent, participantCurrent] = await Promise.all([
      transaction.get(itemSnapshot.ref), transaction.get(participantRef),
    ]);
    if (!itemCurrent.exists || itemCurrent.data().status !== "pending") {
      return false;
    }
    if (!participantCurrent.exists) {
      transaction.update(itemSnapshot.ref, {
        status: "skipped",
        error: "participant-not-found",
        updatedAt: FieldValue.serverTimestamp(),
      });
      return false;
    }
    const data = participantCurrent.data();
    if (data.eventId !== job.eventId ||
        (job.type === "invitation" && (data.invitationSent === true ||
          data.invitationMailStatus === "sending")) ||
        (job.type === "reconfirmation" && (data.attendanceResponse != null ||
          data.reconfirmationMailStatus === "sending"))) {
      transaction.update(itemSnapshot.ref, {status: "skipped",
        updatedAt: FieldValue.serverTimestamp()});
      return false;
    }
    transaction.update(itemSnapshot.ref, {status: "sending",
      updatedAt: FieldValue.serverTimestamp()});
    transaction.update(participantRef, {
      [job.type === "invitation" ? "invitationMailStatus" :
        "reconfirmationMailStatus"]: "sending",
      updatedAt: FieldValue.serverTimestamp(),
    });
    participant = data;
    return true;
  });
  if (!claimed) return "skipped";
  try {
    const result = await sendBulkMail(itemSnapshot.id, participant, event,
      job.type, jobSnapshot.id);
    const now = FieldValue.serverTimestamp();
    const participantUpdate = job.type === "invitation" ? {
      invitationSent: true,
      invitationSentAt: now,
      invitationMailStatus: "sent",
      invitationMessageId: result.messageId || "",
      updatedAt: now,
    } : {
      reconfirmationMailSent: true,
      reconfirmationMailSentAt: now,
      reconfirmationMailStatus: "sent",
      reconfirmationMessageId: result.messageId || "",
      updatedAt: now,
    };
    await Promise.all([
      participantRef.update(participantUpdate),
      itemSnapshot.ref.update({status: "sent", providerMessageId:
        result.messageId || "", sentAt: now, updatedAt: now}),
      db.collection("mailLogs").add({participantId: itemSnapshot.id,
        eventId: job.eventId, type: job.type,
        providerMessageId: result.messageId || "", sentAt: now,
        trigger: "bulk", jobId: jobSnapshot.id}),
    ]);
    return "sent";
  } catch (error) {
    console.error("Bulk mail failed", {jobId: jobSnapshot.id,
      participantId: itemSnapshot.id, error: String(error)});
    const now = FieldValue.serverTimestamp();
    await Promise.all([
      participantRef.update({
        [job.type === "invitation" ? "invitationMailStatus" :
          "reconfirmationMailStatus"]: "failed", updatedAt: now,
      }),
      itemSnapshot.ref.update({status: "failed", error: String(error),
        updatedAt: now}),
    ]);
    return "failed";
  }
}

exports.processBulkMailJobs = onSchedule(
  {schedule: "every 1 minutes", timeZone: "Asia/Tokyo",
    region: "asia-northeast1", secrets: [mailApiKey], timeoutSeconds: 300,
    maxInstances: 1},
  async () => {
    const db = getFirestore();
    const jobs = await db.collection("mailJobs").get();
    for (const jobSnapshot of jobs.docs.filter((doc) =>
      ["queued", "running"].includes(doc.data().status))) {
      const job = jobSnapshot.data();
      const eventSnapshot = await db.collection("events").doc(job.eventId).get();
      if (!eventSnapshot.exists) continue;
      // 多重防御(2層目): legacy以外のイベントのジョブは実行せず、再処理されないよう停止する。
      if (!isLegacyFlow(eventSnapshot.data())) {
        await jobSnapshot.ref.update({status: "blocked", blockedReason: "non-legacy-flow",
          updatedAt: FieldValue.serverTimestamp()});
        continue;
      }
      await jobSnapshot.ref.update({status: "running",
        updatedAt: FieldValue.serverTimestamp()});
      const pending = await jobSnapshot.ref.collection("items")
        .where("status", "==", "pending").limit(25).get();
      const totals = {sent: 0, failed: 0, skipped: 0};
      for (let index = 0; index < pending.docs.length; index += 5) {
        const results = await Promise.all(pending.docs.slice(index, index + 5)
          .map((item) => processBulkItem(db, jobSnapshot, item,
            eventSnapshot.data())));
        for (const result of results) totals[result]++;
      }
      const remaining = await jobSnapshot.ref.collection("items")
        .where("status", "==", "pending").limit(1).get();
      await jobSnapshot.ref.update({
        status: remaining.empty ? "completed" : "running",
        sentCount: FieldValue.increment(totals.sent),
        failedCount: FieldValue.increment(totals.failed),
        skippedCount: FieldValue.increment(totals.skipped),
        updatedAt: FieldValue.serverTimestamp(),
        ...(remaining.empty ? {completedAt: FieldValue.serverTimestamp()} : {}),
      });
    }
  },
);

exports.deleteParticipant = onCall(
  {region: "asia-northeast1", timeoutSeconds: 60},
  async (request) => {
    const {eventId, participantId} = request.data || {};
    if (typeof eventId !== "string" || !eventId ||
        typeof participantId !== "string" || !participantId) {
      throw new HttpsError("invalid-argument", "削除対象が不正です。");
    }
    // 新方式(confirmed)の参加者は上のassertDeletableEventで拒否している(programAttendances等の孤児データを残さないため)。
    // TODO(PHASE-8-REQUIRED): 新方式の参加者削除は、admin認証つきの専用callableで、programAttendances(participantId一致)・
    // 取込監査(importBatches/*/rows)との整合を保って実装すること。それまでこの旧削除では新方式を拒否し続ける。
    const db = getFirestore();
    const participantRef = db.collection("participants").doc(participantId);
    const participant = await participantRef.get();
    if (!participant.exists) throw new HttpsError("not-found", "参加者が見つかりません。");
    if (participant.data().eventId !== eventId) {
      throw new HttpsError("permission-denied", "イベントが一致しません。");
    }
    await assertDeletableEvent(db, eventId);
    const [logs, jobs, walkInRegistrations] = await Promise.all([
      db.collection("mailLogs").where("participantId", "==", participantId).get(),
      db.collection("mailJobs").where("eventId", "==", eventId).get(),
      db.collection("walkInRegistrations")
        .where("participantId", "==", participantId).get(),
    ]);
    const writer = db.bulkWriter();
    writer.delete(participantRef);
    writer.delete(db.collection("checkIns").doc(participantId));
    for (const job of jobs.docs) writer.delete(job.ref.collection("items").doc(participantId));
    for (const registration of walkInRegistrations.docs) writer.delete(registration.ref);
    for (const log of logs.docs) writer.update(log.ref, {
      participantDeleted: true,
      participantDeletedAt: FieldValue.serverTimestamp(),
    });
    await writer.close();
    return {success: true};
  },
);

exports.deleteEvent = onCall(
  {region: "asia-northeast1", timeoutSeconds: 120},
  async (request) => {
    const {eventId} = request.data || {};
    if (typeof eventId !== "string" || !eventId) {
      throw new HttpsError("invalid-argument", "削除対象イベントが不正です。");
    }
    // 新方式(confirmed)のイベントは下のassertDeletableFlowで拒否している(participants・programAttendances・importBatches等の
    // 孤児データを残さないため)。
    // TODO(PHASE-8-REQUIRED): 新方式のイベント削除は、admin認証つきの専用callableで、programAttendances・importBatches(rows含む)を
    // 含めてカスケード削除すること。それまでこの旧削除では新方式を拒否し続ける。
    const db = getFirestore();
    const eventRef = db.collection("events").doc(eventId);
    const event = await eventRef.get();
    if (!event.exists) throw new HttpsError("not-found", "イベントが見つかりません。");
    if (event.data().eventId !== eventId) {
      throw new HttpsError("permission-denied", "イベントIDが一致しません。");
    }
    assertDeletableFlow(event.data());
    const [participants, checkIns, jobs, logs, walkInRegistrations] = await Promise.all([
      db.collection("participants").where("eventId", "==", eventId).get(),
      db.collection("checkIns").where("eventId", "==", eventId).get(),
      db.collection("mailJobs").where("eventId", "==", eventId).get(),
      db.collection("mailLogs").where("eventId", "==", eventId).get(),
      db.collection("walkInRegistrations").where("eventId", "==", eventId).get(),
    ]);
    let writer = db.bulkWriter();
    for (const job of jobs.docs) {
      const items = await job.ref.collection("items").get();
      for (const item of items.docs) writer.delete(item.ref);
    }
    for (const participant of participants.docs) writer.delete(participant.ref);
    for (const checkIn of checkIns.docs) writer.delete(checkIn.ref);
    for (const job of jobs.docs) writer.delete(job.ref);
    for (const registration of walkInRegistrations.docs) {
      writer.delete(registration.ref);
    }
    const deletedAt = FieldValue.serverTimestamp();
    for (const log of logs.docs) writer.update(log.ref, {
      eventDeleted: true,
      eventDeletedAt: deletedAt,
    });
    writer.delete(eventRef);
    await writer.close();
    return {
      success: true,
      participantCount: participants.size,
      checkInCount: checkIns.size,
      mailJobCount: jobs.size,
      retainedMailLogCount: logs.size,
    };
  },
);

// --- 新方式(flow=confirmed)の認証callable ---------------------------------------------
// 新方式の管理系callableは必ず confirmedCallable(アクセスレベル, ハンドラ) で定義する(認可を通らないと実行されない)。
// 従来方式のcallableには認証を付けていない(旧JM Quickの認証はPhase 10)。
exports.getMyAccessRole = confirmedCallable("staffOrAdmin", getMyAccessRoleHandler);

// 当選者CSVの取込(admin専用)。preview=dry-run(書込みなし) / commit=サーバー側で再検証して登録。メールは送らない。
const importApi = createImportApi({getDb: getFirestore, serverTimestamp: () => FieldValue.serverTimestamp()});
exports.previewConfirmedImport = confirmedCallable("admin", importApi.preview);
exports.commitConfirmedImport = confirmedCallable("admin", importApi.commit, {timeoutSeconds: 300});

// 当選メール(confirmed): テンプレート設定・プレビュー・batch単位の送信ジョブ。すべてadmin専用。
// - テンプレートの更新は必ずこのcallable経由(Rulesでクライアントからの直接書込みは拒否)
// - プレビューと実送信は同じレンダラー(renderWinnerMail)を使う
// - ジョブの作成では1通も送らない。送信は管理者が processConfirmedWinnerMailJob を明示的に実行したときだけ
//   (前日リマインド等のSchedulerによる自動送信は、このPhaseでは作らない)
const serverTimestamp = () => FieldValue.serverTimestamp();
const winnerMailApi = createWinnerMailApi({
  getDb: getFirestore, serverTimestamp, generateQrPng, getAppBaseUrl: () => appBaseUrl.value(),
});
const winnerSendApi = createWinnerSendApi({
  getDb: getFirestore, serverTimestamp, generateQrPng, getAppBaseUrl: () => appBaseUrl.value(),
  getTransport: () => createMailApiTransport({endpoint: mailApiUrl.value(), apiKey: mailApiKey.value()}),
});
exports.getConfirmedWinnerMailSettings = confirmedCallable("admin", winnerMailApi.getSettings);
exports.updateConfirmedWinnerMailTemplate = confirmedCallable("admin", winnerMailApi.updateTemplate);
exports.previewConfirmedWinnerMail = confirmedCallable("admin", winnerMailApi.preview, {timeoutSeconds: 60});
exports.createConfirmedWinnerMailJob = confirmedCallable("admin", winnerSendApi.createJob, {timeoutSeconds: 300});
exports.processConfirmedWinnerMailJob = confirmedCallable("admin", winnerSendApi.processJob, {secrets: [mailApiKey], timeoutSeconds: 300});
exports.retryFailedConfirmedWinnerMails = confirmedCallable("admin", winnerSendApi.retryFailed, {timeoutSeconds: 120});
// サーバー側の継続処理(Phase 9A)。管理者の「送信開始」は、希望(dispatchActive)をsendJobsに記録するだけ。
// 実際の配送は、下の定期実行が、ブラウザとは無関係に最後まで進める。配送の状態・claim・leaseは従来のsendJobs/mailDeliveriesが正本。
exports.startConfirmedWinnerMailDelivery = confirmedCallable("admin", winnerSendApi.startDelivery, {timeoutSeconds: 60});
// 前日リマインド(Phase 9B)。イベント全体の全active participantが対象(取込回は問わない)。当選メールとは別のtype・別のjob・別の配送記録・別のテンプレート。
// 配送エンジンとサーバー側の継続処理(下のsweep)は当選メールと共通。設定・プレビュー・手動開始・状態・失敗分の再送はすべてadmin専用。
const reminderApi = createReminderApi({
  getDb: getFirestore, serverTimestamp, generateQrPng, getAppBaseUrl: () => appBaseUrl.value(), winnerSendApi,
});
exports.getConfirmedReminderSettings = confirmedCallable("admin", reminderApi.getSettings, {timeoutSeconds: 120});
exports.updateConfirmedReminderSettings = confirmedCallable("admin", reminderApi.updateSettings, {timeoutSeconds: 60});
exports.previewConfirmedReminderMail = confirmedCallable("admin", reminderApi.preview, {timeoutSeconds: 60});
exports.startConfirmedReminderDelivery = confirmedCallable("admin", reminderApi.startDelivery, {timeoutSeconds: 300});
exports.getConfirmedReminderJob = confirmedCallable("admin", reminderApi.getJob, {timeoutSeconds: 60});
exports.retryFailedConfirmedReminderMails = confirmedCallable("admin", reminderApi.retryFailed, {timeoutSeconds: 120});
// 内部の定期実行(ブラウザ・callableからは起動できない)。旧mailJobsのSchedulerとは別のconfirmed専用。mail-apiのSecretは従来の注入方式のまま。
// 1) 前日リマインドの送信時刻に達したイベントのジョブを作成して引き渡す(同じイベントのジョブは1つ) 2) 引き渡されたジョブの配送を進める。
// maxInstances: 1 で同時実行を1つに抑える(at-least-onceでも二重に動かさない。最終防御はitem単位のclaim)。
exports.sweepConfirmedMailDelivery = onSchedule(
  {schedule: "every 1 minutes", timeZone: "Asia/Tokyo", region: "asia-northeast1", secrets: [mailApiKey], timeoutSeconds: 300, maxInstances: 1},
  async () => {
    let reminders = 0;
    try {
      reminders = (await reminderApi.reconcileDue({limit: winnerSendApi.worker.limits.maxJobsPerSweep})).created.length;
    } catch (error) {
      console.error("reminder reconcile failed", {code: (error && error.code) || "error"}); // 配送のsweepは止めない
    }
    const results = await winnerSendApi.runSweep();
    console.log("confirmed mail delivery sweep", {jobs: results.length, remindersCreated: reminders, processed: results.reduce((n, r) => n + (r.processed || 0), 0)});
  },
);
// 送信管理画面用の読み取り専用API(admin専用)。Flutterはsendjobs/items/mailDeliveriesをFirestoreから直接読まず、必ずこれ経由で状態を取得する。
exports.listConfirmedWinnerMailBatches = confirmedCallable("admin", winnerSendApi.listBatches, {timeoutSeconds: 120});
exports.getConfirmedWinnerMailJob = confirmedCallable("admin", winnerSendApi.getJob, {timeoutSeconds: 60});

// Web参加証とprogram別受付(confirmed)。
// - getConfirmedParticipantPass: 参加者本人がログインなしで自分の参加証を閲覧(読み取り専用)。participantId+publicIdの組だけで閲覧でき、
//   受付・変更はできない。Phase 10でApp Check強制とrate limitを有効にする(auth.jsのPUBLIC_PASS_CALLABLE_OPTIONS / createPassApiのcheckRateLimit)
// - getConfirmedReceptionView / checkInConfirmedProgram: 受付はstaff/adminのみ(Firebase Auth + accessRoles)。programAttendancesが受付の正本
const passApi = createPassApi({getDb: getFirestore, serverTimestamp, getAppBaseUrl: () => appBaseUrl.value()});
exports.getConfirmedParticipantPass = confirmedPublicPassCallable(passApi.getPass);
exports.getConfirmedReceptionView = confirmedCallable("staffOrAdmin", passApi.getReceptionView);
exports.checkInConfirmedProgram = confirmedCallable("staffOrAdmin", passApi.checkIn);
// 受付後の訂正・取消はadminだけ(staffは初回受付のみ)。受付状態の正本はprogramAttendancesのまま。実変更ごとにhistoryを1件追記する。
exports.correctConfirmedProgramAttendance = confirmedCallable("admin", passApi.correct);
exports.cancelConfirmedProgramCheckIn = confirmedCallable("admin", passApi.cancel);
