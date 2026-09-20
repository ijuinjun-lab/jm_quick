// 新方式の当選者CSV取込: commitエンジン(Firestoreへ書く唯一の場所)。
// dbは呼び出し側(index.js)から渡される。このファイルはFirebaseのパッケージを読み込まない。
//
// ■ 欠落防止(最優先): 1CSVデータレコード = 1取込レコード(importRecordId) = 原則1participant。
//   - 人物の同一性(メール・氏名・参照コード・過去のbatch)は見ない。同じ人物の行もすべて別のparticipantになる。
//   - 一意にするのは「batchId + 行番号」だけ。participantIdはimportRecordId(再試行しても同じID)。
//   - reviewは、管理者が明示的に承認した行だけ登録する。errorは承認されても登録しない。
//   - 登録しない行(review未承認・error・operator除外)も、監査(rows)に必ず残る。
//   - 最後に、created + reviewPending + error + excluded (+ blank) が元CSVの全レコード数と一致することを
//     検証し、1件でも合わなければbatchをcommittedにせず失敗させる。
//
// ■ 原子性: 巨大な1トランザクションにはしない。
//   1. batchを status=committing で作成(採番とバッチ作成は1トランザクション)
//   2. 各行を「参加者・programAttendances・監査行」の1トランザクションで、決定的IDにより冪等に書く
//   3. 全行を検証(保存則)
//   4. status=committed
//   途中で失敗しても部分状態は残り得るが、committedにならない限り送信対象にしない(status=failedのまま。
//   同じclientRequestIdで再実行すると、書き込み済みの行はそのまま、残りを続行する)。
// ■ 監査(rows)とレスポンスには、氏名・メール・かな・自由記述を一切入れない(個人情報の正本はparticipantsだけ)。
// ■ 人数の正本はprogramAttendancesのplannedCountのみ(旧参加者の人数フィールドは書かない・読まない)。
// ■ メールは一切送らない(送信はcommitted済みbatchを対象にする後続Phaseの責務)。

const {randomBytes} = require("node:crypto");
const {ApiError} = require("./api_error");
const {requestHash} = require("./import_request");
const {isConfirmedFlow} = require("../flow");

const BATCH_STATUS = Object.freeze({COMMITTING: "committing", COMMITTED: "committed", FAILED: "failed"});
const RESULT = Object.freeze({
  CREATED: "created", REVIEW_PENDING: "review-pending", ERROR: "error", EXCLUDED: "excluded", BLANK: "blank",
});
const DEFAULT_CONCURRENCY = 8;

const defaultPublicId = () => `pub_${randomBytes(24).toString("base64url")}`;
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});

// 管理者の判断(承認・除外)を、計画の各レコードへ適用して、行ごとの結果(result)を決める。
// システムが勝手にreviewをreadyにしたり、行を除外したりしない。
function resolveRecords(plan, request) {
  const byRow = new Map(plan.records.map((record) => [record.sourceRowNumber, record]));
  const approved = new Set(request.approvedReviewRows);
  const excluded = new Map(request.excludedRows.map((e) => [e.sourceRowNumber, e]));
  for (const row of approved) {
    const record = byRow.get(row);
    if (!record) throw invalid("approval-unknown-row", {sourceRowNumber: row});
    if (record.status === "error") throw invalid("error-row-cannot-be-approved", {sourceRowNumber: row});
    if (record.status !== "review") throw invalid("approval-not-review", {sourceRowNumber: row});
    if (excluded.has(row)) throw invalid("approval-and-exclusion-conflict", {sourceRowNumber: row});
  }
  for (const row of excluded.keys()) {
    if (!byRow.has(row)) throw invalid("exclusion-unknown-row", {sourceRowNumber: row});
  }
  return plan.records.map((record) => {
    const exclusion = excluded.get(record.sourceRowNumber);
    let result;
    if (exclusion) result = RESULT.EXCLUDED;
    else if (record.status === "error") result = RESULT.ERROR;
    else if (record.status === "ready") result = RESULT.CREATED;
    else result = approved.has(record.sourceRowNumber) ? RESULT.CREATED : RESULT.REVIEW_PENDING;
    if (result === RESULT.CREATED && !record.participant) {
      // ready/承認済みreviewには必ずparticipant候補がある(氏名・メールのerrorはerror)。無ければ計画の不整合。
      throw new ApiError("internal", "取込計画が不整合です。", {code: "created-without-participant"});
    }
    return {
      record, result, classification: record.status,
      approved: result === RESULT.CREATED && record.status === "review",
      exclusion: exclusion || null,
    };
  });
}

// 空レコードの監査用の項目(全レコードが必ず監査行を持つ)。
function blankItems(plan, batchId, importRecordId) {
  return plan.blankRecordNumbers.map((row) => ({
    record: {
      sourceRowNumber: row, importRecordId: importRecordId(batchId, row), issues: [], attendances: [],
      participantId: null, participant: null, status: "blank",
    },
    result: RESULT.BLANK, classification: "blank", approved: false, exclusion: null,
  }));
}

function countsOf(items) {
  const counts = {total: items.length, created: 0, reviewPending: 0, error: 0, excluded: 0, blank: 0};
  for (const {result} of items) {
    if (result === RESULT.CREATED) counts.created += 1;
    else if (result === RESULT.REVIEW_PENDING) counts.reviewPending += 1;
    else if (result === RESULT.ERROR) counts.error += 1;
    else if (result === RESULT.EXCLUDED) counts.excluded += 1;
    else counts.blank += 1;
  }
  return counts;
}

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

function createImportCommitter({serverTimestamp, generatePublicId = defaultPublicId, concurrency = DEFAULT_CONCURRENCY,
  importRecordId}) {
  const batchRefOf = (db, batchId) => db.collection("importBatches").doc(batchId);

  function rowDoc(item, uid) {
    const {record, result, exclusion} = item;
    return {
      sourceRowNumber: record.sourceRowNumber,
      importRecordId: record.importRecordId,
      classification: item.classification,
      result,
      participantId: result === RESULT.CREATED ? record.participantId : null,
      issueCodes: [...new Set(record.issues.map((issue) => issue.code))],
      programIds: record.attendances.map((a) => a.programId),
      approvedReview: item.approved,
      approvedBy: item.approved ? uid : null,
      approvedAt: item.approved ? serverTimestamp() : null,
      excludedByOperator: Boolean(exclusion),
      excludedBy: exclusion ? uid : null,
      excludedAt: exclusion ? serverTimestamp() : null,
      excludedReason: exclusion ? exclusion.reason : null,
      createdAt: serverTimestamp(),
    };
  }

  function participantDoc(item, {eventId, batchId}) {
    const {record} = item;
    const p = record.participant;
    return {
      participantId: record.participantId,
      eventId,
      publicId: generatePublicId(),
      name: p.name,
      kana: p.kana,
      email: p.email,
      sourceReference: p.sourceReference,
      sourceRegisteredAt: p.sourceRegisteredAt === null ? null : new Date(p.sourceRegisteredAt),
      schemaVersion: p.schemaVersion,
      status: p.status,
      registrationType: "winner",
      importBatchId: batchId,
      importRow: record.sourceRowNumber,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
  }

  function attendanceDoc(attendance, {eventId, batchId}) {
    return {
      eventId,
      participantId: attendance.participantId,
      programId: attendance.programId,
      plannedCount: attendance.plannedCount,
      slotLabel: attendance.slotLabel,
      startAt: attendance.startAt === null ? null : new Date(attendance.startAt),
      endAt: attendance.endAt === null ? null : new Date(attendance.endAt),
      checkedIn: false,
      checkedInAt: null,
      attendedCount: null,
      checkedInBy: null,
      importBatchId: batchId,
      updatedAt: serverTimestamp(),
    };
  }

  function verifyExistingRow(existing, item) {
    const expected = {
      importRecordId: item.record.importRecordId, classification: item.classification, result: item.result,
      participantId: item.result === RESULT.CREATED ? item.record.participantId : null,
      approvedReview: item.approved, excludedByOperator: Boolean(item.exclusion),
    };
    for (const [key, value] of Object.entries(expected)) {
      if (existing[key] !== value) {
        throw new ApiError("failed-precondition", "既存の取込結果と一致しません。", {code: "batch-row-conflict", sourceRowNumber: item.record.sourceRowNumber});
      }
    }
  }

  // 1行を「参加者・programAttendances・監査行」の1トランザクションで書く。
  // 既に監査行があれば(再試行)何もしない=participantも、publicIdも変わらない。
  async function writeRow(db, ctx, item) {
    const batchRef = batchRefOf(db, ctx.batchId);
    const rowRef = batchRef.collection("rows").doc(String(item.record.sourceRowNumber));
    await db.runTransaction(async (tx) => {
      const created = item.result === RESULT.CREATED;
      const participantRef = created ? db.collection("participants").doc(item.record.participantId) : null;
      const attendanceRefs = created
        ? item.record.attendances.map((a) => db.collection("programAttendances").doc(a.attendanceId)) : [];
      const [rowSnap, ...others] = await tx.getAll(rowRef, ...(created ? [participantRef, ...attendanceRefs] : []));
      if (rowSnap.exists) {
        verifyExistingRow(rowSnap.data(), item);
        return;
      }
      if (others.some((snap) => snap.exists)) {
        // 監査行が無いのに同じIDのデータがある=このbatchが書いたものではない。上書きせず失敗させる。
        throw new ApiError("failed-precondition", "取込先のIDに既存のデータがあります。", {code: "record-id-conflict", sourceRowNumber: item.record.sourceRowNumber});
      }
      if (created) {
        tx.create(participantRef, participantDoc(item, ctx));
        item.record.attendances.forEach((a, index) => tx.create(attendanceRefs[index], attendanceDoc(a, ctx)));
      }
      tx.create(rowRef, rowDoc(item, ctx.uid));
    });
  }

  async function loadResult(db, batchId) {
    const batchRef = batchRefOf(db, batchId);
    const [batchSnap, rowsSnap] = await Promise.all([batchRef.get(), batchRef.collection("rows").get()]);
    const b = batchSnap.data();
    const rows = rowsSnap.docs.map((doc) => {
      const r = doc.data();
      return {
        sourceRowNumber: r.sourceRowNumber, importRecordId: r.importRecordId, classification: r.classification,
        result: r.result, participantId: r.participantId, issueCodes: r.issueCodes, programIds: r.programIds,
        approvedReview: r.approvedReview, excludedByOperator: r.excludedByOperator,
      };
    }).sort((a, b2) => a.sourceRowNumber - b2.sourceRowNumber);
    return {
      batchId, eventId: b.eventId, sequence: b.sequence, label: b.label, status: b.status,
      totalRows: b.totalRows, createdCount: b.createdCount, reviewPendingCount: b.reviewPendingCount,
      errorCount: b.errorCount, excludedByOperatorCount: b.excludedByOperatorCount,
      blankRecordCount: b.blankRecordCount, totalRecords: b.totalRecords, rows,
    };
  }

  // 保存則の最終検証。行の監査・participant・programAttendancesが、期待どおり過不足なく存在すること。
  async function verifyConservation(db, ctx, items) {
    const batchRef = batchRefOf(db, ctx.batchId);
    const expected = countsOf(items);
    const rowsSnap = await batchRef.collection("rows").get();
    const actual = countsOf(rowsSnap.docs.map((doc) => ({result: doc.data().result})));
    const rowNumbers = new Set(rowsSnap.docs.map((doc) => doc.data().sourceRowNumber));
    const missing = items.filter((item) => !rowNumbers.has(item.record.sourceRowNumber)).length;
    const [participants, attendances] = await Promise.all([
      db.collection("participants").where("importBatchId", "==", ctx.batchId).count().get(),
      db.collection("programAttendances").where("importBatchId", "==", ctx.batchId).count().get(),
    ]);
    const expectedAttendances = items
      .filter((item) => item.result === RESULT.CREATED)
      .reduce((sum, item) => sum + item.record.attendances.length, 0);
    const sum = actual.created + actual.reviewPending + actual.error + actual.excluded;
    const problems = [];
    if (rowsSnap.size !== expected.total || missing > 0) problems.push("audit-rows-mismatch");
    if (sum !== ctx.totalRows || sum + actual.blank !== ctx.totalRecords) problems.push("conservation-mismatch");
    for (const key of Object.keys(expected)) if (expected[key] !== actual[key]) problems.push(`count-${key}`);
    if (participants.data().count !== expected.created) problems.push("participant-count-mismatch");
    if (attendances.data().count !== expectedAttendances) problems.push("attendance-count-mismatch");
    return {ok: problems.length === 0, problems, actual};
  }

  async function markFailed(db, batchId, reason) {
    try {
      await batchRefOf(db, batchId).update({status: BATCH_STATUS.FAILED, failureReason: reason, updatedAt: serverTimestamp()});
    } catch (secondary) {
      // 失敗の記録に失敗しても、元のエラーを優先する(statusはcommittingのまま=committedではない)。
    }
  }

  // request: parseImportRequest(commit)の結果 / plan: planImportBatchFromRows(...)の結果 / identity: {uid}
  async function commit({db, identity, request, plan}) {
    const {batchId, eventId} = request;
    const hash = requestHash(request);
    const items = [...resolveRecords(plan, request), ...blankItems(plan, batchId, importRecordId)]
      .sort((a, b) => a.record.sourceRowNumber - b.record.sourceRowNumber);
    const expected = countsOf(items);
    const batchRef = batchRefOf(db, batchId);
    const eventRef = db.collection("events").doc(eventId);

    // 1. batchの作成(または既存の再利用)。採番はeventのカウンタを同じトランザクションで進める。
    const started = await db.runTransaction(async (tx) => {
      const [batchSnap, eventSnap] = await tx.getAll(batchRef, eventRef);
      if (batchSnap.exists) {
        const existing = batchSnap.data();
        if (existing.eventId !== eventId || existing.requestHash !== hash) {
          throw new ApiError("already-exists", "同じclientRequestIdで、内容の異なる取込が既に存在します。", {code: "batch-content-mismatch"});
        }
        if (existing.status === BATCH_STATUS.FAILED) {
          tx.update(batchRef, {status: BATCH_STATUS.COMMITTING, failureReason: null, updatedAt: serverTimestamp()});
        }
        return {existing: true, status: existing.status, sequence: existing.sequence};
      }
      if (!eventSnap.exists) throw new ApiError("not-found", "イベントが見つかりません。");
      if (!isConfirmedFlow(eventSnap.data())) {
        throw new ApiError("failed-precondition", "このイベントは新方式(confirmed)ではありません。");
      }
      const sequence = (eventSnap.data().importSequence || 0) + 1;
      tx.update(eventRef, {importSequence: sequence});
      tx.create(batchRef, {
        eventId, sequence, label: request.label || `第${sequence}回`, sourceFileName: request.sourceFileName,
        fileHash: request.fileHash, mappingVersion: plan.batch.mappingVersion, requestHash: hash,
        totalRows: plan.batch.totalRows, totalRecords: plan.batch.totalRecords,
        blankRecordCount: plan.batch.blankRecordCount,
        createdCount: null, reviewPendingCount: null, errorCount: null, excludedByOperatorCount: null,
        expectedCounts: expected, mappingSnapshot: request.normalizedMapping,
        createdAt: serverTimestamp(), createdBy: identity.uid, status: BATCH_STATUS.COMMITTING,
      });
      return {existing: false, status: BATCH_STATUS.COMMITTING, sequence};
    });

    if (started.existing && started.status === BATCH_STATUS.COMMITTED) {
      // 応答が届かずに再送された場合: 既存の結果をそのまま返す(参加者は増えない)。
      return {...(await loadResult(db, batchId)), idempotentReplay: true};
    }

    const ctx = {batchId, eventId, uid: identity.uid, totalRows: plan.batch.totalRows, totalRecords: plan.batch.totalRecords};
    try {
      // 2. 各行を冪等に書く(既に書けた行は何もしない)。
      await runPool(items, concurrency, (item) => writeRow(db, ctx, item));
      // 3. 保存則の検証。1件でも合わなければcommittedにしない。
      const verification = await verifyConservation(db, ctx, items);
      if (!verification.ok) {
        await markFailed(db, batchId, "conservation-violated");
        throw new ApiError("data-loss", "取込結果が元のCSVの全行と一致しません。取込を完了させませんでした。",
          {code: "conservation-violated", problems: verification.problems});
      }
      // 4. committed。
      await db.runTransaction(async (tx) => {
        tx.update(batchRef, {
          status: BATCH_STATUS.COMMITTED, failureReason: null,
          createdCount: verification.actual.created, reviewPendingCount: verification.actual.reviewPending,
          errorCount: verification.actual.error, excludedByOperatorCount: verification.actual.excluded,
          completedAt: serverTimestamp(), updatedAt: serverTimestamp(),
        });
      });
    } catch (error) {
      if (error && error.isApiError === true) {
        if (error.code !== "data-loss") await markFailed(db, batchId, error.details && error.details.code ? error.details.code : "failed");
        throw error;
      }
      await markFailed(db, batchId, "interrupted");
      throw new ApiError("internal", "取込を最後まで完了できませんでした。同じclientRequestIdで再実行すると、続きから完了できます。",
        {code: "commit-interrupted"});
    }
    return {...(await loadResult(db, batchId)), idempotentReplay: false};
  }

  return {commit, loadResult};
}

module.exports = {BATCH_STATUS, RESULT, resolveRecords, createImportCommitter};
