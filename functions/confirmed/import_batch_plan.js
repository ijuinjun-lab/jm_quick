// 新方式(flow=confirmed)の当選者CSV: 取込回(batch)の純粋な計画モデルと、取込レコードID。
// Firestoreへは保存しない(保存は後続Phase)。ネットワークにも触れない。
//
// ■ 一意に管理する対象は「人物」ではなく「batchId + 行番号」の取込レコード(importRecordId)。
//   - 同じ人物が第1回10行目と第2回17行目にいても、別の取込レコードで、両方が処理対象。
//   - 同一batchの同一行を再試行しても同じimportRecordIdになる(二重作成しない。二重送信の防止は後続のmailDelivery管理)。
// ■ システムが行を勝手に除外することはない(「システムによるskip」という状態・件数を持たない)。
//   人が明示的に「この行は送らない」と決めた場合だけ excludedByOperator として記録する(markExcludedByOperator)。

const {createHash} = require("node:crypto");
const {programAttendanceId, validateProgramAttendance} = require("../programs");
const {normalizeImportMapping} = require("./import_mapping");
const {
  STATUS, planImportRows, extractMappedRows, summarizeResults, assertRowConservation, planRowSafely,
} = require("./import_rows");

// batchIdはFirestore自動ID(英数字20文字)やハイフンなしUUID(32文字)を想定。"-" と "_" を含めない。
const BATCH_ID_PATTERN = /^[A-Za-z0-9]{1,40}$/;
const MAX_ROW_NUMBER = 999999;
const MAX_LABEL_LENGTH = 100;
const MAX_FILE_NAME_LENGTH = 255;
const FILE_HASH_PATTERN = /^[0-9a-f]{64}$/;

function isValidBatchId(value) {
  return typeof value === "string" && BATCH_ID_PATTERN.test(value);
}

// 取込レコードID = `${batchId}-${6桁ゼロ埋めの行番号}`。
// - batchIdに"-"が無いため、IDと(batchId, 行番号)が1対1に対応する。
// - Firestoreの文書IDとして安全("/"を含まない)で、同じ入力からは常に同じIDになる。
// - Phase 1のparticipantId規則(英数字とハイフン)を満たすため、そのままparticipantIdにも使える。
function importRecordId(batchId, rowNumber) {
  if (!isValidBatchId(batchId)) throw new Error("invalid batchId");
  if (!Number.isInteger(rowNumber) || rowNumber < 1 || rowNumber > MAX_ROW_NUMBER) {
    throw new Error("invalid rowNumber");
  }
  return `${batchId}-${String(rowNumber).padStart(6, "0")}`;
}

function parseImportRecordId(id) {
  const match = /^([A-Za-z0-9]{1,40})-(\d{6})$/.exec(typeof id === "string" ? id : "");
  if (!match) return null;
  const rowNumber = Number(match[2]);
  return rowNumber >= 1 ? {batchId: match[1], rowNumber} : null;
}

// 1取込レコード = participant 1件。participantIdは取込レコードIDと同じ(再試行しても増えない)。
function participantIdForImportRecord(recordId) {
  if (parseImportRecordId(recordId) === null) throw new Error("invalid importRecordId");
  return recordId;
}

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function assertBatchInputs({eventId, batchId, sequence, label, sourceFileName, fileHash}) {
  if (typeof eventId !== "string" || eventId.trim() === "") throw new Error("invalid eventId");
  if (!isValidBatchId(batchId)) throw new Error("invalid batchId");
  if (!Number.isInteger(sequence) || sequence < 1) throw new Error("invalid sequence");
  if (typeof label !== "string" || label.length > MAX_LABEL_LENGTH) throw new Error("invalid label");
  if (typeof sourceFileName !== "string" || sourceFileName.length > MAX_FILE_NAME_LENGTH) {
    throw new Error("invalid sourceFileName");
  }
  if (typeof fileHash !== "string" || !FILE_HASH_PATTERN.test(fileHash)) throw new Error("invalid fileHash");
}

// 結果1件を取込レコードにする。participantId・attendanceIdを決定的に付け、attendance候補をProgramAttendanceの規則で検証する。
// 検証に失敗してもレコードは消さず、errorとして残す。
function toRecord({eventId, batchId}, result) {
  const recordId = importRecordId(batchId, result.sourceRowNumber);
  const participantId = participantIdForImportRecord(recordId);
  const issues = [...result.issues];
  const attendances = result.attendances.map((a) => ({
    attendanceId: programAttendanceId(participantId, a.programId),
    eventId,
    participantId,
    programId: a.programId,
    plannedCount: a.plannedCount,
    slotLabel: a.slotLabel,
    startAt: a.startAt,
    endAt: a.endAt,
    checkedIn: false,
  }));
  for (const attendance of attendances) {
    const errors = validateProgramAttendance(attendance);
    if (errors.length > 0) {
      issues.push({code: "attendance-invalid", severity: "error", programId: attendance.programId, fields: errors});
    }
  }
  const status = issues.some((i) => i.severity === "error") ? STATUS.ERROR
    : issues.length > 0 ? STATUS.REVIEW : STATUS.READY;
  return {
    importRecordId: recordId,
    batchId,
    sourceRowNumber: result.sourceRowNumber,
    status,
    issues,
    notices: result.notices,
    participantId,
    participant: result.participant,
    attendances,
    excludedByOperator: false,
  };
}

function summarizeBatch(base, records, blankRecordCount, totalRecords) {
  const counts = {readyCount: 0, reviewCount: 0, errorCount: 0};
  for (const record of records) {
    if (record.status === STATUS.READY) counts.readyCount += 1;
    else if (record.status === STATUS.REVIEW) counts.reviewCount += 1;
    else counts.errorCount += 1;
  }
  const totalRows = records.length;
  const excludedByOperatorCount = records.filter((r) => r.excludedByOperator).length;
  if (counts.readyCount + counts.reviewCount + counts.errorCount !== totalRows) {
    throw new Error("batch conservation violated");
  }
  if (totalRows + blankRecordCount !== totalRecords) throw new Error("batch record conservation violated");
  return {...base, totalRows, ...counts, excludedByOperatorCount, blankRecordCount, totalRecords};
}

// 取込回の計画を作る。table = {headers, records}(CSVの全レコード)。
// 戻り値: {ok:true, batch, records, summary} | {ok:false, errors}(必須列の欠落など、ファイル全体の問題)
//   records は入力の全行と1対1(欠落なし)。batch.readyCount + reviewCount + errorCount === batch.totalRows。
//   batch.totalRows + batch.blankRecordCount === batch.totalRecords(空レコードも黙って捨てず件数に出す)。
function planImportBatch({eventId, batchId, sequence, label, sourceFileName, fileHash, mapping, table, eventDate,
  eventProgramIds}) {
  assertBatchInputs({eventId, batchId, sequence, label, sourceFileName, fileHash});
  // 各関数が検証・正規化を行うため、元のmappingをそのまま渡す(正規化済みの値は再検証の入力にしない)。
  const {version: mappingVersion} = normalizeImportMapping(mapping, {eventProgramIds});
  const extraction = extractMappedRows(table, mapping);
  if (!extraction.ok) return {ok: false, errors: extraction.errors};
  const {results, summary} = planImportRows({rows: extraction.rows, mapping, eventDate, eventProgramIds});
  const records = results.map((result) => toRecord({eventId, batchId}, result));
  const batch = summarizeBatch({
    batchId, eventId, sequence, label, sourceFileName, fileHash, mappingVersion,
  }, records, extraction.blankRecordNumbers.length, extraction.totalRecords);
  return {ok: true, batch, records, summary, blankRecordNumbers: extraction.blankRecordNumbers};
}

// 人が明示的に「この行は送らない」と決めた取込レコードを記録した、新しい計画を返す(入力は変更しない)。
// 行は計画から消えず、ready/review/errorの件数も変わらない。excludedByOperatorCountだけが増える。
// システム(planImportBatch)が自動で除外することは無い。
function markExcludedByOperator(plan, {recordIds, operatorId, reason}) {
  if (!Array.isArray(recordIds) || recordIds.length === 0) throw new Error("recordIds required");
  if (typeof operatorId !== "string" || operatorId.trim() === "") throw new Error("operatorId required");
  if (typeof reason !== "string" || reason.trim() === "") throw new Error("reason required");
  const targets = new Set(recordIds);
  const known = new Set(plan.records.map((r) => r.importRecordId));
  for (const id of targets) if (!known.has(id)) throw new Error(`unknown importRecordId: ${id}`);
  const records = plan.records.map((record) => (targets.has(record.importRecordId)
    ? {...record, excludedByOperator: true, excludedBy: operatorId, excludedReason: reason.trim()}
    : record));
  const {batch} = plan;
  return {
    ...plan,
    records,
    batch: summarizeBatch(
      {
        batchId: batch.batchId, eventId: batch.eventId, sequence: batch.sequence, label: batch.label,
        sourceFileName: batch.sourceFileName, fileHash: batch.fileHash, mappingVersion: batch.mappingVersion,
      },
      records, batch.blankRecordCount, batch.totalRecords,
    ),
  };
}

module.exports = {
  isValidBatchId,
  importRecordId,
  parseImportRecordId,
  participantIdForImportRecord,
  sha256Hex,
  planImportBatch,
  markExcludedByOperator,
  // 再エクスポート(呼び出し側が行単位の計画・集計も使えるように)
  planRowSafely,
  summarizeResults,
  assertRowConservation,
};
