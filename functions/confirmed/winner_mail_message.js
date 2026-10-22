// 当選メールの「生成」の共通部品。プレビュー(previewConfirmedWinnerMail)と実送信(送信ジョブのprocessor)は、
// どちらもここの composeWinnerMailFor → renderWinnerMail を使う(プレビュー専用のレンダラーは存在しない)。
// participant・programAttendances・event(snapshot)は、必ずFirestoreの正本から読む(クライアントの入力は使わない)。
//
// 宛先メールアドレスは、送信の直前にparticipantの正本から取得してメモリ上でのみ使う。ジョブ・配送記録・ログへ複製しない。

const {qualification} = require("./application_identity");
const {renderWinnerMail, renderReminderMail} = require("./mail_render");

async function loadAttendances(db, participantId, eventId) {
  const snapshot = await db.collection("programAttendances").where("participantId", "==", participantId).get();
  // 取得順には依存しない(表示順はレンダラーがevent.programsのorderで決める)。別イベントの記録は含めない。
  const values = snapshot.docs.map((doc) => doc.data()).filter((data) => data.eventId === eventId && data.entitlementStatus !== "revoked");
  const batches = new Map();
  for (const a of values) if (a.identityVersion && a.importBatchId && !batches.has(a.importBatchId)) {
    const b = await db.collection("importBatches").doc(a.importBatchId).get();
    batches.set(a.importBatchId, b.exists && b.data().eventId === eventId && b.data().status === "committed");
  }
  return values.filter((a) => !a.identityVersion || batches.get(a.importBatchId) === true);
}

// 戻り値: renderWinnerMail の結果({ok:true,...} | {ok:false, problems})
async function composeWinnerMailFor({db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  return composeMailWith(renderWinnerMail, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng});
}

// 前日リマインド。participant・programAttendances・event・QRは当選メールと同じ正本・同じ関数(文章だけが別テンプレート)。
async function composeReminderMailFor({db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  if (snapshot.reminderFingerprint) {
    const {collectReminderRecipients} = require("./reminder_targets");
    const current = await collectReminderRecipients(db, snapshot.event.eventId, {participantId});
    const item = await db.collection("sendJobs").doc(`reminder-${snapshot.event.eventId}`).collection("items").doc(participantId).get();
    const approved = item.exists ? item.data().approvedSafetyFingerprint : null;
    const expected = approved || snapshot.recipientSafetyFingerprints?.[participantId];
    const actual = expected ? current.recipients[0]?.safetyFingerprint : current.recipients[0]?.fingerprint;
    if (actual !== (expected || snapshot.recipientFingerprints?.[participantId]) || !current.targets.includes(participantId)) return {ok: false, problems: ["reminder-state-changed"]};
  }
  return composeMailWith(renderReminderMail, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng});
}

async function composeMailWith(render, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  let attendances = await loadAttendances(db, participantId, snapshot.event.eventId);
  if (snapshot.grantBatchId && render === renderWinnerMail) {
    const grant = await db.collection("qualificationGrants").doc(`${snapshot.grantBatchId}-${participantId}`).get();
    if (!grant.exists || grant.data().eventId !== snapshot.event.eventId) return {ok: false, problems: ["grant-missing"]};
    const fixed = grant.data().attendances;
    if (!grant.data().initial && fixed.some((a) => !attendances.some((x) => JSON.stringify(qualification(a)) === JSON.stringify(qualification(x))))) {
      return {ok: false, problems: ["grant-changed"]};
    }
    attendances = grant.data().initial ? attendances.filter((a) => grant.data().programIds.includes(a.programId)) : fixed;
  }
  return render({
    snapshot,
    participant: {participantId, name: participant.name, publicId: participant.publicId, sourceRegisteredAt: participant.sourceRegisteredAt},
    attendances,
    appBaseUrl,
    generateQrPng,
  });
}

// mail-api(Cloud Run)へ渡す内容。toは呼び出し側が正本から取得したものを、この関数の引数として渡す(保存しない)。
function buildMailApiMessage({rendered, to, snapshot, participantId, jobId, type = "winner"}) {
  return {
    to,
    senderName: snapshot.event.senderName,
    subject: rendered.subject,
    text: rendered.text,
    html: rendered.html,
    attachments: rendered.attachments,
    metadata: {app: "jm-quick", type, participantId, jobId},
  };
}

module.exports = {loadAttendances, composeWinnerMailFor, composeReminderMailFor, buildMailApiMessage};
