// 前日リマインドの送信対象の安全確認(当選メール送信履歴との照合・メールアドレス重複・照合値・権限)を、
// ローカルのFirestore Emulator + 実際のFirebase Admin SDKで検証する。メールは偽のtransportだけ(実送信なし)。
// データはすべて架空(メールは予約TLD .invalid)。
//  - 当選メール: sent=対象 / unknown=要確認(手動・自動ともジョブを作らない) / pending・sending・failed・記録なし=対象外
//  - 通常当選・繰り上げ当選は同じ対象(件数は種別ごとに分かる)
//  - メール重複: 別の氏名(共有)・同じ氏名で別program・同じ氏名で同じprogramの別時間帯(判定不能)は送信を止めない。
//    同じ氏名・同じprogram・同じ時間帯(重複登録の疑い)はジョブを作らない。統合・削除はしない
//  - 照合値: 宛先の追加・削除、メールアドレス・program・時間・人数・当選メールの状態の変更を検出し、古い確認では作らない
//  - 宛先一覧(個人情報)は対象イベントのevent_manager以上だけ。手動開始は照合値が必須
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, NOT_ATTENDING} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {withValidatedCommit} = require("../test_support/validated_commit");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {createReminderApi} = require("../confirmed/reminder_api");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");
const {loadIndex} = require("../test_support/load_index");
const {assignmentDocId} = require("../event_access");

const silent = {warn: () => {}, info: () => {}};
const T0 = Date.parse("2026-11-29T01:00:00Z");
const errorCode = (promise) => promise.then(() => "ok", (e) => (e.details && e.details.code) || e.code);
const realFetch = globalThis.fetch;

describe("前日リマインドの送信対象の安全確認(Emulator)", {skip: skipReason()}, () => {
  let env;
  let db;
  let send;
  let reminder;
  let api;
  let sends;
  let nowMs;

  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const settings = () => api.settings(asAdmin({eventId: "event1"}));
  const jobExists = async () => (await db.doc("sendJobs/reminder-event1").get()).exists;
  const start = (fingerprint, extra = {}) => api.start(asAdmin({eventId: "event1", expectedTargetsFingerprint: fingerprint, dispatch: false, ...extra}));

  async function seedEvent() {
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場", contact: "架空事務局", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
      programs: [{programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}, {programId: "gamma", name: "トーク", order: 2}],
      winnerMailTemplate: {subject: "当選", introBody: "当選です。", closingBody: "以上", notesBody: null, version: 1, updatedBy: "u-admin"},
      reminderMailTemplate: {subject: "明日です", introBody: "明日です。", closingBody: "以上", notesBody: "すでに参加をキャンセルされた方には、本メールのご案内は適用されません。", version: 1, updatedBy: "u-admin"},
      reminderEnabled: true, reminderSendAt: env.Timestamp.fromMillis(T0),
    });
  }
  // 取込(当選者)。rowsは行ごとの上書き(氏名・メール・参加program等)。
  async function importRows(batchId, rows) {
    const table = makeTable(rows.length, (i) => ({"rd": `${batchId}-${i}`, ...rows[i - 1]}));
    const api = withValidatedCommit(createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()}));
    await api.commit({identity: {uid: "u-admin"}, data: {...buildImportRequest({table, clientRequestId: batchId}),
      acknowledgeExistingEmailDuplicates: true, acknowledgeCsvEmailDuplicates: true}});
    return (await db.collection("participants").where("importBatchId", "==", batchId).get()).docs.map((d) => d.id).sort();
  }
  const winner = (participantId, status) => db.collection("mailDeliveries").doc(`${participantId}_winner`).set({
    eventId: "event1", participantId, type: "winner", jobId: "winner-x", status,
  });
  const person = (n, extra = {}) => ({"氏名": `架空 参加者${n}`, "メールアドレス": `person${n}@example.invalid`, ...extra});
  const amOnly = (slot = "10:00-11:00") => ({"午前参加時間": slot, "午前参加人数": "2", "トークショー": NOT_ATTENDING, "トークショー人数": ""});
  const pmOnly = (slot = "14:00-15:00") => ({"午前参加時間": NOT_ATTENDING, "午前参加人数": "", "午後参加時間": slot, "午後参加人数": "1",
    "トークショー": NOT_ATTENDING, "トークショー人数": ""});

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await seedEvent();
    sends = [];
    nowMs = T0 - 3600 * 1000;
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const transport = {async capabilities() { return {ok: true, missing: []}; }, async send(m) { sends.push(m); return {outcome: "sent", messageId: "m"}; }};
    send = createWinnerSendApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => "https://app.invalid", getTransport: () => transport,
      engineOptions: {now: () => nowMs, leaseMs: 60000, concurrency: 5}});
    reminder = createReminderApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => "https://app.invalid", winnerSendApi: send, now: () => nowMs, logger: silent});
    const wrap = (handler) => { const callable = confirmedCallable("admin", handler, {db, logger: silent}); return (request) => callable.run(request); };
    api = {settings: wrap(reminder.getSettings), start: wrap(reminder.startDelivery), preview: wrap(reminder.preview)};
    globalThis.fetch = async (url, init) => {
      if (String(url).startsWith(env.origin)) return realFetch(url, init);
      throw new Error(`unexpected outbound request blocked by test: ${url}`);
    };
  });

  test("当選メールの状態: sentだけ対象。pending・sending・failed・記録なしは対象外(理由別)。通常当選・繰り上げ当選を統合して数える", async () => {
    const normal = await importRows("batchN", [person(1), person(2), person(3), person(4), person(5), person(6)]);
    const waitlist = await importRows("batchW", [person(7, pmOnly()), person(8, pmOnly())]);
    await db.doc("importBatches/batchW").update({notificationType: "waitlistPromotion"});
    await winner(normal[0], "sent");
    await winner(normal[1], "sent");
    await winner(normal[2], "pending");
    await winner(normal[3], "sending");
    await winner(normal[4], "failed");
    // normal[5]: 配送記録なし
    for (const id of waitlist) await winner(id, "sent");
    const s = await settings();
    assert.equal(s.targets.targetCount, 4);
    assert.deepEqual(s.targets.countsByNotificationType, {normal: 2, waitlistPromotion: 2});
    assert.deepEqual(s.targets.blocked, {unknownWinnerMail: 0, suspectedDuplicates: 0});
    assert.equal(s.targets.excludedByReason["winner-mail-not-sent"], 3, "pending・sending・記録なし");
    assert.equal(s.targets.excludedByReason["winner-mail-failed"], 1);
    const byId = Object.fromEntries(s.recipients.map((r) => [r.participantId, r]));
    assert.deepEqual([normal[2], normal[3], normal[4], normal[5]].map((id) => [byId[id].winnerStatus, byId[id].target]),
      [["pending", false], ["sending", false], ["failed", false], ["none", false]]);
    // 宛先一覧の内容: 氏名・メール・当選種別・program・時間・人数・当選メールの状態
    const w = byId[waitlist[0]];
    assert.equal(w.name, "架空 参加者7");
    assert.equal(w.email, "person7@example.invalid");
    assert.equal(w.notificationType, "waitlistPromotion");
    assert.deepEqual(w.programs, [{programId: "beta", name: "プログラムB", timeText: "14:00-15:00", plannedCount: 1}]);
    assert.equal(w.winnerStatus, "sent");
    assert.equal(w.target, true);
    // 作成されるジョブの宛先 = 画面の送信対象
    await start(s.targets.fingerprint);
    const items = (await db.collection("sendJobs/reminder-event1/items").get()).docs.map((d) => d.id).sort();
    assert.deepEqual(items, s.recipients.filter((r) => r.target).map((r) => r.participantId).sort());
    // プレビューも送信対象だけ
    assert.equal(await errorCode(api.preview(asAdmin({eventId: "event1", participantId: normal[4]}))), "participant-not-target");
  });

  test("当選メールの結果不明(unknown)が1件でもあれば、手動・自動のどちらでもジョブを作らない(sentとみなさない)。結果が確定すれば作れる", async () => {
    const ids = await importRows("batchA", [person(1), person(2), person(3)]);
    await winner(ids[0], "sent");
    await winner(ids[1], "sent");
    await winner(ids[2], "unknown");
    const s = await settings();
    assert.deepEqual(s.targets.blocked, {unknownWinnerMail: 1, suspectedDuplicates: 0});
    assert.equal(s.targets.targetCount, 2);
    assert.equal(s.recipients.find((r) => r.participantId === ids[2]).winnerStatus, "unknown");
    assert.equal(await errorCode(start(s.targets.fingerprint)), "reminder-targets-unresolved");
    nowMs = T0;
    await reminder.reconcileDue({limit: 5}); // 自動(送信予定日時に到達)
    assert.equal(await jobExists(), false, "自動の経路も同じ判定を通り、作られない");
    assert.equal((await db.doc(`mailDeliveries/${ids[2]}_winner`).get()).data().status, "unknown", "確認しても配送結果は変えない");
    // 当選メールの結果が(既存の配送処理で)確定した後は、改めて確認すれば作れる
    await winner(ids[2], "sent");
    assert.equal(await errorCode(start(s.targets.fingerprint)), "targets-changed", "古い確認の照合値では作らない");
    await start((await settings()).targets.fingerprint);
    assert.equal((await db.collection("sendJobs/reminder-event1/items").get()).size, 3);
  });

  test("メール重複: 共有(別の氏名)・同じ氏名で別program・同じ氏名で同じprogramの別時間帯(判定不能)は止めない。同じ氏名・program・時間帯は止める", async () => {
    const shared = {"メールアドレス": "family@example.invalid"};
    const ids = await importRows("batchA", [
      person(1, shared), person(2, shared), // A: 家族等(別の氏名)
      person(3, {...amOnly()}), person(3, {...pmOnly()}), // B: 同じ人が別のprogram
      person(4, {...amOnly("10:00-11:00")}), person(4, {...amOnly("11:00-12:00")}), // 判定不能: 同じ人・同じprogram・別の時間帯
    ]);
    for (const id of ids) await winner(id, "sent");
    const s = await settings();
    const kind = Object.fromEntries(s.recipients.map((r) => [r.participantId, [r.duplicate, r.duplicateGroupSize]]));
    assert.deepEqual(ids.map((id) => kind[id]), [
      ["shared-address", 2], ["shared-address", 2], ["different-programs", 2], ["different-programs", 2], ["undetermined", 2], ["undetermined", 2],
    ]);
    assert.deepEqual(s.targets.blocked, {unknownWinnerMail: 0, suspectedDuplicates: 0});
    assert.equal(s.targets.targetCount, 6, "同じメールアドレスでも、参加者ごとに送る(統合しない)");
    await start(s.targets.fingerprint);
    assert.equal((await db.collection("sendJobs/reminder-event1/items").get()).size, 6);
  });

  test("重複登録の疑い(同じメール・氏名・program・時間帯)はジョブを作らない(手動・自動とも)。参加者は統合・削除しない", async () => {
    const ids = await importRows("batchA", [person(1), person(2)]);
    const again = await importRows("batchB", [person(1)]); // 同じ人の入れ直し
    for (const id of [...ids, ...again]) await winner(id, "sent");
    const s = await settings();
    assert.deepEqual(s.targets.blocked, {unknownWinnerMail: 0, suspectedDuplicates: 2});
    assert.deepEqual(s.recipients.filter((r) => r.duplicate === "suspected-duplicate").map((r) => r.participantId).sort(), [ids[0], again[0]].sort());
    assert.equal(await errorCode(start(s.targets.fingerprint)), "reminder-targets-unresolved");
    nowMs = T0;
    await reminder.reconcileDue({limit: 5});
    assert.equal(await jobExists(), false);
    assert.equal((await db.collection("participants").get()).size, 3, "参加者は統合・削除しない");
  });

  test("照合値: 宛先の追加・削除、メール・program・時間・人数・当選メールの状態・氏名の変更を検出し、古い確認では作らない(何も作られない)", async () => {
    const ids = await importRows("batchA", [person(1), person(2), person(3)]);
    for (const id of ids) await winner(id, "sent");
    const attendanceOf = async (id) => (await db.collection("programAttendances").where("participantId", "==", id).where("programId", "==", "alpha").get()).docs[0].ref;
    const changes = [
      ["メールアドレスの変更", () => db.doc(`participants/${ids[0]}`).update({email: "changed@example.invalid"})],
      ["氏名の変更", () => db.doc(`participants/${ids[0]}`).update({name: "架空 変更後"})],
      ["programの変更", async () => (await attendanceOf(ids[1])).update({programId: "beta"})],
      ["時間の変更", async () => (await attendanceOf(ids[2])).update({slotLabel: "11:00-12:00"})],
      ["人数の変更", async () => (await attendanceOf(ids[0])).update({plannedCount: 5})],
      ["当選メールの状態の変更(対象の削除)", () => winner(ids[2], "failed")],
      ["当選メールの状態の変更(対象の追加)", () => winner(ids[2], "sent")],
      ["参加者の追加", () => importRows("batchB", [person(9)]).then(([id]) => winner(id, "sent"))],
    ];
    for (const [label, change] of changes) {
      const before = (await settings()).targets;
      await change();
      const after = (await settings()).targets;
      assert.notEqual(after.fingerprint, before.fingerprint, label);
      // 照合値だけでも検出する(件数が同じ変更も含む)。画面と同じく件数も送れば、どちらかの照合で必ず拒否される
      assert.equal(await errorCode(start(before.fingerprint)), "targets-changed", label);
      assert.ok(["targets-changed", "target-count-changed"].includes(await errorCode(start(before.fingerprint, {expectedTargetCount: before.targetCount}))), label);
      assert.equal(await jobExists(), false, label);
    }
    // 照合値は個人情報を含まない(sha256)
    const {fingerprint} = (await settings()).targets;
    assert.match(fingerprint, /^[0-9a-f]{64}$/);
    // 最新の確認なら作れる
    await start(fingerprint);
    assert.equal(await jobExists(), true);
  });

  test("手動開始は照合値が必須(確認なしでは作らない)。既存の件数・テンプレートversionの照合も維持", async () => {
    const ids = await importRows("batchA", [person(1), person(2)]);
    for (const id of ids) await winner(id, "sent");
    const s = await settings();
    assert.equal(await errorCode(api.start(asAdmin({eventId: "event1", dispatch: false}))), "targets-fingerprint-required");
    assert.equal(await errorCode(start("x".repeat(64))), "targets-fingerprint-required");
    assert.equal(await errorCode(start(s.targets.fingerprint, {expectedTargetCount: 3})), "target-count-changed");
    assert.equal(await errorCode(start(s.targets.fingerprint, {expectedTemplateVersion: 9})), "template-version-changed");
    assert.equal(await jobExists(), false);
    await start(s.targets.fingerprint, {expectedTargetCount: 2, expectedTemplateVersion: 1});
    assert.equal(await jobExists(), true);
    // 作成済みジョブの再開(送信状況画面の「送信開始」)は照合値なしでよい(宛先は作成時に確定済み。対象は増えない)
    await winner((await importRows("batchB", [person(5)]))[0], "sent");
    const resumed = await api.start(asAdmin({eventId: "event1"}));
    assert.equal(resumed.alreadyExisted, true);
    assert.equal((await db.collection("sendJobs/reminder-event1/items").get()).size, 2, "既存ジョブに宛先は追加されない");
  });

  test("自動の入口と手動開始が競合しても、ジョブは1つ・宛先は送信対象だけ(当選メール未送信者には作らない)", async () => {
    const ids = await importRows("batchA", [person(1), person(2), person(3), person(4)]);
    await winner(ids[0], "sent");
    await winner(ids[1], "sent");
    await winner(ids[2], "failed");
    const {fingerprint} = (await settings()).targets;
    nowMs = T0;
    // 自動の入口は何もしない(手動送信専用)。手動開始(引き渡しあり)と並行しても、ジョブは1つ
    await Promise.all([reminder.reconcileDue({limit: 5}), start(fingerprint, {dispatch: true}).catch(() => null), reminder.reconcileDue({limit: 5})]);
    const items = (await db.collection("sendJobs/reminder-event1/items").get()).docs.map((d) => d.id).sort();
    assert.deepEqual(items, [ids[0], ids[1]].sort());
    assert.equal((await db.doc("sendJobs/reminder-event1").get()).data().targetCount, 2);
    await send.runSweep();
    assert.deepEqual(sends.map((m) => m.metadata.participantId).sort(), [ids[0], ids[1]].sort(), "当選メール未送信・失敗者へは送らない");
    assert.equal(sends.length, 2, "1人1通(二重送信なし)");
  });

  test("権限(実際のindex.js): 宛先一覧(個人情報)は対象イベントのevent_manager以上だけ。受付スタッフ・他イベントの管理者・未ログインは拒否", async () => {
    const ids = await importRows("batchA", [person(1)]);
    await winner(ids[0], "sent");
    await db.collection("events").doc("event2").set({eventId: "event2", flow: "confirmed", eventName: "別の架空イベント", startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), venue: "x"});
    const assign = (eventId, uid, role) => db.collection("eventAssignments").doc(assignmentDocId(eventId, uid)).set({
      eventId, uid, role, active: true, email: `${uid}@example.invalid`, assignedBy: "u-admin",
      assignedAt: env.FieldValue.serverTimestamp(), updatedAt: env.FieldValue.serverTimestamp(),
    });
    await assign("event1", "u-mgr", "event_manager");
    await assign("event1", "u-staff", "staff");
    await assign("event2", "u-mgr2", "event_manager");
    const index = loadIndex(db, {FieldValue: env.FieldValue});
    const call = (uid, data) => errorCode(index.getConfirmedReminderSettings.run({auth: uid ? {uid} : undefined, data}));
    const ok = await index.getConfirmedReminderSettings.run({auth: {uid: "u-mgr"}, data: {eventId: "event1"}});
    assert.equal(ok.recipients[0].email, "person1@example.invalid");
    for (const [uid, expected] of [["u-staff", "permission-denied"], ["u-mgr2", "permission-denied"], [null, "unauthenticated"]]) {
      assert.equal(await call(uid, {eventId: "event1"}), expected, String(uid));
    }
    assert.equal(Object.keys(index).some((name) => /Reminder.*ByStaffKey/.test(name)), false, "受付キーの入口は無い");
    // 送信ジョブ・配送記録には個人情報を複製しない(宛先一覧はAPIの応答だけ)
    await index.startConfirmedReminderDelivery.run({auth: {uid: "u-mgr"}, data: {eventId: "event1", expectedTargetsFingerprint: ok.targets.fingerprint, dispatch: false}});
    const stored = JSON.stringify([...(await db.collection("sendJobs").get()).docs, ...(await db.collection("sendJobs/reminder-event1/items").get()).docs].map((d) => d.data()));
    assert.equal(stored.includes("person1@example.invalid"), false);
    assert.equal(stored.includes("架空 参加者1"), false);
  });

  test("プレビューの対象判定(1人だけ読む)は、宛先一覧の送信対象と常に一致する(対象外・別イベント・未確定の取込回・当選メールの各状態)", async () => {
    const ids = await importRows("batchA", [person(1), person(2), person(3), person(4), person(5), person(6), person(7)]);
    await winner(ids[0], "sent");
    await winner(ids[1], "unknown");
    await winner(ids[2], "failed");
    await winner(ids[3], "pending");
    await winner(ids[4], "sent");
    await db.doc(`participants/${ids[4]}`).update({status: "cancelled"}); // 有効でない
    await winner(ids[5], "sent");
    await db.doc(`participants/${ids[5]}`).update({eventId: "event-other"}); // 別イベント
    const pending = await importRows("batchP", [person(8)]);
    await winner(pending[0], "sent");
    await db.doc("importBatches/batchP").update({status: "committing"}); // 未確定の取込回
    const s = await settings();
    const targets = new Set(s.recipients.filter((r) => r.target).map((r) => r.participantId));
    for (const id of [...ids, ...pending]) {
      const result = await errorCode(api.preview(asAdmin({eventId: "event1", participantId: id})));
      assert.equal(result === "ok", targets.has(id), `${id}: preview=${result} target=${targets.has(id)}`);
    }
    assert.deepEqual([...targets], [ids[0]]);
  });

  test("Firestoreの読取件数(実測): 設定画面・プレビュー・ジョブ作成・送信状況。プレビューはイベント全体を読まない", async () => {
    // 読取を数えるため、実際のAdmin SDKのクラス(このテストのdbのもの)の読み取りメソッドを一時的に包む。
    // require("firebase-admin/firestore") は使わない(同じファイルの権限テストで loadIndex が require.cache を
    // 最小のスタブに置き換えるため、クラスが undefined になる)。
    const docProto = Object.getPrototypeOf(db.doc("x/y"));
    const queryProto = Object.getPrototypeOf(Object.getPrototypeOf(db.collection("x"))); // CollectionReference → Query
    const firestoreProto = Object.getPrototypeOf(db);
    let txProto = null;
    await db.runTransaction(async (tx) => { txProto = Object.getPrototypeOf(tx); });
    const N = 30;
    const ids = await importRows("batchA", Array.from({length: N}, (_, i) => person(i + 1)));
    for (const id of ids) await winner(id, "sent");
    const attendanceCount = (await db.collection("programAttendances").where("eventId", "==", "event1").get()).size;
    let reads = 0;
    const originals = [
      [docProto, "get"], [queryProto, "get"], [firestoreProto, "getAll"], [txProto, "get"],
    ].map(([proto, name]) => [proto, name, proto[name]]);
    const counted = (result) => {
      if (result && Array.isArray(result.docs)) reads += Math.max(1, result.docs.length);
      else if (Array.isArray(result)) reads += result.length;
      else reads += 1;
      return result;
    };
    for (const [proto, name, original] of originals) proto[name] = async function (...args) { return counted(await original.apply(this, args)); };
    const measure = async (run) => { reads = 0; await run(); return reads; };
    try {
      const settingsReads = await measure(() => settings());
      const previewReads = await measure(() => api.preview(asAdmin({eventId: "event1", participantId: ids[0]})));
      const {fingerprint} = (await settings()).targets;
      const createReads = await measure(() => start(fingerprint));
      const jobReads = await measure(() => reminder.getJob({data: {eventId: "event1"}}));
      // 参加者N・受付記録M・当選メールの配送記録N(+イベント・取込回・ジョブ・認可など数件)
      console.log(`reads (participants=${N}, attendances=${attendanceCount}): settings=${settingsReads} preview=${previewReads} create=${createReads} job=${jobReads}`);
      assert.ok(settingsReads <= 2 * N + attendanceCount + 10, `settings ${settingsReads}`);
      // プレビューは参加者数に比例しない(対象判定3件・イベント・その人の受付記録・認可など一定の件数だけ)
      assert.ok(previewReads <= 15, `preview ${previewReads}(イベント全体を読まない)`);
      assert.ok(previewReads * 5 < settingsReads, "プレビューは設定画面(イベント全体)よりずっと少ない");
      assert.ok(createReads <= 2 * N + attendanceCount + 15, `create ${createReads}`);
    } finally {
      for (const [proto, name, original] of originals) proto[name] = original;
    }
  });
});
