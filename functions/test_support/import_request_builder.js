// テスト用: 管理画面(クライアント)が送るのと同じ形の取込リクエストを、架空のCSV表から作る。
// クライアントの責務: mappingが読む列だけを抽出し、全項目が空のレコードはblankRecordNumbersへ入れ、totalRecordsを付ける。
const {normalizeImportMapping, mappedColumns} = require("../confirmed/import_mapping");
const {syntheticMapping, FILE_HASH} = require("../confirmed/test_support/synthetic");

function buildImportRequest({table, mapping = syntheticMapping(), eventId = "event1", clientRequestId = "batchA",
  sourceFileName = "synthetic.csv", fileHash = FILE_HASH, label, approvedReviewRows, excludedRows, extra = {}}) {
  const columns = mappedColumns(normalizeImportMapping(mapping));
  const indexes = columns.map((column) => table.headers.indexOf(column));
  const rows = [];
  const blankRecordNumbers = [];
  table.records.forEach((record, position) => {
    const rowNumber = position + 2;
    if (record.every((value) => String(value).trim() === "")) blankRecordNumbers.push(rowNumber);
    else rows.push({rowNumber, values: indexes.map((index) => String(record[index]))});
  });
  const request = {
    eventId, clientRequestId, sourceFileName, fileHash, mapping, headers: columns, rows,
    totalRecords: table.records.length, blankRecordNumbers, ...extra,
  };
  if (label !== undefined) request.label = label;
  if (approvedReviewRows !== undefined) request.approvedReviewRows = approvedReviewRows;
  if (excludedRows !== undefined) request.excludedRows = excludedRows;
  return request;
}

module.exports = {buildImportRequest};
