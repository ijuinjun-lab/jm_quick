// Manager-only recovery. Persisted rows remain quarantined when a batch is abandoned.
const {ApiError} = require("./api_error");
const {digest, decodePlan} = require("./application_identity");
const invalid = (code) => new ApiError("failed-precondition", "取込回の状態を更新して、確認し直してください。", {code});
function createImportRecoveryApi({getDb, serverTimestamp}) {
  function parse(data, abandoning = false) {
    const allowed = abandoning ? ["eventId", "batchId", "reason", "expectedFingerprint"] : ["eventId"];
    if (!data || Object.keys(data).some((k) => !allowed.includes(k)) || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId || "")) throw invalid("invalid-request");
    if (abandoning && (!/^[A-Za-z0-9_-]{1,128}$/.test(data.batchId || "") || typeof data.reason !== "string" || !data.reason.trim() || data.reason.length > 200)) throw invalid("invalid-abandonment");
  }
  const rowView = (snap) => snap.docs.map((d) => {
    const r = d.data(); return {sourceRowNumber: r.sourceRowNumber, result: r.result, participantId: r.participantId || null, programIds: r.programIds || []};
  }).sort((a, b) => a.sourceRowNumber - b.sourceRowNumber);
  const fingerprint = (b, rows) => digest([b.status, b.requestHash, rows]);
  async function list({data}) {
    parse(data); const db = getDb();
    const snaps = await db.collection("importBatches").where("eventId", "==", data.eventId).get();
    const batches = [];
    for (const snap of snaps.docs) {
      const b = snap.data(); if (!["committing", "failed", "abandoned"].includes(b.status)) continue;
      const rows = rowView(await snap.ref.collection("rows").get());
      const persisted = new Set(rows.map((r) => r.sourceRowNumber));
      const pendingRows = b.identityPlan ? decodePlan(b.identityPlan).rows.map((r) => r.sourceRowNumber).filter((n) => !persisted.has(n)) : [];
      batches.push({pendingRows,batchId: snap.id, status: b.status, sequence: b.sequence, label: b.label || "", sourceFileName: b.sourceFileName || "",
        totalRecords: b.totalRecords, persistedCount: rows.length, pendingCount: Math.max(0, b.totalRecords - rows.length), rows,
        failureReason: b.failureReason || null, fingerprint: fingerprint(b, rows),
        abandonedReason: b.abandonedReason || null});
    }
    return {batches: batches.sort((a, b) => b.sequence - a.sequence)};
  }
  async function abandon({identity, data}) {
    parse(data, true); const db = getDb();
    const ref = db.collection("importBatches").doc(data.batchId), eventRef = db.collection("events").doc(data.eventId);
    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const event = await tx.get(eventRef);
      const rowsSnap = await tx.get(ref.collection("rows"));
      if (!snap.exists || snap.data().eventId !== data.eventId || !event.exists) throw invalid("batch-not-found");
      const b = snap.data();
      if (b.status === "abandoned") return {batchId: data.batchId, status: "abandoned", alreadyAbandoned: true};
      if (!["committing", "failed"].includes(b.status)) throw invalid("batch-not-abandonable");
      const rows = rowView(rowsSnap);
      if (fingerprint(b, rows) !== data.expectedFingerprint) throw invalid("import-state-changed");
      tx.update(ref, {status: "abandoned", abandonedReason: data.reason.trim(), abandonedBy: identity.uid,
        abandonedAt: serverTimestamp(), updatedAt: serverTimestamp(), persistedRowCount: rows.length});
      if (event.data().activeImportBatch === data.batchId) tx.update(eventRef, {activeImportBatch: null});
      return {batchId: data.batchId, status: "abandoned", persistedCount: rows.length};
    });
  }
  return {list, abandon};
}
module.exports = {createImportRecoveryApi};
