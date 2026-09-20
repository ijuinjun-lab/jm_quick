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
const {createSendJobEngine} = require("./send_jobs");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const JOB_ID_PATTERN = /^winner-[A-Za-z0-9]{1,40}$/;
const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;
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
    const request = parseKeys(data, ["eventId", "batchId"]);
    if (typeof request.eventId !== "string" || !EVENT_ID_PATTERN.test(request.eventId)) throw invalid("invalid-event-id");
    if (!isValidBatchId(request.batchId)) throw invalid("invalid-batch-id");
    const db = getDb();
    const {event} = await loadConfirmedEvent(db, request.eventId);
    const built = buildMailSnapshot(request.eventId, event);
    if (!built.ok) {
      throw new ApiError("failed-precondition", "当選メールの設定が完了していないため、送信ジョブを作成できません。", {code: "mail-not-ready", problems: built.problems});
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

  return {createJob, processJob, retryFailed, engine};
}

module.exports = {createWinnerSendApi};
