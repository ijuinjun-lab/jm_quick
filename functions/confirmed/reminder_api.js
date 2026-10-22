// リマインド(confirmed)のAPI: 設定・プレビュー・ジョブの作成(自動/手動)・状態・失敗分の再送。すべてadmin専用callable(index.jsで認可)。
// 定期実行(reconcileDue)は、既存の sweepConfirmedMailDelivery の冒頭から呼ばれる(Schedulerを増やさない)。
//
// ■ 第1回は旧ID reminder-{eventId} / {participantId}_reminderを維持。第2回は reminder2- / _reminder2。
//   当選メール送信済みでも、リマインドは別の配送として送れる。リマインドの状態は当選メールの状態に影響しない(逆も同じ)。
// ■ 配送エンジン(claim・lease・保存則・dispatchActive・halt・上限DELIVERY_LIMITS)は当選メールと共通(send_jobs.js / delivery_worker.js)。
//   このファイルは「何を・誰へ・いつ」だけを決める。
// ■ テンプレートは第1回reminderMailTemplate / 第2回reminder2MailTemplate。ジョブ作成時にsnapshotへ固定する。
// ■ リマインドは管理者の手動送信専用(送信前の宛先一覧を確認してから開始する)。自動送信は停止している:
//   - reconcileDue(既存のsweepConfirmedMailDeliveryの冒頭から呼ばれる)は何もしない(ジョブを作らない・引き渡さない)。
//     過去に保存された reminderEnabled=true / reminderSendAt や、外部からの更新があっても、自動では送信されない。
//   - updateSettings は reminderEnabled=true(自動送信の有効化)を拒否する。保存済みの値は削除しない(無効化・日時・文面の保存は可能)。
//   手動で作成・引き渡したジョブの配送は、従来どおりsweep(サーバー側の継続処理)が行う。
// ■ 対象者はジョブ作成の時点で確定し、targetCountとして固定する。作成後に参加者が増減しても、既存ジョブへは自動で追加しない。
// ■ 対象者の判定は collectReminderRecipients(reminder_targets.js)だけ(設定画面・プレビュー・手動開始・自動作成で共通)。
//   当選メールが送信済み(sent)の参加者だけが対象。当選メールの結果不明(unknown)・重複登録の疑いが1件でもあれば、
//   手動・自動のどちらでもジョブを作らない(未解決の間は送らない。sentとみなさない・統合しない)。
//   手動開始は、管理画面で確認した照合値(expectedTargetsFingerprint)が必須。宛先・メールアドレス・program・時間・人数・
//   当選メールの状態のどれかが確認後に変わっていれば、作成しない(古い確認で送らない)。
// ■ 設定の変更は「まだジョブが作られていない次の判断」にだけ作用する。作成済みジョブの配送は、設定の変更で止めも作り直しもしない。
// ■ 内部処理の入力はeventId/jobIdだけ。氏名・メール・本文・QR・publicIdをscheduler/workerへ渡さない(配送時にFirestoreの正本から取得)。

const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {buildMailSnapshot, missingOptionalFields, toDate} = require("./mail_view_model");
const {validateTemplateInput} = require("./winner_mail_template");
const {loadConfirmedEvent} = require("./winner_mail_api");
const {composeReminderMailFor} = require("./winner_mail_message");
const {collectReminderRecipients, isReminderTarget} = require("./reminder_targets");
const {JOB} = require("./send_jobs");
const {roundOf, roundEvent, fieldFor, schedule, jobIdForReminder} = require("./reminder_rounds");
const {isValidParticipantId} = require("../programs");

const TEMPLATE_FIELD = "reminderMailTemplate";
const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const SCHEDULER_IDENTITY = Object.freeze({uid: "system:reminder-scheduler"});
const AUTO_SEND_DISABLED = true; // リマインドは手動送信専用(自動送信の経路を止める)
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("body-not-object");
  for (const key of Object.keys(data)) if (key !== "round" && !allowed.includes(key)) throw invalid("unknown-key", {path: key});
  if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id");
  roundOf(data.round);
  return data;
}

// イベントの終了時刻(endAt、無ければstartAt)。これ以降はリマインドを作成・送信開始しない。
const eventEnd = (event) => toDate(event.endAt) || toDate(event.startAt);

function createReminderApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl, winnerSendApi, now = () => Date.now(), logger}) {
  const {engine, worker} = winnerSendApi;
  const jobRef = (db, jobId) => db.collection("sendJobs").doc(jobId);

  const eventEnded = (event) => { const end = eventEnd(event); return Boolean(end) && now() >= end.getTime(); };

  // ---- 設定 ----------------------------------------------------------------------------------------
  async function getSettings({data}) {
    const request = parseKeys(data, ["eventId"]);
    const db = getDb();
    const {event: storedEvent} = await loadConfirmedEvent(db, request.eventId);
    const event = roundEvent(storedEvent, request.round);
    const built = buildMailSnapshot(request.eventId, event, {templateField: TEMPLATE_FIELD});
    const template = event[TEMPLATE_FIELD] || null;
    const targets = await collectReminderRecipients(db, request.eventId, {event});
    const jobId = jobIdForReminder(request.eventId, request.round);
    const job = await winnerSendApi.jobViewOf(jobId);
    return {
      eventId: request.eventId,
      eventName: typeof event.eventName === "string" ? event.eventName : "",
      eventStartAt: iso(event.startAt),
      eventEnded: eventEnded(event),
      enabled: roundOf(request.round) === 1 && event.reminderEnabled === true,
      sendAt: iso(event.reminderSendAt),
      round: roundOf(request.round), plannedDate: event.reminderPlannedDate, plannedTime: event.reminderPlannedTime,
      template: template ? {
        subject: template.subject || "", introBody: template.introBody || "", closingBody: template.closingBody || "",
        notesBody: template.notesBody || "", adoptionNotesBody: template.adoptionNotesBody || "", version: Number.isInteger(template.version) ? template.version : 0,
      } : null,
      ready: built.ok,
      problems: built.ok ? [] : built.problems,
      missingOptional: built.ok ? missingOptionalFields(built.snapshot) : [],
      // 対象人数・対象外人数はサーバーの計算結果(イベント全体の全active participant。取込回は問わない)
      targets: {targetCount: targets.targets.length, excludedCount: targets.excludedCount, excludedByReason: targets.excludedByReason, totalParticipants: targets.totalParticipants,
        countsByNotificationType: targets.counts, blocked: targets.blocked, fingerprint: targets.fingerprint},
      // 送信前の宛先一覧(対象・対象外とも)。個人情報を含むため、このAPIは対象イベントのevent_manager以上だけ(index.jsで認可)。
      recipients: targets.recipients,
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
    const request = parseKeys(data, ["eventId", "reminderEnabled", "reminderSendAt", "template", "acknowledgePast", "plannedDate", "plannedTime"]);
    if (request.reminderEnabled === undefined && request.reminderSendAt === undefined && request.template === undefined && request.plannedDate === undefined && request.plannedTime === undefined) throw invalid("nothing-to-update");
    if (request.reminderEnabled !== undefined && typeof request.reminderEnabled !== "boolean") throw invalid("invalid-enabled");
    if (request.acknowledgePast !== undefined && typeof request.acknowledgePast !== "boolean") throw invalid("invalid-acknowledge");
    // 自動送信は停止している(手動送信専用)。有効化の要求は、何も書かずに拒否する
    if (request.reminderEnabled === true) {
      throw new ApiError("failed-precondition", "リマインドの自動送信は使用できません。宛先一覧を確認してから、手動で送信してください。", {code: "auto-send-disabled"});
    }
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
      if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      const event = roundEvent(snapshot.data(), request.round);
      if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      const current = event[TEMPLATE_FIELD] || null;
      // テンプレート: 内容が変わるときだけversionを進める(同じ内容の再送では進めない)。当選メールのテンプレートには触れない。
      let nextTemplate = current;
      if (template) {
        if (request.template.adoptionNotesBody === undefined && current?.adoptionNotesBody) template.value.adoptionNotesBody = current.adoptionNotesBody;
        const same = current && (current.adoptionNotesBody || null) === (template.value.adoptionNotesBody || null) && current.subject === template.value.subject && current.introBody === template.value.introBody &&
          current.closingBody === template.value.closingBody && (current.notesBody || null) === template.value.notesBody;
        if (!same) {
          const version = (current && Number.isInteger(current.version) ? current.version : 0) + 1;
          nextTemplate = {...template.value, version, updatedAt: serverTimestamp(), updatedBy: identity.uid};
        }
      }
      if (request.plannedDate !== undefined || request.plannedTime !== undefined) {
        if (request.reminderSendAt !== undefined) throw invalid("conflicting-schedule");
        sendAt = schedule(request.plannedDate === undefined ? event.reminderPlannedDate : request.plannedDate,
          request.plannedTime === undefined ? event.reminderPlannedTime : request.plannedTime);
      }
      const enabled = roundOf(request.round) === 2 ? false : request.reminderEnabled !== undefined ? request.reminderEnabled : event.reminderEnabled === true;
      const nextSendAt = sendAt !== undefined ? sendAt : toDate(event.reminderSendAt);
      const update = {[fieldFor("reminderUpdatedAt", request.round)]: serverTimestamp(), [fieldFor("reminderUpdatedBy", request.round)]: identity.uid};
      if (request.reminderEnabled !== undefined && roundOf(request.round) === 1) update.reminderEnabled = request.reminderEnabled;
      if (sendAt !== undefined) {
        update[fieldFor("reminderSendAt", request.round)] = sendAt;
        const selected = roundEvent({reminderSendAt: sendAt}, 1);
        update[fieldFor("reminderPlannedDate", request.round)] = request.plannedDate !== undefined ? request.plannedDate :
          request.plannedTime !== undefined ? event.reminderPlannedDate : selected.reminderPlannedDate;
        update[fieldFor("reminderPlannedTime", request.round)] = request.plannedTime !== undefined ? request.plannedTime :
          request.plannedDate !== undefined ? event.reminderPlannedTime : selected.reminderPlannedTime;
      }
      if (nextTemplate !== current) update[fieldFor(TEMPLATE_FIELD, request.round)] = nextTemplate;
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
    const {event: storedEvent} = await loadConfirmedEvent(db, request.eventId);
    const event = roundEvent(storedEvent, request.round);
    const built = buildMailSnapshot(request.eventId, event, {templateField: TEMPLATE_FIELD});
    if (!built.ok) return {ready: false, problems: built.problems};
    // 送信対象と同じ条件(有効な参加者で当選メール送信済み)を、この1人についてだけ確かめる(イベント全体は読まない)
    const {target, participant} = await isReminderTarget(db, request.eventId, request.participantId);
    if (!target) {
      throw new ApiError("failed-precondition", "この参加者はリマインドの対象ではありません。", {code: "participant-not-target"});
    }
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
  // 指定した回の決定的IDのジョブへ到達する。既にあれば、その状態を返す(再作成・対象の追加・状態の巻き戻しはしない)。
  // expected*: 管理画面で確認した値。ジョブを新規作成する場合だけ照合し、違えば作成しない。
  // requireConfirmation: 手動開始。ジョブを新しく作る場合は、管理画面で確認した照合値が必須(既存ジョブの再開には不要。宛先は作成時に確定済み)。
  async function ensureJob({db, identity, eventId, round = 1, expectedTemplateVersion, expectedTargetCount, expectedTargetsFingerprint, requireConfirmation = false}) {
    const {event: storedEvent} = await loadConfirmedEvent(db, eventId);
    const event = roundEvent(storedEvent, round);
    const jobId = jobIdForReminder(eventId, round);
    const existing = await jobRef(db, jobId).get();
    if (existing.exists && existing.data().status !== JOB.PREPARING) return {...(await engine.summarize(db, jobId)), alreadyExisted: true};
    if (existing.exists && existing.data().snapshot?.reminderTargets) {
      const saved = existing.data();
      return engine.openJob({db, identity, type: "reminder", jobId, eventId, targets: saved.snapshot.reminderTargets,
        excludedInactiveCount: saved.excludedInactiveCount, snapshot: saved.snapshot});
    }
    if (!existing.exists && !schedule(event.reminderPlannedDate, event.reminderPlannedTime)) throw new ApiError("failed-precondition", "送信予定日と時刻を設定してください。", {code: "send-at-required"});
    if (requireConfirmation && expectedTargetsFingerprint === undefined) throw invalid("targets-fingerprint-required");
    if (eventEnded(event)) throw new ApiError("failed-precondition", "イベントが終了しているため、リマインドを作成できません。", {code: "event-ended"});
    const built = buildMailSnapshot(eventId, event, {templateField: TEMPLATE_FIELD});
    if (!built.ok) {
      throw new ApiError("failed-precondition", "リマインドの文面またはイベント情報が不足しているため、ジョブを作成できません。", {code: "mail-not-ready", problems: built.problems});
    }
    // 対象者は「この時点」の、当選メール送信済みの有効な参加者(イベント全体)。ここで確定し、targetCountとして固定する。
    const collected = await collectReminderRecipients(db, eventId, {event});
    built.snapshot.reminderTargets = collected.targets;
    built.snapshot.reminderScheduledAt = iso(event.reminderSendAt);
    built.snapshot.reminderRound = roundOf(round);
    built.snapshot.reminderJobId = jobId;
    built.snapshot.reminderFingerprint = collected.fingerprint;
    built.snapshot.recipientSafetyFingerprints = Object.fromEntries(collected.recipients.filter((r) => r.target).map((r) => [r.participantId, r.safetyFingerprint]));
    built.snapshot.recipientFingerprints = Object.fromEntries(collected.recipients.filter((r) => r.target).map((r) => [r.participantId, r.fingerprint]));
    // 当選メールの結果不明・重複登録の疑いが残っていれば、手動・自動のどちらでも作らない(未解決のまま送らない)
    if (collected.blocked.unknownWinnerMail > 0 || collected.blocked.suspectedDuplicates > 0) {
      throw new ApiError("failed-precondition", "追加当選通知が未送信・結果不明、または重複登録の疑いがある参加者がいるため、リマインドを作成できません。宛先一覧で確認してください。",
        {code: "reminder-targets-unresolved", ...collected.blocked});
    }
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
      // 宛先・メールアドレス・program・時間・人数・当選メールの状態のどれかが、確認後に変わっていれば作らない
      if (expectedTargetsFingerprint !== undefined && expectedTargetsFingerprint !== collected.fingerprint) {
        throw new ApiError("failed-precondition", "確認した後に、送信対象または送信内容(宛先・参加内容・当選メールの状態)が変わりました。画面を更新して、もう一度確認してください。",
          {code: "targets-changed"});
      }
    }
    return engine.openJob({
      db, identity, type: "reminder", jobId, eventId, targets: collected.targets, excludedInactiveCount: collected.excludedCount, snapshot: built.snapshot,
    });
  }

  // 管理者の手動開始(復旧・前倒し用)。自動開始と同じジョブへ到達し、別便は作らない。サーバー側の継続処理へ引き渡す。
  async function startDelivery({identity, data}) {
    const request = parseKeys(data, ["eventId", "expectedTemplateVersion", "expectedTargetCount", "expectedTargetsFingerprint", "dispatch"]);
    for (const key of ["expectedTemplateVersion", "expectedTargetCount"]) {
      if (request[key] !== undefined && !Number.isInteger(request[key])) throw invalid(`invalid-${key}`);
    }
    // 照合値(管理画面で宛先一覧を確認した値)。ジョブを新しく作る手動開始では必須(ensureJob)。形式が違えば拒否する
    if (request.expectedTargetsFingerprint !== undefined &&
      (typeof request.expectedTargetsFingerprint !== "string" || !/^[0-9a-f]{64}$/.test(request.expectedTargetsFingerprint))) {
      throw invalid("targets-fingerprint-required");
    }
    if (request.dispatch !== undefined && typeof request.dispatch !== "boolean") throw invalid("invalid-dispatch");
    const db = getDb();
    const job = await ensureJob({db, identity, eventId: request.eventId, round: request.round, expectedTemplateVersion: request.expectedTemplateVersion,
      expectedTargetCount: request.expectedTargetCount, expectedTargetsFingerprint: request.expectedTargetsFingerprint, requireConfirmation: true});
    if (request.dispatch === false || job.status !== JOB.READY) return job;
    return {...(await worker.requestDelivery({db, identity, jobId: job.jobId})), alreadyExisted: job.alreadyExisted};
  }

  // ---- 状態・失敗分の再送 ---------------------------------------------------------------------------------
  async function getJob({data}) {
    const request = parseKeys(data, ["eventId", "itemStatus", "limit", "after"]);
    return winnerSendApi.readJob({...winnerSendApi.parseReadOptions(request), jobId: jobIdForReminder(request.eventId, request.round), batchLabel: `第${roundOf(request.round)}回リマインド`});
  }

  // failed(確実に渡っていない)の項目だけを未送信へ戻す。sent・unknown・sending・pendingは対象外。送信は startDelivery(引き渡し)が行う。
  async function retryFailed({data}) {
    const request = parseKeys(data, ["eventId"]);
    return engine.retryFailed({db: getDb(), jobId: jobIdForReminder(request.eventId, request.round)});
  }

  // ---- 定期実行: 送信時刻に達したイベントのジョブを作成し、サーバー側の継続処理へ引き渡す ----------------------------------
  // 既存の sweepConfirmedMailDelivery の冒頭から呼ばれる。何度実行されても、同じイベントのジョブは1つ(決定的ID + transaction)。
  // 自動送信は停止している: 送信予定日時・reminderEnabled の保存値にかかわらず、ジョブを作らず、引き渡さない。
  // 呼び出し元のsweepは管理者が開始済みの配送だけを継続する。
  async function reconcileDue({limit = 5} = {}) {
    if (AUTO_SEND_DISABLED) return {created: [], autoSendDisabled: true};
    return {created: [], autoSendDisabled: true};
  }

  return {getSettings, updateSettings, preview, startDelivery, getJob, retryFailed, reconcileDue, ensureJob};
}

module.exports = {createReminderApi, TEMPLATE_FIELD, SCHEDULER_IDENTITY};
