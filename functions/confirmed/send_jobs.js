// 当選メールの送信ジョブ(batch単位)のエンジン。Firestoreへ書く場所。dbは呼び出し側から渡される(Firebaseは読み込まない)。
// 実メールは送らない: 送信は注入されたtransport(テストでは偽物)へ渡すだけ。
//
// ■ コレクション(すべてクライアントから直接read/write不可。旧mailJobsは使わない=旧processorに誤処理されない):
//     sendJobs/{jobId}                    : batch単位のジョブ(jobId = "winner-{batchId}"。1 batchにつき1ジョブ)
//     sendJobs/{jobId}/items/{participantId} : ジョブ内の各参加者の状態(表示用。宛先メールは持たない)
//     mailDeliveries/{participantId}_winner  : 「この参加者へ当選メールを送ったか」の正本(配送の状態はここだけが正本)
// ■ 責務の分離: participants=誰が参加するか / programAttendances=何に何人参加するか / mailDeliveries=どう配送したか。
//   participantsに送信済みフラグは持たせない(旧invitationSent等はconfirmedでは使わない)。
// ■ 対象は「status=committedのimportBatchの、status=activeのparticipant」だけ(committing/failedのbatchは拒否)。
//   人物の重複排除はしない(同じメール・氏名・参照コードの参加者も、すべて別の対象として1件ずつ)。
// ■ 保存則: ジョブ作成時 items数 == deliveries数 == targetCount == (batchのcreated数 - 有効でない参加者数)、
//   完了時 sent + failed + unknown == targetCount で pending/sending が0件。
// ■ 個人のメールアドレスはjob・item・deliveryへ複製しない(送信の直前にparticipantsの正本から取得)。ログにも出さない。
//
// ■ 二重送信防止(mailDeliveriesの状態機械):
//     pending  --claim(lease)--> sending --(dispatch開始を記録)--> 送信 --> sent / failed / unknown
//     sent    : 通常の再送対象外。            failed : 「失敗分の再送」で pending に戻せる(確実に渡っていないもの)。
//     unknown : 渡ったか判断できない。自動再送しない(人の確認が先)。
//     sending : lease有効中は他のworkerがclaimできない。
//       - dispatch開始の記録前にworkerが落ちた(=確実に未送信) → lease期限後に再claimできる
//       - dispatch開始の記録後に結果が不明(lease期限切れ・応答不明) → unknown(自動再送しない)
//     結果の書込みは claimId が一致する場合だけ(他のworkerの結果を上書きしない)。

const {randomBytes} = require("node:crypto");
const {ApiError} = require("./api_error");

const DELIVERY = Object.freeze({PENDING: "pending", SENDING: "sending", SENT: "sent", FAILED: "failed", UNKNOWN: "unknown"});
const JOB = Object.freeze({PREPARING: "preparing", READY: "ready", COMPLETED: "completed", FAILED: "failed"});
const TYPE = "winner";
const DEFAULT_LEASE_MS = 120000;
const DEFAULT_CONCURRENCY = 5;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const LEASE_EXPIRED_AFTER_DISPATCH = "lease-expired-after-dispatch";

const jobIdForBatch = (batchId) => `winner-${batchId}`;
const deliveryIdFor = (participantId) => `${participantId}_${TYPE}`;
const toMillis = (value) => (value && typeof value.toMillis === "function" ? value.toMillis() : value instanceof Date ? value.getTime() : Number(value) || 0);

async function runPool(items, limit, task) {
  let next = 0;
  const workers = Array.from({length: Math.min(limit, items.length)}, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      await task(items[index]);
    }
  });
  await Promise.all(workers);
}

function createSendJobEngine({serverTimestamp, now = () => Date.now(), leaseMs = DEFAULT_LEASE_MS, concurrency = DEFAULT_CONCURRENCY,
  generateToken = () => randomBytes(16).toString("hex"), composeMail, buildMessage, generateQrPng, getAppBaseUrl}) {
  const jobRef = (db, jobId) => db.collection("sendJobs").doc(jobId);
  const itemRef = (db, jobId, participantId) => jobRef(db, jobId).collection("items").doc(participantId);
  const deliveryRef = (db, participantId) => db.collection("mailDeliveries").doc(deliveryIdFor(participantId));

  async function countItems(db, jobId, status) {
    const result = await jobRef(db, jobId).collection("items").where("status", "==", status).count().get();
    return result.data().count;
  }

  async function summarize(db, jobId) {
    const snapshot = await jobRef(db, jobId).get();
    const job = snapshot.data();
    const counts = {};
    for (const status of Object.values(DELIVERY)) counts[status] = await countItems(db, jobId, status);
    return {
      jobId, eventId: job.eventId, batchId: job.batchId, batchSequence: job.batchSequence, status: job.status,
      templateVersion: job.templateVersion, targetCount: job.targetCount, excludedInactiveCount: job.excludedInactiveCount,
      sentCount: counts.sent, failedCount: counts.failed, unknownCount: counts.unknown, pendingCount: counts.pending, sendingCount: counts.sending,
    };
  }

  // ---- ジョブ作成 -----------------------------------------------------------------------------
  // snapshot: buildMailSnapshotの結果(テンプレート+event内容。個人情報なし)。ジョブへ固定し、以後の文章はこれで生成する。
  async function createJob({db, identity, eventId, batchId, snapshot}) {
    const batchSnapshot = await db.collection("importBatches").doc(batchId).get();
    if (!batchSnapshot.exists) throw new ApiError("not-found", "取込回が見つかりません。");
    const batch = batchSnapshot.data();
    if (batch.eventId !== eventId) throw new ApiError("failed-precondition", "取込回がこのイベントのものではありません。", {code: "batch-event-mismatch"});
    // committed以外(committing/failed)のbatchの参加者は、絶対に送信対象にしない。
    if (batch.status !== "committed") {
      throw new ApiError("failed-precondition", "取込が完了(committed)していない取込回には、送信ジョブを作成できません。", {code: "batch-not-committed", status: batch.status});
    }
    const participants = (await db.collection("participants").where("importBatchId", "==", batchId).get()).docs;
    if (participants.some((doc) => doc.data().eventId !== eventId)) {
      throw new ApiError("failed-precondition", "取込回の参加者にこのイベントのものでないデータがあります。", {code: "participant-event-mismatch"});
    }
    // 保存則: batchのcreated数と、実在する参加者数が一致すること(欠落があれば作成しない)。
    if (participants.length !== batch.createdCount) {
      throw new ApiError("data-loss", "取込回の参加者数が、取込結果の件数と一致しません。ジョブを作成しませんでした。",
        {code: "participants-mismatch", createdCount: batch.createdCount, found: participants.length});
    }
    const targets = participants.filter((doc) => doc.data().status === "active").map((doc) => doc.id).sort();
    const excludedInactiveCount = participants.length - targets.length;
    if (targets.length === 0) throw new ApiError("failed-precondition", "送信対象の参加者がいません。", {code: "no-targets"});

    const jobId = jobIdForBatch(batchId);
    const ref = jobRef(db, jobId);
    const started = await db.runTransaction(async (tx) => {
      const existing = await tx.get(ref);
      if (existing.exists) {
        const job = existing.data();
        if (job.eventId !== eventId || job.batchId !== batchId) throw new ApiError("failed-precondition", "既存のジョブと一致しません。", {code: "job-conflict"});
        return {existing: true, status: job.status, targetCount: job.targetCount};
      }
      tx.create(ref, {
        eventId, batchId, batchSequence: batch.sequence, type: TYPE, status: JOB.PREPARING, targetCount: targets.length,
        excludedInactiveCount, sentCount: 0, failedCount: 0, unknownCount: 0, batchCreatedCount: batch.createdCount,
        templateVersion: snapshot.template.version, snapshot, createdAt: serverTimestamp(), createdBy: identity.uid, completedAt: null,
      });
      return {existing: false, status: JOB.PREPARING, targetCount: targets.length};
    });
    // 既に準備完了・処理済みのジョブは、そのまま返す(再作成しない。作成後にテンプレートが変わっても既存ジョブは変わらない)。
    if (started.existing && started.status !== JOB.PREPARING) return {...(await summarize(db, jobId)), alreadyExisted: true};
    if (started.existing && started.targetCount !== targets.length) {
      throw new ApiError("failed-precondition", "準備中のジョブの対象数が、現在の参加者数と一致しません。", {code: "job-target-changed"});
    }

    try {
      // 各参加者の item と delivery を、1トランザクションで冪等に作る(再実行しても増えない・上書きしない)。
      await runPool(targets, concurrency, async (participantId) => {
        const iRef = itemRef(db, jobId, participantId);
        const dRef = deliveryRef(db, participantId);
        await db.runTransaction(async (tx) => {
          const [itemSnap, deliverySnap] = await tx.getAll(iRef, dRef);
          if (itemSnap.exists) return;
          if (deliverySnap.exists) {
            // 配送記録が既にある(別ジョブ・過去の送信)参加者を、黙って対象に含めない・上書きしない。
            throw new ApiError("failed-precondition", "この参加者には既に配送記録があります。", {code: "delivery-exists", participantId});
          }
          tx.create(dRef, {
            eventId, batchId, participantId, type: TYPE, jobId, status: DELIVERY.PENDING, templateVersion: snapshot.template.version,
            attemptCount: 0, leaseUntil: null, dispatchStartedAt: null, claimId: null, messageId: null, lastErrorCode: null, sentAt: null,
            createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
          });
          tx.create(iRef, {
            participantId, status: DELIVERY.PENDING, attemptCount: 0, leaseUntil: null, messageId: null, lastErrorCode: null, sentAt: null,
            updatedAt: serverTimestamp(),
          });
        });
      });
      // 保存則: items数 == deliveries数 == targetCount。合わなければジョブを作成済みとして扱わない。
      const [items, deliveries] = await Promise.all([
        jobRef(db, jobId).collection("items").count().get(),
        db.collection("mailDeliveries").where("jobId", "==", jobId).count().get(),
      ]);
      if (items.data().count !== targets.length || deliveries.data().count !== targets.length) {
        await ref.update({status: JOB.FAILED, failureReason: "conservation-violated", updatedAt: serverTimestamp()});
        throw new ApiError("data-loss", "送信対象の件数とジョブ項目の件数が一致しません。ジョブを作成しませんでした。",
          {code: "job-items-mismatch", targetCount: targets.length, items: items.data().count, deliveries: deliveries.data().count});
      }
      await ref.update({status: JOB.READY, updatedAt: serverTimestamp()});
    } catch (error) {
      if (error && error.isApiError === true) throw error;
      throw new ApiError("internal", "ジョブの準備を最後まで完了できませんでした。同じ取込回で再実行すると続きから完了できます。", {code: "job-preparation-interrupted"});
    }
    return {...(await summarize(db, jobId)), alreadyExisted: started.existing};
  }

  // ---- 1件の送信(claim → dispatch開始 → 送信 → 結果) ---------------------------------------
  // claim: pending、またはlease期限切れで「dispatch前」のsendingだけを取得できる。
  async function claimItem({db, jobId, participantId}) {
    const iRef = itemRef(db, jobId, participantId);
    const dRef = deliveryRef(db, participantId);
    return db.runTransaction(async (tx) => {
      const [deliverySnap, itemSnap] = await tx.getAll(dRef, iRef);
      if (!deliverySnap.exists || !itemSnap.exists) throw new ApiError("failed-precondition", "配送記録が見つかりません。", {code: "delivery-missing"});
      const delivery = deliverySnap.data();
      if (delivery.jobId !== jobId) return {claimed: false, reason: "other-job"};
      const t = now();
      if (delivery.status === DELIVERY.SENDING) {
        if (toMillis(delivery.leaseUntil) > t) return {claimed: false, reason: "lease-active"};
        if (delivery.dispatchStartedAt) {
          // lease期限切れで、dispatch開始の記録がある: 送ったかもしれない。unknown(自動再送しない)。claimIdは残し、遅れて届く結果で確定できるようにする。
          tx.update(dRef, {status: DELIVERY.UNKNOWN, lastErrorCode: LEASE_EXPIRED_AFTER_DISPATCH, leaseUntil: null, updatedAt: serverTimestamp()});
          tx.update(iRef, {status: DELIVERY.UNKNOWN, lastErrorCode: LEASE_EXPIRED_AFTER_DISPATCH, leaseUntil: null, updatedAt: serverTimestamp()});
          return {claimed: false, reason: "marked-unknown"};
        }
        // dispatch開始の記録前に落ちた(確実に未送信): 再claimできる。
      } else if (delivery.status !== DELIVERY.PENDING) {
        return {claimed: false, reason: delivery.status};
      }
      const claimId = generateToken();
      const leaseUntil = new Date(t + leaseMs);
      const attemptCount = (delivery.attemptCount || 0) + 1;
      tx.update(dRef, {status: DELIVERY.SENDING, claimId, leaseUntil, attemptCount, dispatchStartedAt: null, updatedAt: serverTimestamp()});
      tx.update(iRef, {status: DELIVERY.SENDING, leaseUntil, attemptCount, updatedAt: serverTimestamp()});
      return {claimed: true, claimId, attemptCount};
    });
  }

  // dispatch開始の記録。これ以降に落ちた場合は「送ったかもしれない」ものとして扱う。claimが失われていれば false(送信しない)。
  async function startDispatch({db, jobId, participantId, claimId}) {
    const dRef = deliveryRef(db, participantId);
    const iRef = itemRef(db, jobId, participantId);
    return db.runTransaction(async (tx) => {
      const [deliverySnap] = await tx.getAll(dRef);
      const delivery = deliverySnap.data();
      if (!delivery || delivery.status !== DELIVERY.SENDING || delivery.claimId !== claimId || toMillis(delivery.leaseUntil) <= now()) return false;
      const leaseUntil = new Date(now() + leaseMs);
      tx.update(dRef, {dispatchStartedAt: new Date(now()), leaseUntil, updatedAt: serverTimestamp()});
      tx.update(iRef, {leaseUntil, updatedAt: serverTimestamp()});
      return true;
    });
  }

  // 結果の書込み。claimIdが一致する場合だけ(他のworkerの結果を上書きしない)。
  // 「lease期限切れでunknownにされた後に、同じworkerの結果が遅れて届いた」場合は、その結果で確定できる。
  async function finishItem({db, jobId, participantId, claimId, outcome, messageId, errorCode}) {
    const dRef = deliveryRef(db, participantId);
    const iRef = itemRef(db, jobId, participantId);
    return db.runTransaction(async (tx) => {
      const [deliverySnap] = await tx.getAll(dRef);
      const delivery = deliverySnap.data();
      const lateResult = delivery && delivery.status === DELIVERY.UNKNOWN && delivery.lastErrorCode === LEASE_EXPIRED_AFTER_DISPATCH;
      if (!delivery || delivery.claimId !== claimId || (delivery.status !== DELIVERY.SENDING && !lateResult)) return {applied: false};
      const update = {
        status: outcome, claimId: null, leaseUntil: null, updatedAt: serverTimestamp(),
        lastErrorCode: outcome === DELIVERY.SENT ? null : errorCode || "unknown",
        messageId: outcome === DELIVERY.SENT ? messageId || "" : null,
        sentAt: outcome === DELIVERY.SENT ? serverTimestamp() : null,
      };
      tx.update(dRef, update);
      const {claimId: _claimId, ...itemUpdate} = update;
      tx.update(iRef, itemUpdate);
      return {applied: true};
    });
  }

  async function processItem({db, jobId, job, participantId, transport}) {
    const claim = await claimItem({db, jobId, participantId});
    if (!claim.claimed) return {outcome: "skipped", reason: claim.reason};
    const {claimId} = claim;
    const fail = async (errorCode) => {
      await finishItem({db, jobId, participantId, claimId, outcome: DELIVERY.FAILED, errorCode});
      return {outcome: DELIVERY.FAILED, reason: errorCode};
    };
    let message;
    try {
      // 生成(送信前)。ここで失敗しても、まだdispatchしていないので確実に未送信 = failed。
      const participantSnap = await db.collection("participants").doc(participantId).get();
      const participant = participantSnap.exists ? participantSnap.data() : null;
      if (!participant || participant.eventId !== job.eventId || participant.status !== "active") return await fail("participant-unavailable");
      const to = typeof participant.email === "string" ? participant.email.trim().toLowerCase() : "";
      if (!EMAIL_PATTERN.test(to)) return await fail("participant-email-invalid");
      // ジョブに固定したsnapshotで生成する(プレビューと同じ composeMail = renderWinnerMail)。
      const rendered = await composeMail({db, snapshot: job.snapshot, participantId, participant, appBaseUrl: getAppBaseUrl(), generateQrPng});
      if (!rendered.ok) return await fail(`render-${rendered.problems[0] || "error"}`);
      message = buildMessage({rendered, to, snapshot: job.snapshot, participantId, jobId});
    } catch (error) {
      return fail("render-error");
    }

    if (!(await startDispatch({db, jobId, participantId, claimId}))) return {outcome: "skipped", reason: "claim-lost"};
    // ここから先は「送ったかもしれない」。例外・不明な結果は unknown(自動再送しない)。
    let result;
    try {
      result = await transport.send(message);
    } catch (error) {
      result = {outcome: DELIVERY.UNKNOWN, errorCode: "transport-exception"};
    }
    const outcome = [DELIVERY.SENT, DELIVERY.FAILED, DELIVERY.UNKNOWN].includes(result && result.outcome) ? result.outcome : DELIVERY.UNKNOWN;
    await finishItem({db, jobId, participantId, claimId, outcome, messageId: result && result.messageId, errorCode: result && result.errorCode});
    return {outcome};
  }

  // ---- ジョブの進行・完了判定 ---------------------------------------------------------------
  async function refreshJob(db, jobId) {
    const summary = await summarize(db, jobId);
    const settled = summary.pendingCount === 0 && summary.sendingCount === 0;
    const total = summary.sentCount + summary.failedCount + summary.unknownCount;
    if (settled && total !== summary.targetCount) {
      await jobRef(db, jobId).update({status: JOB.FAILED, failureReason: "conservation-violated", updatedAt: serverTimestamp()});
      throw new ApiError("data-loss", "配送結果の合計が対象数と一致しません。", {code: "delivery-count-mismatch", targetCount: summary.targetCount, total});
    }
    // sent + failed + unknown == targetCount で pending/sending が残っていない場合だけ completed。
    const status = settled && total === summary.targetCount ? JOB.COMPLETED : JOB.READY;
    await jobRef(db, jobId).update({
      status, sentCount: summary.sentCount, failedCount: summary.failedCount, unknownCount: summary.unknownCount,
      completedAt: status === JOB.COMPLETED ? serverTimestamp() : null, updatedAt: serverTimestamp(),
    });
    return {...summary, status};
  }

  // 未処理(pending・lease期限切れのsending)の項目を最大limit件処理する。failed/unknown/sentは対象外。
  async function processJob({db, jobId, limit, transport}) {
    const snapshot = await jobRef(db, jobId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "送信ジョブが見つかりません。");
    const job = snapshot.data();
    if (job.status === JOB.PREPARING || job.status === JOB.FAILED) {
      throw new ApiError("failed-precondition", "ジョブの準備が完了していないため、処理できません。", {code: "job-not-ready", status: job.status});
    }
    const work = await jobRef(db, jobId).collection("items").where("status", "in", [DELIVERY.PENDING, DELIVERY.SENDING]).limit(limit).get();
    const results = [];
    await runPool(work.docs.map((doc) => doc.id), concurrency, async (participantId) => {
      results.push(await processItem({db, jobId, job, participantId, transport}));
    });
    const summary = await refreshJob(db, jobId);
    return {...summary, processed: results.filter((r) => r.outcome !== "skipped").length, skipped: results.filter((r) => r.outcome === "skipped").length};
  }

  // failed(確実に渡っていない)の項目だけを pending に戻す。sent・unknownは触らない。送信は processJob で明示的に行う。
  async function retryFailed({db, jobId}) {
    const snapshot = await jobRef(db, jobId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "送信ジョブが見つかりません。");
    if (snapshot.data().status === JOB.PREPARING || snapshot.data().status === JOB.FAILED) {
      throw new ApiError("failed-precondition", "ジョブの準備が完了していないため、再送を準備できません。", {code: "job-not-ready"});
    }
    const failed = await jobRef(db, jobId).collection("items").where("status", "==", DELIVERY.FAILED).get();
    let retried = 0;
    await runPool(failed.docs.map((doc) => doc.id), concurrency, async (participantId) => {
      const applied = await db.runTransaction(async (tx) => {
        const [deliverySnap, itemSnap] = await tx.getAll(deliveryRef(db, participantId), itemRef(db, jobId, participantId));
        if (deliverySnap.data().status !== DELIVERY.FAILED || itemSnap.data().status !== DELIVERY.FAILED) return false;
        const reset = {status: DELIVERY.PENDING, leaseUntil: null, dispatchStartedAt: null, updatedAt: serverTimestamp()};
        tx.update(deliveryRef(db, participantId), {...reset, claimId: null});
        tx.update(itemRef(db, jobId, participantId), reset);
        return true;
      });
      if (applied) retried += 1;
    });
    const summary = await refreshJob(db, jobId);
    return {...summary, retried};
  }

  return {createJob, processJob, retryFailed, summarize, claimItem, startDispatch, finishItem, refreshJob};
}

module.exports = {DELIVERY, JOB, jobIdForBatch, deliveryIdFor, createSendJobEngine};
