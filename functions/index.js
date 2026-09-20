const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret, defineString} = require("firebase-functions/params");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {createHash, randomBytes} = require("crypto");

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
      const sendAt = event.confirmationSendAt?.toDate?.();
      const startAt = event.startAt?.toDate?.();
      if (!sendAt || !startAt || now < sendAt || now >= startAt) continue;
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
    const db = getFirestore();
    const participantRef = db.collection("participants").doc(participantId);
    const participant = await participantRef.get();
    if (!participant.exists) throw new HttpsError("not-found", "参加者が見つかりません。");
    if (participant.data().eventId !== eventId) {
      throw new HttpsError("permission-denied", "イベントが一致しません。");
    }
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
    const db = getFirestore();
    const eventRef = db.collection("events").doc(eventId);
    const event = await eventRef.get();
    if (!event.exists) throw new HttpsError("not-found", "イベントが見つかりません。");
    if (event.data().eventId !== eventId) {
      throw new HttpsError("permission-denied", "イベントIDが一致しません。");
    }
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
