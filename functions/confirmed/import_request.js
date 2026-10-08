// 新方式の当選者CSV取込API(preview / commit)のリクエスト検証。純粋関数のみ。
//
// ■ 契約(クライアントは「必要な列だけ」を渡す。未マップの列=氏名・メール以外の自由記述などは送らせない):
//   {
//     eventId, clientRequestId,          // clientRequestId = batchId。英数字1〜40文字(冪等キー。再送は同じ値)
//     sourceFileName, fileHash,          // 監査用(fileHashはsha256の16進64文字)
//     label?,                            // 表示名。省略時はサーバーが「第N回」を付ける
//     mapping,                           // Phase 3のimport mapping
//     headers,                           // mappingが読む列の名前だけ(過不足なし)
//     rows: [{rowNumber, values}],       // rowNumber = CSVのレコード番号(ヘッダー=1、最初のデータ行=2)。valuesはheadersと同順の文字列
//     totalRecords, blankRecordNumbers,  // 元CSVのデータレコード総数(空レコードを含む)と、全項目が空だったレコード番号
//     corrections?, excludedRows?        // 検証画面での管理者の対処(validate・preview・commit共通。原本のrowsは変えない):
//                                         //   corrections: [{sourceRowNumber, column, value}] 修正した値(修正できる列だけ)
//                                         //   excludedRows: [{sourceRowNumber, reason}]        今回の取込から除外する行
//     approvedReviewRows?                // commitのみ。確認が必要な行(review)を許可した管理者の明示的な判断
//     acknowledgeIgnoredCounts?          // commitのみ。受け付けるが使わない(不参加のprogramに残る人数は参考情報で、確認は要らない)
//     acknowledgeExistingEmailDuplicates? // commitのみ。既存の有効な参加者とのメール重複を、別参加者として取り込むことの明示的な許可
//     acknowledgeCsvEmailDuplicates?      // commitのみ。CSV内のメール重複を、別参加者として取り込むことの明示的な許可
//     approvalKeys?                      // commitのみ。管理者が許可した警告の鍵(検証が行ごとに返したapprovalKeysの値)。
//                                         // 新しい取込回では、許可が必要な警告すべての「現在の」鍵が含まれていなければ拒否する
//     expectedImportSequence?, validationFingerprint? // commitのみ。検証(validate)が返した次の取込回の番号と検証の指紋。
//                                         // 新しい取込回を作るときは必須(サーバーが採番と同じトランザクションで照合する)
//   }
// ■ 行の欠落を許さない: rows と blankRecordNumbers を合わせて、2..totalRecords+1 の全レコード番号を
//   過不足なく(重複なく)ちょうど1回ずつ含んでいなければ拒否する。クライアントが行を黙って落とす余地を作らない。
// ■ 人物の同一性は見ない(同じメール・氏名・参照コードの行も、そのまま別の行として受け付ける)。

const {createHash} = require("node:crypto");
const {ApiError} = require("./api_error");
const {ImportMappingError, normalizeImportMapping, mappedColumns} = require("./import_mapping");
const {isValidBatchId} = require("./import_batch_plan");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const FILE_HASH_PATTERN = /^[0-9a-f]{64}$/;
const MAX_ROWS = 5000;
const MAX_HEADERS = 60;
const MAX_VALUE_LENGTH = 2000;
const MAX_LABEL_LENGTH = 100;
const MAX_FILE_NAME_LENGTH = 255;
const MAX_REASON_LENGTH = 200;
const MAX_DECISIONS = MAX_ROWS;

const COMMON_KEYS = ["eventId", "clientRequestId", "sourceFileName", "fileHash", "label", "mapping", "headers", "rows",
  "totalRecords", "blankRecordNumbers", "corrections", "excludedRows"];
const COMMIT_KEYS = [...COMMON_KEYS, "approvedReviewRows", "acknowledgeExistingEmailDuplicates",
  "acknowledgeCsvEmailDuplicates", "acknowledgeIgnoredCounts", "approvalKeys", "expectedImportSequence", "validationFingerprint"];
const ACK_KEYS = ["acknowledgeExistingEmailDuplicates", "acknowledgeCsvEmailDuplicates", "acknowledgeIgnoredCounts"];
const FINGERPRINT_PATTERN = /^[0-9a-f]{64}$/;
const MAX_APPROVAL_KEYS = MAX_ROWS * 3; // 1行あたり最大3種類(確認が必要・既存参加者との重複・CSV内の重複)

const invalid = (code, path, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, path, ...extra});
const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isInt = (v, min) => Number.isInteger(v) && v >= min;

function parseDecisions(data, path, parseItem) {
  const raw = data === undefined ? [] : data;
  if (!Array.isArray(raw) || raw.length > MAX_DECISIONS) throw invalid("invalid-list", path);
  const items = raw.map((item, index) => parseItem(item, `${path}[${index}]`));
  const numbers = items.map((item) => item.sourceRowNumber);
  if (new Set(numbers).size !== numbers.length) throw invalid("duplicate-row-decision", path);
  return items.sort((a, b) => a.sourceRowNumber - b.sourceRowNumber);
}

// 修正できる列: 参加者の氏名・メール・HEBEL属性と、各programの人数・参加・時間枠の列(検証で問題になる値だけ。汎用のCSV編集はしない)。
function correctableColumns(mapping) {
  const columns = new Set([mapping.participant.nameColumn, mapping.participant.emailColumn]);
  if (mapping.participant.hebelResidenceColumn) columns.add(mapping.participant.hebelResidenceColumn);
  for (const program of mapping.programs) {
    for (const column of [program.countColumn, program.participationColumn, program.slotColumn]) if (column) columns.add(column);
  }
  return columns;
}

// 検証して正規化したリクエストを返す。不正ならApiError(invalid-argument)。
// commit=false(validate・preview)では、許可(approvedReviewRows・acknowledge*)・番号・指紋を受け付けない。
function parseImportRequest(data, {commit}) {
  if (!isPlainObject(data)) throw invalid("body-not-object", "");
  const allowed = commit ? COMMIT_KEYS : COMMON_KEYS;
  for (const key of Object.keys(data)) {
    if (!allowed.includes(key)) throw invalid("unknown-key", key);
  }
  if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id", "eventId");
  if (!isValidBatchId(data.clientRequestId)) throw invalid("invalid-client-request-id", "clientRequestId");
  if (typeof data.sourceFileName !== "string" || data.sourceFileName.length > MAX_FILE_NAME_LENGTH) {
    throw invalid("invalid-source-file-name", "sourceFileName");
  }
  if (typeof data.fileHash !== "string" || !FILE_HASH_PATTERN.test(data.fileHash)) throw invalid("invalid-file-hash", "fileHash");
  if (data.label !== undefined && (typeof data.label !== "string" || data.label.length > MAX_LABEL_LENGTH)) {
    throw invalid("invalid-label", "label");
  }

  let mapping;
  try {
    mapping = normalizeImportMapping(data.mapping);
  } catch (error) {
    if (error instanceof ImportMappingError) throw invalid("invalid-mapping", "mapping", {mappingErrors: error.errors});
    throw error;
  }

  // 列: mappingが読む列と過不足なく一致(未マップの列を送らせない=データ最小化)。
  const {headers} = data;
  if (!Array.isArray(headers) || headers.length === 0 || headers.length > MAX_HEADERS ||
      headers.some((h) => typeof h !== "string" || h.trim() === "")) {
    throw invalid("invalid-headers", "headers");
  }
  const headerNames = headers.map((h) => h.trim());
  if (new Set(headerNames).size !== headerNames.length) throw invalid("duplicate-header", "headers");
  const needed = new Set(mappedColumns(mapping));
  const missing = [...needed].filter((c) => !headerNames.includes(c));
  if (missing.length > 0) throw invalid("column-missing", "headers", {columns: missing});
  const extra = headerNames.filter((c) => !needed.has(c));
  if (extra.length > 0) throw invalid("unexpected-column", "headers", {columns: extra});

  // 行: 番号・値の型と件数。
  if (!isInt(data.totalRecords, 0) || data.totalRecords > MAX_ROWS) throw invalid("invalid-total-records", "totalRecords");
  if (!Array.isArray(data.rows) || data.rows.length > MAX_ROWS) throw invalid("invalid-rows", "rows");
  const rows = data.rows.map((row, index) => {
    const path = `rows[${index}]`;
    if (!isPlainObject(row) || !isInt(row.rowNumber, 2) || !Array.isArray(row.values) ||
        row.values.length > MAX_HEADERS || row.values.some((v) => typeof v !== "string" || v.length > MAX_VALUE_LENGTH)) {
      throw invalid("invalid-row", path);
    }
    for (const key of Object.keys(row)) if (key !== "rowNumber" && key !== "values") throw invalid("unknown-key", `${path}.${key}`);
    return {sourceRowNumber: row.rowNumber, values: row.values};
  });
  const blank = data.blankRecordNumbers;
  if (!Array.isArray(blank) || blank.length > MAX_ROWS || blank.some((n) => !isInt(n, 2))) {
    throw invalid("invalid-blank-record-numbers", "blankRecordNumbers");
  }

  // 欠落の防止: 2..totalRecords+1 の全レコード番号が、rowsかblankのどちらかにちょうど1回ずつ現れること。
  const seen = new Set();
  for (const n of [...rows.map((r) => r.sourceRowNumber), ...blank]) {
    if (seen.has(n)) throw invalid("duplicate-record-number", "rows");
    seen.add(n);
  }
  const lastNumber = data.totalRecords + 1;
  const outOfRange = [...seen].filter((n) => n > lastNumber);
  const absent = [];
  for (let n = 2; n <= lastNumber; n += 1) if (!seen.has(n)) absent.push(n);
  if (outOfRange.length > 0 || absent.length > 0) {
    throw invalid("record-accounting-mismatch", "rows", {
      totalRecords: data.totalRecords, received: seen.size, missingRecordNumbers: absent.slice(0, 20),
      outOfRangeRecordNumbers: outOfRange.slice(0, 20),
    });
  }

  const request = {
    eventId: data.eventId,
    batchId: data.clientRequestId,
    sourceFileName: data.sourceFileName,
    fileHash: data.fileHash,
    label: data.label === undefined ? null : data.label,
    mapping: data.mapping,
    normalizedMapping: mapping,
    headers: headerNames,
    rows: rows.sort((a, b) => a.sourceRowNumber - b.sourceRowNumber),
    totalRecords: data.totalRecords,
    blankRecordNumbers: [...blank].sort((a, b) => a - b),
    corrections: [],
    approvedReviewRows: [],
    excludedRows: [],
    acknowledgeExistingEmailDuplicates: false,
    acknowledgeCsvEmailDuplicates: false,
    acknowledgeIgnoredCounts: false,
    approvalKeys: [],
    expectedImportSequence: null,
    validationFingerprint: null,
  };
  // 対処(修正・除外)は、元のCSVの実在する行(空レコード・ヘッダーは対象外)だけ。
  const rowByNumber = new Map(request.rows.map((row) => [row.sourceRowNumber, row]));
  request.excludedRows = parseDecisions(data.excludedRows, "excludedRows", (item, path) => {
    if (!isPlainObject(item) || !isInt(item.sourceRowNumber, 2) || typeof item.reason !== "string" ||
        item.reason.trim() === "" || item.reason.length > MAX_REASON_LENGTH) {
      throw invalid("invalid-exclusion", path);
    }
    for (const key of Object.keys(item)) if (key !== "sourceRowNumber" && key !== "reason") throw invalid("unknown-key", `${path}.${key}`);
    if (!rowByNumber.has(item.sourceRowNumber)) throw invalid("exclusion-unknown-row", path, {sourceRowNumber: item.sourceRowNumber});
    return {sourceRowNumber: item.sourceRowNumber, reason: item.reason.trim()};
  });
  const rawCorrections = data.corrections === undefined ? [] : data.corrections;
  if (!Array.isArray(rawCorrections) || rawCorrections.length > MAX_DECISIONS) throw invalid("invalid-list", "corrections");
  const correctable = correctableColumns(mapping);
  const seenCorrections = new Set();
  request.corrections = rawCorrections.map((item, index) => {
    const path = `corrections[${index}]`;
    if (!isPlainObject(item) || !isInt(item.sourceRowNumber, 2) || typeof item.column !== "string" ||
        typeof item.value !== "string" || item.value.length > MAX_VALUE_LENGTH) {
      throw invalid("invalid-correction", path);
    }
    for (const key of Object.keys(item)) if (!["sourceRowNumber", "column", "value"].includes(key)) throw invalid("unknown-key", `${path}.${key}`);
    const row = rowByNumber.get(item.sourceRowNumber);
    if (!row) throw invalid("correction-unknown-row", path, {sourceRowNumber: item.sourceRowNumber});
    if (!correctable.has(item.column)) throw invalid("correction-column-not-allowed", path);
    const key = `${item.sourceRowNumber}\n${item.column}`;
    if (seenCorrections.has(key)) throw invalid("duplicate-correction", path);
    seenCorrections.add(key);
    const index2 = headerNames.indexOf(item.column);
    const original = index2 < row.values.length ? row.values[index2] : "";
    if (original === item.value) throw invalid("correction-unchanged", path);
    return {sourceRowNumber: item.sourceRowNumber, column: item.column, value: item.value};
  }).sort((a, b) => (a.sourceRowNumber - b.sourceRowNumber) || (a.column < b.column ? -1 : a.column > b.column ? 1 : 0));
  if (commit) {
    const approved = data.approvedReviewRows === undefined ? [] : data.approvedReviewRows;
    if (!Array.isArray(approved) || approved.length > MAX_DECISIONS || approved.some((n) => !isInt(n, 2))) {
      throw invalid("invalid-list", "approvedReviewRows");
    }
    if (new Set(approved).size !== approved.length) throw invalid("duplicate-row-decision", "approvedReviewRows");
    request.approvedReviewRows = [...approved].sort((a, b) => a - b);
    for (const key of ACK_KEYS) {
      if (data[key] !== undefined && typeof data[key] !== "boolean") throw invalid("invalid-acknowledgement", key);
      request[key] = data[key] === true;
    }
    const keys = data.approvalKeys === undefined ? [] : data.approvalKeys;
    if (!Array.isArray(keys) || keys.length > MAX_APPROVAL_KEYS || keys.some((k) => typeof k !== "string" || !FINGERPRINT_PATTERN.test(k))) {
      throw invalid("invalid-list", "approvalKeys");
    }
    if (new Set(keys).size !== keys.length) throw invalid("duplicate-approval-key", "approvalKeys");
    request.approvalKeys = [...keys].sort();
    if (data.expectedImportSequence !== undefined) {
      if (!isInt(data.expectedImportSequence, 1) || data.expectedImportSequence > 1000000) {
        throw invalid("invalid-expected-import-sequence", "expectedImportSequence");
      }
      request.expectedImportSequence = data.expectedImportSequence;
    }
    if (data.validationFingerprint !== undefined) {
      if (typeof data.validationFingerprint !== "string" || !FINGERPRINT_PATTERN.test(data.validationFingerprint)) {
        throw invalid("invalid-validation-fingerprint", "validationFingerprint");
      }
      request.validationFingerprint = data.validationFingerprint;
    }
  }
  return request;
}

// 行データ(mappedな列だけ)を、Phase 3の planImportBatchFromRows が受け取る形へ変換する。
// 管理者の修正(corrections)は、ここで最終的な値として重ねる(原本のrequest.rowsは変えない)。判定は常に最終的な値で行う。
// 値の個数がheadersと違う行は、捨てずに structuralIssues(review)として残す。
function toPlanRows(request) {
  const corrected = new Map();
  for (const c of request.corrections || []) corrected.set(`${c.sourceRowNumber}\n${c.column}`, c.value);
  return request.rows.map((row) => {
    const cells = {};
    request.headers.forEach((header, index) => {
      const key = `${row.sourceRowNumber}\n${header}`;
      cells[header] = corrected.has(key) ? corrected.get(key) : index < row.values.length ? row.values[index] : "";
    });
    const planRow = {sourceRowNumber: row.sourceRowNumber, cells};
    if (row.values.length !== request.headers.length) planRow.structuralIssues = ["row-length-mismatch"];
    return planRow;
  });
}

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

// 同じclientRequestIdの再送が「同じ内容」かを判定するためのハッシュ(内容 = CSVの行・mapping・管理者の判断すべて)。
// 重複等の許可・期待する取込回の番号・検証の指紋は、内容ではなく作成の条件なので含めない(既存の取込回のハッシュも変わらない)。
function requestHash(request) {
  const content = {
    eventId: request.eventId, sourceFileName: request.sourceFileName, fileHash: request.fileHash, label: request.label,
    mapping: request.normalizedMapping, headers: request.headers, rows: request.rows,
    totalRecords: request.totalRecords, blankRecordNumbers: request.blankRecordNumbers,
    approvedReviewRows: request.approvedReviewRows, excludedRows: request.excludedRows,
    // 修正がある場合だけ含める(修正の無い取込・既存の取込回のハッシュは従来と同じ)。
    ...(request.corrections && request.corrections.length > 0 ? {corrections: request.corrections} : {}),
  };
  return createHash("sha256").update(canonical(content)).digest("hex");
}

module.exports = {MAX_ROWS, parseImportRequest, toPlanRows, requestHash, correctableColumns};
