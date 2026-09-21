// 前日リマインド(confirmed)のAPI: 設定・プレビュー・ジョブの作成(自動/手動)・状態・失敗分の再送。すべてadmin専用callable(index.jsで認可)。
// 定期実行(reconcileDue)は、既存の sweepConfirmedMailDelivery の冒頭から呼ばれる(Schedulerを増やさない)。
//
// ■ 当選メールとは別の配送: type=reminder。jobは reminder-{eventId}(イベントに1つ)、配送記録は mailDeliveries/{participantId}_reminder。
//   当選メール送信済みでも、リマインドは別の配送として送れる。リマインドの状態は当選メールの状態に影響しない(逆も同じ)。
// ■ 配送エンジン(claim・lease・保存則・dispatchActive・halt・上限DELIVERY_LIMITS)は当選メールと共通(send_jobs.js / delivery_worker.js)。
//   このファイルは「何を・誰へ・いつ」だけを決める。
// ■ テンプレートは event.reminderMailTemplate(当選メールの winnerMailTemplate とは別データ)。ジョブ作成時にversionごとsnapshotへ固定する。
// ■ 送信日時(reminderSendAt)と有効化(reminderEnabled、既定false)は、明示的に管理者が設定する。設定の保存だけではメールは送られない。
//   自動でジョブが作られる条件: flow=confirmed / reminderEnabled=true / reminderSendAt <= 現在 / イベント未終了 / 対象1件以上 / 同じジョブが未作成。
// ■ 対象者はジョブ作成の時点で確定し、targetCountとして固定する。作成後に参加者が増減しても、既存ジョブへは自動で追加しない。
// ■ 設定の変更は「まだジョブが作られていない次の判断」にだけ作用する。作成済みジョブの配送は、設定の変更で止めも作り直しもしない。
// ■ 内部処理の入力はeventId/jobIdだけ。氏名・メール・本文・QR・publicIdをscheduler/workerへ渡さない(配送時にFirestoreの正本から取得)。

const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {buildMailSnapshot, missingOptionalFields, toDate} = require("./mail_view_model");
const {validateTemplateInput, templateProblems} = require("./winner_mail_template");
const {loadConfirmedEvent} = require("./winner_mail_api");
const {composeReminderMailFor} = require("./winner_mail_message");
const {collectReminderTargets} = require("./reminder_targets");
const {jobIdForReminder, JOB} = require("./send_jobs");
const {isValidParticipantId} = require("../programs");

const TEMPLATE_FIELD = "reminderMailTemplate";
const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const SCHEDULER_IDENTITY = Object.freeze({uid: "system:reminder-scheduler"});
const SCAN_LIMIT = 50; // 定期実行が1回に調べる「自動送信が有効なイベント」の上限(読み取りの上限)
const REMINDER_LABEL = "前日リマインド";
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("body-not-object");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unknown-key", {path: key});
  if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id");
  return data;
}

// イベントの終了時刻(endAt、無ければstartAt)。これ以降はリマインドを作成・送信開始しない。
const eventEnd = (event) => toDate(event.endAt) || toDate(event.startAt);

function createReminderApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl, winnerSendApi, now = () => Date.now(), logger}) {
  const log = logger || console;
  const {engine, worker} = winnerSendApi;
  const jobRef = (db, jobId) => db.collection("sendJobs").doc(jobId);

  const eventEnded = (event) => { const end = eventEnd(event); return Boolean(end) && now() >= end.getTime(); };

  // ---- 設定 ----------------------------------------------------------------------------------------
  async function getSettings({data}) {
    const request = parseKeys(data, ["eventId"]);
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event, {templateField: TEMPLATE_FIELD});
    const template = event[TEMPLATE_FIELD] || null;
    const targets = await collectReminderTargets(db, request.eventId);
    const jobId = jobIdForReminder(request.eventId);
    const job = await winnerSendApi.jobViewOf(jobId);
    return {
      eventId: request.eventId,
      eventName: typeof event.eventName === "string" ? event.eventName : "",
      eventStartAt: iso(event.startAt),
      eventEnded: eventEnded(event),
      enabled: event.reminderEnabled === true,
      sendAt: iso(event.reminderSendAt),
      template: template ? {
        subject: template.subject || "", introBody: template.introBody || "", closingBody: template.closingBody || "",
        notesBody: template.notesBody || "", version: Number.isInteger(template.version) ? template.version : 0,
      } : null,
      ready: built.ok,
      problems: built.ok ? [] : built.problems,
      missingOptional: built.ok ? missingOptionalFields(built.snapshot) : [],
      // 対象人数・対象外人数はサーバーの計算結果(イベント全体の全active participant。取込回は問わない)
      targets: {targetCount: targets.targets.length, excludedCount: targets.excludedCount, excludedByReason: targets.excludedByReason, totalParticipants: targets.totalParticipants},
      previewParticipantId: targets.targets.length > 0 ? targets.targets[0] : null,
      job,
      // ジョブ作成後に参加者が追加・状態変更された場合の注意用(既存ジョブへは自動で追加しない)
      changedSinceJob: job ? {currentTargetCount: targets.targets.length, jobTargetCount: job.targetCount, changed: targets.targets.length !== job.targetCount} : null,
    };
  }

  function parseSendAt(value) {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) throw invalid("invalid-send-at");
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) throw invalid("invalid-send-at");
    return date;
  }

  // 設定の保存(有効/無効・送信日時・テンプレート)。保存だけではメールは送られない。
  async function updateSettings({identity, data}) {
    const request = parseKeys(data, ["eventId", "reminderEnabled", "reminderSendAt", "template", "acknowledgePast"]);
    if (request.reminderEnabled === undefined && request.reminderSendAt === undefined && request.template === undefined) throw invalid("nothing-to-update");
    if (request.reminderEnabled !== undefined && typeof request.reminderEnabled !== "boolean") throw invalid("invalid-enabled");
    if (request.acknowledgePast !== undefined && typeof request.acknowledgePast !== "boolean") throw invalid("invalid-acknowledge");
    let sendAt;
    if (request.reminderSendAt !== undefined) sendAt = request.reminderSendAt === null ? null : parseSendAt(request.reminderSendAt);
    let template;
    if (request.template !== undefined) {
      template = validateTemplateInput(request.template);
      if (!template.ok) throw invalid("invalid-template", {errors: template.errors});
    }
    const db = getDb();
    const ref = db.collection("events").doc(request.eventId);
    return db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const jobExists = (await tx.get(jobRef(db, jobIdForReminder(request.eventId)))).exists;
      if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      const event = snapshot.data();
      if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      const current = event[TEMPLATE_FIELD] || null;
      // テンプレート: 内容が変わるときだけversionを進める(同じ内容の再送では進めない)。当選メールのテンプレートには触れない。
      let nextTemplate = current;
      if (template) {
        const same = current && current.subject === template.value.subject && current.introBody === template.value.introBody &&
          current.closingBody === template.value.closingBody && (current.notesBody || null) === template.value.notesBody;
        if (!same) {
          const version = (current && Number.isInteger(current.version) ? current.version : 0) + 1;
          nextTemplate = {...template.value, version, updatedAt: serverTimestamp(), updatedBy: identity.uid};
        }
      }
      const enabled = request.reminderEnabled !== undefined ? request.reminderEnabled : event.reminderEnabled === true;
      const nextSendAt = sendAt !== undefined ? sendAt : toDate(event.reminderSendAt);
      if (enabled) {
        // 有効化には、送信日時・完全なテンプレート・送信に必要なイベント情報が揃っていること。
        if (!nextSendAt) throw new ApiError("failed-precondition", "自動送信を有効にするには、送信予定日時を設定してください。", {code: "send-at-required"});
        const built = buildMailSnapshot(request.eventId, {...event, [TEMPLATE_FIELD]: nextTemplate}, {templateField: TEMPLATE_FIELD});
        if (!built.ok) throw new ApiError("failed-precondition", "前日リマインドの文面またはイベント情報が不足しているため、自動送信を有効にできません。", {code: "mail-not-ready", problems: built.problems});
        // 送信のタイミングに関わる変更(有効化・送信日時)で、まだジョブが作られていない場合だけ、終了・過去日時を検査する。
        // (文面だけの編集や、作成済みジョブがある場合の設定変更は、新しい送信を引き起こさないので対象外)
        const scheduleChanged = request.reminderEnabled !== undefined || sendAt !== undefined;
        if (scheduleChanged && !jobExists) {
          if (eventEnded(event)) throw new ApiError("failed-precondition", "イベントが終了しているため、自動送信を有効にできません。", {code: "event-ended"});
          // 過去の時刻で有効にすると、次の定期実行で直ちに全員へ送信される。明示的な確認(acknowledgePast)がなければサーバーが拒否する。
          if (nextSendAt.getTime() <= now() && request.acknowledgePast !== true) {
            throw new ApiError("failed-precondition", "送信予定日時が過去です。有効にすると直ちに送信されます。確認のうえ、もう一度実行してください。", {code: "send-at-in-past"});
          }
        }
      }
      const update = {reminderUpdatedAt: serverTimestamp(), reminderUpdatedBy: identity.uid};
      if (request.reminderEnabled !== undefined) update.reminderEnabled = request.reminderEnabled;
      if (sendAt !== undefined) update.reminderSendAt = sendAt;
      if (nextTemplate !== current) update[TEMPLATE_FIELD] = nextTemplate;
      tx.update(ref, update);
      // 既存ジョブは変更しない(設定は「まだジョブが作られていない次の判断」にだけ作用する)。
      return {
        eventId: request.eventId, enabled, sendAt: nextSendAt ? nextSendAt.toISOString() : null,
        templateVersion: nextTemplate && Number.isInteger(nextTemplate.version) ? nextTemplate.version : null,
        templateChanged: nextTemplate !== current,
      };
    });
  }

  // ---- プレビュー(当選メールと同じview model・レンダラー。文章だけが別テンプレート) -------------------------------
  async function preview({data}) {
    const request = parseKeys(data, ["eventId", "participantId"]);
    if (!isValidParticipantId(request.participantId)) throw invalid("invalid-participant-id");
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event, {templateField: TEMPLATE_FIELD});
    if (!built.ok) return {ready: false, problems: built.problems};
    const {targets} = await collectReminderTargets(db, request.eventId);
    if (!targets.includes(request.participantId)) {
      throw new ApiError("failed-precondition", "この参加者は前日リマインドの対象ではありません。", {code: "participant-not-target"});
    }
    const participant = (await db.collection("participants").doc(request.participantId).get()).data();
    const rendered = await composeReminderMailFor({db, snapshot: built.snapshot, participantId: request.participantId, participant, appBaseUrl: getAppBaseUrl(), generateQrPng});
    if (!rendered.ok) return {ready: false, problems: rendered.problems};
    return {
      ready: true, eventId: request.eventId, participantId: request.participantId, templateVersion: built.snapshot.template.version,
      senderName: built.snapshot.event.senderName, subject: rendered.subject, text: rendered.text, html: rendered.html,
      qrPayload: rendered.qrPayload, webPassUrl: rendered.webPassUrl, qrPngBase64: rendered.attachments[0].contentBase64,
      missingOptional: missingOptionalFields(built.snapshot),
    };
  }

  // ---- ジョブの作成(自動・手動の共通の入口) ----------------------------------------------------------------
  // どちらから入っても reminder-{eventId} の1つのジョブへ到達する。既にあれば、その状態を返す(再作成・対象の追加・状態の巻き戻しはしない)。
  // expected*: 管理画面で確認した値。ジョブを新規作成する場合だけ照合し、違えば作成しない。
  async function ensureJob({db, identity, eventId, expectedTemplateVersion, expectedTargetCount}) {
    const {event} = await loadConfirmedEvent(db, eventId);
    const jobId = jobIdForReminder(eventId);
    const existing = await jobRef(db, jobId).get();
    if (existing.exists && existing.data().status !== JOB.PREPARING) return {...(await engine.summarize(db, jobId)), alreadyExisted: true};
    if (eventEnded(event)) throw new ApiError("failed-precondition", "イベントが終了しているため、前日リマインドを作成できません。", {code: "event-ended"});
    const built = buildMailSnapshot(eventId, event, {templateField: TEMPLATE_FIELD});
    if (!built.ok) {
      throw new ApiError("failed-precondition", "前日リマインドの文面またはイベント情報が不足しているため、ジョブを作成できません。", {code: "mail-not-ready", problems: built.problems});
    }
    // 対象者は「この時点」の全active participant(イベント全体)。ここで確定し、targetCountとして固定する。
    const collected = await collectReminderTargets(db, eventId);
    if (collected.targets.length === 0) throw new ApiError("failed-precondition", "送信対象の参加者がいません。", {code: "no-targets"});
    if (!existing.exists) {
      if (expectedTemplateVersion !== undefined && expectedTemplateVersion !== built.snapshot.template.version) {
        throw new ApiError("failed-precondition", "確認したテンプレートのバージョンが変更されています。画面を更新して、もう一度確認してください。",
          {code: "template-version-changed", expected: expectedTemplateVersion, current: built.snapshot.template.version});
      }
      if (expectedTargetCount !== undefined && expectedTargetCount !== collected.targets.length) {
        throw new ApiError("failed-precondition", "確認した対象人数と現在の対象人数が異なります。画面を更新して、もう一度確認してください。",
          {code: "target-count-changed", expected: expectedTargetCount, current: collected.targets.length});
      }
    }
    return engine.openJob({
      db, identity, type: "reminder", jobId, eventId, targets: collected.targets, excludedInactiveCount: collected.excludedCount, snapshot: built.snapshot,
    });
  }

  // 管理者の手動開始(復旧・前倒し用)。自動開始と同じジョブへ到達し、別便は作らない。サーバー側の継続処理へ引き渡す。
  async function startDelivery({identity, data}) {
    const request = parseKeys(data, ["eventId", "expectedTemplateVersion", "expectedTargetCount", "dispatch"]);
    for (const key of ["expectedTemplateVersion", "expectedTargetCount"]) {
      if (request[key] !== undefined && !Number.isInteger(request[key])) throw invalid(`invalid-${key}`);
    }
    if (request.dispatch !== undefined && typeof request.dispatch !== "boolean") throw invalid("invalid-dispatch");
    const db = getDb();
    const job = await ensureJob({db, identity, eventId: request.eventId, expectedTemplateVersion: request.expectedTemplateVersion, expectedTargetCount: request.expectedTargetCount});
    if (request.dispatch === false || job.status !== JOB.READY) return job;
    return {...(await worker.requestDelivery({db, identity, jobId: job.jobId})), alreadyExisted: job.alreadyExisted};
  }

  // ---- 状態・失敗分の再送 ---------------------------------------------------------------------------------
  async function getJob({data}) {
    const request = parseKeys(data, ["eventId", "itemStatus", "limit", "after"]);
    return winnerSendApi.readJob({...winnerSendApi.parseReadOptions(request), jobId: jobIdForReminder(request.eventId), batchLabel: REMINDER_LABEL});
  }

  // failed(確実に渡っていない)の項目だけを未送信へ戻す。sent・unknown・sending・pendingは対象外。送信は startDelivery(引き渡し)が行う。
  async function retryFailed({data}) {
    const request = parseKeys(data, ["eventId"]);
    return engine.retryFailed({db: getDb(), jobId: jobIdForReminder(request.eventId)});
  }

  // ---- 定期実行: 送信時刻に達したイベントのジョブを作成し、サーバー側の継続処理へ引き渡す ----------------------------------
  // 既存の sweepConfirmedMailDelivery の冒頭から呼ばれる。何度実行されても、同じイベントのジョブは1つ(決定的ID + transaction)。
  async function reconcileDue({limit = 5} = {}) {
    const db = getDb();
    const events = (await db.collection("events").where("reminderEnabled", "==", true).limit(SCAN_LIMIT).get()).docs;
    const created = [];
    for (const doc of events) {
      if (created.length >= limit) break;
      const event = doc.data();
      if (!isConfirmedFlow(event)) continue;
      const sendAt = toDate(event.reminderSendAt);
      if (!sendAt || sendAt.getTime() > now()) continue; // 送信予定日時に未到達
      if (event.reminderJobReady === true) continue; // 作成済み(標識。ジョブを毎回読まないため)
      const jobId = jobIdForReminder(doc.id);
      try {
        const existing = await jobRef(db, jobId).get();
        if (existing.exists && existing.data().status !== JOB.PREPARING) {
          // 既に作成済み(手動開始など)。標識だけ付けて何もしない(再作成・再引き渡しはしない)。
          await doc.ref.update({reminderJobReady: true});
          continue;
        }
        const job = await ensureJob({db, identity: SCHEDULER_IDENTITY, eventId: doc.id});
        if (job.status === JOB.READY) {
          await worker.requestDelivery({db, identity: SCHEDULER_IDENTITY, jobId});
          await doc.ref.update({reminderJobReady: true});
          created.push(jobId);
        }
      } catch (error) {
        // 1つのイベントの失敗で他を止めない。個人情報を含まない情報だけをログに残す。次の定期実行で再度判断する。
        log.warn("reminder reconcile skipped", {eventId: doc.id, code: error && error.details && error.details.code ? error.details.code : (error && error.code) || "error"});
      }
    }
    return {created};
  }

  return {getSettings, updateSettings, preview, startDelivery, getJob, retryFailed, reconcileDue, ensureJob};
}

module.exports = {createReminderApi, TEMPLATE_FIELD, SCHEDULER_IDENTITY};
