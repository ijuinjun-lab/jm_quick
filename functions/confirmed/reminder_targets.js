// 前日リマインドの送信対象(イベント全体)。サーバーがFirestoreの正本から計算する。Flutterは対象人数を計算しない。
//
// ■ 対象 = イベントの全participantのうち、次をすべて満たすもの:
//     eventId が対象イベント / schemaVersion == 2(confirmed方式) / status == active /
//     importBatchId があるなら、そのbatchが committed で、同じイベントのもの
// ■ どの取込回(第1回・第2回…)から登録されたかは、対象の判定に使わない。committedなbatchの有効な参加者を、イベント横断ですべて集める。
// ■ 人物単位の重複排除はしない。同じメールアドレス・同じ氏名・同じ参照コードのparticipantも、participantの数だけ対象にする(欠落を作らない)。
// ■ 対象外(cancelled等の有効でない参加者、committing/failedのbatch由来)は、理由別に件数だけ数える。

const PARTICIPANT_SCHEMA_VERSION = 2;
const EXCLUDED = Object.freeze({
  NOT_CONFIRMED: "not-confirmed",
  INACTIVE: "inactive",
  BATCH_INVALID: "batch-invalid",
  BATCH_NOT_COMMITTED: "batch-not-committed",
});

// 戻り値: {targets: [participantId昇順], excludedByReason: {理由: 件数}, excludedCount, totalParticipants}
async function collectReminderTargets(db, eventId) {
  const participants = (await db.collection("participants").where("eventId", "==", eventId).get()).docs;
  const batchIds = [];
  for (const doc of participants) {
    const id = doc.data().importBatchId;
    if (typeof id === "string" && !batchIds.includes(id)) batchIds.push(id);
  }
  const committed = new Map();
  if (batchIds.length > 0) {
    const batches = await db.getAll(...batchIds.map((id) => db.collection("importBatches").doc(id)));
    batches.forEach((snapshot, index) => {
      const data = snapshot.exists ? snapshot.data() : null;
      committed.set(batchIds[index], Boolean(data) && data.eventId === eventId && data.status === "committed");
    });
  }
  const targets = [];
  const excludedByReason = {};
  const exclude = (reason) => { excludedByReason[reason] = (excludedByReason[reason] || 0) + 1; };
  for (const doc of participants) {
    const p = doc.data();
    if (p.schemaVersion !== PARTICIPANT_SCHEMA_VERSION) { exclude(EXCLUDED.NOT_CONFIRMED); continue; }
    if (p.status !== "active") { exclude(EXCLUDED.INACTIVE); continue; }
    if (p.importBatchId !== undefined && p.importBatchId !== null) {
      if (typeof p.importBatchId !== "string") { exclude(EXCLUDED.BATCH_INVALID); continue; }
      // committing / failed のbatch由来は対象にしない(Phase 5の境界)
      if (committed.get(p.importBatchId) !== true) { exclude(EXCLUDED.BATCH_NOT_COMMITTED); continue; }
    }
    targets.push(doc.id);
  }
  targets.sort();
  const excludedCount = participants.length - targets.length;
  return {targets, excludedByReason, excludedCount, totalParticipants: participants.length};
}

module.exports = {PARTICIPANT_SCHEMA_VERSION, EXCLUDED, collectReminderTargets};
