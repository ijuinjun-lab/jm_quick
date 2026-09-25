// Phase 1B: イベント単位の認可で「どのイベントに対する操作か」をサーバー側で確定するresolver。
//
// confirmedEventCallable(auth.js)は、ハンドラより前に、ここに定義したresolverだけを使って対象eventIdを確定し、
// event_access.js(Firestoreの正本)で「このuidが、このeventIdに対して必要なrankを持つか」を判定する。
// 任意の関数をresolverとして渡すことはできない(auth.jsがこの一覧に含まれるかを確認する)。
//
// 戻り値(クライアントへ直接は返さない):
//   {kind: "event", eventId} … 対象イベントが確定した
//   {kind: "invalid"}        … 入力の形式が不正(eventId・jobIdが無い・形式が違う)
//   {kind: "unknown"}        … 形式は正しいが、正本(sendJobs等)が見つからない(存在の有無は呼び出し側へ区別して返さない)
//
// 信用しないもの: クライアントが名乗るrole・eventRole。jobId系では、クライアントが送るeventIdも使わない(送っても無視される。
// 各ハンドラは想定外のキーを拒否する)。対象のイベントは sendJobs/{jobId}.eventId(Admin SDKで読む正本)で決まる。
// participant・batch・attendanceが本当にそのイベントに属するかは、各ハンドラが正本で照合する(pass_api / winner_* / import_*)。

const {isValidEventId} = require("./event_access");

// sendJobsのID(当選メール: winner-{batchId} / 前日リマインド: reminder-{eventId})。文書パスを壊す文字は含めない。
const SEND_JOB_ID_PATTERN = /^[A-Za-z0-9_-]{1,200}$/;

const INVALID = Object.freeze({kind: "invalid"});
const UNKNOWN = Object.freeze({kind: "unknown"});
const isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

// data.eventId をそのまま対象にする(形式だけ確認)。そのイベントに属さないparticipant・batch等は、ハンドラが正本で拒否する。
async function dataEventId({data}) {
  if (!isPlainObject(data) || !isValidEventId(data.eventId)) return INVALID;
  return {kind: "event", eventId: data.eventId};
}

// data.jobId の送信ジョブを読み、その正本の eventId を対象にする。
async function sendJobEventId({data, db}) {
  if (!isPlainObject(data) || typeof data.jobId !== "string" || !SEND_JOB_ID_PATTERN.test(data.jobId)) return INVALID;
  const snapshot = await db.collection("sendJobs").doc(data.jobId).get();
  if (!snapshot.exists) return UNKNOWN;
  const job = snapshot.data() || {};
  return isValidEventId(job.eventId) ? {kind: "event", eventId: job.eventId} : UNKNOWN;
}

const EVENT_SCOPES = Object.freeze({dataEventId, sendJobEventId});

module.exports = {EVENT_SCOPES, SEND_JOB_ID_PATTERN};
