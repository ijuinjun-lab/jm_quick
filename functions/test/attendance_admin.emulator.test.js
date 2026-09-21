// program別受付の「人数訂正・受付取消・再受付」(admin専用)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続して検証する。実Firestore・メール送信は一切ない。
// データはすべて架空(メールは予約TLD .invalid)。実CSV・実参加者・実publicIdは使わない。
//
// 受付状態の正本は programAttendances のまま。訂正は attendedCount だけ、取消は受付状態だけを変え、実変更ごとに履歴(history)が1件だけ追記される。
// plannedCount・participant・publicId・QR・Web参加証URL・メール配送(sendJobs・mailDeliveries)は変わらない。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, makeRecord, HEADERS} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createPassApi} = require("../confirmed/pass_api");
const {receptionQrPayload} = require("../confirmed/pass_urls");
const {confirmedCallable, confirmedPublicPassCallable} = require("../auth");

const silent = {warn: () => {}, info: () => {}};
const APP_BASE_URL = "https://app.invalid";
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const errorOf = async (promise) => { try { await promise; } catch (error) { return {code: error.code, details: error.details}; } assert.fail("拒否されるはず"); };
const realFetch = globalThis.fetch;

describe("受付の訂正・取消・再受付(admin専用 / Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let pass; let view; let checkIn; let correct; let cancel;
  let externalCalls;

  const as = (uid) => (data) => ({auth: {uid}, data});
  const asStaff = as("u-staff");
  const asAdmin = as("u-admin");
  const asAdmin2 = as("u-admin2");
  const get = async (p) => (await db.doc(p).get()).data();
  const docs = async (p) => (await db.collection(p).get()).docs;

  function makeApis() {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const api = createPassApi({getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent});
    const publicCallable = confirmedPublicPassCallable(api.getPass, {logger: silent});
    const wrap = (level, handler) => { const callable = confirmedCallable(level, handler, {db, logger: silent}); return (request) => callable.run(request); };
    pass = (data) => publicCallable.run({data});
    view = wrap("staffOrAdmin", api.getReceptionView);
    checkIn = wrap("staffOrAdmin", api.checkIn);
    correct = wrap("admin", api.correct);
    cancel = wrap("admin", api.cancel);
  }

  async function seedEvent() {
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場ホール", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
      programs: [{programId: "gamma", name: "プログラムC", order: 2}, {programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1},
        {programId: "custom-zeta-9", name: "任意のprogram", order: 3}],
    });
  }
  const importApi = () => createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
  async function importBatch() {
    // 午前(alpha)=2名 / 午後(beta)=3名 / トーク(gamma)=1名 の3programに参加する参加者を2人
    const records = [1, 2].map((i) => makeRecord(i, {"午後参加時間": "13:00-14:00", "午後参加人数": "3"}));
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table: {headers: HEADERS, records}, clientRequestId: "batchA"})});
  }
  const participants = async () => (await docs("participants")).map((d) => d.data()).sort((a, b) => a.importRow - b.importRow);
  const ids = (p) => ({eventId: p.eventId, participantId: p.participantId, publicId: p.publicId});
  const att = (p, programId) => get(`programAttendances/${p.participantId}_${programId}`);
  // 連番はIDの末尾(Phase 7の check-in-1 には sequence フィールドが無いので、IDから復元する)
  const seqOf = (id) => Number(id.split("-").pop());
  const history = async (p, programId) => (await docs(`programAttendances/${p.participantId}_${programId}/history`)).map((d) => ({id: d.id, ...d.data(), sequence: d.data().sequence ?? seqOf(d.id)})).sort((a, b) => a.sequence - b.sequence);
  const doCheckIn = (p, programId, attendedCount, actor = asStaff) => checkIn(actor({...ids(p), programId, attendedCount}));
  const doCorrect = (p, programId, attendedCount, actor = asAdmin, extra = {}) => correct(actor({...ids(p), programId, attendedCount, ...extra}));
  const doCancel = (p, programId, actor = asAdmin, extra = {}) => cancel(actor({...ids(p), programId, ...extra}));
  const snapshotOf = async (collections) => JSON.stringify(await Promise.all(collections.map(async (c) => (await docs(c)).map((d) => [d.id, d.data()]))));

  // 受付状態の不変条件: 未受付なら checkedInAt・attendedCount・checkedInBy は null、受付済みなら attendedCount は1以上の整数
  function assertInvariant(a, label = "") {
    if (a.checkedIn === true) {
      assert.ok(Number.isInteger(a.attendedCount) && a.attendedCount >= 1 && a.attendedCount <= 999, `${label} 受付済みなのにattendedCountが不正: ${a.attendedCount}`);
      assert.ok(a.checkedInAt, `${label} 受付済みなのにcheckedInAtがない`);
      assert.ok(typeof a.checkedInBy === "string" && a.checkedInBy, `${label} 受付済みなのにcheckedInByがない`);
    } else {
      assert.equal(a.checkedIn, false, label);
      assert.equal(a.checkedInAt, null, `${label} 未受付なのにcheckedInAtがある`);
      assert.equal(a.attendedCount, null, `${label} 未受付なのにattendedCountがある`);
      assert.equal(a.checkedInBy, null, `${label} 未受付なのにcheckedInByがある`);
    }
  }
  // 履歴を連番順にたどって現在状態を再現し、実際の状態と一致すること(履歴と現在状態の整合)
  function assertHistoryMatches(a, hist, label = "") {
    let state = {checkedIn: false, attendedCount: null};
    hist.forEach((h, index) => {
      assert.equal(h.sequence, index + 1, `${label} 連番に欠落・重複がない`);
      assert.equal(h.id, `${h.action}-${h.sequence}`, `${label} IDは{action}-{sequence}`);
      assert.equal(h.before.checkedIn, state.checkedIn, `${label} #${h.sequence} beforeが直前の状態`);
      assert.equal(h.before.attendedCount, state.attendedCount, `${label} #${h.sequence} beforeの人数が直前の状態`);
      state = {checkedIn: h.after.checkedIn, attendedCount: h.after.attendedCount};
    });
    assert.equal(a.historySequence, hist.length, `${label} historySequence == 履歴の件数`);
    assert.deepEqual([a.checkedIn, a.attendedCount], [state.checkedIn, state.attendedCount], `${label} 履歴の最後のafter == 現在状態`);
  }

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    for (const [uid, role] of [["u-admin", "admin"], ["u-admin2", "admin"], ["u-staff", "staff"]]) await db.collection("accessRoles").doc(uid).set({role, active: true});
    await seedEvent();
    makeApis();
    await importBatch();
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  // ---------------------------------------------------------------------------------------------
  describe("認可: 初回受付はstaff/admin、訂正・取消はadminだけ", () => {
    test("未認証は unauthenticated、staffは permission-denied、adminは成功(訂正・取消とも)。拒否では何も書かれない", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      const before = await snapshotOf(["programAttendances"]);
      await rejectsWith(correct({data: {...ids(p), programId: "alpha", attendedCount: 1}}), "unauthenticated");
      await rejectsWith(cancel({data: {...ids(p), programId: "alpha"}}), "unauthenticated");
      await rejectsWith(doCorrect(p, "alpha", 1, asStaff), "permission-denied");
      await rejectsWith(doCancel(p, "alpha", asStaff), "permission-denied");
      assert.equal(await snapshotOf(["programAttendances"]), before);
      assert.equal((await doCorrect(p, "alpha", 1)).changed, true);
      assert.equal((await doCancel(p, "alpha")).changed, true);
    });

    test("bodyにrole・uidを入れても権限昇格できない(staffは拒否のまま)。adminがbodyに余計なキーを入れると入力不正", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await rejectsWith(correct(asStaff({...ids(p), programId: "alpha", attendedCount: 1, role: "admin", uid: "u-admin"})), "permission-denied");
      await rejectsWith(cancel(asStaff({...ids(p), programId: "alpha", role: "admin", uid: "u-admin"})), "permission-denied");
      await rejectsWith(correct({auth: {uid: "u-staff", token: {role: "admin", admin: true}}, data: {...ids(p), programId: "alpha", attendedCount: 1}}), "permission-denied");
      for (const extra of [{plannedCount: 9}, {checkedIn: false}, {checkedInBy: "x"}, {changedBy: "u-forged"}, {changedAt: "2020-01-01"}, {uid: "u-admin"}, {role: "admin"}]) {
        await rejectsWith(doCorrect(p, "alpha", 1, asAdmin, extra), "invalid-argument");
        await rejectsWith(doCancel(p, "alpha", asAdmin, extra), "invalid-argument");
      }
      assert.equal((await att(p, "alpha")).attendedCount, 2);
    });

    test("実際の公開設定(index.js)でも、訂正・取消はadmin専用(初回受付はstaffOrAdmin)", () => {
      const index = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
      assert.match(index, /^exports\.correctConfirmedProgramAttendance = confirmedCallable\("admin", passApi\.correct\)/m);
      assert.match(index, /^exports\.cancelConfirmedProgramCheckIn = confirmedCallable\("admin", passApi\.cancel\)/m);
      assert.match(index, /^exports\.checkInConfirmedProgram = confirmedCallable\("staffOrAdmin", passApi\.checkIn\)/m);
    });

    test("publicIdだけを知る第三者(参加証の閲覧者)は、訂正・取消も初回受付もできない(公開のcallableに操作の入口がない)", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await rejectsWith(pass({...ids(p), programId: "alpha", attendedCount: 1}), "not-found");
      assert.equal((await att(p, "alpha")).attendedCount, 2);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("人数訂正(attendedCountだけを変える)", () => {
    test("2 → 1、1 → 3。checkedIn・checkedInAt・checkedInBy・plannedCountは不変。履歴の changedBy は訂正したadminのUID", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2, asStaff);
      const first = await att(p, "alpha");
      const r1 = await doCorrect(p, "alpha", 1, asAdmin);
      assert.deepEqual([r1.changed, r1.program.attendedCount, r1.program.plannedCount], [true, 1, 2]);
      const r2 = await doCorrect(p, "alpha", 3, asAdmin2);
      assert.deepEqual([r2.changed, r2.program.attendedCount], [true, 3]);
      const after = await att(p, "alpha");
      assert.deepEqual([after.checkedIn, after.attendedCount, after.plannedCount], [true, 3, 2], "plannedCount(予定)と実来場人数は別");
      assert.equal(after.checkedInAt.toMillis(), first.checkedInAt.toMillis(), "checkedInAtは初回受付時刻のまま");
      assert.equal(after.checkedInBy, "u-staff", "checkedInByは初回受付者のまま(訂正者に置き換えない)");
      const hist = await history(p, "alpha");
      assert.deepEqual(hist.map((h) => [h.id, h.action, h.changedBy]), [["check-in-1", "check-in", "u-staff"], ["correction-2", "correction", "u-admin"], ["correction-3", "correction", "u-admin2"]]);
      assert.deepEqual([hist[1].before.attendedCount, hist[1].after.attendedCount, hist[2].before.attendedCount, hist[2].after.attendedCount], [2, 1, 1, 3]);
      assert.equal(hist[1].before.checkedInBy, "u-staff");
      assert.ok(hist[1].changedAt && typeof hist[1].changedAt.toDate === "function", "changedAtはサーバー時刻");
      assertInvariant(after);
      assertHistoryMatches(after, hist);
    });

    test("同じ人数への訂正(応答消失後の再試行を含む)はno-op: 状態変更0・history追加0", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await doCorrect(p, "alpha", 1);
      const before = JSON.stringify([await att(p, "alpha"), await history(p, "alpha")]);
      for (let i = 0; i < 5; i += 1) {
        const retry = await doCorrect(p, "alpha", 1);
        assert.deepEqual([retry.changed, retry.noop, retry.program.attendedCount], [false, "no-change", 1]);
      }
      assert.equal(JSON.stringify([await att(p, "alpha"), await history(p, "alpha")]), before);
      assert.equal((await history(p, "alpha")).length, 2);
    });

    test("未受付のprogramは訂正できない(受付済みにならない・履歴なし)。0・負数・文字列・小数・1000以上・未指定は拒否", async () => {
      const [p] = await participants();
      assert.equal((await errorOf(doCorrect(p, "alpha", 1))).details.code, "attendance-not-checked-in");
      const a = await att(p, "alpha");
      assert.deepEqual([a.checkedIn, a.attendedCount, a.checkedInAt, a.checkedInBy], [false, null, null, null]);
      assert.equal((await history(p, "alpha")).length, 0);
      await doCheckIn(p, "alpha", 2);
      for (const value of [0, -1, "1", 1.5, 1000, Number.MAX_SAFE_INTEGER, null, undefined, NaN]) {
        await rejectsWith(correct(asAdmin({...ids(p), programId: "alpha", attendedCount: value})), "invalid-argument");
      }
      assert.equal((await att(p, "alpha")).attendedCount, 2);
      assert.equal((await history(p, "alpha")).length, 1);
      await doCorrect(p, "alpha", 999);
      assert.equal((await att(p, "alpha")).attendedCount, 999);
    });

    test("participantId/publicId/eventId/programIdの不一致・無効な参加者・committedでないbatchは、訂正も取消もできない(何も変わらない)", async () => {
      const [p, q] = await participants();
      await doCheckIn(p, "alpha", 2);
      const before = await snapshotOf(["programAttendances"]);
      const code = async (fn) => (await errorOf(fn())).details.code;
      assert.equal(await code(() => correct(asAdmin({...ids(p), publicId: q.publicId, programId: "alpha", attendedCount: 1}))), "public-id-mismatch");
      assert.equal(await code(() => correct(asAdmin({...ids(p), eventId: "event2", programId: "alpha", attendedCount: 1}))), "event-mismatch");
      assert.equal(await code(() => correct(asAdmin({...ids(p), programId: "zzz", attendedCount: 1}))), "attendance-missing");
      await db.doc(`participants/${p.participantId}`).update({status: "cancelled"});
      assert.equal(await code(() => doCorrect(p, "alpha", 1)), "participant-not-active");
      assert.equal(await code(() => doCancel(p, "alpha")), "participant-not-active");
      await db.doc(`participants/${p.participantId}`).update({status: "active"});
      await db.doc("importBatches/batchA").update({status: "failed"});
      assert.equal(await code(() => doCorrect(p, "alpha", 1)), "batch-not-committed");
      assert.equal(await code(() => doCancel(p, "alpha")), "batch-not-committed");
      await db.doc("importBatches/batchA").update({status: "committed"});
      await db.doc("events/event1").update({flow: "legacy"});
      assert.equal(await code(() => doCorrect(p, "alpha", 1)), "event-not-confirmed");
      await db.doc("events/event1").update({flow: "confirmed"});
      assert.equal(await snapshotOf(["programAttendances"]), before);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("受付の取消と再受付", () => {
    test("取消: checkedIn・checkedInAt・attendedCount・checkedInByが未受付の状態に戻り、plannedCountとparticipant.statusは不変。取消の履歴が1件", async () => {
      const [p] = await participants();
      await doCheckIn(p, "beta", 2);
      const before = await att(p, "beta");
      const participantBefore = await get(`participants/${p.participantId}`);
      const result = await doCancel(p, "beta", asAdmin);
      assert.deepEqual([result.changed, result.program.checkedIn, result.program.plannedCount], [true, false, 3]);
      assert.ok(!("attendedCount" in result.program) && !("checkedInAt" in result.program));
      const after = await att(p, "beta");
      assert.deepEqual([after.checkedIn, after.checkedInAt, after.attendedCount, after.checkedInBy, after.plannedCount], [false, null, null, null, 3]);
      assertInvariant(after);
      assert.deepEqual(await get(`participants/${p.participantId}`), participantBefore, "participant(status・publicId含む)は不変。取消は参加者のキャンセルではない");
      const hist = await history(p, "beta");
      assert.deepEqual(hist.map((h) => [h.id, h.action, h.changedBy]), [["check-in-1", "check-in", "u-staff"], ["cancellation-2", "cancellation", "u-admin"]]);
      assert.deepEqual([hist[1].before.checkedIn, hist[1].before.attendedCount, hist[1].before.checkedInBy], [true, 2, "u-staff"]);
      assert.deepEqual([hist[1].after.checkedIn, hist[1].after.attendedCount, hist[1].after.checkedInAt, hist[1].after.checkedInBy], [false, null, null, null]);
      assert.equal(hist[1].before.checkedInAt.toMillis(), before.checkedInAt.toMillis());
      assertHistoryMatches(after, hist);
    });

    test("未受付のprogramへの取消は明示的なno-op(履歴なし・状態変更なし)。二重取消でも取消の履歴は1件だけ(応答消失後の再試行を含む)", async () => {
      const [p] = await participants();
      const none = await doCancel(p, "alpha");
      assert.deepEqual([none.changed, none.noop], [false, "not-checked-in"]);
      assert.equal((await history(p, "alpha")).length, 0);
      await doCheckIn(p, "alpha", 2);
      const first = await doCancel(p, "alpha");
      assert.equal(first.changed, true);
      for (let i = 0; i < 4; i += 1) assert.deepEqual([(await doCancel(p, "alpha")).changed, (await doCancel(p, "alpha", asAdmin2)).noop], [false, "not-checked-in"]);
      const hist = await history(p, "alpha");
      assert.equal(hist.filter((h) => h.action === "cancellation").length, 1);
      assert.equal(hist.length, 2);
    });

    test("取消後の訂正は受付を復活させない(拒否)", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await doCancel(p, "alpha");
      assert.equal((await errorOf(doCorrect(p, "alpha", 1))).details.code, "attendance-not-checked-in");
      assertInvariant(await att(p, "alpha"));
      assert.equal((await att(p, "alpha")).checkedIn, false);
    });

    test("再受付(Phase 7の初回受付経路): check-in-1 / cancellation-2 / check-in-3 が順に残り、既存の履歴は上書きされない。新しい受付情報で受付済みになる", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2, asStaff);
      const firstHistory = (await docs(`programAttendances/${p.participantId}_alpha/history`)).find((d) => d.id === "check-in-1").data();
      await doCancel(p, "alpha", asAdmin);
      const again = await doCheckIn(p, "alpha", 1, asAdmin2);
      assert.equal(again.alreadyCheckedIn, false);
      const a = await att(p, "alpha");
      assert.deepEqual([a.checkedIn, a.attendedCount, a.checkedInBy, a.plannedCount], [true, 1, "u-admin2", 2]);
      assert.ok(a.checkedInAt, "新しいcheckedInAt");
      const hist = await history(p, "alpha");
      assert.deepEqual(hist.map((h) => h.id), ["check-in-1", "cancellation-2", "check-in-3"]);
      assert.deepEqual(hist.map((h) => h.action), ["check-in", "cancellation", "check-in"]);
      assert.deepEqual((await docs(`programAttendances/${p.participantId}_alpha/history`)).find((d) => d.id === "check-in-1").data(), firstHistory, "check-in-1は不変");
      assertInvariant(a);
      assertHistoryMatches(a, hist);
      // 再受付後の再試行(Phase 7の二重受付防止): 追加の受付も履歴もない
      const retry = await doCheckIn(p, "alpha", 5, asStaff);
      assert.equal(retry.alreadyCheckedIn, true);
      assert.equal((await history(p, "alpha")).length, 3);
      assert.equal((await att(p, "alpha")).attendedCount, 1);
    });

    test("一連の操作(初回受付→訂正→再訂正→取消→再受付→再訂正)でplannedCountは一度も変わらず、履歴の連番が復元できる", async () => {
      const [p] = await participants();
      const planned = (await att(p, "beta")).plannedCount;
      const seen = [];
      const record = async () => seen.push((await att(p, "beta")).plannedCount);
      await doCheckIn(p, "beta", 3); await record();
      await doCorrect(p, "beta", 2); await record();
      await doCorrect(p, "beta", 1); await record();
      await doCancel(p, "beta"); await record();
      await doCheckIn(p, "beta", 3); await record();
      await doCorrect(p, "beta", 2); await record();
      assert.ok(seen.every((n) => n === planned), `plannedCountが変化した: ${seen}`);
      const hist = await history(p, "beta");
      assert.deepEqual(hist.map((h) => h.id), ["check-in-1", "correction-2", "correction-3", "cancellation-4", "check-in-5", "correction-6"]);
      assertHistoryMatches(await att(p, "beta"), hist);
      assert.ok(hist.every((h) => (h.before.plannedCount === undefined) && (h.after.plannedCount === undefined)), "plannedCountは監査対象に複製しない(正本が不変)");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("既存(Phase 7)データとの互換: 履歴の連番を持たず check-in-1 だけがあるデータへ、migrationなしで追記できる", () => {
    async function legacyCheckedIn(p, programId, count) {
      // Phase 7時点の形: historySequenceなし・受付済み・履歴は check-in-1 だけ
      const ref = db.doc(`programAttendances/${p.participantId}_${programId}`);
      await ref.update({checkedIn: true, checkedInAt: env.Timestamp.fromDate(new Date("2026-11-30T02:00:00Z")), attendedCount: count, checkedInBy: "u-staff"});
      await ref.collection("history").doc("check-in-1").set({action: "check-in", eventId: p.eventId, participantId: p.participantId, programId, before: {checkedIn: false, attendedCount: null}, after: {checkedIn: true, attendedCount: count}, changedBy: "u-staff", changedAt: env.Timestamp.fromDate(new Date("2026-11-30T02:00:00Z"))});
    }

    test("既存のcheck-in-1を変更・削除せず、訂正はcorrection-2、取消はcancellation-3として追記される。再受付はcheck-in-4", async () => {
      const [p] = await participants();
      await legacyCheckedIn(p, "alpha", 2);
      const original = (await docs(`programAttendances/${p.participantId}_alpha/history`))[0].data();
      assert.equal((await att(p, "alpha")).historySequence, undefined);
      await doCorrect(p, "alpha", 1);
      await doCancel(p, "alpha");
      await doCheckIn(p, "alpha", 2, asStaff);
      const hist = await history(p, "alpha");
      assert.deepEqual(hist.map((h) => h.id), ["check-in-1", "correction-2", "cancellation-3", "check-in-4"]);
      assert.deepEqual((await docs(`programAttendances/${p.participantId}_alpha/history`)).find((d) => d.id === "check-in-1").data(), original, "既存履歴は不変");
      assert.equal((await att(p, "alpha")).historySequence, 4);
      assert.equal(hist[1].before.attendedCount, 2);
      assertInvariant(await att(p, "alpha"));
    });

    test("未受付で履歴のない既存データへの初回受付は、従来どおり check-in-1(Phase 7と同じID)", async () => {
      const [p] = await participants();
      await doCheckIn(p, "gamma", 1);
      assert.deepEqual((await history(p, "gamma")).map((h) => h.id), ["check-in-1"]);
      assert.equal((await att(p, "gamma")).historySequence, 1);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("program独立性: 1つのprogramへの操作は他のprogramに影響しない(任意のprogramIdで成立)", () => {
    async function seedCustomProgram(p) {
      await db.doc(`programAttendances/${p.participantId}_custom-zeta-9`).set({
        eventId: p.eventId, participantId: p.participantId, programId: "custom-zeta-9", plannedCount: 4, slotLabel: null, startAt: null, endAt: null,
        checkedIn: false, checkedInAt: null, attendedCount: null, checkedInBy: null, importBatchId: "batchA", updatedAt: env.Timestamp.now(),
      });
    }

    test("A受付済み・B受付済み・C未受付 から、Aの訂正・取消・再受付をしても、B・Cのcheckedin状態・履歴は1つも変わらない", async () => {
      const [p, other] = await participants();
      await doCheckIn(p, "alpha", 2);
      await doCheckIn(p, "beta", 1);
      const others = async () => JSON.stringify([await att(p, "beta"), await history(p, "beta"), await att(p, "gamma"), await history(p, "gamma"), await att(other, "alpha"), await history(other, "alpha")]);
      const before = await others();
      await doCorrect(p, "alpha", 1);
      assert.equal(await others(), before, "Aの訂正でB/Cは不変");
      await doCancel(p, "alpha");
      assert.equal(await others(), before, "Aの取消でB/Cは不変");
      assert.deepEqual([(await att(p, "beta")).checkedIn, (await att(p, "beta")).attendedCount, (await att(p, "gamma")).checkedIn], [true, 1, false]);
      await doCheckIn(p, "alpha", 3);
      assert.equal(await others(), before, "Aの再受付でB/Cは不変");
      const shown = await view(asStaff({...ids(p)}));
      assert.deepEqual(shown.programs.map((x) => [x.programId, x.checkedIn]), [["alpha", true], ["beta", true], ["gamma", false]]);
    });

    test("program名に依存しない: 任意のprogramId(custom-zeta-9)でも、初回受付→訂正→取消→再受付が成立し、他のprogramは不変", async () => {
      const [p] = await participants();
      await seedCustomProgram(p);
      await doCheckIn(p, "alpha", 2);
      const alphaBefore = JSON.stringify([await att(p, "alpha"), await history(p, "alpha")]);
      await doCheckIn(p, "custom-zeta-9", 4);
      await doCorrect(p, "custom-zeta-9", 2);
      await doCancel(p, "custom-zeta-9");
      await doCheckIn(p, "custom-zeta-9", 3);
      assert.deepEqual((await history(p, "custom-zeta-9")).map((h) => h.id), ["check-in-1", "correction-2", "cancellation-3", "check-in-4"]);
      assert.equal((await att(p, "custom-zeta-9")).plannedCount, 4);
      assert.equal(JSON.stringify([await att(p, "alpha"), await history(p, "alpha")]), alphaBefore);
    });

    test("別のprogram・別のparticipantは同時に操作しても互いに影響しない(各々の履歴が独立)", async () => {
      const [p, q] = await participants();
      await Promise.all([doCheckIn(p, "alpha", 2), doCheckIn(p, "beta", 3), doCheckIn(q, "alpha", 1), doCheckIn(q, "gamma", 1)]);
      await Promise.all([doCorrect(p, "alpha", 1), doCancel(p, "beta"), doCorrect(q, "alpha", 5), doCorrect(q, "gamma", 9)]);
      const expected = [[p, "alpha", [true, 1]], [p, "beta", [false, null]], [q, "alpha", [true, 5]], [q, "gamma", [true, 9]]];
      for (const [who, programId, [checkedIn, count]] of expected) {
        const a = await att(who, programId);
        assert.deepEqual([a.checkedIn, a.attendedCount], [checkedIn, count], `${who.participantId}_${programId}`);
        assertInvariant(a);
        assertHistoryMatches(a, await history(who, programId), `${who.participantId}_${programId}`);
      }
      assert.equal((await att(p, "gamma")).checkedIn, false);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("同時操作(transactionで整合性を保つ)", () => {
    test("同じprogramへの同時100件の人数訂正: 現在状態と履歴が矛盾せず、各履歴のbeforeが直前の状態", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      const counts = Array.from({length: 100}, (_, i) => (i % 9) + 1); // 1..9(2と同じ値・重複する値を含む)
      const results = await Promise.all(counts.map((n, i) => doCorrect(p, "alpha", n, i % 2 === 0 ? asAdmin : asAdmin2)));
      const a = await att(p, "alpha");
      const hist = await history(p, "alpha");
      assertInvariant(a);
      assertHistoryMatches(a, hist);
      const changed = results.filter((r) => r.changed).length;
      assert.equal(hist.length, 1 + changed, "実変更ごとに履歴が1件(no-opは0件)");
      assert.ok(hist.slice(1).every((h) => h.action === "correction" && h.before.attendedCount !== h.after.attendedCount), "履歴は実際に変わった訂正だけ");
      assert.ok(counts.includes(a.attendedCount), "最終状態はいずれかの訂正の値");
      assert.equal(a.checkedInBy, "u-staff");
      assert.equal(a.plannedCount, 2);
    });

    test("同じprogramへの同時100件の取消: 取消の成功は1回だけ、cancellationの履歴も1件だけ", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      const results = await Promise.all(Array.from({length: 100}, (_, i) => doCancel(p, "alpha", i % 2 === 0 ? asAdmin : asAdmin2)));
      assert.equal(results.filter((r) => r.changed === true).length, 1);
      assert.equal(results.filter((r) => r.noop === "not-checked-in").length, 99);
      const hist = await history(p, "alpha");
      assert.equal(hist.filter((h) => h.action === "cancellation").length, 1);
      assert.equal(hist.length, 2);
      assertInvariant(await att(p, "alpha"));
      assertHistoryMatches(await att(p, "alpha"), hist);
    });

    test("訂正と取消を同時実行: 順序が履歴で確定し、現在状態と一致する。取消後に遅れた訂正が受付を復活させない", async () => {
      for (let round = 0; round < 3; round += 1) {
        const [p, q] = await participants();
        const target = round === 1 ? q : p;
        const programId = ["alpha", "beta", "gamma"][round];
        await doCheckIn(target, programId, 2);
        const ops = [];
        for (let i = 0; i < 30; i += 1) ops.push(doCorrect(target, programId, (i % 5) + 1, i % 2 ? asAdmin : asAdmin2).catch((e) => ({rejected: e.details && e.details.code})));
        for (let i = 0; i < 4; i += 1) ops.push(doCancel(target, programId, i % 2 ? asAdmin : asAdmin2));
        const results = await Promise.all(ops);
        const a = await att(target, programId);
        const hist = await history(target, programId);
        assertInvariant(a, `round${round}`);
        assertHistoryMatches(a, hist, `round${round}`);
        assert.equal(hist.filter((h) => h.action === "cancellation").length, 1, "取消は1回だけ");
        // 取消の後に成立した訂正は無い(受付の復活なし)
        const cancelAt = hist.findIndex((h) => h.action === "cancellation");
        assert.ok(hist.slice(cancelAt + 1).length === 0, "取消の後に履歴が追記されない(訂正は拒否される)");
        assert.equal(a.checkedIn, false);
        assert.ok(results.some((r) => r.rejected === "attendance-not-checked-in") || results.filter((r) => r.changed).length >= 1);
      }
    });

    test("取消と再受付が競合しても、不正な状態(未受付なのにattendedCountあり等)にならず、履歴の連番が整合する", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      const ops = [];
      for (let i = 0; i < 10; i += 1) {
        ops.push(doCancel(p, "alpha", asAdmin));
        ops.push(doCheckIn(p, "alpha", (i % 4) + 1, asStaff).catch((e) => ({rejected: e.code})));
        ops.push(doCorrect(p, "alpha", (i % 3) + 1, asAdmin2).catch((e) => ({rejected: e.details && e.details.code})));
      }
      await Promise.all(ops);
      const a = await att(p, "alpha");
      const hist = await history(p, "alpha");
      assertInvariant(a);
      assertHistoryMatches(a, hist);
      assert.equal(a.plannedCount, 2);
      const ids = hist.map((h) => h.id);
      assert.equal(new Set(ids).size, ids.length, "履歴IDが衝突しない");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("不変であるべきもの(publicId・QR・Web参加証URL・メール配送・participant)", () => {
    test("一連の受付操作の前後で、publicId・受付QR・Web参加証URL・participantが完全に一致し、参加証は現在の受付状態を反映する(読み取り専用)", async () => {
      const [p] = await participants();
      const participantBefore = await get(`participants/${p.participantId}`);
      const passBefore = await pass({participantId: p.participantId, publicId: p.publicId});
      const expectedQr = receptionQrPayload({appBaseUrl: APP_BASE_URL, eventId: "event1", participantId: p.participantId, publicId: p.publicId});
      assert.equal(passBefore.qrPayload, expectedQr);
      const shown = async () => (await pass({participantId: p.participantId, publicId: p.publicId}));
      await doCheckIn(p, "alpha", 2);
      assert.equal((await shown()).programs.find((x) => x.programId === "alpha").checkedIn, true);
      await doCorrect(p, "alpha", 1);
      await doCancel(p, "alpha");
      const cancelled = await shown();
      assert.equal(cancelled.programs.find((x) => x.programId === "alpha").checkedIn, false, "取消後は未受付として反映");
      assert.equal(cancelled.programs.length, 3, "参加資格は失効しない(participantはactiveのまま)");
      await doCheckIn(p, "alpha", 3);
      await doCorrect(p, "alpha", 2);
      const final = await shown();
      assert.equal(final.programs.find((x) => x.programId === "alpha").checkedIn, true);
      assert.equal(final.qrPayload, passBefore.qrPayload, "QR payload不変");
      assert.equal(final.webPassUrl, passBefore.webPassUrl, "Web参加証URL不変");
      assert.deepEqual(await get(`participants/${p.participantId}`), participantBefore, "publicId・status等のparticipantは不変");
      assert.equal((await get(`participants/${p.participantId}`)).status, "active");
    });

    test("winner・reminderのsendJobs・mailDeliveries・mailJobsは、受付の訂正・取消・再受付で1つも変わらない(メール再送・QR再発行なし)", async () => {
      const [p] = await participants();
      // 当選メール・リマインドの配送状態を模したデータ(Phase 6〜9Bの構造)
      await db.doc("sendJobs/winner-batchA").set({type: "winner", eventId: "event1", batchId: "batchA", status: "completed", targetCount: 2, templateVersion: 1, dispatchActive: false});
      await db.doc("sendJobs/reminder-event1").set({type: "reminder", eventId: "event1", batchId: null, status: "completed", targetCount: 2, templateVersion: 1, dispatchActive: false});
      await db.doc(`mailDeliveries/${p.participantId}_winner`).set({participantId: p.participantId, type: "winner", status: "sent", jobId: "winner-batchA", attemptCount: 1});
      await db.doc(`mailDeliveries/${p.participantId}_reminder`).set({participantId: p.participantId, type: "reminder", status: "unknown", jobId: "reminder-event1", attemptCount: 1});
      const before = await snapshotOf(["sendJobs", "mailDeliveries", "mailJobs", "checkIns"]);
      await doCheckIn(p, "alpha", 2);
      await doCorrect(p, "alpha", 1);
      await doCancel(p, "alpha");
      await doCheckIn(p, "alpha", 2);
      await doCorrect(p, "alpha", 3);
      assert.equal(await snapshotOf(["sendJobs", "mailDeliveries", "mailJobs", "checkIns"]), before);
      assert.equal((await docs("checkIns")).length, 0, "旧checkInsを受付の正本にしない");
    });

    test("履歴・受付ドキュメントに、氏名・メール・かな・publicId・QR payloadを複製しない。履歴のキーは必要最小限", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await doCorrect(p, "alpha", 1);
      await doCancel(p, "alpha");
      await doCheckIn(p, "alpha", 2);
      const stored = await get(`participants/${p.participantId}`);
      const text = JSON.stringify([...(await docs(`programAttendances/${p.participantId}_alpha/history`)).map((d) => d.data()), await att(p, "alpha")]);
      for (const secret of [stored.name, stored.email, stored.kana, stored.publicId, "example.invalid", "/reception?", "publicId"]) {
        if (secret) assert.ok(!text.includes(secret), `複製してはならない値: ${String(secret).slice(0, 12)}`);
      }
      const allowed = ["action", "sequence", "eventId", "participantId", "programId", "before", "after", "changedBy", "changedAt"];
      for (const d of await docs(`programAttendances/${p.participantId}_alpha/history`)) assert.deepEqual(Object.keys(d.data()).sort(), [...allowed].sort());
    });

    test("registeredCountを参照しない・新しい状態コレクション(corrections等)を作らない", async () => {
      const [p] = await participants();
      await doCheckIn(p, "alpha", 2);
      await doCorrect(p, "alpha", 1);
      await doCancel(p, "alpha");
      const collections = (await db.listCollections()).map((c) => c.id).sort();
      assert.deepEqual(collections, ["accessRoles", "events", "importBatches", "participants", "programAttendances"]);
      const source = fs.readFileSync(path.join(__dirname, "..", "confirmed", "pass_api.js"), "utf8");
      assert.ok(!source.includes("registered" + "Count"));
    });
  });

  test("インスタンス内の直列化を切っても(Firestoreのtransactionと再実行だけで)、同時の訂正・取消・再受付の整合性が保たれる(履歴と現在状態が一致)", async () => {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const raw = createPassApi({getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent, serializeLocally: false});
    const wrapRaw = (level, handler) => { const callable = confirmedCallable(level, handler, {db, logger: silent}); return (request) => callable.run(request); };
    const rawCorrect = wrapRaw("admin", raw.correct);
    const rawCancel = wrapRaw("admin", raw.cancel);
    const rawCheckIn = wrapRaw("staffOrAdmin", raw.checkIn);
    const [p] = await participants();
    await doCheckIn(p, "alpha", 2);
    const ops = [];
    for (let i = 0; i < 6; i += 1) ops.push(rawCorrect(asAdmin({...ids(p), programId: "alpha", attendedCount: (i % 3) + 1})).catch((e) => ({rejected: e.details && e.details.code})));
    ops.push(rawCancel(asAdmin({...ids(p), programId: "alpha"})));
    ops.push(rawCheckIn(asStaff({...ids(p), programId: "alpha", attendedCount: 4})).catch((e) => ({rejected: e.code})));
    const results = await Promise.all(ops);
    assert.equal(results.length, 8);
    const a = await att(p, "alpha");
    assertInvariant(a);
    assertHistoryMatches(a, await history(p, "alpha"));
    assert.equal(a.plannedCount, 2);
  });

  test("外部通信0件・メール送信0件(Emulator以外へのfetchなし)", async () => {
    const [p] = await participants();
    await doCheckIn(p, "alpha", 2);
    await doCorrect(p, "alpha", 1);
    await doCancel(p, "alpha");
    assert.deepEqual(externalCalls, []);
  });
});
