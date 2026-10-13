// 新方式(flow=confirmed)イベントの「イベント設定」(基本情報の確認・修正)。getSettings / updateSettings。
// 認可(対象イベントのevent_manager以上=システム管理者・そのイベントのイベント管理者)は index.js の confirmedEventCallable が済ませている。
//
// ■ 編集できるのは基本情報の6フィールドだけ: eventName / startAt / endAt / venue / venueInfo.address / venueInfo.access。
//   eventId・flow・programs・参加者・受付記録・送信履歴・テンプレート・reminder設定には触れない(書くのは対象のeventドキュメントと履歴だけ)。
//   入力の検証は作成API(event_create_api.js)と同じ関数・同じ上限を使う。住所・アクセスは当選メール設定と同じ validateVenueInfo。
// ■ 同時更新: 変更する各フィールドについて、クライアントが読み込んだ時点の値(expected)を送り、transactionの中で現在値と照合する。
//   違えば何も書かずに拒否する(後から保存した人が、他の人の変更を気付かずに上書きしない。当選メール設定で住所が変わった場合も検出する)。
// ■ 変更履歴: events/{eventId}/settingsHistory/settings-{連番} に、変更したフィールドの変更前・変更後・操作者UID・サーバー時刻・
//   その時点の送信済みメール件数を追記する(追記のみ。クライアントからは読み書きできない=Rulesのdefault deny)。
// ■ 送信済みメール: 取得時に、このイベントの送信ジョブの送信済み・結果不明の件数を返す(画面の警告用)。メールの再送・変更通知はしない。
// ■ 終了日時は追加・変更できるが、消すことはできない(欠席判定の根拠を失わないため)。開始日時の過去チェックはしない(終了後の訂正を許す)。

const {ApiError} = require("./api_error");
const {validateVenueInfo} = require("./winner_mail_template");
const {keysOf, text, date, LIMITS} = require("./event_create_api");

const SETTINGS_FIELDS = Object.freeze(["eventName", "startAt", "endAt", "venue", "address", "access"]);
const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const invalid = (code, extra) => new ApiError("invalid-argument", `リクエストが不正です: ${code}`, {code, ...extra});

const isoOf = (value) => {
  const d = value && typeof value.toDate === "function" ? value.toDate() : value instanceof Date ? value : null;
  return d && !Number.isNaN(d.getTime()) ? d.toISOString() : null;
};
const textOrNull = (value) => (typeof value === "string" && value.trim() !== "" ? value : null);

// 保存されている基本情報(比較・表示用の正規化した形)。日時はISO(UTC)。
function settingsOf(event) {
  return {
    eventName: typeof event.eventName === "string" ? event.eventName : "",
    startAt: isoOf(event.startAt),
    endAt: isoOf(event.endAt),
    venue: typeof event.venue === "string" ? event.venue : "",
    address: textOrNull(event.venueInfo && event.venueInfo.address),
    access: textOrNull(event.venueInfo && event.venueInfo.access),
  };
}

// 比較用: 日時はISOへ、空文字はnullへ(同じ値の別表記で「変更あり」「競合」と誤判定しない)
function comparable(field, value) {
  if (value === undefined || value === null || value === "") return null;
  if (field === "startAt" || field === "endAt") {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? `invalid:${value}` : d.toISOString();
  }
  return typeof value === "string" ? value.trim() : value;
}

function eventIdOf(data) {
  if (typeof data.eventId !== "string" || !EVENT_ID_PATTERN.test(data.eventId)) throw invalid("invalid-event-id", {path: "eventId"});
  return data.eventId;
}

function confirmedEventOf(snapshot) {
  const event = snapshot.exists ? snapshot.data() : null;
  if (!event || event.flow !== "confirmed") throw new ApiError("failed-precondition", "新方式のイベントを確認できませんでした。");
  return event;
}

// このイベントの送信ジョブの、送信済み・結果不明の件数(当選メール・繰り上げ当選メール・前日リマインド)
function sentMailOf(jobsSnapshot) {
  let sentCount = 0;
  let unknownCount = 0;
  for (const doc of jobsSnapshot.docs) {
    const job = doc.data();
    sentCount += Number.isInteger(job.sentCount) ? job.sentCount : 0;
    unknownCount += Number.isInteger(job.unknownCount) ? job.unknownCount : 0;
  }
  return {sentCount, unknownCount, jobCount: jobsSnapshot.size};
}

// 入力: {eventId, changes: {field: 新しい値}, expected: {field: 読み込んだ時点の値}}。changesのキーは基本情報の6フィールドだけ。
function parseChanges(data) {
  keysOf(data, ["eventId", "changes", "expected"], "");
  keysOf(data.changes, SETTINGS_FIELDS, "changes");
  keysOf(data.expected, SETTINGS_FIELDS, "expected");
  const fields = Object.keys(data.changes);
  if (fields.length === 0) throw invalid("nothing-to-update", {path: "changes"});
  for (const field of fields) {
    if (!Object.prototype.hasOwnProperty.call(data.expected, field)) throw invalid("expected-required", {path: `expected.${field}`});
  }
  const value = {};
  for (const field of fields) {
    const raw = data.changes[field];
    if (field === "eventName") value.eventName = text(raw, {name: "changes.eventName", max: LIMITS.eventName, required: true});
    if (field === "venue") value.venue = text(raw, {name: "changes.venue", max: LIMITS.venue, required: true});
    if (field === "startAt" || field === "endAt") value[field] = date(raw, `changes.${field}`, {required: true});
  }
  if (fields.includes("address") || fields.includes("access")) {
    const venueInfo = validateVenueInfo({
      ...(fields.includes("address") ? {address: data.changes.address} : {}),
      ...(fields.includes("access") ? {access: data.changes.access} : {}),
    });
    if (!venueInfo.ok) throw invalid("invalid-venue-info", {errors: venueInfo.errors});
    for (const field of ["address", "access"]) if (fields.includes(field)) value[field] = venueInfo.value[field];
  }
  return {eventId: eventIdOf(data), fields, value, expected: data.expected};
}

function createEventSettingsApi({getDb, serverTimestamp, logger}) {
  const log = logger || console;
  const jobsOf = (db, eventId) => db.collection("sendJobs").where("eventId", "==", eventId);

  async function getSettings({data}) {
    keysOf(data, ["eventId"], "");
    const eventId = eventIdOf(data);
    const db = getDb();
    const [snapshot, jobs] = await Promise.all([db.collection("events").doc(eventId).get(), jobsOf(db, eventId).get()]);
    return {eventId, settings: settingsOf(confirmedEventOf(snapshot)), sentMail: sentMailOf(jobs)};
  }

  async function updateSettings({identity, data}) {
    const request = parseChanges(data);
    const db = getDb();
    const ref = db.collection("events").doc(request.eventId);
    const result = await db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref);
      const jobs = await tx.get(jobsOf(db, request.eventId));
      const event = confirmedEventOf(snapshot);
      const current = settingsOf(event);
      // 同時更新: 読み込んだ時点の値と現在値が違えば、何も書かずに拒否する
      const conflicted = request.fields.filter((f) => comparable(f, request.expected[f]) !== comparable(f, current[f]));
      if (conflicted.length > 0) {
        throw new ApiError("aborted", "ほかの操作でイベント設定が変更されています。最新の内容を読み込み直してから、もう一度保存してください。",
          {code: "event-settings-changed", fields: conflicted});
      }
      const next = {...current};
      for (const field of request.fields) {
        const v = request.value[field];
        next[field] = v instanceof Date ? v.toISOString() : v === undefined ? null : v;
      }
      const changed = request.fields.filter((f) => comparable(f, next[f]) !== comparable(f, current[f]));
      if (changed.length === 0) throw new ApiError("failed-precondition", "変更がありません。", {code: "no-change"});
      if (!next.startAt) throw invalid("required", {path: "startAt"});
      if (next.endAt && new Date(next.endAt).getTime() <= new Date(next.startAt).getTime()) throw invalid("invalid-time-range", {path: "endAt"});

      const sequence = (Number.isInteger(event.settingsHistorySequence) ? event.settingsHistorySequence : 0) + 1;
      const update = {settingsHistorySequence: sequence, updatedAt: serverTimestamp(), updatedBy: identity.uid};
      for (const field of changed) {
        if (field === "startAt" || field === "endAt") update[field] = new Date(next[field]);
        else if (field === "eventName" || field === "venue") update[field] = next[field];
      }
      if (changed.includes("address") || changed.includes("access")) {
        update.venueInfo = {...(event.venueInfo || {}), address: next.address, access: next.access};
      }
      tx.update(ref, update);
      tx.create(ref.collection("settingsHistory").doc(`settings-${sequence}`), {
        sequence, eventId: request.eventId, changedFields: changed,
        before: Object.fromEntries(changed.map((f) => [f, current[f]])),
        after: Object.fromEntries(changed.map((f) => [f, next[f]])),
        // 変更時点で送信済みのメールがあったか(送信済みメールは変更・再送しない)
        sentMailAtChange: sentMailOf(jobs),
        changedBy: identity.uid, changedAt: serverTimestamp(),
      });
      return {changed, sequence, settings: next};
    });
    log.info("confirmed event settings update", {eventId: request.eventId, fields: result.changed, sequence: result.sequence, uid: identity.uid});
    return {eventId: request.eventId, changed: true, changedFields: result.changed, sequence: result.sequence, settings: result.settings};
  }

  return {getSettings, updateSettings};
}

module.exports = {createEventSettingsApi, parseChanges, settingsOf, SETTINGS_FIELDS};
