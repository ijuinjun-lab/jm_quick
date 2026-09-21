// 当選メールの送信ジョブのAPI(admin専用callableのハンドラ): 作成・処理・失敗分の再送。
// 認可(admin)は index.js の confirmedCallable("admin", ...) が済ませている。
//
// ■ 実メールを送るのは「管理者が明示的に処理を実行したとき」だけ(processConfirmedWinnerMailJob)。ジョブの作成では1通も送らない。
//   importの成功だけでも送信されない(import処理とmail deliveryは完全に分離)。Schedulerによる自動送信もない。
// ■ 送信の前に、mail-apiが html・attachments に対応していることを確認する。未対応・確認不能なら fail-closed(何も送らない)。
// ■ テンプレートが未設定・不完全、またはイベント情報が不足していればジョブを作成しない(勝手な既定本文で送らない)。

const {ApiError} = require("./api_error");
const {isValidBatchId} = require("./import_batch_plan");
const {buildMailSnapshot} = require("./mail_view_model");
const {loadConfirmedEvent} = require("./winner_mail_api");
const {composeWinnerMailFor, buildMailApiMessage} = require("./winner_mail_message");
const {createSendJobEngine, DELIVERY} = require("./send_jobs");
const {toDate} = require("./mail_view_model");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const JOB_ID_PATTERN = /^winner-[A-Za-z0-9]{1,40}$/;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;
const DEFAULT_ITEMS_LIMIT = 100;
const MAX_ITEMS_LIMIT = 200;
const PARTICIPANT_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const iso = (value) => { const d = toDate(value); return d ? d.toISOString() : null; };
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});

function parseKeys(data, allowed) {
  if (data === null || typeof data !== "object" || Array.isArray(data)) throw invalid("body-not-object");
  for (const key of Object.keys(data)) if (!allowed.includes(key)) throw invalid("unknown-key", {path: key});
  return data;
}

function createWinnerSendApi({getDb, serverTimestamp, generateQrPng, getAppBaseUrl, getTransport, engineOptions = {}}) {
  const engine = createSendJobEngine({
    serverTimestamp, generateQrPng, getAppBaseUrl, composeMail: composeWinnerMailFor, buildMessage: buildMailApiMessage, ...engineOptions,
  });

  const parseJobId = (value) => {
    if (typeof value !== "string" || !JOB_ID_PATTERN.test(value)) throw invalid("invalid-job-id");
    return value;
  };

  // 取込回(committed)の参加者への送信ジョブを作成する。送信はしない。
  async function createJob({identity, data}) {
    const request = parseKeys(data, ["eventId", "batchId", "expectedTemplateVersion"]);
    if (request.expectedTemplateVersion !== undefined && !Number.isInteger(request.expectedTemplateVersion)) throw invalid("invalid-expected-template-version");
    if (typeof request.eventId !== "string" || !EVENT_ID_PATTERN.test(request.eventId)) throw invalid("invalid-event-id");
    if (!isValidBatchId(request.batchId)) throw invalid("invalid-batch-id");
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event);
    if (!built.ok) {
      throw new ApiError("failed-precondition", "当選メールの設定が完了していないため、送信ジョブを作成できません。", {code: "mail-not-ready", problems: built.problems});
    }
    // 管理画面で確認したテンプレートversionと、作成する瞬間のversionが違えば作成しない(確認していない版を固定しない)。
    // 既存ジョブが既にある場合は、テンプレートが変わっていても既存ジョブがそのまま返る(下のengineが判断する)。
    if (request.expectedTemplateVersion !== undefined && request.expectedTemplateVersion !== built.snapshot.template.version &&
        !(await db.collection("sendJobs").doc(`winner-${request.batchId}`).get()).exists) {
      throw new ApiError("failed-precondition", "確認したテンプレートのバージョンが変更されています。画面を更新して、もう一度確認してください。",
        {code: "template-version-changed", expected: request.expectedTemplateVersion, current: built.snapshot.template.version});
    }
    // 作成時のテンプレート・イベント内容(個人情報なし)をジョブに固定する(templateVersion)。
    return engine.createJob({db, identity, eventId: request.eventId, batchId: request.batchId, snapshot: built.snapshot});
  }

  // 管理者が明示的に実行する処理。未処理の項目を最大limit件、送信する。
  async function processJob({data}) {
    const request = parseKeys(data, ["jobId", "limit"]);
    const jobId = parseJobId(request.jobId);
    let limit = DEFAULT_LIMIT;
    if (request.limit !== undefined) {
      if (!Number.isInteger(request.limit) || request.limit < 1 || request.limit > MAX_LIMIT) throw invalid("invalid-limit");
      limit = request.limit;
    }
    const db = getDb();
    const snapshot = await db.collection("sendJobs").doc(jobId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "送信ジョブが見つかりません。");
    const transport = getTransport();
    // fail-closed: mail-apiが html・attachments に対応していることを確認できなければ、1件も送らない。
    const capability = await transport.capabilities();
    if (!capability.ok) {
      throw new ApiError("failed-precondition", "メール送信サービスが、QR付きメールに必要な機能(html・添付)に対応していることを確認できません。送信を中止しました。",
        {code: "mail-api-incapable", missing: capability.missing});
    }
    return engine.processJob({db, jobId, limit, transport});
  }

  // 失敗(確実に渡っていない)の項目だけを送信待ちに戻す。sent・unknownは対象外。送信はprocessで行う。
  async function retryFailed({data}) {
    const request = parseKeys(data, ["jobId"]);
    return engine.retryFailed({db: getDb(), jobId: parseJobId(request.jobId)});
  }

  // ---- 管理画面用の読み取り専用API(状態はすべてサーバーの正本から。クライアントは対象者を計算しない) ----------------------
  const countOf = async (query) => (await query.count().get()).data().count;

  // 保存則の表示用の判定。UIも同じ判定を(サーバーの値を使って)行い、合わなければ「状態を確認できません」とする。
  function conservationOf(summary) {
    const total = summary.pendingCount + summary.sendingCount + summary.sentCount + summary.failedCount + summary.unknownCount;
    const settled = summary.pendingCount === 0 && summary.sendingCount === 0;
    return {
      total,
      consistent: total === summary.targetCount,
      // completedなら sent + failed + unknown == targetCount で、pending/sendingが残っていないこと
      completedConsistent: summary.status !== "completed" || (settled && summary.sentCount + summary.failedCount + summary.unknownCount === summary.targetCount),
    };
  }

  function jobView(summary, jobDoc) {
    return {
      jobId: summary.jobId, eventId: summary.eventId, batchId: summary.batchId, batchSequence: summary.batchSequence,
      status: summary.status, templateVersion: summary.templateVersion, targetCount: summary.targetCount,
      excludedInactiveCount: summary.excludedInactiveCount,
      counts: {pending: summary.pendingCount, sending: summary.sendingCount, sent: summary.sentCount, failed: summary.failedCount, unknown: summary.unknownCount},
      createdAt: iso(jobDoc.createdAt), completedAt: iso(jobDoc.completedAt),
      conservation: conservationOf(summary),
    };
  }

  // イベントの取込回(batch)の一覧。送信できるか・対象人数・既存ジョブの状態を返す。メール・氏名は返さない。
  async function listBatches({data}) {
    const request = parseKeys(data, ["eventId"]);
    if (typeof request.eventId !== "string" || !EVENT_ID_PATTERN.test(request.eventId)) throw invalid("invalid-event-id");
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event);
    const template = event.winnerMailTemplate || null;
    const batchDocs = (await db.collection("importBatches").where("eventId", "==", request.eventId).get()).docs
      .map((doc) => ({batchId: doc.id, ...doc.data()}))
      .sort((a, b) => (a.sequence - b.sequence) || (a.batchId < b.batchId ? -1 : 1));
    const batches = [];
    for (const batch of batchDocs) {
      const committed = batch.status === "committed";
      const row = {
        batchId: batch.batchId, sequence: batch.sequence, label: typeof batch.label === "string" ? batch.label : `第${batch.sequence}回`,
        status: batch.status, importedCount: committed ? batch.createdCount : null, createdAt: iso(batch.createdAt),
        targetCount: null, excludedInactiveCount: null, consistent: null, previewParticipantId: null, job: null, canCreateJob: false, blockedReasons: [],
      };
      if (committed) {
        // 送信対象 = このbatch由来のstatus=activeのparticipant。人物の重複排除はしない(同じメール・氏名も1件ずつ)。
        const [found, active] = await Promise.all([
          countOf(db.collection("participants").where("importBatchId", "==", batch.batchId)),
          countOf(db.collection("participants").where("importBatchId", "==", batch.batchId).where("status", "==", "active")),
        ]);
        row.targetCount = active;
        row.excludedInactiveCount = found - active;
        row.consistent = found === batch.createdCount;
        // 送信前プレビュー用の参加者(このbatchの有効な参加者の先頭1人。IDのみ。氏名・メールは返さない)
        const first = await db.collection("participants").where("importBatchId", "==", batch.batchId).where("status", "==", "active").orderBy("__name__").limit(1).get();
        row.previewParticipantId = first.docs.length > 0 ? first.docs[0].id : null;
      } else {
        row.blockedReasons.push("batch-not-committed");
      }
      const jobSnapshot = await db.collection("sendJobs").doc(`winner-${batch.batchId}`).get();
      if (jobSnapshot.exists) row.job = jobView(await engine.summarize(db, `winner-${batch.batchId}`), jobSnapshot.data());
      if (committed) {
        if (!row.consistent) row.blockedReasons.push("participants-mismatch");
        if (row.targetCount === 0) row.blockedReasons.push("no-targets");
        if (!built.ok) row.blockedReasons.push("mail-not-ready");
        if (row.job) row.blockedReasons.push("job-exists");
      }
      row.canCreateJob = row.blockedReasons.length === 0;
      batches.push(row);
    }
    return {
      eventId: request.eventId,
      eventName: typeof event.eventName === "string" ? event.eventName : "",
      template: {version: template && Number.isInteger(template.version) ? template.version : null, ready: built.ok, problems: built.ok ? [] : built.problems},
      batches,
    };
  }

  // ジョブの状態と、参加者ごとの配送状態(participantId・表示名・状態だけ。メールアドレスは返さない)。
  async function getJob({data}) {
    const request = parseKeys(data, ["jobId", "itemStatus", "limit", "after"]);
    const jobId = parseJobId(request.jobId);
    if (request.itemStatus !== undefined && !Object.values(DELIVERY).includes(request.itemStatus)) throw invalid("invalid-item-status");
    let limit = DEFAULT_ITEMS_LIMIT;
    if (request.limit !== undefined) {
      if (!Number.isInteger(request.limit) || request.limit < 1 || request.limit > MAX_ITEMS_LIMIT) throw invalid("invalid-limit");
      limit = request.limit;
    }
    if (request.after !== undefined && (typeof request.after !== "string" || !PARTICIPANT_ID_PATTERN.test(request.after))) throw invalid("invalid-after");
    const db = getDb();
    const jobSnapshot = await db.collection("sendJobs").doc(jobId).get();
    if (!jobSnapshot.exists) throw new ApiError("not-found", "送信ジョブが見つかりません。");
    const jobDoc = jobSnapshot.data();
    const summary = await engine.summarize(db, jobId);
    const batchSnapshot = await db.collection("importBatches").doc(jobDoc.batchId).get();

    let query = db.collection("sendJobs").doc(jobId).collection("items");
    if (request.itemStatus !== undefined) query = query.where("status", "==", request.itemStatus);
    query = query.orderBy("__name__");
    if (request.after !== undefined) query = query.startAfter(request.after);
    const page = (await query.limit(limit + 1).get()).docs;
    const shown = page.slice(0, limit);
    const names = shown.length > 0 ? await db.getAll(...shown.map((doc) => db.collection("participants").doc(doc.id))) : [];
    const nowMs = Date.now();
    const items = shown.map((doc, index) => {
      const item = doc.data();
      const participant = names[index] && names[index].exists ? names[index].data() : null;
      const leaseMs = item.leaseUntil && typeof item.leaseUntil.toMillis === "function" ? item.leaseUntil.toMillis() : 0;
      return {
        participantId: doc.id,
        name: participant && typeof participant.name === "string" ? participant.name : "",
        status: item.status,
        attemptCount: Number.isInteger(item.attemptCount) ? item.attemptCount : 0,
        ...(item.lastErrorCode ? {lastErrorCode: item.lastErrorCode} : {}),
        ...(item.status === DELIVERY.SENDING ? {leaseActive: leaseMs > nowMs} : {}),
      };
    });
    return {
      job: {...jobView(summary, jobDoc), batchLabel: batchSnapshot.exists && typeof batchSnapshot.data().label === "string" ? batchSnapshot.data().label : ""},
      items,
      nextAfter: page.length > limit ? shown[shown.length - 1].id : null,
    };
  }

  return {createJob, processJob, retryFailed, listBatches, getJob, engine};
}

module.exports = {createWinnerSendApi};
