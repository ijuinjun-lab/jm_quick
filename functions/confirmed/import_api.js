// 新方式の当選者CSV取込API(admin専用callableのハンドラ): validateConfirmedImport / previewConfirmedImport / commitConfirmedImport。
// 認可(admin)はindex.jsの confirmedCallable("admin", ...) が済ませており、ここへ届く identity はサーバー側で確定した値。
// dbは createImportApi の getDb から取得する(このファイルはFirebaseのパッケージを読み込まない)。
//
// ■ クライアントを信用しない:
//   - eventの内容は必ずサーバーで再読込する(存在・flow=confirmed・program定義)。クライアントが送ったeventの内容は使わない。
//   - commitでは、preview結果も、クライアントが送る participant データも信用しない。mapping・headers・rowsから、
//     サーバーがPhase 3の変換・検証をもう一度実行する(クライアントから受け取るのは元のCSVの値と、管理者の判断だけ)。
// ■ validate・previewはFirestoreへ一切書き込まない(読み取りのみ)。レスポンスに氏名・メール・かな・自由記述を含めない。
// ■ validate(取込前の検証)はpreview・commitと同じ計画(buildPlan)を使う。行の判定を別に作らない(import_validation.js)。
// ■ 新しい取込回を作るcommitは、UIを信用せずサーバーだけで次を保証する(何か1つでも満たさなければ何も書かない):
//   - 未解決のエラーの行が0件(error行を取込対象から外せるのは、管理者が明示的に「今回の取込から除外」した場合だけ)
//   - 確認が必要な行(review)はすべて許可または除外済み(不参加のprogramに残る人数は参考情報。確認は要らない)
//   - 管理者の修正(corrections)は最終的な値としてサーバーが再計算する(修正しただけで正常扱いにはしない)
//   - 検証が返した expectedImportSequence が、採番と同じトランザクションの中の「現在の取込回の番号+1」と一致する
//   - 検証の指紋(validationFingerprint)が、同じトランザクションの中で再計算した値と一致する
//     (CSVの内容・列の対応・次の取込回の番号・既存の参加者/CSV内で重複している行が、検証時から変わっていない)
//   - 既存の参加者とのメール重複・CSV内のメール重複は、それぞれ管理者の明示的な許可がある
//   - 許可が必要な警告(確認が必要な行・メール重複)はすべて、現在の検証結果の許可の鍵(approvalKeys)で許可されている
//     (行を修正した・重複相手が変わった等で鍵が変わった警告は、古い許可では取り込めない。改めて許可が必要)
//   1つの取込回の番号につき作られる取込回は1つだけ(番号はeventのカウンタをトランザクションで進める)。
//   既存の取込回の再送(冪等な再実行・続きからの完了)には適用しない(その取込回の作成時点で判断済みのため)。
// ■ メールは一切送らない。

const {ApiError} = require("./api_error");
const {validateImportMapping} = require("./import_mapping");
const {isConfirmedFlow} = require("../flow");
const {parseImportRequest, toPlanRows} = require("./import_request");
const {planImportBatchFromRows, importRecordId} = require("./import_batch_plan");
const {createImportCommitter, resolveRecords} = require("./import_commit");
const {validateImportPlan, existingEmailHashes, duplicateRows, pendingRows, fingerprintOf, createdEmailHashes, approvalKeysOf} =
  require("./import_validation");

const {rolesFor, participationType, typeSummary} = require("./participation_types");

const JST_OFFSET_MS = 9 * 3600 * 1000;
const SAME_FILE_LIMIT = 5;

// eventを再読込して検証する。戻り値: {eventProgramIds, eventDate}
async function loadConfirmedEvent(db, eventId, normalizedMapping) {
  const snapshot = await db.collection("events").doc(eventId).get();
  if (!snapshot.exists) throw new ApiError("not-found", "イベントが見つかりません。");
  const event = snapshot.data();
  if (!isConfirmedFlow(event)) throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
  const eventProgramIds = (Array.isArray(event.programs) ? event.programs : [])
    .map((program) => (program && typeof program.programId === "string" ? program.programId : null))
    .filter((id) => id !== null);
  const unknown = normalizedMapping.programs.map((p) => p.programId).filter((id) => !eventProgramIds.includes(id));
  if (unknown.length > 0) {
    throw new ApiError("failed-precondition", "mappingのprogramがイベントに定義されていません。", {code: "program-not-in-event", programIds: unknown});
  }
  let eventDate;
  const needsDate = normalizedMapping.programs.some((p) => p.slotColumn && p.slotFormat === "timeRange");
  if (needsDate) {
    const start = event.startAt && typeof event.startAt.toDate === "function" ? event.startAt.toDate() : null;
    if (!start || Number.isNaN(start.getTime())) {
      throw new ApiError("failed-precondition", "イベントの開始日時が未設定のため、時間枠を解釈できません。", {code: "event-start-missing"});
    }
    // 日付はイベントの開始日時(日本時間)から決める。クライアントが送る日付は使わない。
    eventDate = new Date(start.getTime() + JST_OFFSET_MS).toISOString().slice(0, 10);
  }
  rolesFor(eventId, event);
  return {eventProgramIds, eventDate, event};
}

function buildPlan(request, {eventProgramIds, eventDate}) {
  return planImportBatchFromRows({
    eventId: request.eventId,
    batchId: request.batchId,
    sequence: 1, // 実際のsequenceはcommitのトランザクションで採番する(行の内容には影響しない)。
    label: request.label || "",
    sourceFileName: request.sourceFileName,
    fileHash: request.fileHash,
    mapping: request.mapping,
    rows: toPlanRows(request),
    blankRecordNumbers: request.blankRecordNumbers,
    totalRecords: request.totalRecords,
    eventDate,
    eventProgramIds,
  });
}

// 既存として数えるメール(ハッシュ)の材料。値はサーバー内だけで使い、応答には含めない。
//  - participants: このイベントの有効な参加者(トランザクションの外で読む。読み取りの範囲を小さく保つ)
//  - batches: このイベントの取込回(commitでは採番と同じトランザクションの中で読む。同時に確定した取込回も必ず含まれる)
const activeParticipantsQuery = (db, eventId) => db.collection("participants").where("eventId", "==", eventId).where("status", "==", "active");
const eventBatchesQuery = (db, eventId) => db.collection("importBatches").where("eventId", "==", eventId);
const dataOf = (snapshot) => snapshot.docs.map((doc) => doc.data());
const batchesOf = (snapshot) => snapshot.docs.map((doc) => ({id: doc.id, ...doc.data()}));

const excludedSetOf = (request) => new Set(request.excludedRows.map((e) => e.sourceRowNumber));
const correctedSetOf = (request) => new Set(request.corrections.map((c) => c.sourceRowNumber));

const stale = () => new ApiError("failed-precondition", "取込状況が変更されました。再度検証してください。", {code: "import-state-changed"});

function createImportApi({getDb, serverTimestamp, generatePublicId, concurrency}) {
  const committer = createImportCommitter({serverTimestamp, generatePublicId, concurrency, importRecordId});

  // 取込前の検証。何も書き込まない。行の判定はpreviewと同じ計画から読み替えるだけ。
  async function validate({data}) {
    const request = parseImportRequest(data, {commit: false});
    const db = getDb();
    const context = await loadConfirmedEvent(db, request.eventId, request.normalizedMapping);
    const plan = buildPlan(request, context);
    const [existing, eventSnap, participantsSnap, batchesSnap] = await Promise.all([
      db.collection("importBatches").doc(request.batchId).get(),
      db.collection("events").doc(request.eventId).get(),
      activeParticipantsQuery(db, request.eventId).get(),
      eventBatchesQuery(db, request.eventId).get(),
    ]);
    const state = {participants: dataOf(participantsSnap), batches: batchesOf(batchesSnap)};
    const resuming = existing.exists && existing.data().eventId === request.eventId && existing.data().status !== "committed";
    const excludeBatchId = resuming ? request.batchId : null;
    const existingHashes = existingEmailHashes({eventId: request.eventId, ...state, excludeBatchId});
    const validation = validateImportPlan({eventId: request.eventId, event: context.event, records: plan.records, existingHashes,
      excluded: excludedSetOf(request), corrected: correctedSetOf(request), planRows: toPlanRows(request)});
    const expectedImportSequence = (eventSnap.data().importSequence || 0) + 1;
    const batches = [...state.batches].sort((a, b) => (a.sequence || 0) - (b.sequence || 0));
    return {
      batchId: request.batchId,
      eventId: request.eventId,
      totalRecords: plan.batch.totalRecords,
      blankRecordCount: plan.batch.blankRecordCount,
      ...validation,
      existingActiveParticipantCount: state.participants.filter((p) => excludeBatchId === null || p.importBatchId !== excludeBatchId).length,
      // このイベントの取込回(番号・状態だけ)。画面は「既に取り込まれている回」「次に新規取込すると第N回」を示す。
      importedBatches: batches.map((b) => ({sequence: b.sequence, status: b.status})),
      sameFileBatches: batches.filter((b) => b.fileHash === request.fileHash).slice(0, SAME_FILE_LIMIT)
        .map((b) => ({batchId: b.id, sequence: b.sequence, status: b.status})),
      existingBatch: existing.exists && existing.data().eventId === request.eventId ?
        {status: existing.data().status, sequence: existing.data().sequence} : null,
      // 新しい取込回を作るcommitは、この番号と指紋を送る(サーバーが採番と同じトランザクションで照合する)。
      expectedImportSequence,
      nextImportSequence: expectedImportSequence,
      validationFingerprint: fingerprintOf({
        request, expectedImportSequence,
        existingDuplicateRows: validation.existingDuplicateRows, csvDuplicateRows: validation.csvDuplicateRows,
      }),
      mappingWarnings: validateImportMapping(request.mapping).warnings,
    };
  }

  // dry-run。何も書き込まない。
  async function preview({data}) {
    const request = parseImportRequest(data, {commit: false});
    const db = getDb();
    const context = await loadConfirmedEvent(db, request.eventId, request.normalizedMapping);
    const plan = buildPlan(request, context);
    const [existing, sameFile] = await Promise.all([
      db.collection("importBatches").doc(request.batchId).get(),
      db.collection("importBatches").where("eventId", "==", request.eventId).where("fileHash", "==", request.fileHash)
        .limit(SAME_FILE_LIMIT).get(),
    ]);
    const {batch, records, summary} = plan;
    const excluded = excludedSetOf(request);
    const corrected = correctedSetOf(request);
    return {
      batchId: request.batchId,
      eventId: request.eventId,
      mappingVersion: batch.mappingVersion,
      // 最終的に取り込まれる内容の集計(原本の行数・修正した行・今回の取込から除外した行・取込予定の行)。
      decisionSummary: {
        originalRows: records.length, correctedRows: corrected.size, excludedRows: excluded.size,
        importRows: records.filter((r) => !excluded.has(r.sourceRowNumber)).length,
      },
      ...(rolesFor(request.eventId, context.event) ? {participationTypes: typeSummary(request.eventId, records, context.event)} : {}),
      totalRecords: batch.totalRecords,
      totalRows: batch.totalRows,
      readyCount: batch.readyCount,
      reviewCount: batch.reviewCount,
      errorCount: batch.errorCount,
      blankRecordCount: batch.blankRecordCount,
      blankRecordNumbers: plan.blankRecordNumbers,
      participantCandidateCount: summary.participantCandidateCount,
      attendanceCandidateCount: summary.attendanceCandidateCount,
      issueCounts: summary.issueCounts,
      // 参考情報(人物の重複判定ではない): 同じファイル(ハッシュ)が既に取り込まれていれば知らせる。取込は止めない。
      sameFileBatches: sameFile.docs.map((doc) => ({batchId: doc.id, sequence: doc.data().sequence, status: doc.data().status})),
      // Phase 1B: 同じbatchId(clientRequestId)が別イベントの取込回なら、そのstatus・sequenceは返さない(他イベントの情報を出さない)。
      // その場合commitは既存どおり batch-content-mismatch で拒否される。
      existingBatch: existing.exists && existing.data().eventId === request.eventId ?
        {status: existing.data().status, sequence: existing.data().sequence} : null,
      mappingWarnings: validateImportMapping(request.mapping).warnings,
      // 行の突合は sourceRowNumber(元CSVのレコード番号)で行う。個人情報は含めない。
      rows: records.map((record) => ({
        sourceRowNumber: record.sourceRowNumber,
        importRecordId: record.importRecordId,
        classification: record.status,
        ...(rolesFor(request.eventId, context.event) ? {participationType: record.status === "ready" ? participationType(request.eventId, record.attendances, context.event) : null} : {}),
        issueCodes: [...new Set(record.issues.map((issue) => issue.code))],
        programIds: record.attendances.map((a) => a.programId),
        ...(excluded.has(record.sourceRowNumber) ? {excluded: true} : {}),
        ...(corrected.has(record.sourceRowNumber) ? {corrected: true} : {}),
      })),
    };
  }

  async function commit({identity, data}) {
    const request = parseImportRequest(data, {commit: true});
    const db = getDb();
    const context = await loadConfirmedEvent(db, request.eventId, request.normalizedMapping);
    // previewの結果は使わず、ここでもう一度、サーバー側で変換・検証する。
    const plan = buildPlan(request, context);
    const {eventId} = request;
    // 管理者の判断(承認・除外)の矛盾は、従来どおり先にinvalid-argumentで拒否する。
    const items = resolveRecords(plan, request);
    const excluded = excludedSetOf(request);
    const approved = new Set(request.approvedReviewRows);
    const pending = pendingRows({records: plan.records, excluded});
    // 既存の取込回(再送・続きからの完了)は従来どおり(作成時点で判断済み。下のguardも呼ばれない)。
    if (!(await db.collection("importBatches").doc(request.batchId).get()).exists) {
      // 新しい取込回: 未解決のエラー(今回の取込から除外していないerror行)が1件でもあれば取り込まない。
      // エラー行を取込対象から外せるのは、管理者が明示的に除外した場合だけ(システムが勝手に落とすことはしない)。
      if (pending.errorRows.length > 0) {
        throw new ApiError("failed-precondition", "未解決のエラーの行があるため取り込めません。検証画面で修正するか、今回の取込から除外してください。",
          {code: "import-has-errors", count: pending.errorRows.length});
      }
      // 確認が必要な行(review)は、許可するか除外する(黙って取込対象から外さない)。
      const unresolvedReview = pending.reviewRows.filter((n) => !approved.has(n));
      if (unresolvedReview.length > 0) {
        throw new ApiError("failed-precondition", "確認が必要な行が解決されていません。検証画面で許可するか、今回の取込から除外してください。",
          {code: "unresolved-review-rows", count: unresolvedReview.length});
      }
      if (request.expectedImportSequence === null || request.validationFingerprint === null) {
        throw new ApiError("failed-precondition", "検証が済んでいないため取り込めません。検証からやり直してください。", {code: "validation-required"});
      }
    }
    // 採番と同じトランザクションの中で、検証時の状態(次の取込回の番号・取り込む内容(修正・除外を含む)・重複している行)を
    // 最新の状態で再計算して照合する。同時に別の取込が確定していれば番号か指紋が変わるため、勝手に次の回として取り込まず、再検証を求める。
    const participants = dataOf(await activeParticipantsQuery(db, eventId).get());
    const allowed = new Map(); // 行番号 → 許可した警告(監査用)
    const allow = (rows, code) => rows.forEach((n) => allowed.set(n, [...(allowed.get(n) || []), code]));
    const recordAllowed = (dup) => {
      allowed.clear();
      allow(pending.reviewRows, "review");
      allow(dup.existingDuplicateRows, "email-duplicate-existing");
      allow(dup.csvDuplicateRows, "email-duplicate-in-csv");
    };
    // 続きからの完了(guardが呼ばれない)でも監査を残せるよう、同じ定義で先に計算しておく(新しい取込回ではguardの値で上書き)。
    recordAllowed(duplicateRows({eventId, records: plan.records, excluded, existingHashes: existingEmailHashes({eventId, participants,
      batches: batchesOf(await eventBatchesQuery(db, eventId).get()), excludeBatchId: request.batchId})}));
    const guardNewBatch = async (tx, {sequence}) => {
      if (request.expectedImportSequence !== sequence) throw stale();
      const state = {participants, batches: batchesOf(await tx.get(eventBatchesQuery(db, eventId)))};
      const dup = duplicateRows({eventId, records: plan.records, existingHashes: existingEmailHashes({eventId, ...state}), excluded});
      const fingerprint = fingerprintOf({
        request, expectedImportSequence: sequence, existingDuplicateRows: dup.existingDuplicateRows, csvDuplicateRows: dup.csvDuplicateRows,
      });
      if (fingerprint !== request.validationFingerprint) throw stale();
      if (dup.existingDuplicateRows.length > 0 && !request.acknowledgeExistingEmailDuplicates) {
        throw new ApiError("failed-precondition", "このイベントの既存の参加者とメールアドレスが同じ参加者が含まれています。検証画面で重複を確認し、別参加者として取り込むことを選んでください。",
          {code: "existing-email-duplicates-unacknowledged", count: dup.existingDuplicateRows.length});
      }
      if (dup.csvDuplicateRows.length > 0 && !request.acknowledgeCsvEmailDuplicates) {
        throw new ApiError("failed-precondition", "CSV内に同じメールアドレスの行があります。検証画面で重複を確認し、別参加者として取り込むことを選んでください。",
          {code: "csv-email-duplicates-unacknowledged", count: dup.csvDuplicateRows.length});
      }
      // 許可した警告が、現在の検証結果の警告と一致すること(行番号ではなく、行の最終的な値と警告の内容から作る鍵で照合する)。
      const approvedKeys = new Set(request.approvalKeys);
      const outdated = [];
      for (const [n, keys] of approvalKeysOf({eventId, records: plan.records, planRows: toPlanRows(request), dup, excluded})) {
        // 鍵があるのは、今回の取込から除外していない行の、許可が必要な警告だけ(未許可のreviewは上で拒否済み)。
        if (Object.values(keys).some((key) => !approvedKeys.has(key))) outdated.push(n);
      }
      if (outdated.length > 0) {
        throw new ApiError("failed-precondition", "許可した後に内容が変わった警告があります。検証画面で改めて確認し、許可してください。",
          {code: "approvals-outdated", count: outdated.length});
      }
      recordAllowed(dup);
      // 取込中に別の取込が同じメールを作らないかの確認用(メールそのものではなくハッシュ。importBatchesはクライアントから読めない)。
      return {
        createdEmailHashes: createdEmailHashes(eventId, items),
        correctedRowCount: correctedSetOf(request).size,
        allowedWarningCounts: {
          review: pending.reviewRows.length, existingEmailDuplicates: dup.existingDuplicateRows.length,
          csvEmailDuplicates: dup.csvDuplicateRows.length,
        },
      };
    };
    // 行ごとの監査(管理者の対処): 原本の値と修正後の値(修正した列だけ)・許可した警告・対処の種類。
    const correctionsByRow = new Map();
    for (const c of request.corrections) correctionsByRow.set(c.sourceRowNumber, [...(correctionsByRow.get(c.sourceRowNumber) || []), c]);
    const originalOf = (rowNumber, column) => {
      const row = request.rows.find((r) => r.sourceRowNumber === rowNumber);
      const index = request.headers.indexOf(column);
      return row && index >= 0 && index < row.values.length ? row.values[index] : "";
    };
    const rowAudit = (item) => {
      const n = item.record.sourceRowNumber;
      const corrections = (correctionsByRow.get(n) || []).map((c) => ({column: c.column, originalValue: originalOf(n, c.column), correctedValue: c.value}));
      const allowedWarnings = allowed.get(n) || [];
      const resolution = item.exclusion ? "excluded" : corrections.length > 0 ? "modified" : allowedWarnings.length > 0 ? "allowed" : "none";
      return {resolution, allowedWarnings, correctedColumns: corrections.map((c) => c.column), corrections};
    };
    return committer.commit({db, identity, request, plan, guardNewBatch, rowAudit});
  }

  return {validate, preview, commit};
}

module.exports = {createImportApi};
