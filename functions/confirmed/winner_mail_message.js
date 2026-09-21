// 当選メールの「生成」の共通部品。プレビュー(previewConfirmedWinnerMail)と実送信(送信ジョブのprocessor)は、
// どちらもここの composeWinnerMailFor → renderWinnerMail を使う(プレビュー専用のレンダラーは存在しない)。
// participant・programAttendances・event(snapshot)は、必ずFirestoreの正本から読む(クライアントの入力は使わない)。
//
// 宛先メールアドレスは、送信の直前にparticipantの正本から取得してメモリ上でのみ使う。ジョブ・配送記録・ログへ複製しない。

const {renderWinnerMail, renderReminderMail} = require("./mail_render");

async function loadAttendances(db, participantId, eventId) {
  const snapshot = await db.collection("programAttendances").where("participantId", "==", participantId).get();
  // 取得順には依存しない(表示順はレンダラーがevent.programsのorderで決める)。別イベントの記録は含めない。
  return snapshot.docs.map((doc) => doc.data()).filter((data) => data.eventId === eventId);
}

// 戻り値: renderWinnerMail の結果({ok:true,...} | {ok:false, problems})
async function composeWinnerMailFor({db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  return composeMailWith(renderWinnerMail, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng});
}

// 前日リマインド。participant・programAttendances・event・QRは当選メールと同じ正本・同じ関数(文章だけが別テンプレート)。
async function composeReminderMailFor({db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  return composeMailWith(renderReminderMail, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng});
}

async function composeMailWith(render, {db, snapshot, participantId, participant, appBaseUrl, generateQrPng}) {
  const attendances = await loadAttendances(db, participantId, snapshot.event.eventId);
  return render({
    snapshot,
    participant: {participantId, name: participant.name, publicId: participant.publicId},
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
