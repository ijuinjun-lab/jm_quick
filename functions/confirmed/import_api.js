// 新方式の当選者CSV取込API(admin専用callableのハンドラ): previewConfirmedImport / commitConfirmedImport。
// 認可(admin)はindex.jsの confirmedCallable("admin", ...) が済ませており、ここへ届く identity はサーバー側で確定した値。
// dbは createImportApi の getDb から取得する(このファイルはFirebaseのパッケージを読み込まない)。
//
// ■ クライアントを信用しない:
//   - eventの内容は必ずサーバーで再読込する(存在・flow=confirmed・program定義)。クライアントが送ったeventの内容は使わない。
//   - commitでは、preview結果も、クライアントが送る participant データも信用しない。mapping・headers・rowsから、
//     サーバーがPhase 3の変換・検証をもう一度実行する(クライアントから受け取るのは元のCSVの値と、管理者の判断だけ)。
// ■ previewはFirestoreへ一切書き込まない(読み取りのみ)。レスポンスに氏名・メール・かな・自由記述を含めない。
// ■ メールは一切送らない。

const {ApiError} = require("./api_error");
const {validateImportMapping} = require("./import_mapping");
const {isConfirmedFlow} = require("../flow");
const {parseImportRequest, toPlanRows} = require("./import_request");
const {planImportBatchFromRows, importRecordId} = require("./import_batch_plan");
const {createImportCommitter} = require("./import_commit");

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
  return {eventProgramIds, eventDate};
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

function createImportApi({getDb, serverTimestamp, generatePublicId, concurrency}) {
  const committer = createImportCommitter({serverTimestamp, generatePublicId, concurrency, importRecordId});

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
    return {
      batchId: request.batchId,
      eventId: request.eventId,
      mappingVersion: batch.mappingVersion,
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
        issueCodes: [...new Set(record.issues.map((issue) => issue.code))],
        programIds: record.attendances.map((a) => a.programId),
      })),
    };
  }

  async function commit({identity, data}) {
    const request = parseImportRequest(data, {commit: true});
    const db = getDb();
    const context = await loadConfirmedEvent(db, request.eventId, request.normalizedMapping);
    // previewの結果は使わず、ここでもう一度、サーバー側で変換・検証する。
    const plan = buildPlan(request, context);
    return committer.commit({db, identity, request, plan});
  }

  return {preview, commit};
}

module.exports = {createImportApi};
