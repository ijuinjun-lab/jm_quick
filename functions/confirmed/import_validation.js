// 新方式(flow=confirmed)の当選者CSV: 取込前の「検証」と、commitでの再確認に使う純粋関数(Firestore・ネットワークに触れない)。
//
// ■ 行の判定(ready/review/error)は作らない。planImportBatchFromRows(preview・commitと同じ計画)の結果を
//   そのまま読み替えるだけ: error → エラー / review → 警告。検証とプレビュー・取込の判定は食い違わない。
// ■ 検証が加えるのは「見える化」だけ。行を除外・統合・skipしない(1行=1参加者はそのまま)。
//   - CSV内のメール重複 / このイベントの既存の有効な参加者(取込回が作る・作った参加者を含む)とのメール重複(警告)
//   - 不参加のprogramに残っていて無視される人数(planRowのnotice。参考情報: 見せるだけで、許可は要らない)
//   - 参加タイプ(participationMappingのあるイベントだけ)を判定できない行(警告)
//   - HEBEL属性(列を指定した取込だけ): 行ごとの分類と分類別の件数(未知の値は計画がreviewにしている)
// ■ メールの比較は planRow が作った participant.email(import_rows.js の normalizeEmail: trim+小文字化)。
//   既存参加者側も同じ normalizeEmail を通し、イベントIDと組にしたハッシュ(emailHash)で比べる(独自の正規化はしない)。
// ■ 検証の指紋(fingerprintOf): CSVの内容・列の対応・イベント・次の取込回の番号・重複している行から、サーバーが毎回同じ値を
//   再計算できる。commitは採番と同じトランザクションの中で再計算し、検証時の値と一致しなければ書かない(秘密情報は使わない)。
// ■ 許可の鍵(approvalKeysOf): 許可が必要な警告(確認が必要な行・既存参加者/CSV内のメール重複)ごとに、
//   その行の最終的な値(原本+修正)・警告の内容(問題のコード・重複相手の行)から作るハッシュ。
//   commitは、許可した警告の鍵が「現在の」検証結果の鍵と一致することを確認する。行を修正したり、重複相手が変わったりすれば
//   鍵が変わるため、古い許可(同じ行番号の許可)は流用できない。
// ■ 応答には氏名・メールを含めない(行番号と判定コードだけ。表示する氏名・メールは画面が手元のCSVから取る)。

const {createHash} = require("node:crypto");
const {normalizeEmail} = require("./import_rows");
const {participationType, rolesFor, typeSummary} = require("./participation_types");
const {HEBEL_RESIDENCE, hebelResidenceSummary} = require("./hebel_residence");

const RESULT = Object.freeze({OK: "ok", WARNING: "warning", ERROR: "error", INFO: "info"});
const EXISTING_DUPLICATE = "email-duplicate-existing";
const CSV_DUPLICATE = "email-duplicate-in-csv";
const TYPE_UNDETERMINED = "participation-type-undetermined";
const IGNORED_COUNT = "not-attending-count-ignored";
const FINGERPRINT_VERSION = 1;
const APPROVAL_KEY_VERSION = 1;
// 許可が必要な警告の種類(許可の鍵の対象)。
const APPROVAL = Object.freeze({REVIEW: "review", EXISTING_DUPLICATE: "existingDuplicate", CSV_DUPLICATE: "csvDuplicate"});
// 計画の注記(notice)の扱い: どちらも参考情報(見せるだけ。取込・参加の判定に影響せず、許可も要らない)。
// 無視される人数: 不参加のprogramに残っている人数(参加扱いにはせず、人数は無視する)。登録日時を解釈できないこと。
const NOTICE_SEVERITY = Object.freeze({[IGNORED_COUNT]: RESULT.INFO, "registered-at-unparsed": RESULT.INFO});

const sha256 = (text) => createHash("sha256").update(text).digest("hex");

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

// イベントIDと組にしたメールのハッシュ。取込中の取込回へ保存し、重複の確認に使う(メールそのものは複製しない)。
function emailHash(eventId, email) {
  return sha256(`${eventId}\n${normalizeEmail(email)}`);
}

// 既存として数えるメールのハッシュ: 有効な参加者 + 取込回(状態を問わない)が作る・作った参加者のハッシュ。
// 取込回のハッシュは採番と同じトランザクションの中で読むため、同時に確定した別の取込回の分も必ず数えられる
// (取込中で参加者がまだ書かれていない取込回も含む)。
// excludeBatchId: 途中で止まった同じ取込回を続きから完了する場合の、その取込回自身の分は数えない。
function existingEmailHashes({eventId, participants, batches, excludeBatchId = null}) {
  const hashes = new Set();
  for (const p of participants) {
    if (excludeBatchId !== null && p.importBatchId === excludeBatchId) continue;
    if (p && p.status === "active" && typeof p.email === "string" && normalizeEmail(p.email) !== "") hashes.add(emailHash(eventId, p.email));
  }
  for (const b of batches) {
    if (b.id === excludeBatchId || !Array.isArray(b.createdEmailHashes)) continue;
    for (const h of b.createdEmailHashes) hashes.add(h);
  }
  return hashes;
}

// 重複している行(参加者候補のある行のうち、今回の取込から除外していない行が対象)。検証とcommitで同じ定義。
function duplicateRows({eventId, records, existingHashes, excluded = new Set()}) {
  const rowsByEmail = new Map();
  for (const record of records) {
    if (!record.participant || excluded.has(record.sourceRowNumber)) continue;
    const list = rowsByEmail.get(record.participant.email) || [];
    list.push(record.sourceRowNumber);
    rowsByEmail.set(record.participant.email, list);
  }
  const existing = [];
  const csv = [];
  for (const record of records) {
    if (!record.participant || excluded.has(record.sourceRowNumber)) continue;
    if (rowsByEmail.get(record.participant.email).length > 1) csv.push(record.sourceRowNumber);
    if (existingHashes.has(emailHash(eventId, record.participant.email))) existing.push(record.sourceRowNumber);
  }
  return {existingDuplicateRows: existing.sort((a, b) => a - b), csvDuplicateRows: csv.sort((a, b) => a - b), rowsByEmail};
}

// 取り込む内容: 原本のCSV(行・列の対応・ファイル) + 管理者の修正 + 今回の取込から除外した行。
// ファイル名・ラベル・許可(承認・重複等の確認)は含めない(許可はcommitが最新の状態に対して確認する)。
function contentHash(request) {
  return sha256(canonical({
    eventId: request.eventId, fileHash: request.fileHash, mapping: request.normalizedMapping, headers: request.headers,
    rows: request.rows, totalRecords: request.totalRecords, blankRecordNumbers: request.blankRecordNumbers,
    corrections: request.corrections || [], excludedRows: (request.excludedRows || []).map((e) => e.sourceRowNumber),
    // 繰り上げ当選だけ含める(通常当選=既存の指紋は従来と同じ)。検証と確定で通知種別・シート(候補のシートを含む)が違えば指紋が一致しない。
    ...(request.notificationType === "waitlistPromotion" ?
      {notificationType: request.notificationType, sourceSheetName: request.sourceSheetName,
        sourceSheetCandidates: request.sourceSheetCandidates} : {}),
  }));
}

// 対処が必要な行(今回の取込から除外していない行だけ)。検証の表示とcommitの確認で同じ定義。
// ignoredCountRows(不参加のprogramに残っている人数)は参考情報の一覧(対処・許可は要らない)。
function pendingRows({records, excluded = new Set()}) {
  const included = records.filter((r) => !excluded.has(r.sourceRowNumber));
  return {
    errorRows: included.filter((r) => r.status === "error").map((r) => r.sourceRowNumber),
    reviewRows: included.filter((r) => r.status === "review").map((r) => r.sourceRowNumber),
    ignoredCountRows: included.filter((r) => (r.notices || []).some((n) => n.code === IGNORED_COUNT)).map((r) => r.sourceRowNumber),
  };
}

// 検証の指紋。サーバーが再計算できる値だけから作る(改ざんされた値は、commitの再計算と一致しない)。
function fingerprintOf({request, expectedImportSequence, existingDuplicateRows, csvDuplicateRows}) {
  return sha256(canonical({
    v: FINGERPRINT_VERSION, content: contentHash(request), expectedImportSequence, existingDuplicateRows, csvDuplicateRows,
  }));
}

// 許可が必要な警告ごとの鍵(今回の取込から除外していない行だけ)。行番号 → {review?, existingDuplicate?, csvDuplicate?}。
// planRows: toPlanRows(request)の結果(最終的な値)。dup: duplicateRows の結果。検証とcommitで同じ定義。
// 鍵には、その行の最終的な値と警告の内容を含める(他の行の値は含めない。他の行を修正しても、この行の許可は
// 重複相手が変わらない限り有効)。
function approvalKeysOf({eventId, records, planRows, dup, excluded = new Set()}) {
  const cellsByRow = new Map(planRows.map((row) => [row.sourceRowNumber, row.cells]));
  const existingSet = new Set(dup.existingDuplicateRows);
  const key = (n, kind, detail) => sha256(canonical({v: APPROVAL_KEY_VERSION, eventId, row: n, kind, cells: cellsByRow.get(n) || {}, detail}));
  const keys = new Map();
  for (const record of records) {
    const n = record.sourceRowNumber;
    if (excluded.has(n)) continue;
    const rowKeys = {};
    if (record.status === "review") {
      const issues = record.issues.map((i) => ({code: i.code, programId: i.programId || null, column: i.column || null}));
      rowKeys[APPROVAL.REVIEW] = key(n, APPROVAL.REVIEW, {issues});
    }
    if (record.participant) {
      if (existingSet.has(n)) rowKeys[APPROVAL.EXISTING_DUPLICATE] = key(n, APPROVAL.EXISTING_DUPLICATE, {email: record.participant.email});
      const partners = (dup.rowsByEmail.get(record.participant.email) || []).filter((m) => m !== n);
      if (partners.length > 0) {
        rowKeys[APPROVAL.CSV_DUPLICATE] = key(n, APPROVAL.CSV_DUPLICATE, {email: record.participant.email, partners: [...partners].sort((a, b) => a - b)});
      }
    }
    if (Object.keys(rowKeys).length > 0) keys.set(n, rowKeys);
  }
  return keys;
}

// excluded: 今回の取込から除外した行番号(Set) / corrected: 修正した行番号(Set) / planRows: 最終的な値(許可の鍵に使う)。
// hebelResidenceMapped: HEBEL属性の列を指定した取込か(trueのときだけ、行ごとの分類と集計を返す)。
// autoExcluded: excludedのうち、自動除外(原本でキャンセル)の行番号(Set)。行と件数に自動であることを示す(管理者は取り消せない)。
function validateImportPlan({eventId, event, records, existingHashes, excluded = new Set(), corrected = new Set(), planRows = [],
  hebelResidenceMapped = false, autoExcluded = new Set()}) {
  const dup = duplicateRows({eventId, records, existingHashes, excluded});
  const {existingDuplicateRows, csvDuplicateRows, rowsByEmail} = dup;
  const approvalKeys = approvalKeysOf({eventId, records, planRows, dup, excluded});
  const existingSet = new Set(existingDuplicateRows);
  const typed = Boolean(rolesFor(eventId, event));

  const rows = records.map((record) => {
    const findings = record.issues.map((issue) => ({
      code: issue.code, severity: issue.severity === "error" ? RESULT.ERROR : RESULT.WARNING,
      ...(issue.programId ? {programId: issue.programId} : {}),
    }));
    for (const notice of record.notices || []) {
      if (NOTICE_SEVERITY[notice.code]) {
        findings.push({code: notice.code, severity: NOTICE_SEVERITY[notice.code], ...(notice.programId ? {programId: notice.programId} : {})});
      }
    }
    const isExcluded = excluded.has(record.sourceRowNumber);
    let others = [];
    if (record.participant && !isExcluded) {
      others = rowsByEmail.get(record.participant.email).filter((n) => n !== record.sourceRowNumber);
      if (others.length > 0) findings.push({code: CSV_DUPLICATE, severity: RESULT.WARNING});
      if (existingSet.has(record.sourceRowNumber)) findings.push({code: EXISTING_DUPLICATE, severity: RESULT.WARNING});
    }
    const type = typed && record.status !== "error" ? participationType(eventId, record.attendances, event) : null;
    if (typed && record.status !== "error" && type === null) findings.push({code: TYPE_UNDETERMINED, severity: RESULT.WARNING});
    // 行の判定: エラー > 警告(要確認) > 参考情報 > 正常。
    const result = findings.some((f) => f.severity === RESULT.ERROR) ? RESULT.ERROR
      : findings.some((f) => f.severity === RESULT.WARNING) ? RESULT.WARNING
      : findings.some((f) => f.severity === RESULT.INFO) ? RESULT.INFO : RESULT.OK;
    return {
      sourceRowNumber: record.sourceRowNumber, classification: record.status, result, findings,
      ...(isExcluded ? {excluded: true} : {}), ...(autoExcluded.has(record.sourceRowNumber) ? {autoExcluded: true} : {}),
      ...(corrected.has(record.sourceRowNumber) ? {corrected: true} : {}),
      programIds: record.attendances.map((a) => a.programId),
      ...(typed ? {participationType: type} : {}),
      ...(hebelResidenceMapped ? {hebelResidence: hebelCategoryOf(record)} : {}),
      ...(others.length > 0 ? {duplicateRows: others} : {}),
      ...(approvalKeys.has(record.sourceRowNumber) ? {approvalKeys: approvalKeys.get(record.sourceRowNumber)} : {}),
    };
  });

  // 件数(正常・警告・エラー・参考情報・項目別)は、今回の取込から除外していない行だけで数える。除外した行は別に数える。
  const counts = {okCount: 0, warningCount: 0, errorCount: 0, infoCount: 0};
  const findingCounts = {};
  for (const row of rows) {
    if (row.excluded) continue;
    counts[`${row.result}Count`] += 1;
    // 項目別の件数は「その問題を持つ行の数」(1行に同じ問題が複数programであっても1件)。
    for (const code of new Set(row.findings.map((f) => f.code))) findingCounts[code] = (findingCounts[code] || 0) + 1;
  }
  return {
    totalRows: rows.length, ...counts, findingCounts,
    existingEmailDuplicateCount: existingDuplicateRows.length,
    csvEmailDuplicateCount: csvDuplicateRows.length,
    existingDuplicateRows, csvDuplicateRows,
    ...pendingRows({records, excluded}),
    excludedRowCount: rows.filter((r) => r.excluded).length,
    // 自動除外(原本でキャンセル)。自動除外のある取込だけ返す(無い取込の応答は従来と同じ)。
    ...(autoExcluded.size > 0 ? {autoExcludedRowCount: autoExcluded.size, autoExcludedRows: [...autoExcluded].sort((a, b) => a - b)} : {}),
    correctedRowCount: rows.filter((r) => r.corrected).length,
    importRowCount: rows.filter((r) => !r.excluded).length,
    ...(typed ? {participationTypes: typeSummary(eventId, records.filter((r) => !excluded.has(r.sourceRowNumber)), event)} : {}),
    // 分類別の件数は、今回の取込から除外していない行だけで数える(未設定=空欄、未知=確認が必要)。
    ...(hebelResidenceMapped ? {
      hebelResidenceSummary: hebelResidenceSummary(rows.filter((r) => !r.excluded).map((r) => r.hebelResidence)),
    } : {}),
    rows,
  };
}

// 計画の行のHEBEL属性の分類。計画が分類を持たない行(内部エラーの行)は判定できていないため「未知」として見せる。
function hebelCategoryOf(record) {
  return record.hebelResidence ? record.hebelResidence.category : HEBEL_RESIDENCE.UNKNOWN;
}

// 新しい取込回が作る参加者のメール(ハッシュ)。取込回へ保存し、取込中に別の取込が同じメールを作らないかの確認に使う。
// items: import_commit.js の resolveRecords の結果。
function createdEmailHashes(eventId, items) {
  return [...new Set(items.filter((item) => item.result === "created" && item.record.participant)
    .map((item) => emailHash(eventId, item.record.participant.email)))].sort();
}

module.exports = {
  RESULT, APPROVAL, EXISTING_DUPLICATE, CSV_DUPLICATE, TYPE_UNDETERMINED, IGNORED_COUNT,
  emailHash, approvalKeysOf, existingEmailHashes, duplicateRows, pendingRows, contentHash, fingerprintOf, validateImportPlan, createdEmailHashes,
};
