// 送信ジョブ(sendJobs)のサーバー側継続処理。ブラウザは配送処理の実行主体ではない。
//
// ■ 方式: 「希望する状態(desired state)」をFirestoreに記録し、定期実行(Cloud Scheduler、既存の旧Schedulerと同じ仕組み)が
//   その状態に向けて少しずつ進める(reconcile)。新しいインフラ(Cloud Tasks等のキュー・IAM・service account)は不要。
//     - 管理者の「送信開始」= sendJobs/{jobId} に dispatchActive=true を書く(1回のtransaction。冪等)。これが「引き渡し」。
//     - 定期実行(sweep)は dispatchActive=true のジョブだけを対象に、1回の実行で少数のchunkを処理する。
//     - ブラウザは状態を表示するだけ。閉じても、リロードしても、別端末から開いても、処理は続く。
// ■ at-least-once前提: sweepは何度・並行して起動されても安全。最終防御は既存の sendJobs/items/mailDeliveries の
//   claim・lease・状態遷移(send_jobs.js)であり、この層はそれを迂回しない(「まだ送っていないはず」で送らない)。
//   job単位のworker leaseは、無駄な並行処理を避けるための補助(正しさの根拠ではない)。
// ■ 継続条件: pendingが残る → 次のsweepが続きを処理 / sendingがlease中 → 奪わない(次のsweepで再確認) /
//   pending・sendingが0 → 終端(completed。sent+failed+unknown==targetCountの保存則を満たす場合だけ)→ dispatchActive=false。
//   failed・unknownしか残らない場合は終端(自動再送しない。failedは管理者の「失敗分だけ再送」、unknownは人の確認が先)。
// ■ 無限ループ・費用暴走の防止: すべての上限は DELIVERY_LIMITS に集約。
//     chunkSize(1回の処理件数) / maxChunksPerRun・runBudgetMs(1回の実行の上限) / maxJobsPerSweep /
//     maxNoProgressRuns(進捗のない実行が続いたら停止) / maxRunsPerActivation(1回の「送信開始」で許す実行回数の上限)。
//   異常(ジョブが不正・保存則の破れ・イベントが不正・進捗なし・実行回数上限)では dispatchActive=false にして停止し、
//   dispatchHaltedReason に理由を残す(管理者が確認して再開する)。自動で再開しない。
// ■ 内部処理の入力は jobId だけ(氏名・メール・本文・QR・publicIdは持ち回らない。すべてFirestoreの正本から読む)。
// ■ このファイルはFirebaseに依存しない(db・serverTimestampは注入)。前日リマインド等、別種のメールでも同じ仕組みを使える
//   (メールの生成・種類はjobのsnapshotとengineのcomposeMailが決める)。

const {ApiError} = require("./api_error");
const {isConfirmedFlow} = require("../flow");
const {JOB} = require("./send_jobs");

const DELIVERY_LIMITS = Object.freeze({
  chunkSize: 20, // 1回のprocessJobで処理する最大件数。1 chunkの最悪所要時間 = chunkSize / concurrency × 送信タイムアウト
  maxChunksPerRun: 30, // 1回の実行で処理するchunk数の上限
  runBudgetMs: 150000, // 新しいchunkを始めてよい経過時間の上限(関数のタイムアウト300秒より十分手前で止める)
  workerLeaseMs: 360000, // job単位のworker lease(関数のタイムアウトより長い。chunkごとに延長する)
  maxNoProgressRuns: 10, // 進捗のない実行がこの回数続いたら停止(1分間隔なら約10分)
  maxRunsPerActivation: 720, // 1回の「送信開始」で許す実行回数の上限(1分間隔なら約12時間)
  maxJobsPerSweep: 5, // 1回のsweepで扱うジョブ数の上限
});

const HALT = Object.freeze({
  JOB_NOT_READY: "job-not-ready",
  EVENT_NOT_CONFIRMED: "event-not-confirmed",
  CONSERVATION: "conservation-violated",
  NO_PROGRESS: "no-progress",
  RUN_LIMIT: "run-limit",
});

const toMillis = (value) => (value && typeof value.toMillis === "function" ? value.toMillis() : value instanceof Date ? value.getTime() : Number(value) || 0);

function createDeliveryWorker({engine, serverTimestamp, now = () => Date.now(), limits = DELIVERY_LIMITS, workerId = () => Math.random().toString(36).slice(2)}) {
  const jobRef = (db, jobId) => db.collection("sendJobs").doc(jobId);
  const halt = (reason) => ({dispatchActive: false, dispatchHaltedReason: reason, dispatchFinishedAt: serverTimestamp(), dispatchWorkerId: null, dispatchWorkerLeaseUntil: null});

  // ---- 引き渡し(管理者の「送信開始」) -------------------------------------------------------------
  // 「サーバーで送信を続ける」という希望を記録する。何度呼んでも安全(既に有効なら何も壊さない)。メールはここでは送らない。
  async function requestDelivery({db, identity, jobId}) {
    const snapshot = await jobRef(db, jobId).get();
    if (!snapshot.exists) throw new ApiError("not-found", "送信ジョブが見つかりません。");
    const status = snapshot.data().status;
    // 準備中・準備失敗のジョブは開始できない。completedは「送るものが無い」場合だけ受け付ける(下で判定。何も有効化しない)。
    if (status !== JOB.READY && status !== JOB.COMPLETED) {
      throw new ApiError("failed-precondition", "ジョブの準備が完了していないため、送信を開始できません。", {code: "job-not-ready", status});
    }
    const summary = await engine.summarize(db, jobId);
    const total = summary.pendingCount + summary.sendingCount + summary.sentCount + summary.failedCount + summary.unknownCount;
    if (total !== summary.targetCount) {
      throw new ApiError("failed-precondition", "配送状態の合計が対象数と一致しないため、送信を開始できません。", {code: "delivery-count-mismatch", targetCount: summary.targetCount, total});
    }
    if (summary.pendingCount + summary.sendingCount === 0) return {...summary, dispatchActive: false, nothingToSend: true};
    if (status === JOB.COMPLETED) {
      throw new ApiError("failed-precondition", "完了と記録されているジョブに未送信が残っています。状態を確認してください。", {code: "delivery-count-mismatch", status});
    }
    const seq = await db.runTransaction(async (tx) => {
      const current = (await tx.get(jobRef(db, jobId))).data();
      const next = (current.dispatchRequestSeq || 0) + 1;
      const wasActive = current.dispatchActive === true;
      tx.update(jobRef(db, jobId), {
        dispatchActive: true, dispatchRequestSeq: next, dispatchHaltedReason: null, dispatchFinishedAt: null,
        // 新しい「送信開始」ごとに、実行回数・進捗なしの回数をリセットする(暴走防止の上限は「1回の開始」あたり)
        ...(wasActive ? {} : {dispatchRequestedAt: serverTimestamp(), dispatchRequestedBy: identity.uid, dispatchRunCount: 0, dispatchNoProgressRuns: 0}),
        updatedAt: serverTimestamp(),
      });
      return next;
    });
    return {...summary, dispatchActive: true, dispatchRequestSeq: seq, nothingToSend: false};
  }

  // ---- job単位のworker lease ---------------------------------------------------------------------
  async function acquire(db, jobId, id) {
    return db.runTransaction(async (tx) => {
      const snapshot = await tx.get(jobRef(db, jobId));
      if (!snapshot.exists) return {skip: "job-missing"};
      const job = snapshot.data();
      if (job.dispatchActive !== true) return {skip: "inactive"};
      if (job.dispatchWorkerId && job.dispatchWorkerId !== id && toMillis(job.dispatchWorkerLeaseUntil) > now()) return {skip: "worker-active"};
      const runCount = (job.dispatchRunCount || 0) + 1;
      if (runCount > limits.maxRunsPerActivation) {
        tx.update(jobRef(db, jobId), {...halt(HALT.RUN_LIMIT), updatedAt: serverTimestamp()});
        return {skip: "run-limit", halted: HALT.RUN_LIMIT};
      }
      tx.update(jobRef(db, jobId), {
        dispatchWorkerId: id, dispatchWorkerLeaseUntil: new Date(now() + limits.workerLeaseMs), dispatchRunCount: runCount,
        dispatchLastRunAt: serverTimestamp(), updatedAt: serverTimestamp(),
      });
      return {ok: true, seq: job.dispatchRequestSeq || 0, noProgressRuns: job.dispatchNoProgressRuns || 0, status: job.status, eventId: job.eventId};
    });
  }

  async function renew(db, jobId, id) {
    await jobRef(db, jobId).update({dispatchWorkerLeaseUntil: new Date(now() + limits.workerLeaseMs), dispatchWorkerId: id});
  }

  // 実行の終了。終端(finished)なら、開始要求(seq)が実行中に変わっていない場合だけ dispatchActive=false にする。
  async function release(db, jobId, id, {finished, seq, progress, haltReason, note}) {
    await db.runTransaction(async (tx) => {
      const current = (await tx.get(jobRef(db, jobId))).data();
      if (!current || current.dispatchWorkerId !== id) return; // leaseを失っている(他のworkerが引き継いだ)場合は何も書かない
      const update = {dispatchWorkerId: null, dispatchWorkerLeaseUntil: null, dispatchLastNote: note || null, updatedAt: serverTimestamp()};
      if (haltReason) Object.assign(update, halt(haltReason));
      else if (finished && (current.dispatchRequestSeq || 0) === seq) Object.assign(update, {dispatchActive: false, dispatchFinishedAt: serverTimestamp(), dispatchHaltedReason: null});
      // 進捗があればリセット。無ければ加算(上限に達したら停止)。
      if (!haltReason) {
        const noProgress = progress ? 0 : (current.dispatchNoProgressRuns || 0) + 1;
        update.dispatchNoProgressRuns = noProgress;
        if (!finished && noProgress >= limits.maxNoProgressRuns) Object.assign(update, halt(HALT.NO_PROGRESS));
      }
      tx.update(jobRef(db, jobId), update);
    });
  }

  // 1つのジョブを、上限の範囲で処理する。何度・並行して呼ばれても安全(item単位のclaim/leaseが最終防御)。
  // getTransport: () => transport(Secretの注入方式は呼び出し側=index.jsのまま)。
  async function runJob({db, jobId, getTransport}) {
    const id = workerId();
    const lease = await acquire(db, jobId, id);
    if (!lease.ok) return {skipped: lease.skip, halted: lease.halted || null};
    const startedAt = now();
    let processed = 0;
    let finished = false;
    let haltReason = null;
    let note = null;
    try {
      const event = (await db.collection("events").doc(lease.eventId).get());
      if (!event.exists || !isConfirmedFlow(event.data())) throw Object.assign(new Error("halt"), {haltReason: HALT.EVENT_NOT_CONFIRMED});
      if (lease.status !== JOB.READY) throw Object.assign(new Error("halt"), {haltReason: HALT.JOB_NOT_READY});
      let transport;
      try {
        transport = getTransport();
        // fail-closed: QR付きメールに必要な機能を確認できなければ、1通も送らない(進捗なしとして数え、上限で停止する)
        const capability = await transport.capabilities();
        if (!capability.ok) { note = "mail-api-incapable"; transport = null; }
      } catch (error) {
        note = "transport-unavailable";
        transport = null;
      }
      for (let chunk = 0; transport && chunk < limits.maxChunksPerRun; chunk += 1) {
        if (chunk > 0 && now() - startedAt >= limits.runBudgetMs) { note = "run-budget-reached"; break; }
        const result = await engine.processJob({db, jobId, limit: limits.chunkSize, transport});
        processed += result.processed;
        if (result.pendingCount === 0 && result.sendingCount === 0) { finished = true; break; }
        if (result.processed === 0) { note = result.sendingCount > 0 ? "waiting-for-lease" : "no-progress"; break; }
        await renew(db, jobId, id);
      }
    } catch (error) {
      if (error && error.haltReason) haltReason = error.haltReason;
      else if (error && error.isApiError === true && error.code === "data-loss") haltReason = HALT.CONSERVATION;
      else if (error && error.isApiError === true && error.details && error.details.code === "job-not-ready") haltReason = HALT.JOB_NOT_READY;
      else note = "worker-error"; // 想定外の例外: 停止せず、進捗なしとして数える(上限で停止)。詳細(個人情報の可能性)はログに出さない
    }
    await release(db, jobId, id, {finished, seq: lease.seq, progress: processed > 0, haltReason, note});
    return {processed, finished, halted: haltReason, note};
  }

  // 定期実行の入口: 有効なジョブ(dispatchActive=true)だけを、上限の範囲で処理する。
  async function sweep({db, getTransport}) {
    const active = await db.collection("sendJobs").where("dispatchActive", "==", true).limit(limits.maxJobsPerSweep).get();
    const results = [];
    for (const doc of active.docs) results.push({jobId: doc.id, ...(await runJob({db, jobId: doc.id, getTransport}))});
    return results;
  }

  return {requestDelivery, runJob, sweep, limits};
}

module.exports = {DELIVERY_LIMITS, HALT, createDeliveryWorker};
