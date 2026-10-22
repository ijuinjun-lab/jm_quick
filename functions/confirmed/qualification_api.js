const {ApiError} = require("./api_error");
const {isValidParticipantId, isValidProgramId, programAttendanceId} = require("../programs");
const {isConfirmedFlow} = require("../flow");

// Event manager only (index.js). Revocation is distinct from cancelling check-in.
// Keep the QR, attendance counts and history; never resurrect via an import.
function createQualificationApi({getDb, serverTimestamp}) {
  async function revoke({identity, data}) {
    if (!data || Object.keys(data).some((k) => !["eventId", "participantId", "programId", "reason"].includes(k)) ||
        typeof data.eventId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(data.eventId) ||
        !isValidParticipantId(data.participantId) || !isValidProgramId(data.programId) ||
        typeof data.reason !== "string" || !data.reason.trim() || data.reason.length > 200) {
      throw new ApiError("invalid-argument", "取消理由と対象を確認してください。");
    }
    const db = getDb();
    const eventRef = db.collection("events").doc(data.eventId);
    const pRef = db.collection("participants").doc(data.participantId);
    const aRef = db.collection("programAttendances").doc(programAttendanceId(data.participantId, data.programId));
    return db.runTransaction(async (tx) => {
      const [es, ps, as] = await tx.getAll(eventRef, pRef, aRef);
      if (!es.exists || !isConfirmedFlow(es.data()) || !ps.exists || !as.exists ||
          ps.data().eventId !== data.eventId || as.data().eventId !== data.eventId) throw new ApiError("not-found", "参加資格が見つかりません。");
      if (es.data().activeImportBatch) throw new ApiError("failed-precondition", "取込完了後に再実行してください。", {code: "import-in-progress"});
      const a = as.data();
      if (a.entitlementStatus === "revoked") return {changed: false};
      const sequence = (Number.isInteger(a.historySequence) ? a.historySequence : a.checkedIn ? 1 : 0) + 1;
      tx.update(aRef, {entitlementStatus: "revoked", historySequence: sequence, updatedAt: serverTimestamp()});
      tx.create(aRef.collection("history").doc(`qualification-revoked-${sequence}`), {
        action: "qualification-revoked", sequence, eventId: data.eventId, participantId: data.participantId, programId: data.programId,
        before: {entitlementStatus: "active"}, after: {entitlementStatus: "revoked"}, reason: data.reason.trim(),
        changedBy: identity.uid, changedAt: serverTimestamp(),
      });
      // Serialize against import allocation and invalidate any previously reviewed identity inventory.
      tx.update(eventRef, {qualificationRevision: (es.data().qualificationRevision || 0) + 1});
      return {changed: true};
    });
  }
  return {revoke};
}
module.exports = {createQualificationApi};
