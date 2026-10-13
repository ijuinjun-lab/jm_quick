// 前日リマインドの送信対象(イベント全体)。サーバーがFirestoreの正本から計算する。Flutterは対象人数を計算しない。
//
// ■ collectReminderTargets(既存。当選メールのプレビュー対象選択 winner_mail_api.js も使う。出力は変えない):
//   イベントの全participantのうち、次をすべて満たすもの:
//     eventId が対象イベント / schemaVersion == 2(confirmed方式) / status == active /
//     importBatchId があるなら、そのbatchが committed で、同じイベントのもの
//   どの取込回(第1回・第2回…)から登録されたかは、対象の判定に使わない。人物単位の重複排除はしない。
//   対象外(cancelled等の有効でない参加者、committing/failedのbatch由来)は、理由別に件数だけ数える。
//
// ■ collectReminderRecipients(前日リマインド専用。手動開始・自動作成・設定画面・プレビューの共通の入口):
//   上の条件を満たす参加者について、さらに当選メールの配送記録(mailDeliveries/{participantId}_winner)を照合する。
//     sent → 送信対象 / unknown → 要確認(送信対象にせず、未解決の間はジョブを作らない。sentとみなさない)/
//     pending・sending・failed・配送記録なし → 送信対象外(理由別に数える)
//   通常当選・繰り上げ当選は区別せず同じ対象(当選種別は取込回の notificationType。表示・件数用)。
//   メールアドレスの重複は、統合・削除せずに分類する(送信は参加者ごとに1通のまま):
//     shared-address(別の氏名。家族等の共有と推定)/ different-programs(同じ氏名・別のprogram)/
//     undetermined(氏名が空、または同じ氏名・同じprogramで時間帯だけ違う。推測で確定しない)/
//     suspected-duplicate(同じ氏名・同じprogram・同じ時間帯。重複登録の疑い。未解決の間はジョブを作らない)
//   照合値(fingerprint): 全参加者の 参加者ID・当選メールの状態・メールアドレス・氏名・当選種別・program・時間帯・予定人数 から作る
//   sha256(値そのものは含まない)。確認時とジョブ作成時で比べ、違えば古い確認で送らない。

const crypto = require("node:crypto");
const {normalizePrograms, programTimeText} = require("./mail_view_model");
const {notificationTypeOf} = require("./notification_type");

const PARTICIPANT_SCHEMA_VERSION = 2;
const EXCLUDED = Object.freeze({
  NOT_CONFIRMED: "not-confirmed",
  INACTIVE: "inactive",
  BATCH_INVALID: "batch-invalid",
  BATCH_NOT_COMMITTED: "batch-not-committed",
  // 以下は collectReminderRecipients だけ(当選メールの配送記録による対象外)
  WINNER_NOT_SENT: "winner-mail-not-sent",
  WINNER_FAILED: "winner-mail-failed",
  WINNER_UNKNOWN: "winner-mail-unknown",
});
const WINNER_STATUS = Object.freeze({SENT: "sent", UNKNOWN: "unknown", FAILED: "failed", PENDING: "pending", SENDING: "sending", NONE: "none"});
const DUPLICATE = Object.freeze({
  NONE: "none",
  SHARED: "shared-address",
  DIFFERENT_PROGRAMS: "different-programs",
  UNDETERMINED: "undetermined",
  SUSPECTED: "suspected-duplicate",
});
// 1人の分類は、その人を含む組のうち最も注意の要るもの
const DUPLICATE_RANK = {[DUPLICATE.NONE]: 0, [DUPLICATE.SHARED]: 1, [DUPLICATE.DIFFERENT_PROGRAMS]: 2, [DUPLICATE.UNDETERMINED]: 3, [DUPLICATE.SUSPECTED]: 4};
const GET_ALL_CHUNK = 300;

// 1人の参加者が条件を満たすか。満たさなければ理由(EXCLUDED)。batchCommitted(id)は取込回が確定済みで同じイベントか。
// loadEligible(イベント全体)と isReminderTarget(1人)の共通の判定(条件を二重に持たない)。
function ineligibleReason(p, batchCommitted) {
  if (p.schemaVersion !== PARTICIPANT_SCHEMA_VERSION) return EXCLUDED.NOT_CONFIRMED;
  if (p.status !== "active") return EXCLUDED.INACTIVE;
  if (p.importBatchId !== undefined && p.importBatchId !== null) {
    if (typeof p.importBatchId !== "string") return EXCLUDED.BATCH_INVALID;
    // committing / failed のbatch由来は対象にしない(Phase 5の境界)
    if (!batchCommitted(p.importBatchId)) return EXCLUDED.BATCH_NOT_COMMITTED;
  }
  return null;
}

// 参加者・取込回を読み、受付・参加証と同じ条件で振り分ける(共通の読み取り)。
async function loadEligible(db, eventId) {
  const participants = (await db.collection("participants").where("eventId", "==", eventId).get()).docs;
  const batchIds = [];
  for (const doc of participants) {
    const id = doc.data().importBatchId;
    if (typeof id === "string" && !batchIds.includes(id)) batchIds.push(id);
  }
  const batches = new Map();
  if (batchIds.length > 0) {
    const snaps = await db.getAll(...batchIds.map((id) => db.collection("importBatches").doc(id)));
    snaps.forEach((snapshot, index) => batches.set(batchIds[index], snapshot.exists ? snapshot.data() : null));
  }
  const committed = (id) => {
    const data = batches.get(id);
    return Boolean(data) && data.eventId === eventId && data.status === "committed";
  };
  const eligible = [];
  const excludedByReason = {};
  const exclude = (reason) => { excludedByReason[reason] = (excludedByReason[reason] || 0) + 1; };
  for (const doc of participants) {
    const reason = ineligibleReason(doc.data(), committed);
    if (reason) { exclude(reason); continue; }
    eligible.push(doc);
  }
  eligible.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return {participants, batches, eligible, excludedByReason};
}

// 戻り値: {targets: [participantId昇順], excludedByReason: {理由: 件数}, excludedCount, totalParticipants}
async function collectReminderTargets(db, eventId) {
  const {participants, eligible, excludedByReason} = await loadEligible(db, eventId);
  const targets = eligible.map((doc) => doc.id);
  return {targets, excludedByReason, excludedCount: participants.length - targets.length, totalParticipants: participants.length};
}

const normalizedText = (value) => (typeof value === "string" ? value.normalize("NFKC").replace(/\s+/g, "").toLowerCase() : "");
const normalizedEmail = (value) => (typeof value === "string" ? value.trim().toLowerCase() : "");

// 同じメールアドレスの2人の関係
function pairKind(a, b) {
  if (!a.nameKey || !b.nameKey) return DUPLICATE.UNDETERMINED;
  if (a.nameKey !== b.nameKey) return DUPLICATE.SHARED;
  const slots = new Set(a.programs.map((p) => `${p.programId}\n${normalizedText(p.timeText)}`));
  if (b.programs.some((p) => slots.has(`${p.programId}\n${normalizedText(p.timeText)}`))) return DUPLICATE.SUSPECTED;
  const programIds = new Set(a.programs.map((p) => p.programId));
  if (b.programs.some((p) => programIds.has(p.programId))) return DUPLICATE.UNDETERMINED;
  return DUPLICATE.DIFFERENT_PROGRAMS;
}

// 戻り値: collectReminderTargets と同じ項目(targetsは当選メール送信済みの参加者だけ)に加えて、
//   recipients: [{participantId, name, email, notificationType, programs:[{programId, name, timeText, plannedCount}],
//                 winnerStatus, target, excludedReason, duplicate, duplicateGroupSize}](participantId昇順。対象外も含む)
//   counts: {normal, waitlistPromotion}(送信対象のうち)/ blocked: {unknownWinnerMail, suspectedDuplicates} / fingerprint
async function collectReminderRecipients(db, eventId, {event} = {}) {
  const loadedEvent = event || (await db.collection("events").doc(eventId).get()).data() || {};
  const {participants, batches, eligible, excludedByReason} = await loadEligible(db, eventId);
  const deliveryRefs = eligible.map((doc) => db.collection("mailDeliveries").doc(`${doc.id}_winner`));
  const deliveries = [];
  for (let i = 0; i < deliveryRefs.length; i += GET_ALL_CHUNK) {
    const chunk = deliveryRefs.slice(i, i + GET_ALL_CHUNK);
    if (chunk.length > 0) deliveries.push(...(await db.getAll(...chunk)));
  }
  const eligibleIds = new Set(eligible.map((doc) => doc.id));
  const attendancesBy = new Map();
  if (eligible.length > 0) {
    for (const doc of (await db.collection("programAttendances").where("eventId", "==", eventId).get()).docs) {
      const a = doc.data();
      if (!eligibleIds.has(a.participantId)) continue;
      if (!attendancesBy.has(a.participantId)) attendancesBy.set(a.participantId, []);
      attendancesBy.get(a.participantId).push(a);
    }
  }
  const programs = normalizePrograms(loadedEvent.programs);
  const programById = new Map(programs.map((p) => [p.programId, p]));

  const recipients = eligible.map((doc, index) => {
    const p = doc.data();
    const delivery = deliveries[index] && deliveries[index].exists ? deliveries[index].data() : null;
    const status = delivery && Object.values(WINNER_STATUS).includes(delivery.status) ? delivery.status : WINNER_STATUS.NONE;
    const batch = typeof p.importBatchId === "string" ? batches.get(p.importBatchId) : null;
    const entries = (attendancesBy.get(doc.id) || [])
      .map((a) => {
        const program = programById.get(a.programId) || {};
        return {
          programId: a.programId, name: program.name || a.programId, order: Number.isInteger(program.order) ? program.order : 9999,
          timeText: programTimeText(a, program) || null, plannedCount: Number.isInteger(a.plannedCount) ? a.plannedCount : null,
        };
      })
      .sort((a, b) => (a.order - b.order) || (a.programId < b.programId ? -1 : a.programId > b.programId ? 1 : 0))
      .map(({order, ...rest}) => rest);
    const excludedReason = status === WINNER_STATUS.SENT ? null :
      status === WINNER_STATUS.UNKNOWN ? EXCLUDED.WINNER_UNKNOWN :
        status === WINNER_STATUS.FAILED ? EXCLUDED.WINNER_FAILED : EXCLUDED.WINNER_NOT_SENT;
    return {
      participantId: doc.id, name: typeof p.name === "string" ? p.name : "", email: typeof p.email === "string" ? p.email : "",
      notificationType: notificationTypeOf(batch), programs: entries, winnerStatus: status,
      target: status === WINNER_STATUS.SENT, excludedReason, duplicate: DUPLICATE.NONE, duplicateGroupSize: 1,
      emailKey: normalizedEmail(p.email), nameKey: normalizedText(p.name),
    };
  });

  // メールアドレスの重複: 送信しうる参加者(送信済み・結果不明)の中で分類する(統合・削除はしない)
  const groups = new Map();
  for (const r of recipients) {
    if (!r.emailKey || (r.winnerStatus !== WINNER_STATUS.SENT && r.winnerStatus !== WINNER_STATUS.UNKNOWN)) continue;
    if (!groups.has(r.emailKey)) groups.set(r.emailKey, []);
    groups.get(r.emailKey).push(r);
  }
  for (const group of groups.values()) {
    if (group.length < 2) continue;
    for (const r of group) {
      r.duplicateGroupSize = group.length;
      for (const other of group) {
        if (other === r) continue;
        const kind = pairKind(r, other);
        if (DUPLICATE_RANK[kind] > DUPLICATE_RANK[r.duplicate]) r.duplicate = kind;
      }
    }
  }

  const merged = {...excludedByReason};
  for (const r of recipients) if (r.excludedReason) merged[r.excludedReason] = (merged[r.excludedReason] || 0) + 1;
  const targets = recipients.filter((r) => r.target).map((r) => r.participantId);
  const counts = {normal: 0, waitlistPromotion: 0};
  for (const r of recipients) if (r.target) counts[r.notificationType === "waitlistPromotion" ? "waitlistPromotion" : "normal"] += 1;
  const blocked = {
    unknownWinnerMail: recipients.filter((r) => r.winnerStatus === WINNER_STATUS.UNKNOWN).length,
    suspectedDuplicates: recipients.filter((r) => r.target && r.duplicate === DUPLICATE.SUSPECTED).length,
  };
  // 照合値: 送信内容・宛先に関わる値すべて(個人情報そのものは含めず、ハッシュだけ)
  const fingerprint = crypto.createHash("sha256").update(JSON.stringify(recipients.map((r) => [
    r.participantId, r.winnerStatus, r.emailKey, r.nameKey, r.name, r.notificationType,
    r.programs.map((x) => [x.programId, x.timeText, x.plannedCount]),
  ]))).digest("hex");
  return {
    targets, excludedByReason: merged, excludedCount: participants.length - targets.length, totalParticipants: participants.length,
    recipients: recipients.map(({emailKey, nameKey, ...rest}) => rest), counts, blocked, fingerprint,
  };
}

// 1人の参加者が前日リマインドの送信対象か(プレビュー用。collectReminderRecipients の target と同じ条件:
// 有効な参加者で、当選メールが送信済み)。イベント全体を読まない(参加者・取込回・当選メールの配送記録の3件だけ)。
// 送信の可否(結果不明・重複登録の疑い・照合値)は、ジョブ作成時に collectReminderRecipients がイベント全体で判定する。
async function isReminderTarget(db, eventId, participantId) {
  const snapshot = await db.collection("participants").doc(participantId).get();
  const p = snapshot.exists ? snapshot.data() : null;
  if (!p || p.eventId !== eventId) return {target: false, participant: null};
  let batch = null;
  if (typeof p.importBatchId === "string") {
    const b = await db.collection("importBatches").doc(p.importBatchId).get();
    batch = b.exists ? b.data() : null;
  }
  const committed = () => Boolean(batch) && batch.eventId === eventId && batch.status === "committed";
  if (ineligibleReason(p, committed)) return {target: false, participant: p};
  const delivery = await db.collection("mailDeliveries").doc(`${participantId}_winner`).get();
  return {target: delivery.exists && delivery.data().status === WINNER_STATUS.SENT, participant: p};
}

module.exports = {PARTICIPANT_SCHEMA_VERSION, EXCLUDED, WINNER_STATUS, DUPLICATE, collectReminderTargets, collectReminderRecipients, isReminderTarget};
