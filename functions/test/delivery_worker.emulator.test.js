// サーバー側の継続処理(sendJobs.dispatchActive + 定期実行sweep)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続し、メール送信は「偽のtransport」だけを使う。
// SendGrid・Cloud Run mail-apiの実URL、Cloud Tasks等の実サービスへの通信・作成は一切ない。データはすべて架空(メールは予約TLD .invalid)。
//
// 「ブラウザ(Flutter)が処理を呼ばなくても、サーバー側だけで完了する」ことを、process callable(ブラウザが繰り返し呼んでいた入口)を
// 一度も呼ばずに確認する。at-least-once(二重起動・再試行・二重の引き渡し)に対しても、sendJobs/mailDeliveriesの状態で二重送信が起きない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {DELIVERY_LIMITS, HALT} = require("../confirmed/delivery_worker");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const silent = {warn: () => {}};
const APP_BASE_URL = "https://app.invalid";
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const realFetch = globalThis.fetch;
const TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "当選おめでとうございます。", closingBody: "お会いできるのを楽しみにしています。", notesBody: null};

describe("サーバー側の継続処理(Emulator + 実Admin SDK + 偽transport)", {skip: skipReason()}, () => {
  let env;
  let db;
  let send; // createWinnerSendApiの結果(worker・runSweepを含む)
  let api; // 認可つきのcallable
  let sends;
  let behavior;
  let externalCalls;
  let nowMs;
  let capable;
  let transportFactory;
  let processCallableCalls;

  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});
  const transport = {
    async capabilities() { return capable; },
    async send(message) { sends.push(JSON.parse(JSON.stringify(message))); return behavior(message); },
  };
  const get = async (path) => (await db.doc(path).get()).data();
  const docs = async (path) => (await db.collection(path).get()).docs;
  const sentTo = () => sends.reduce((acc, m) => ({...acc, [m.metadata.participantId]: (acc[m.metadata.participantId] || 0) + 1}), {});

  function makeApis(limits = DELIVERY_LIMITS) {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    send = createWinnerSendApi({
      getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL, getTransport: () => transportFactory(),
      engineOptions: {now: () => nowMs, leaseMs: 60000, concurrency: 5},
      workerOptions: {limits: {...DELIVERY_LIMITS, ...limits}},
    });
    const wrap = (handler) => { const callable = confirmedCallable("admin", handler, {db, logger: silent}); return (request) => callable.run(request); };
    api = {
      create: wrap(send.createJob), start: wrap(send.startDelivery), retry: wrap(send.retryFailed), job: wrap(send.getJob),
      // ブラウザが繰り返し呼んでいた処理callable。このテストでは「呼ばれなくても完了する」ことの確認のため、呼び出しを数える。
      process: (request) => { processCallableCalls += 1; return wrap(send.processJob)(request); },
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
  async function importBatch(clientRequestId, tableOrN = 3) {
    const table = typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN;
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table, clientRequestId})});
  }
  const create = (batchId = "batchA") => api.create(asAdmin({eventId: "event1", batchId, expectedTemplateVersion: 3}));
  const start = (jobId = "winner-batchA", actor = asAdmin) => api.start(actor({jobId}));
  const sweep = () => send.runSweep();
  const job = () => get("sendJobs/winner-batchA");
  const view = async (jobId = "winner-batchA") => (await api.job(asAdmin({jobId}))).job;
  // 引き渡しまでを済ませる(ブラウザの操作はここまで)
  async function handOff(n, table) {
    await importBatch("batchA", table || n);
    await create();
    return start();
  }

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
    sends = [];
    behavior = (message) => ({outcome: "sent", messageId: `mid-${message.metadata.participantId}`});
    nowMs = Date.parse("2026-11-01T00:00:00Z");
    capable = {ok: true, missing: []};
    transportFactory = () => transport;
    processCallableCalls = 0;
    makeApis();
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  describe("引き渡し(startConfirmedWinnerMailDelivery)", () => {
    test("未認証は unauthenticated、staffは permission-denied、adminは成功。引き渡しではメールを1通も送らない", async () => {
      await importBatch("batchA", 5);
      await create();
      await rejectsWith(api.start({data: {jobId: "winner-batchA"}}), "unauthenticated");
      await rejectsWith(start("winner-batchA", asStaff), "permission-denied");
      assert.equal((await job()).dispatchActive, undefined, "拒否された要求は何も書かない");
      const result = await start();
      assert.equal(result.dispatchActive, true);
      assert.equal(sends.length, 0, "送信はサーバー側の定期実行が行う(引き渡し自体は送らない)");
      const stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchRequestedBy, stored.dispatchRunCount, stored.dispatchHaltedReason], [true, "u-admin", 0, null]);
      assert.ok(stored.dispatchRequestedAt);
    });

    test("準備中のジョブ・存在しないジョブ・不正な入力・想定外のキーは拒否される", async () => {
      await importBatch("batchA", 3);
      await create();
      await db.doc("sendJobs/winner-batchA").update({status: "preparing"});
      await rejectsWith(start(), "failed-precondition");
      await rejectsWith(start("winner-nothere"), "not-found");
      await rejectsWith(start("bad"), "invalid-argument");
      await rejectsWith(api.start(asAdmin({jobId: "winner-batchA", limit: 5})), "invalid-argument");
      assert.equal((await job()).dispatchActive, undefined);
    });

    test("送るものが無いジョブ(全件sent・failedのみ・unknownのみ)は、有効化されない(終端後に再び動き続けない)", async () => {
      await handOff(5);
      await sweep();
      assert.equal((await job()).status, "completed");
      const again = await start();
      assert.deepEqual([again.nothingToSend, again.dispatchActive], [true, false]);
      assert.equal((await job()).dispatchActive, false);
    });

    test("配送状態の合計が対象数と一致しないジョブは開始できない(保存則)", async () => {
      await importBatch("batchA", 5);
      await create();
      await db.doc("sendJobs/winner-batchA/items/batchA-000002").delete();
      const error = await start().catch((e) => e);
      assert.equal(error.code, "failed-precondition");
      assert.equal(error.details.code, "delivery-count-mismatch");
      assert.equal((await job()).dispatchActive, undefined);
    });

    test("二重の引き渡し(連打・並行)でも有効なジョブは1つで、その後の配送は1件ずつ", async () => {
      await handOff(100);
      const results = await Promise.all(Array.from({length: 5}, () => start().catch((e) => e)));
      assert.ok(results.every((r) => r.dispatchActive === true), "全ての要求が成功(冪等)");
      assert.equal((await docs("sendJobs")).length, 1);
      assert.equal((await job()).dispatchRunCount, 0, "引き渡しの重複で実行回数が増えない");
      await sweep();
      assert.equal(sends.length, 100);
      assert.ok(Object.values(sentTo()).every((n) => n === 1));
    });
  });

  describe("ブラウザが処理を呼ばなくても、サーバー側だけで完了する", () => {
    test("引き渡し後、process callable(ブラウザの処理ループ)を0回しか呼ばずに全件処理され、completedになる", async () => {
      await handOff(100);
      assert.equal(sends.length, 0);
      const results = await sweep();
      assert.equal(processCallableCalls, 0, "ブラウザ側の処理callableは一度も呼んでいない");
      assert.equal(results.length, 1);
      const state = await view();
      assert.equal(state.status, "completed");
      assert.deepEqual(state.counts, {pending: 0, sending: 0, sent: 100, failed: 0, unknown: 0});
      assert.equal(state.targetCount, 100);
      assert.equal(state.conservation.completedConsistent, true);
      assert.equal(sends.length, 100, "100件が100件だけ送信された");
      assert.ok(Object.values(sentTo()).every((n) => n === 1));
      assert.equal(state.dispatch.active, false, "終端で継続処理が止まる");
      assert.ok(state.dispatch.finishedAt);
    });

    test("同一メール100participantでも100件、同一氏名100participantでも100件(人物の重複排除をしない)", async () => {
      await handOff(100, makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      await sweep();
      assert.equal(sends.length, 100);
      assert.equal(new Set(sends.map((m) => m.metadata.participantId)).size, 100);
      assert.equal((await view()).counts.sent, 100);
      await env.clear();
      await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
      await seedEvent();
      sends = [];
      await handOff(100, makeTable(100, () => ({"氏名": "架空同姓同名"})));
      await sweep();
      assert.equal(sends.length, 100);
      assert.equal((await view()).counts.sent, 100);
    });

    test("ブラウザ(polling)が止まっていても配送は継続し、後から状態を取得すれば(別端末・再ログイン相当)結果が分かる", async () => {
      await handOff(30);
      // 状態の取得(ブラウザのpolling)を一切行わないまま、サーバー側の定期実行だけが進む
      await sweep();
      // 後から別の管理者セッションが開く: サーバーの正本から現在状態を復元できる
      const restored = await api.job({auth: {uid: "u-admin"}, data: {jobId: "winner-batchA"}});
      assert.deepEqual([restored.job.status, restored.job.counts.sent, restored.job.dispatch.active], ["completed", 30, false]);
      assert.equal(restored.items.length, 30);
    });

    test("sendJobs・items・mailDeliveriesに、メールアドレス・氏名は保存されず、内部処理の入力はjobIdだけ", async () => {
      await handOff(10);
      await sweep();
      const all = JSON.stringify([...(await docs("sendJobs")), ...(await docs("sendJobs/winner-batchA/items")), ...(await docs("mailDeliveries"))].map((d) => d.data()));
      assert.ok(!all.includes("example.invalid"));
      const stored = await get("participants/batchA-000002");
      assert.ok(!all.includes(stored.name));
      const worker = require("../confirmed/delivery_worker");
      assert.equal(worker.createDeliveryWorker({engine: send.engine, serverTimestamp: () => 0}).runJob.length, 1, "runJobは1つの引数オブジェクト(jobId等)だけを受け取る");
    });
  });

  describe("at-least-once: 二重起動・再試行・中断からの復旧でも二重送信しない", () => {
    test("同じjobに複数のworkerを同時に起動しても、100件を超える配送は発生せず、同じparticipantへ2回送られない", async () => {
      await handOff(100);
      const results = await Promise.all(Array.from({length: 6}, () => send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport})));
      assert.equal(sends.length, 100);
      assert.ok(Object.values(sentTo()).every((n) => n === 1));
      assert.ok(results.some((r) => r.skipped === "worker-active" || r.finished), "job単位のleaseで、無駄な並行処理は避けられる");
      assert.equal((await view()).counts.sent, 100);
    });

    test("job単位のleaseを迂回して並行処理しても(item単位のclaimが最終防御)、二重送信しない: worker×2 + 手動のprocess callable×2", async () => {
      await handOff(100);
      // 別々のworkerIDで、job leaseを無視して並行に走らせる(leaseを直前に消して競合させる)
      const run = async () => { await db.doc("sendJobs/winner-batchA").update({dispatchWorkerId: null, dispatchWorkerLeaseUntil: null}); return send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport}); };
      await Promise.all([run(), run(), api.process(asAdmin({jobId: "winner-batchA", limit: 50})), api.process(asAdmin({jobId: "winner-batchA", limit: 50}))]);
      await sweep();
      assert.equal(sends.length, 100, "100件を超える配送なし");
      assert.ok(Object.values(sentTo()).every((n) => n === 1));
      const state = await view();
      assert.deepEqual([state.status, state.counts.sent, state.counts.pending, state.counts.sending], ["completed", 100, 0, 0]);
    });

    test("同じworker入力(jobId)を何度処理しても安全: 完了前後で繰り返しsweepしても増殖しない", async () => {
      await handOff(50);
      for (let i = 0; i < 4; i += 1) await sweep();
      await send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport});
      await send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport});
      assert.equal(sends.length, 50);
      const state = await view();
      assert.deepEqual([state.status, state.counts.sent, state.dispatch.active], ["completed", 50, false]);
    });

    test("途中(40件処理後)でworkerが異常終了 → 再開後、最初の40件は再送されず、残りだけが処理され、100件分の状態が揃う", async () => {
      makeApis({chunkSize: 10});
      await handOff(100);
      let calls = 0;
      // 41件目以降のsendは結果が返らない(workerのプロセスが死んだ状態を再現: 結果もclaimの解放も行われない)
      behavior = (message) => {
        calls += 1;
        return calls > 40 ? new Promise(() => {}) : {outcome: "sent", messageId: `mid-${message.metadata.participantId}`};
      };
      const dead = send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport});
      await new Promise((resolve) => setTimeout(resolve, 1500)); // 死んだworkerは進まない
      const firstFortyIds = sends.slice(0, 40).map((m) => m.metadata.participantId);
      const inFlight = sends.length - 40; // 結果が返らないまま止まった送信(dispatch済み)
      assert.ok(inFlight >= 1 && inFlight <= 5);
      assert.equal((await view()).counts.sent, 40);
      // 時間が経ち、死んだworkerのjob lease・item leaseが切れた後に、定期実行が再開する
      behavior = (message) => ({outcome: "sent", messageId: `mid-${message.metadata.participantId}`});
      nowMs += 15 * 60 * 1000;
      const dispatchedBefore = sends.length;
      for (let i = 0; i < 4; i += 1) await sweep();
      const after = await view();
      assert.equal(after.status, "completed");
      assert.equal(after.counts.sent + after.counts.failed + after.counts.unknown, 100, "100件分の状態が揃う");
      assert.equal(after.counts.pending + after.counts.sending, 0);
      // dispatch済みで結果不明のものは unknown(自動再送しない)。それ以外の残りだけが処理された
      assert.equal(after.counts.unknown, inFlight);
      assert.equal(after.counts.sent, 100 - inFlight);
      assert.ok(Object.values(sentTo()).every((n) => n === 1), "どのparticipantにも2回は送られない");
      for (const id of firstFortyIds) assert.equal(sentTo()[id], 1, "最初の40件は再送されない");
      assert.equal(sends.length - dispatchedBefore, 100 - 40 - inFlight, "再開後の送信は、残りの未送信分だけ");
      void dead;
    });

    test("dispatch前にworkerが落ちた(確実に未送信)itemは、lease期限後にサーバー側の再実行で送られる(既存の復旧方式)", async () => {
      await handOff(10);
      // 1件をclaimしたまま落ちた(dispatchの記録なし)
      const claim = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      assert.equal(claim.claimed, true);
      await sweep(); // lease有効中は奪わず、他の9件だけ送る
      assert.equal(sends.length, 9);
      assert.ok(!sentTo()["batchA-000002"]);
      assert.equal((await view()).dispatch.active, true, "sendingが残っているので継続");
      nowMs += 2 * 60 * 1000;
      await sweep();
      assert.equal(sentTo()["batchA-000002"], 1);
      assert.equal(sends.length, 10);
      assert.equal((await view()).status, "completed");
    });

    test("sending(lease有効)のitemを別workerが奪わない。lease期限切れでdispatch済みなら unknown(自動再送しない)", async () => {
      await handOff(20);
      await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"}); // A: dispatch前
      const b = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000003"});
      await send.engine.startDispatch({db, jobId: "winner-batchA", participantId: "batchA-000003", claimId: b.claimId}); // B: dispatch済み
      await sweep();
      assert.equal(sends.length, 18);
      assert.ok(!sentTo()["batchA-000002"] && !sentTo()["batchA-000003"], "lease有効中の2件は送られない");
      let state = await view();
      assert.deepEqual([state.counts.sending, state.counts.sent, state.dispatch.active], [2, 18, true]);
      nowMs += 2 * 60 * 1000;
      await sweep();
      state = await view();
      assert.equal(sentTo()["batchA-000002"], 1, "A(未dispatch)は再claimして送信");
      assert.ok(!sentTo()["batchA-000003"], "B(dispatch済みで結果不明)は再送しない");
      assert.deepEqual([state.counts.sent, state.counts.unknown, state.counts.sending, state.status], [19, 1, 0, "completed"]);
      assert.equal((await get("mailDeliveries/batchA-000003_winner")).lastErrorCode, "lease-expired-after-dispatch");
    });
  });

  describe("sent / failed / unknown の扱い(自動再送しない)", () => {
    test("sentは再送されない: 終端後・再起動後・失敗分の管理者再送後のいずれでも", async () => {
      await handOff(20);
      behavior = (m) => (m.metadata.participantId === "batchA-000005" ? {outcome: "failed", errorCode: "mail-api-400"} : {outcome: "sent", messageId: "m"});
      await sweep();
      const before = sends.length;
      await sweep();
      await send.worker.runJob({db, jobId: "winner-batchA", getTransport: () => transport});
      assert.equal(sends.length, before);
      behavior = () => ({outcome: "sent", messageId: "m2"});
      await api.retry(asAdmin({jobId: "winner-batchA"}));
      await start();
      await sweep();
      assert.equal(sends.length - before, 1, "再送されたのは失敗の1件だけ");
      assert.equal(sentTo()["batchA-000005"], 2);
      for (const [id, n] of Object.entries(sentTo())) if (id !== "batchA-000005") assert.equal(n, 1, id);
    });

    test("failedは自動再送されない(サーバー側の継続処理はfailedしか残らなければ終端)。管理者の「失敗分だけ再送」+引き渡しで、failedだけが再処理される", async () => {
      await handOff(12);
      const failing = new Set(["batchA-000003", "batchA-000005"]);
      behavior = (m) => (failing.has(m.metadata.participantId) ? {outcome: "failed", errorCode: "mail-api-400"} : {outcome: "sent", messageId: `mid-${m.metadata.participantId}`});
      await sweep();
      let state = await view();
      assert.deepEqual([state.status, state.counts.failed, state.counts.sent, state.dispatch.active], ["completed", 2, 10, false]);
      const dispatched = sends.length;
      for (let i = 0; i < 3; i += 1) await sweep();
      assert.equal(sends.length, dispatched, "failedを自動再送しない");
      failing.clear();
      const retried = await api.retry(asAdmin({jobId: "winner-batchA"}));
      assert.equal(retried.retried, 2);
      assert.equal(sends.length, dispatched, "retryはpendingへ戻すだけ(送信しない)");
      await start();
      await sweep();
      assert.deepEqual(sends.slice(dispatched).map((m) => m.metadata.participantId).sort(), ["batchA-000003", "batchA-000005"]);
      state = await view();
      assert.deepEqual([state.status, state.counts.sent, state.counts.failed], ["completed", 12, 0]);
    });

    test("unknownは自動再送されず、管理者の失敗分再送の対象にもならない(pendingへ戻らない・failedに変わらない)", async () => {
      await handOff(10);
      behavior = (m) => {
        const id = m.metadata.participantId;
        if (id === "batchA-000004") return {outcome: "unknown", errorCode: "timeout"};
        if (id === "batchA-000006") return {outcome: "failed", errorCode: "mail-api-400"};
        return {outcome: "sent", messageId: `mid-${id}`};
      };
      await sweep();
      const dispatched = sends.length;
      let state = await view();
      assert.deepEqual([state.status, state.counts.unknown, state.counts.failed], ["completed", 1, 1]);
      for (let i = 0; i < 3; i += 1) await sweep();
      behavior = () => ({outcome: "sent", messageId: "later"});
      await api.retry(asAdmin({jobId: "winner-batchA"}));
      await start();
      await sweep();
      state = await view();
      assert.equal(sentTo()["batchA-000004"], 1, "unknownの参加者へは再送しない");
      assert.equal(sends.length - dispatched, 1, "再送は failed の1件だけ");
      assert.deepEqual([state.counts.unknown, state.counts.failed, state.counts.sent], [1, 0, 9]);
      assert.equal((await get("mailDeliveries/batchA-000004_winner")).status, "unknown");
    });
  });

  describe("継続条件・終端・上限(無限ループ・費用暴走の防止)", () => {
    test("1回の実行の上限(chunk数・時間)に達しても、pendingが残る間は有効なまま次の実行が続きを処理する。全件完了で停止", async () => {
      makeApis({chunkSize: 10, maxChunksPerRun: 3});
      await handOff(100);
      await sweep();
      let state = await view();
      assert.deepEqual([state.counts.sent, state.counts.pending, state.dispatch.active, state.status], [30, 70, true, "ready"]);
      assert.ok(sends.length <= 30, "1回の実行はchunk数の上限まで");
      let runs = 1;
      while ((await view()).dispatch.active && runs < 20) { await sweep(); runs += 1; }
      state = await view();
      assert.equal(runs, 4, "10+10+... : 30+30+30+10");
      assert.deepEqual([state.status, state.counts.sent, state.dispatch.active], ["completed", 100, false]);
      assert.equal(sends.length, 100);
    });

    test("時間の上限(runBudgetMs)に達したら、新しいchunkを始めず次の実行へ引き継ぐ", async () => {
      makeApis({chunkSize: 10, maxChunksPerRun: 30, runBudgetMs: 5000});
      await handOff(50);
      behavior = (m) => { nowMs += 3000; return {outcome: "sent", messageId: `mid-${m.metadata.participantId}`}; };
      await sweep();
      const state = await view();
      assert.ok(state.counts.sent > 0 && state.counts.pending > 0, "途中で引き継ぎ");
      assert.equal(state.dispatch.active, true);
      assert.equal((await job()).dispatchLastNote, "run-budget-reached");
    });

    test("終端(pending・sendingが0)になったら継続処理を止め、以後のsweepはそのジョブに何もしない(書込みも通信もしない)", async () => {
      await handOff(10);
      await sweep();
      const finished = JSON.stringify(await job());
      let transportBuilt = 0;
      transportFactory = () => { transportBuilt += 1; return transport; };
      const results = await sweep();
      assert.deepEqual(results, [], "有効なジョブが無ければ何も処理しない");
      assert.equal(transportBuilt, 0, "mail-apiのSecret・transportも使わない");
      assert.equal(JSON.stringify(await job()), finished);
    });

    test("保存則が壊れたら completed にせず停止する(conservation-violated)。以後は再処理されない", async () => {
      await handOff(10);
      await db.doc("sendJobs/winner-batchA/items/batchA-000002").delete(); // 何らかの不具合でitemが失われた
      await db.doc("sendJobs/winner-batchA").update({dispatchRequestSeq: 1}); // (開始後にitemが失われた状態)
      await sweep();
      const stored = await job();
      assert.notEqual(stored.status, "completed");
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.CONSERVATION]);
      const dispatched = sends.length;
      await sweep();
      await sweep();
      assert.equal(sends.length, dispatched, "停止後は再処理・再実行されない");
    });

    test("mail-apiがQR付きメールに対応していない/確認できない場合は fail-closed(1通も送らない)。進捗なしが続けば停止し、無限に続かない", async () => {
      makeApis({maxNoProgressRuns: 3});
      await handOff(10);
      capable = {ok: false, missing: ["html"]};
      for (let i = 0; i < 2; i += 1) await sweep();
      assert.equal(sends.length, 0);
      assert.equal((await job()).dispatchActive, true, "上限に達するまでは継続(一時的な不調かもしれない)");
      await sweep();
      const stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.NO_PROGRESS]);
      assert.equal(sends.length, 0);
      const calls = sends.length;
      await sweep();
      await sweep();
      assert.equal(sends.length, calls);
      // 管理者が原因を直して再度引き渡せば、再開できる(自動では再開しない)
      capable = {ok: true, missing: []};
      const restarted = await start();
      assert.equal(restarted.dispatchActive, true);
      const after = await job();
      assert.deepEqual([after.dispatchHaltedReason, after.dispatchRunCount, after.dispatchNoProgressRuns], [null, 0, 0]);
      await sweep();
      assert.equal(sends.length, 10);
      assert.equal((await view()).status, "completed");
    });

    test("transportを作れない(設定・Secretが欠けている)場合も、送信せず、進捗なしとして数えて停止する", async () => {
      makeApis({maxNoProgressRuns: 2});
      await handOff(5);
      transportFactory = () => { throw new Error("mail api key required"); };
      await sweep();
      await sweep();
      assert.equal(sends.length, 0);
      const stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.NO_PROGRESS]);
      assert.equal(stored.dispatchLastNote, "transport-unavailable");
    });

    test("sendingのleaseが切れない間に何度実行されても、実行回数の上限(maxRunsPerActivation)で停止する", async () => {
      makeApis({maxRunsPerActivation: 3, maxNoProgressRuns: 100});
      await handOff(5);
      await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      for (let i = 0; i < 5; i += 1) await sweep();
      const stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.RUN_LIMIT]);
      assert.equal(stored.dispatchRunCount, 3, "上限を超えて実行されない");
    });

    test("イベントがconfirmedでなくなった・ジョブが準備完了でない場合は、送信せず停止する", async () => {
      await handOff(5);
      await db.doc("events/event1").update({flow: "legacy"});
      await sweep();
      let stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.EVENT_NOT_CONFIRMED]);
      assert.equal(sends.length, 0);
      await db.doc("events/event1").update({flow: "confirmed"});
      await db.doc("sendJobs/winner-batchA").update({dispatchActive: true, dispatchHaltedReason: null, status: "preparing"});
      await sweep();
      stored = await job();
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, HALT.JOB_NOT_READY]);
      assert.equal(sends.length, 0);
    });

    test("1回のsweepで扱うジョブ数にも上限がある(maxJobsPerSweep)", async () => {
      makeApis({maxJobsPerSweep: 1});
      await importBatch("batchA", 3);
      await importBatch("batchB", 3);
      await create("batchA");
      await create("batchB");
      await start("winner-batchA");
      await start("winner-batchB");
      const results = await sweep();
      assert.equal(results.length, 1);
    });

    test("定数は1か所(DELIVERY_LIMITS)に集約され、変更できない(凍結)", () => {
      assert.ok(Object.isFrozen(DELIVERY_LIMITS));
      assert.deepEqual(Object.keys(DELIVERY_LIMITS).sort(), ["chunkSize", "maxChunksPerRun", "maxJobsPerSweep", "maxNoProgressRuns", "maxRunsPerActivation", "runBudgetMs", "workerLeaseMs"]);
      assert.ok(DELIVERY_LIMITS.chunkSize <= 200, "従来の1回最大200件を超えない");
      assert.ok(DELIVERY_LIMITS.runBudgetMs < 300000, "関数のタイムアウト(300秒)より手前で新しいchunkを止める");
    });
  });

  test("外部通信0件: Emulator以外へのfetchは一度も行われない(送信は偽のtransportのみ。Cloud Tasks等も使わない)", async () => {
    await handOff(20);
    await sweep();
    assert.deepEqual(externalCalls, []);
  });
});
