// 当選メール送信管理UI用の読み取り専用API(listConfirmedWinnerMailBatches / getConfirmedWinnerMailJob)と、
// 作成時のテンプレートversion確認(expectedTemplateVersion)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続して検証する。
// メール送信は「偽のtransport」で、SendGrid・Cloud Runの実URLへの通信は一切ない。データはすべて架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const silent = {warn: () => {}};
const APP_BASE_URL = "https://app.invalid";
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const realFetch = globalThis.fetch;
const TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "当選おめでとうございます。", closingBody: "お会いできるのを楽しみにしています。", notesBody: null};

describe("当選メール送信管理API(Emulator + 実Admin SDK + 偽transport)", {skip: skipReason()}, () => {
  let env;
  let db;
  let api; // 認可つきのcallable(実際の公開と同じconfirmedCallable("admin", ...))
  let sends;
  let behavior;
  let externalCalls;
  let nowMs;

  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});
  const transport = {
    async capabilities() { return {ok: true, missing: []}; },
    async send(message) { sends.push(JSON.parse(JSON.stringify(message))); return behavior(message); },
  };
  const get = async (path) => (await db.doc(path).get()).data();
  const docs = async (path) => (await db.collection(path).get()).docs;

  function makeApis() {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const send = createWinnerSendApi({
      getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL, getTransport: () => transport,
      engineOptions: {now: () => nowMs, leaseMs: 60000, concurrency: 4},
    });
    const mail = createWinnerMailApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL});
    const wrap = (handler) => { const callable = confirmedCallable("admin", handler, {db, logger: silent}); return (request) => callable.run(request); };
    api = {
      list: wrap(send.listBatches), job: wrap(send.getJob), create: wrap(send.createJob), process: wrap(send.processJob), retry: wrap(send.retryFailed),
      updateTemplate: wrap(mail.updateTemplate),
    };
  }

  async function seedEvent(overrides = {}) {
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場ホール", contact: "架空事務局", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
      programs: [{programId: "gamma", name: "トークセッション", order: 2}, {programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}],
      winnerMailTemplate: {...TEMPLATE, version: 3, updatedBy: "u-admin"},
      ...overrides,
    });
  }
  const importApi = () => createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
  async function importBatch(clientRequestId, tableOrN = 3, extra = {}) {
    const table = typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN;
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table, clientRequestId, ...extra})});
  }
  const list = (actor = asAdmin) => api.list(actor({eventId: "event1"}));
  const rowOf = (result, batchId) => result.batches.find((b) => b.batchId === batchId);
  const create = (batchId, extra = {}) => api.create(asAdmin({eventId: "event1", batchId, ...extra}));
  const processAll = (jobId, extra = {}) => api.process(asAdmin({jobId, ...extra}));

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("u-staff").set({role: "staff", active: true});
    await seedEvent();
    makeApis();
    sends = [];
    behavior = (message) => ({outcome: "sent", messageId: `mid-${message.metadata.participantId}`});
    nowMs = Date.parse("2026-11-01T00:00:00Z");
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  describe("認可(admin専用)", () => {
    test("未認証は unauthenticated、staffは permission-denied、adminは成功(一覧・ジョブ状態とも)", async () => {
      await importBatch("batchA", 3);
      await create("batchA");
      await rejectsWith(api.list({data: {eventId: "event1"}}), "unauthenticated");
      await rejectsWith(api.list(asStaff({eventId: "event1"})), "permission-denied");
      await rejectsWith(api.job({data: {jobId: "winner-batchA"}}), "unauthenticated");
      await rejectsWith(api.job(asStaff({jobId: "winner-batchA"})), "permission-denied");
      assert.equal((await list()).batches.length, 1);
      assert.equal((await api.job(asAdmin({jobId: "winner-batchA"}))).job.targetCount, 3);
    });

    // Phase 1B: 実際の公開設定では、対象イベントのevent_manager以上(adminは全イベント)。
    // eventIdで指定するものはdata.eventId、jobIdで指定するものはsendJobs/{jobId}.eventId(正本)を対象イベントにする。
    test("実際の公開設定(index.js)では、5つの送信管理callableは対象イベントのevent_manager以上(jobId系はsendJobsのeventIdで認可)", () => {
      const fs = require("node:fs");
      const index = fs.readFileSync(require("node:path").join(__dirname, "..", "index.js"), "utf8");
      for (const name of ["listConfirmedWinnerMailBatches", "createConfirmedWinnerMailJob"]) {
        assert.match(index, new RegExp(`^exports\\.${name} = confirmedEventCallable\\("eventManager", EVENT_SCOPES\\.dataEventId, `, "m"), name);
      }
      for (const name of ["getConfirmedWinnerMailJob", "processConfirmedWinnerMailJob", "retryFailedConfirmedWinnerMails"]) {
        assert.match(index, new RegExp(`^exports\\.${name} = confirmedEventCallable\\("eventManager", EVENT_SCOPES\\.sendJobEventId, `, "m"), name);
      }
    });

    test("不正な入力(想定外のキー・不正なID・不正なstatus/limit)は拒否される", async () => {
      await rejectsWith(api.list(asAdmin({eventId: "event1", extra: 1})), "invalid-argument");
      await rejectsWith(api.list(asAdmin({eventId: "../x"})), "invalid-argument");
      await rejectsWith(api.list(asAdmin({eventId: "no-such-event"})), "not-found");
      await rejectsWith(api.job(asAdmin({jobId: "winner-x", itemStatus: "weird"})), "invalid-argument");
      await rejectsWith(api.job(asAdmin({jobId: "winner-x", limit: 0})), "invalid-argument");
      await rejectsWith(api.job(asAdmin({jobId: "bad"})), "invalid-argument");
      await rejectsWith(api.job(asAdmin({jobId: "winner-nothere"})), "not-found");
      await db.collection("events").doc("legacy1").set({eventId: "legacy1", eventName: "旧"});
      await rejectsWith(api.list(asAdmin({eventId: "legacy1"})), "failed-precondition");
    });
  });

  describe("batch一覧(サーバーの正本から)", () => {
    test("committedなbatchは、取込件数・メール対象(active)・状態を返し、送信ジョブ作成が可能", async () => {
      await importBatch("batchA", 90);
      await importBatch("batchB", 43);
      const result = await list();
      assert.equal(result.eventName, "架空イベント");
      assert.deepEqual(result.template, {version: 3, ready: true, problems: []});
      assert.deepEqual(result.batches.map((b) => [b.batchId, b.sequence, b.label, b.status, b.importedCount, b.targetCount, b.excludedInactiveCount, b.consistent, b.job, b.canCreateJob]),
        [["batchA", 1, "第1回", "committed", 90, 90, 0, true, null, true], ["batchB", 2, "第2回", "committed", 43, 43, 0, true, null, true]]);
    });

    test("送信前プレビュー用に、対象batchの有効な参加者IDを1件返す(committedのみ。氏名・メールは返さない)", async () => {
      await importBatch("batchA", 4);
      await importBatch("batchB", 3);
      await db.doc("participants/batchA-000002").update({status: "cancelled"});
      await db.doc("importBatches/batchB").update({status: "committing"});
      const result = await list();
      assert.equal(rowOf(result, "batchA").previewParticipantId, "batchA-000003", "cancelledは飛ばして有効な先頭");
      assert.equal(rowOf(result, "batchB").previewParticipantId, null);
    });

    test("committedでも対象0件(全員cancelled)のbatchはpreviewParticipantId=null・targetCount=0・no-targetsで、送信もできない", async () => {
      await importBatch("batchA", 3);
      const participants = await docs("participants");
      for (const doc of participants) {
        await doc.ref.update({status: "cancelled"});
      }
      const row = rowOf(await list(), "batchA");
      assert.deepEqual(
        [row.status, row.targetCount, row.excludedInactiveCount, row.previewParticipantId, row.canCreateJob, row.blockedReasons],
        ["committed", 0, 3, null, false, ["no-targets"]],
      );
      await rejectsWith(create("batchA"), "failed-precondition");
    });

    test("同一メール100participantでも対象100、同一氏名100でも対象100(人物の重複排除をしない)", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      await importBatch("batchB", makeTable(100, () => ({"氏名": "架空同姓同名"})));
      await importBatch("batchC", makeTable(100, () => ({"rd": "R-SAME"})));
      const result = await list();
      for (const id of ["batchA", "batchB", "batchC"]) {
        assert.equal(rowOf(result, id).targetCount, 100, id);
        assert.equal(rowOf(result, id).importedCount, 100, id);
      }
    });

    test("cancelledの参加者は対象から除かれ、除外数として別に表示される(対象 + 除外 = 取込件数)", async () => {
      await importBatch("batchA", 10);
      await db.doc("participants/batchA-000002").update({status: "cancelled"});
      await db.doc("participants/batchA-000003").update({status: "cancelled"});
      const row = rowOf(await list(), "batchA");
      assert.deepEqual([row.importedCount, row.targetCount, row.excludedInactiveCount, row.canCreateJob], [10, 8, 2, true]);
    });

    test("committing・failedのbatchは状態だけ表示され、送信対象人数は出さず、ジョブ作成は不可(作成しても拒否される)", async () => {
      await importBatch("batchA", 3);
      await importBatch("batchB", 3);
      await importBatch("batchC", 3);
      await db.doc("importBatches/batchB").update({status: "committing"});
      await db.doc("importBatches/batchC").update({status: "failed"});
      const result = await list();
      for (const id of ["batchB", "batchC"]) {
        const row = rowOf(result, id);
        assert.deepEqual([row.targetCount, row.importedCount, row.canCreateJob, row.blockedReasons], [null, null, false, ["batch-not-committed"]], id);
        await rejectsWith(create(id), "failed-precondition");
      }
      assert.equal(rowOf(result, "batchA").status, "committed");
      assert.equal((await docs("sendJobs")).length, 0);
    });

    test("参加者数が取込結果と一致しないbatchは送信不可(consistent=false)。テンプレート未設定でも送信不可", async () => {
      await importBatch("batchA", 5);
      await db.doc("participants/batchA-000002").delete();
      let row = rowOf(await list(), "batchA");
      assert.deepEqual([row.consistent, row.canCreateJob, row.blockedReasons], [false, false, ["participants-mismatch"]]);
      await importBatch("batchB", 3);
      await db.doc("events/event1").update({winnerMailTemplate: env.FieldValue.delete()});
      const result = await list();
      assert.equal(result.template.ready, false);
      assert.equal(result.template.version, null);
      assert.ok(result.template.problems.length > 0);
      row = rowOf(result, "batchB");
      assert.deepEqual([row.canCreateJob, row.blockedReasons], [false, ["mail-not-ready"]]);
    });

    test("ジョブ作成済みのbatchには、ジョブの状態(templateVersion・件数・状態)が付き、再作成は不可", async () => {
      await importBatch("batchA", 5);
      await importBatch("batchB", 4);
      await create("batchA");
      const result = await list();
      const a = rowOf(result, "batchA");
      assert.equal(a.canCreateJob, false);
      assert.deepEqual(a.blockedReasons, ["job-exists"]);
      assert.deepEqual([a.job.jobId, a.job.status, a.job.templateVersion, a.job.targetCount, a.job.counts],
        ["winner-batchA", "ready", 3, 5, {pending: 5, sending: 0, sent: 0, failed: 0, unknown: 0}]);
      assert.match(a.job.createdAt, /^\d{4}-\d{2}-\d{2}T/);
      assert.equal(rowOf(result, "batchB").job, null, "別batchのジョブとは混ざらない");
      assert.equal(rowOf(result, "batchB").canCreateJob, true);
    });

    test("一覧・ジョブ状態の取得は読み取り専用(何も書き込まれない)で、メールアドレス・氏名を返さない", async () => {
      await importBatch("batchA", 6);
      await create("batchA");
      const snapshot = async () => JSON.stringify(await Promise.all(["events", "importBatches", "participants", "programAttendances", "sendJobs", "mailDeliveries"].map(async (c) => (await docs(c)).map((d) => [d.id, d.data()]))));
      const before = await snapshot();
      const listed = await list();
      await api.job(asAdmin({jobId: "winner-batchA"}));
      assert.equal(await snapshot(), before);
      const p = await get("participants/batchA-000002");
      const text = JSON.stringify(listed);
      assert.ok(!text.includes(p.email) && !text.includes(p.name) && !text.includes("example.invalid"));
    });
  });

  describe("templateVersionの確認と固定", () => {
    test("画面で確認したversionと現在のversionが同じなら作成でき、ジョブにそのversionが固定される", async () => {
      await importBatch("batchA", 3);
      const job = await create("batchA", {expectedTemplateVersion: 3});
      assert.equal(job.templateVersion, 3);
      assert.equal((await get("sendJobs/winner-batchA")).templateVersion, 3);
    });

    test("確認した後にテンプレートが更新されていたら、確認していない版を固定せず作成しない(ジョブも配送記録も作られない)", async () => {
      await importBatch("batchA", 3);
      await api.updateTemplate(asAdmin({eventId: "event1", template: {...TEMPLATE, subject: "更新後の件名"}}));
      const error = await api.create(asAdmin({eventId: "event1", batchId: "batchA", expectedTemplateVersion: 3})).catch((e) => e);
      assert.equal(error.code, "failed-precondition");
      assert.equal(error.details.code, "template-version-changed");
      assert.deepEqual([error.details.expected, error.details.current], [3, 4]);
      assert.equal((await docs("sendJobs")).length, 0);
      assert.equal((await docs("mailDeliveries")).length, 0);
      assert.equal((await create("batchA", {expectedTemplateVersion: 4})).templateVersion, 4);
    });

    test("作成後にテンプレートを変更しても、そのジョブのversionは変わらない(ジョブ状態にも作成時のversionが出る)", async () => {
      await importBatch("batchA", 3);
      await create("batchA", {expectedTemplateVersion: 3});
      await api.updateTemplate(asAdmin({eventId: "event1", template: {...TEMPLATE, subject: "後から変更"}}));
      const result = await list();
      assert.equal(result.template.version, 4, "現在のテンプレート");
      assert.equal(rowOf(result, "batchA").job.templateVersion, 3, "このジョブは作成時のv3のまま");
      await processAll("winner-batchA");
      assert.ok(sends.every((m) => m.subject === TEMPLATE.subject), "送信内容も作成時の文章");
      // 既存ジョブがあれば、古いversionを期待した再作成の呼び出しでも、既存ジョブがそのまま返る(新規作成でも上書きでもない)
      const again = await create("batchA", {expectedTemplateVersion: 3});
      assert.deepEqual([again.alreadyExisted, again.templateVersion], [true, 3]);
    });

    test("expectedTemplateVersionが整数でなければ拒否", async () => {
      await importBatch("batchA", 3);
      await rejectsWith(create("batchA", {expectedTemplateVersion: "3"}), "invalid-argument");
      await rejectsWith(create("batchA", {expectedTemplateVersion: 3.5}), "invalid-argument");
    });
  });

  describe("ジョブ状態(pending / sending / sent / failed / unknown を別々に)", () => {
    const jobOf = async (jobId = "winner-batchA", extra = {}) => api.job(asAdmin({jobId, ...extra}));

    test("処理前はすべてpending。処理後に sent・failed・unknown が別々の件数で返り、合計 == targetCount、completed", async () => {
      await importBatch("batchA", 12);
      await create("batchA");
      let state = (await jobOf()).job;
      assert.deepEqual(state.counts, {pending: 12, sending: 0, sent: 0, failed: 0, unknown: 0});
      assert.deepEqual(state.conservation, {total: 12, consistent: true, completedConsistent: true});
      behavior = (message) => {
        const id = message.metadata.participantId;
        if (["batchA-000003", "batchA-000005"].includes(id)) return {outcome: "failed", errorCode: "mail-api-400"};
        if (id === "batchA-000004") return {outcome: "unknown", errorCode: "timeout"};
        return {outcome: "sent", messageId: `mid-${id}`};
      };
      await processAll("winner-batchA");
      state = (await jobOf()).job;
      assert.equal(state.status, "completed");
      assert.deepEqual(state.counts, {pending: 0, sending: 0, sent: 9, failed: 2, unknown: 1}, "failedとunknownは別の件数");
      assert.equal(state.counts.sent + state.counts.failed + state.counts.unknown, state.targetCount);
      assert.deepEqual(state.conservation, {total: 12, consistent: true, completedConsistent: true});
      assert.ok(state.completedAt);
    });

    test("sending(処理中)はsendingとして返り、completedにならない。leaseの有効・期限切れもitemに出る", async () => {
      await importBatch("batchA", 4);
      await create("batchA");
      const engine = createWinnerSendApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp(), generateQrPng, getAppBaseUrl: () => APP_BASE_URL,
        getTransport: () => transport, engineOptions: {now: () => Date.now(), leaseMs: 60000}}).engine;
      const claimed = await engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      assert.equal(claimed.claimed, true);
      const {job, items} = await jobOf("winner-batchA", {itemStatus: "sending"});
      assert.deepEqual(job.counts, {pending: 3, sending: 1, sent: 0, failed: 0, unknown: 0});
      assert.equal(job.status, "ready");
      assert.deepEqual(items.map((i) => [i.participantId, i.status, i.leaseActive]), [["batchA-000002", "sending", true]]);
      await db.doc("mailDeliveries/batchA-000002_winner").update({leaseUntil: new Date(Date.now() - 1000)});
      await db.doc("sendJobs/winner-batchA/items/batchA-000002").update({leaseUntil: new Date(Date.now() - 1000)});
      assert.equal((await jobOf("winner-batchA", {itemStatus: "sending"})).items[0].leaseActive, false);
    });

    test("参加者の一覧は participantId・表示名・状態だけ(メールアドレス・lease・claimIdは返さない)。状態で絞り込める", async () => {
      await importBatch("batchA", 6);
      await create("batchA");
      behavior = (message) => (message.metadata.participantId === "batchA-000004" ? {outcome: "unknown", errorCode: "timeout"} : message.metadata.participantId === "batchA-000005" ? {outcome: "failed", errorCode: "mail-api-400"} : {outcome: "sent", messageId: "m"});
      await processAll("winner-batchA");
      const all = await jobOf();
      assert.equal(all.items.length, 6);
      assert.deepEqual(all.items.map((i) => i.participantId), [...all.items.map((i) => i.participantId)].sort());
      const stored = await get("participants/batchA-000002");
      assert.equal(all.items[0].name, stored.name);
      const text = JSON.stringify(all);
      assert.ok(!text.includes(stored.email) && !text.includes("example.invalid") && !text.includes("claimId") && !text.includes("messageId"));
      for (const item of all.items) assert.ok(Object.keys(item).every((k) => ["participantId", "name", "status", "attemptCount", "lastErrorCode", "leaseActive"].includes(k)));
      const failed = await jobOf("winner-batchA", {itemStatus: "failed"});
      const unknown = await jobOf("winner-batchA", {itemStatus: "unknown"});
      assert.deepEqual(failed.items.map((i) => [i.participantId, i.status, i.lastErrorCode]), [["batchA-000005", "failed", "mail-api-400"]]);
      assert.deepEqual(unknown.items.map((i) => [i.participantId, i.status, i.lastErrorCode]), [["batchA-000004", "unknown", "timeout"]]);
    });

    test("参加者の一覧はページングでき、全件を過不足なく取得できる(100件)", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      await create("batchA");
      const seen = [];
      let after;
      let pages = 0;
      do {
        const page = await jobOf("winner-batchA", {limit: 30, ...(after ? {after} : {})});
        seen.push(...page.items.map((i) => i.participantId));
        after = page.nextAfter;
        pages += 1;
      } while (after);
      assert.equal(pages, 4);
      assert.equal(seen.length, 100);
      assert.equal(new Set(seen).size, 100, "重複も欠落もない");
      assert.equal((await jobOf()).job.targetCount, 100);
    });

    test("失敗分だけ再送: failedだけがpendingに戻り、sent・unknownは不変。再取得した状態に反映される", async () => {
      await importBatch("batchA", 8);
      await create("batchA");
      const failing = new Set(["batchA-000003", "batchA-000005"]);
      behavior = (message) => {
        const id = message.metadata.participantId;
        if (failing.has(id)) return {outcome: "failed", errorCode: "mail-api-400"};
        if (id === "batchA-000004") return {outcome: "unknown", errorCode: "timeout"};
        return {outcome: "sent", messageId: `mid-${id}`};
      };
      await processAll("winner-batchA");
      assert.deepEqual((await jobOf()).job.counts, {pending: 0, sending: 0, sent: 5, failed: 2, unknown: 1});
      failing.clear();
      const retried = await api.retry(asAdmin({jobId: "winner-batchA"}));
      assert.equal(retried.retried, 2);
      const mid = (await jobOf()).job;
      assert.deepEqual(mid.counts, {pending: 2, sending: 0, sent: 5, failed: 0, unknown: 1});
      assert.equal(mid.status, "ready", "再送待ちがあるのでcompletedではない");
      const sentBefore = sends.length;
      await processAll("winner-batchA");
      assert.deepEqual(sends.slice(sentBefore).map((m) => m.metadata.participantId).sort(), ["batchA-000003", "batchA-000005"], "失敗した2件だけ");
      const done = (await jobOf()).job;
      assert.deepEqual(done.counts, {pending: 0, sending: 0, sent: 7, failed: 0, unknown: 1}, "unknownは変わらない");
      assert.equal(done.status, "completed");
      assert.deepEqual(done.conservation, {total: 8, consistent: true, completedConsistent: true});
    });

    test("保存則の不一致(件数の合計が対象数と違う)は conservation.consistent=false で検知できる(完了扱いにしない材料)", async () => {
      await importBatch("batchA", 5);
      await create("batchA");
      // 何らかの不具合でitemが1件失われた状態を作る
      await db.doc("sendJobs/winner-batchA/items/batchA-000002").delete();
      const state = (await jobOf()).job;
      assert.deepEqual(state.conservation, {total: 4, consistent: false, completedConsistent: true});
      assert.equal(state.targetCount, 5);
      // completedと記録されているのに、pendingが残っている不整合も検知できる
      await db.doc("sendJobs/winner-batchA").update({status: "completed"});
      const inconsistent = (await jobOf()).job;
      assert.equal(inconsistent.conservation.completedConsistent, false);
    });

    test("応答が届かなかった場合の復元: 作成後に一覧を再取得すると既存ジョブが分かり、再作成は既存ジョブを返す(新規作成・二重送信にならない)", async () => {
      await importBatch("batchA", 7);
      await create("batchA", {expectedTemplateVersion: 3}); // 応答は捨てる(ブラウザが受け取れなかった)
      const restored = rowOf(await list(), "batchA");
      assert.equal(restored.job.jobId, "winner-batchA");
      assert.equal(restored.canCreateJob, false);
      assert.deepEqual(restored.job.counts, {pending: 7, sending: 0, sent: 0, failed: 0, unknown: 0});
      const again = await create("batchA", {expectedTemplateVersion: 3});
      assert.equal(again.alreadyExisted, true);
      assert.equal((await docs("sendJobs")).length, 1);
      assert.equal((await docs("mailDeliveries")).length, 7);
      // 処理の応答が失われても、サーバーの状態が正本: 再取得すると送信済みが分かり、再処理しても再送されない
      await processAll("winner-batchA");
      const sentOnce = sends.length;
      const reloaded = (await api.job(asAdmin({jobId: "winner-batchA"}))).job;
      assert.deepEqual([reloaded.status, reloaded.counts.sent], ["completed", 7]);
      await processAll("winner-batchA");
      assert.equal(sends.length, sentOnce, "sentは再送されない");
    });

    test("連続して作成を要求しても(ダブルクリック相当・並行)、ジョブは1つ・配送記録はparticipantあたり1件", async () => {
      await importBatch("batchA", 20);
      const results = await Promise.all(Array.from({length: 5}, () => create("batchA", {expectedTemplateVersion: 3}).catch((e) => e)));
      assert.ok(results.some((r) => r.jobId === "winner-batchA"));
      assert.equal((await docs("sendJobs")).length, 1);
      assert.equal((await docs("mailDeliveries")).length, 20);
      assert.equal((await docs("sendJobs/winner-batchA/items")).length, 20);
      // 後から作成を再実行すれば、欠落なく完成している(並行の一部が待たされた場合も含む)
      const done = await create("batchA", {expectedTemplateVersion: 3});
      assert.deepEqual([done.status, done.targetCount, done.pendingCount], ["ready", 20, 20]);
    });

    test("同一メール100participantのジョブで、全員が1通ずつ送られ、100 sent でcompleted(UIの対象100と一致)", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      assert.equal(rowOf(await list(), "batchA").targetCount, 100);
      await create("batchA", {expectedTemplateVersion: 3});
      await processAll("winner-batchA", {limit: 200});
      assert.equal(sends.length, 100);
      const state = (await api.job(asAdmin({jobId: "winner-batchA"}))).job;
      assert.deepEqual([state.status, state.targetCount, state.counts.sent], ["completed", 100, 100]);
    });
  });

  test("外部通信0件: Emulator以外へのfetchは一度も行われない(送信は偽のtransportのみ)", async () => {
    await importBatch("batchA", 5);
    await create("batchA");
    await processAll("winner-batchA");
    await list();
    assert.deepEqual(externalCalls, []);
  });
});
