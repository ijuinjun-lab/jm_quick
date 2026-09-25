// 前日リマインド(confirmed)の統合テスト。ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続し、
// メール送信は「偽のtransport」だけを使う。SendGrid・Cloud Run mail-apiの実URL・Cloud Tasks等への通信・作成は一切ない。
// データはすべて架空(メールは予約TLD .invalid)。実CSVの参加者は使わない。
//
// 対象はイベント全体の全active participant(取込回は問わない)。当選メールとは別のtype・job・配送記録・テンプレート。
// 配送はPhase 9Aのサーバー側継続処理(sweep)を再利用し、ブラウザ(Flutter)の処理呼び出しは一切ない。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {createReminderApi} = require("../confirmed/reminder_api");
const {DELIVERY_LIMITS} = require("../confirmed/delivery_worker");
const {buildMailSnapshot} = require("../confirmed/mail_view_model");
const {renderWinnerMail, renderReminderMail} = require("../confirmed/mail_render");
const {loadAttendances} = require("../confirmed/winner_mail_message");
const {receptionQrPayload} = require("../confirmed/pass_urls");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const silent = {warn: () => {}, info: () => {}};
const APP_BASE_URL = "https://app.invalid";
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const realFetch = globalThis.fetch;
const WINNER_TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "当選おめでとうございます。", closingBody: "お会いできるのを楽しみにしています。", notesBody: null};
const REMINDER_TEMPLATE = {subject: "【明日開催】架空イベントのご案内", introBody: "いよいよ明日です。", closingBody: "お気をつけてお越しください。", notesBody: "雨天決行です。"};
const T0 = Date.parse("2026-11-29T01:00:00Z"); // 送信予定日時(JST 10:00)
const EVENT_START = "2026-11-30T01:00:00Z";
const EVENT_END = "2026-11-30T07:00:00Z";

describe("前日リマインド(Emulator + 実Admin SDK + 偽transport)", {skip: skipReason()}, () => {
  let env;
  let db;
  let send; // 当選メールのAPI(配送エンジン・worker・sweepを含む)
  let reminder; // 前日リマインドのAPI
  let api; // 認可つきのcallable
  let sends;
  let behavior;
  let externalCalls;
  let nowMs;
  let capable;
  let transportFactory;

  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});
  const transport = {
    async capabilities() { return capable; },
    async send(message) { sends.push(JSON.parse(JSON.stringify(message))); return behavior(message); },
  };
  const get = async (path) => (await db.doc(path).get()).data();
  const docs = async (path) => (await db.collection(path).get()).docs;
  const remindersSent = () => sends.filter((m) => m.metadata.type === "reminder");
  const perParticipant = (list) => list.reduce((acc, m) => ({...acc, [m.metadata.participantId]: (acc[m.metadata.participantId] || 0) + 1}), {});

  function makeApis(limits = DELIVERY_LIMITS) {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    send = createWinnerSendApi({
      getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL, getTransport: () => transportFactory(),
      engineOptions: {now: () => nowMs, leaseMs: 60000, concurrency: 5},
      workerOptions: {limits: {...DELIVERY_LIMITS, ...limits}},
    });
    reminder = createReminderApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL, winnerSendApi: send, now: () => nowMs, logger: silent});
    const winnerMail = createWinnerMailApi({getDb: () => db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL});
    const wrap = (handler) => { const callable = confirmedCallable("admin", handler, {db, logger: silent}); return (request) => callable.run(request); };
    api = {
      settings: wrap(reminder.getSettings), update: wrap(reminder.updateSettings), preview: wrap(reminder.preview), start: wrap(reminder.startDelivery),
      job: wrap(reminder.getJob), retry: wrap(reminder.retryFailed),
      winnerPreview: wrap(winnerMail.preview), winnerCreate: wrap(send.createJob), winnerStart: wrap(send.startDelivery), winnerUpdateTemplate: wrap(winnerMail.updateTemplate),
    };
  }

  async function seedEvent(overrides = {}) {
    const event = {
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date(EVENT_START)), endAt: env.Timestamp.fromDate(new Date(EVENT_END)),
      venue: "架空会場ホール", contact: "架空事務局", venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
      programs: [{programId: "gamma", name: "トークセッション", order: 2}, {programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}],
      winnerMailTemplate: {...WINNER_TEMPLATE, version: 3, updatedBy: "u-admin"},
      reminderMailTemplate: {...REMINDER_TEMPLATE, version: 2, updatedBy: "u-admin"},
      reminderEnabled: true, reminderSendAt: env.Timestamp.fromMillis(T0),
      ...overrides,
    };
    for (const key of Object.keys(event)) if (event[key] === undefined) delete event[key];
    await db.collection("events").doc("event1").set(event);
  }
  const importApi = () => createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
  async function importBatch(clientRequestId, tableOrN = 3) {
    const table = typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN;
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table, clientRequestId})});
  }
  const JOB = "reminder-event1";
  const job = () => get(`sendJobs/${JOB}`);
  const jobItems = () => docs(`sendJobs/${JOB}/items`);
  const reconcile = () => reminder.reconcileDue({limit: 5});
  const sweep = () => send.runSweep();
  // 送信時刻に達し、定期実行が「ジョブ作成 → 引き渡し → 配送」を行う(ブラウザは一切関与しない)
  async function due(times = 1) {
    nowMs = T0;
    for (let i = 0; i < times; i += 1) { await reconcile(); await sweep(); }
  }
  const view = async () => (await api.job(asAdmin({eventId: "event1"}))).job;

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
    nowMs = T0 - 24 * 3600 * 1000;
    capable = {ok: true, missing: []};
    transportFactory = () => transport;
    makeApis();
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  // ---------------------------------------------------------------------------------------------
  describe("自動でジョブを作る条件(Scheduler)", () => {
    test("confirmedイベントだけが対象。legacy・flow未設定・未知のflowでは、有効でもジョブを作らない", async () => {
      await importBatch("batchA", 3);
      for (const flow of ["legacy", "confirmd", undefined]) {
        await seedEvent({flow});
        nowMs = T0;
        await reconcile();
        assert.equal((await docs("sendJobs")).length, 0, String(flow));
      }
      await seedEvent();
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 1);
    });

    test("reminderEnabled=false(既定)ならジョブを作らない。送信予定日時を過ぎていても", async () => {
      await importBatch("batchA", 3);
      for (const enabled of [false, undefined]) {
        await seedEvent({reminderEnabled: enabled});
        nowMs = T0 + 3600 * 1000;
        await reconcile();
        await sweep();
      }
      assert.equal((await docs("sendJobs")).length, 0);
      assert.equal(sends.length, 0);
    });

    test("送信予定日時の1秒前はジョブなし、ちょうどの時刻で作成、以後の再実行では新規作成なし(絶対時刻で比較)", async () => {
      await importBatch("batchA", 5);
      nowMs = T0 - 1000;
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 0, "1秒前");
      nowMs = T0;
      const first = await reconcile();
      assert.deepEqual(first.created, [JOB], "ちょうど");
      const created = await job();
      nowMs = T0 + 1000;
      await reconcile();
      nowMs = T0 + 3600 * 1000;
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 1, "後の再実行では新規作成なし");
      assert.equal((await job()).createdAt.toMillis(), created.createdAt.toMillis());
    });

    test("送信予定日時が未設定・イベント終了後・対象が0件・文面未設定なら、ジョブを作らない(勝手に補完しない)", async () => {
      await importBatch("batchA", 3);
      await seedEvent({reminderSendAt: undefined});
      nowMs = T0;
      await reconcile();
      await seedEvent();
      nowMs = Date.parse(EVENT_END) + 1000;
      await reconcile();
      await seedEvent({reminderMailTemplate: undefined});
      nowMs = T0;
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 0);
      await env.clear();
      await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
      await seedEvent();
      nowMs = T0;
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 0, "対象0件");
    });

    test("Schedulerを2回・10回・100回相当(並行を含む)実行しても、ジョブは1つ・itemはtargetCount・sentの再送なし", async () => {
      await importBatch("batchA", 12);
      nowMs = T0;
      await Promise.all(Array.from({length: 5}, () => reconcile()));
      for (const times of [2, 10, 100]) {
        for (let i = 0; i < times; i += 1) await reconcile();
        assert.equal((await docs("sendJobs")).length, 1, `${times}回`);
        assert.equal((await jobItems()).length, 12);
        assert.equal((await docs("mailDeliveries")).length, 12);
      }
      await sweep();
      const sentOnce = sends.length;
      assert.equal(sentOnce, 12);
      for (let i = 0; i < 10; i += 1) { await reconcile(); await sweep(); }
      assert.equal(sends.length, sentOnce, "sentの再送なし");
      assert.equal((await job()).targetCount, 12);
    });

    test("ジョブIDは決定的(reminder-{eventId})で、当選メールのジョブ(winner-{batchId})と別", async () => {
      await importBatch("batchA", 3);
      await due();
      assert.deepEqual((await docs("sendJobs")).map((d) => d.id), [JOB]);
      assert.equal((await job()).type, "reminder");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("対象者: イベント全体の全active participant(取込回を問わない)", () => {
    test("複数のcommitted batchを横断して対象にする(第1回90・第2回43・第3回17 = 150)", async () => {
      await importBatch("batchA", 90);
      await importBatch("batchB", 43);
      await importBatch("batchC", 17);
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual([settings.targets.targetCount, settings.targets.excludedCount, settings.targets.totalParticipants], [150, 0, 150]);
      nowMs = T0;
      await reconcile();
      const created = await job();
      assert.equal(created.targetCount, 150);
      assert.equal((await jobItems()).length, 150);
      assert.equal((await docs("mailDeliveries")).length, 150);
    });

    test("A: 同一メールのactive participant 100件 → targetCount 100・100の配送状態・欠落0", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      await due();
      const state = await view();
      assert.deepEqual([state.targetCount, state.counts.sent, state.status], [100, 100, "completed"]);
      assert.equal((await jobItems()).length, 100);
      assert.equal(remindersSent().length, 100);
      assert.equal(new Set(remindersSent().map((m) => m.metadata.participantId)).size, 100, "欠落0・重複0");
    });

    test("B: 同一氏名のactive participant 100件 → targetCount 100・100の配送状態・欠落0", async () => {
      await importBatch("batchA", makeTable(100, () => ({"氏名": "架空同姓同名", "rd": "R-SAME"})));
      await due();
      const state = await view();
      assert.deepEqual([state.targetCount, state.counts.sent, state.status], [100, 100, "completed"]);
      assert.equal(new Set(remindersSent().map((m) => m.metadata.participantId)).size, 100);
    });

    test("C: 複数batch(第1回40・第2回35・第3回25)がすべてcommitted・active → targetCount 100(batch境界による欠落なし)", async () => {
      await importBatch("batchA", 40);
      await importBatch("batchB", 35);
      await importBatch("batchC", 25);
      await due();
      const state = await view();
      assert.deepEqual([state.targetCount, state.counts.sent, state.status], [100, 100, "completed"]);
      const ids = new Set(remindersSent().map((m) => m.metadata.participantId));
      for (const [prefix, n] of [["batchA", 40], ["batchB", 35], ["batchC", 25]]) {
        assert.equal([...ids].filter((id) => id.startsWith(prefix)).length, n, prefix);
      }
    });

    test("cancelled・inactiveは対象外(対象外の件数と理由が分かる)。同じメールの別participantは対象のまま", async () => {
      await importBatch("batchA", 10);
      await db.doc("participants/batchA-000002").update({status: "cancelled"});
      await db.doc("participants/batchA-000003").update({status: "inactive"});
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual([settings.targets.targetCount, settings.targets.excludedCount, settings.targets.excludedByReason], [8, 2, {inactive: 2}]);
      await due();
      assert.equal((await job()).targetCount, 8);
      assert.equal((await job()).excludedInactiveCount, 2);
      assert.ok(!perParticipant(remindersSent())["batchA-000002"] && !perParticipant(remindersSent())["batchA-000003"]);
    });

    test("committing・failedのbatch由来のparticipantは対象外。committedのbatchの参加者だけ", async () => {
      await importBatch("batchA", 5);
      await importBatch("batchB", 4);
      await importBatch("batchC", 3);
      await db.doc("importBatches/batchB").update({status: "committing"});
      await db.doc("importBatches/batchC").update({status: "failed"});
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual([settings.targets.targetCount, settings.targets.excludedCount, settings.targets.excludedByReason], [5, 7, {"batch-not-committed": 7}]);
      await due();
      assert.equal((await job()).targetCount, 5);
      assert.ok([...Object.keys(perParticipant(remindersSent()))].every((id) => id.startsWith("batchA")));
    });

    test("別イベント・schemaVersionが2でないparticipantは対象にならない", async () => {
      await importBatch("batchA", 4);
      await db.doc("participants/batchA-000002").update({schemaVersion: 1});
      await db.collection("participants").doc("other-000002").set({participantId: "other-000002", eventId: "event2", status: "active", schemaVersion: 2, name: "別イベント", email: "o@example.invalid", publicId: "pub_" + "z".repeat(30)});
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual([settings.targets.targetCount, settings.targets.excludedByReason], [3, {"not-confirmed": 1}]);
    });

    test("targetCountはジョブ作成時に固定される。作成後にparticipantを追加・変更しても既存ジョブは変わらず、管理画面で差分が分かる", async () => {
      await importBatch("batchA", 10);
      nowMs = T0;
      await reconcile();
      await importBatch("batchB", 5); // 後から追加された第2回
      await db.doc("participants/batchA-000002").update({status: "cancelled"});
      await reconcile();
      await reconcile();
      assert.equal((await job()).targetCount, 10, "既存jobのtargetCountは変わらない");
      assert.equal((await jobItems()).length, 10);
      assert.equal((await docs("mailDeliveries")).length, 10);
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual(settings.changedSinceJob, {currentTargetCount: 14, jobTargetCount: 10, changed: true});
      await sweep();
      // 追加分へは自動送信しない。作成時の対象10件のうち、送信時点でcancelledの1件は「送信不可(failed)」として状態が残る(欠落なし)
      assert.equal(remindersSent().length, 9);
      assert.ok(!Object.keys(perParticipant(remindersSent())).some((id) => id.startsWith("batchB")));
      const state = await view();
      assert.deepEqual([state.targetCount, state.counts.sent, state.counts.failed], [10, 9, 1]);
      assert.equal((await get("mailDeliveries/batchA-000002_reminder")).lastErrorCode, "participant-unavailable");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("テンプレート(当選メールとは別データ・version固定)", () => {
    test("reminderMailTemplateはwinnerMailTemplateとは別。リマインドの更新は当選メールのテンプレートに触れない", async () => {
      const before = await get("events/event1");
      const result = await api.update(asAdmin({eventId: "event1", template: {...REMINDER_TEMPLATE, subject: "【更新】前日のご案内"}}));
      assert.deepEqual([result.templateChanged, result.templateVersion], [true, 3]);
      const event = await get("events/event1");
      assert.equal(event.reminderMailTemplate.subject, "【更新】前日のご案内");
      assert.equal(event.reminderMailTemplate.version, 3);
      assert.deepEqual(event.winnerMailTemplate, before.winnerMailTemplate, "winnerMailTemplateは不変(versionも)");
      // 同じ内容の再送ではversionを進めない
      const again = await api.update(asAdmin({eventId: "event1", template: {...REMINDER_TEMPLATE, subject: "【更新】前日のご案内"}}));
      assert.deepEqual([again.templateChanged, again.templateVersion], [false, 3]);
      // 当選メール側の更新もリマインドに影響しない
      await api.winnerUpdateTemplate(asAdmin({eventId: "event1", template: {...WINNER_TEMPLATE, subject: "当選メールの新件名"}}));
      assert.equal((await get("events/event1")).reminderMailTemplate.version, 3);
      assert.equal((await get("events/event1")).winnerMailTemplate.version, 4);
    });

    test("ジョブ作成時にreminderMailTemplateのversionと文面を固定する。作成後にテンプレートを変更しても、既存jobのメールは変わらない", async () => {
      await importBatch("batchA", 6);
      nowMs = T0;
      await reconcile();
      const created = await job();
      assert.equal(created.templateVersion, 2);
      assert.equal(created.snapshot.template.subject, REMINDER_TEMPLATE.subject);
      await api.update(asAdmin({eventId: "event1", template: {...REMINDER_TEMPLATE, subject: "作成後に変更した件名", introBody: "変更後の冒頭"}}));
      assert.equal((await get("events/event1")).reminderMailTemplate.version, 3);
      await sweep();
      assert.equal((await job()).templateVersion, 2);
      assert.equal(remindersSent().length, 6);
      assert.ok(remindersSent().every((m) => m.subject === REMINDER_TEMPLATE.subject && m.text.includes("いよいよ明日です。") && !m.text.includes("変更後の冒頭")));
      assert.ok((await docs("mailDeliveries")).every((d) => d.data().templateVersion === 2));
    });

    test("自動・手動のどちらの入口でも、同じversion固定を通る。確認したversion・対象人数と違えば手動開始は作成しない", async () => {
      await importBatch("batchA", 5);
      const error = await api.start(asAdmin({eventId: "event1", expectedTemplateVersion: 1, expectedTargetCount: 5})).catch((e) => e);
      assert.equal(error.details.code, "template-version-changed");
      const error2 = await api.start(asAdmin({eventId: "event1", expectedTemplateVersion: 2, expectedTargetCount: 9})).catch((e) => e);
      assert.equal(error2.details.code, "target-count-changed");
      assert.equal((await docs("sendJobs")).length, 0, "確認と違う内容ではジョブを作らない");
      const started = await api.start(asAdmin({eventId: "event1", expectedTemplateVersion: 2, expectedTargetCount: 5}));
      assert.deepEqual([started.jobId, started.templateVersion, started.targetCount, started.dispatchActive], [JOB, 2, 5, true]);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("当選メールと同じQR・Web参加証・参加内容(再発行なし)", () => {
    test("winnerとreminderで、QR payload・Web参加証URL・program名・時間・plannedCountが同一。publicIdは変わらない", async () => {
      await importBatch("batchA", 4);
      const event = await get("events/event1");
      const winnerSnapshot = buildMailSnapshot("event1", event);
      const reminderSnapshot = buildMailSnapshot("event1", event, {templateField: "reminderMailTemplate"});
      assert.ok(winnerSnapshot.ok && reminderSnapshot.ok);
      const before = await get("participants/batchA-000002");
      const attendances = await loadAttendances(db, "batchA-000002", "event1");
      const participant = {participantId: "batchA-000002", name: before.name, publicId: before.publicId};
      const winner = await renderWinnerMail({snapshot: winnerSnapshot.snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng});
      const remind = await renderReminderMail({snapshot: reminderSnapshot.snapshot, participant, attendances, appBaseUrl: APP_BASE_URL, generateQrPng});
      assert.ok(winner.ok && remind.ok);
      assert.equal(remind.qrPayload, winner.qrPayload);
      assert.equal(remind.qrPayload, receptionQrPayload({appBaseUrl: APP_BASE_URL, eventId: "event1", participantId: "batchA-000002", publicId: before.publicId}), "受付QRの正本(Phase 6)");
      assert.equal(remind.webPassUrl, winner.webPassUrl);
      assert.deepEqual(remind.viewModel.programs, winner.viewModel.programs, "program名・時間・plannedCountは同じview model");
      assert.equal(remind.attachments[0].contentBase64, winner.attachments[0].contentBase64, "QR画像も同一(再発行なし)");
      assert.notEqual(remind.subject, winner.subject, "文章だけが別テンプレート");
      assert.deepEqual(await get("participants/batchA-000002"), before, "参加者・publicIdは変更されない");
    });

    test("実際に送信された当選メールとリマインドで、同じparticipantのQR画像・Web参加証URL・受付内容が同一(1つのQR・1つの参加証)", async () => {
      await importBatch("batchA", 5);
      await api.winnerCreate(asAdmin({eventId: "event1", batchId: "batchA", expectedTemplateVersion: 3}));
      await api.winnerStart(asAdmin({jobId: "winner-batchA"}));
      await sweep(); // 当選メール(サーバー側継続配送)
      await due();
      const winners = sends.filter((m) => m.metadata.type === "winner");
      assert.equal(winners.length, 5);
      assert.equal(remindersSent().length, 5);
      for (const w of winners) {
        const r = remindersSent().find((m) => m.metadata.participantId === w.metadata.participantId);
        assert.ok(r, "同じparticipantへ");
        assert.equal(r.attachments[0].contentBase64, w.attachments[0].contentBase64);
        const url = (m) => m.text.match(/https:\/\/app\.invalid\/p\/[^\s]+/)[0];
        assert.equal(url(r), url(w));
        assert.equal(r.to, w.to);
        // 参加内容(program・時間・人数)の行が同じ
        for (const line of w.text.split("\n").filter((l) => /^(■|参加時間：|参加人数：)/.test(l))) assert.ok(r.text.includes(line), line);
      }
    });

    test("前日リマインドの本文: 参加者名・イベント名・開催日・会場・住所・アクセス・program・時間・人数・QR・Web参加証URL・注意事項・締め文・問い合わせ先", async () => {
      await importBatch("batchA", 3);
      const preview = await api.preview(asAdmin({eventId: "event1", participantId: "batchA-000002"}));
      assert.equal(preview.ready, true);
      assert.equal(preview.templateVersion, 2);
      const participant = await get("participants/batchA-000002");
      for (const part of [`${participant.name} 様`, "【架空イベント】", "2026年11月30日(月) 10:00〜16:00", "架空会場ホール", "架空県架空市1-2-3", "架空駅から徒歩5分",
        "プログラムA", "トークセッション", "参加時間：", "参加人数：", "受付用QRコードが表示できない場合はこちら", preview.webPassUrl, "雨天決行です。", "お気をつけてお越しください。", "架空事務局", "いよいよ明日です。"]) {
        assert.ok(preview.text.includes(part), `text: ${part}`);
      }
      assert.ok(preview.html.includes("cid:jm-quick-reception-qr") && preview.html.includes("架空イベント"));
      assert.equal(preview.subject, REMINDER_TEMPLATE.subject);
      assert.ok(preview.qrPngBase64.length > 100);
    });

    test("プレビューは対象のparticipantだけ(cancelled・committing由来は拒否)。文面が不完全なら理由を返す", async () => {
      await importBatch("batchA", 3);
      await importBatch("batchB", 2);
      await db.doc("participants/batchA-000003").update({status: "cancelled"});
      await db.doc("importBatches/batchB").update({status: "committing"});
      for (const id of ["batchA-000003", "batchB-000002", "nothere-000002"]) {
        assert.equal((await api.preview(asAdmin({eventId: "event1", participantId: id})).catch((e) => e)).details.code, "participant-not-target", id);
      }
      await db.doc("events/event1").update({reminderMailTemplate: env.FieldValue.delete()});
      const notReady = await api.preview(asAdmin({eventId: "event1", participantId: "batchA-000002"}));
      assert.equal(notReady.ready, false);
      assert.ok(notReady.problems.length > 0);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("当選メールとの分離", () => {
    test("winnerとreminderのmailDeliveriesは別(IDも別)。winner送信済みでもreminderの対象になり、reminderの結果はwinnerの状態を変えない", async () => {
      await importBatch("batchA", 8);
      await api.winnerCreate(asAdmin({eventId: "event1", batchId: "batchA", expectedTemplateVersion: 3}));
      await api.winnerStart(asAdmin({jobId: "winner-batchA"}));
      await sweep();
      const winnerBefore = JSON.stringify((await docs("mailDeliveries")).filter((d) => d.id.endsWith("_winner")).map((d) => [d.id, d.data()]));
      assert.equal((await get("sendJobs/winner-batchA")).status, "completed");
      // リマインドは一部失敗・unknownでも、winnerの配送状態は変わらない
      behavior = (m) => (m.metadata.participantId === "batchA-000002" ? {outcome: "failed", errorCode: "mail-api-400"} : m.metadata.participantId === "batchA-000003" ? {outcome: "unknown", errorCode: "timeout"} : {outcome: "sent", messageId: "m"});
      await due();
      const ids = (await docs("mailDeliveries")).map((d) => d.id).sort();
      assert.equal(ids.length, 16);
      assert.equal(ids.filter((id) => id.endsWith("_winner")).length, 8);
      assert.equal(ids.filter((id) => id.endsWith("_reminder")).length, 8);
      assert.equal(JSON.stringify((await docs("mailDeliveries")).filter((d) => d.id.endsWith("_winner")).map((d) => [d.id, d.data()])), winnerBefore, "winnerの配送状態は不変");
      const state = await view();
      assert.deepEqual([state.counts.sent, state.counts.failed, state.counts.unknown], [6, 1, 1]);
      assert.equal((await get("mailDeliveries/batchA-000002_winner")).status, "sent");
      assert.equal((await get("mailDeliveries/batchA-000002_reminder")).status, "failed");
      assert.equal((await get("sendJobs/winner-batchA")).status, "completed");
    });

    test("リマインドのジョブ・配送記録は type=reminder / jobId=reminder-{eventId}。旧mailJobsは使わない", async () => {
      await importBatch("batchA", 3);
      await due();
      assert.ok((await docs("mailDeliveries")).every((d) => d.data().type === "reminder" && d.data().jobId === JOB && d.id === `${d.data().participantId}_reminder`));
      assert.ok(sends.every((m) => m.metadata.type === "reminder" && m.metadata.jobId === JOB));
      assert.equal((await docs("mailJobs")).length, 0);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("サーバー側の継続配送(ブラウザ非依存)", () => {
    test("送信時刻に達 → ジョブ作成 → 引き渡し → 配送 → completed が、ブラウザの処理呼び出し0回でサーバーだけで完了する", async () => {
      await importBatch("batchA", 40);
      await importBatch("batchB", 35);
      await importBatch("batchC", 25);
      await due(); // Schedulerだけ。管理画面のcallableは1つも呼んでいない
      const state = await view();
      assert.deepEqual([state.status, state.targetCount, state.counts, state.dispatch.active], ["completed", 100, {pending: 0, sending: 0, sent: 100, failed: 0, unknown: 0}, false]);
      assert.equal(state.conservation.completedConsistent, true);
      assert.equal(remindersSent().length, 100);
      assert.ok(Object.values(perParticipant(remindersSent())).every((n) => n === 1));
    });

    test("引き渡しは reminderSendAt の到達時に行われ、それまでは配送されない。作成直後にdispatchActiveが記録される", async () => {
      await importBatch("batchA", 6);
      nowMs = T0 - 60000;
      await reconcile();
      await sweep();
      assert.equal(sends.length, 0);
      nowMs = T0;
      await reconcile();
      const created = await job();
      assert.deepEqual([created.status, created.dispatchActive, created.dispatchRequestedBy], ["ready", true, "system:reminder-scheduler"]);
      assert.equal(sends.length, 0, "作成の時点ではまだ送らない(配送はsweepが行う)");
      await sweep();
      assert.equal(sends.length, 6);
    });

    test("workerを二重起動しても、対象数を超える配送は起きず、同じparticipantへ2回送られない", async () => {
      await importBatch("batchA", 60);
      nowMs = T0;
      await reconcile();
      const results = await Promise.all(Array.from({length: 6}, () => send.worker.runJob({db, jobId: JOB, getTransport: () => transport})));
      assert.equal(remindersSent().length, 60);
      assert.ok(Object.values(perParticipant(remindersSent())).every((n) => n === 1));
      assert.ok(results.some((r) => r.skipped === "worker-active" || r.finished));
    });

    test("途中でworkerが停止(40件処理後)しても、再開後に二重送信せず全件の状態が確定する", async () => {
      makeApis({chunkSize: 10});
      await importBatch("batchA", 100);
      nowMs = T0;
      await reconcile();
      let calls = 0;
      behavior = (m) => { calls += 1; return calls > 40 ? new Promise(() => {}) : {outcome: "sent", messageId: `mid-${m.metadata.participantId}`}; };
      send.worker.runJob({db, jobId: JOB, getTransport: () => transport});
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const inFlight = sends.length - 40;
      assert.ok(inFlight >= 1 && inFlight <= 5);
      behavior = (m) => ({outcome: "sent", messageId: `mid-${m.metadata.participantId}`});
      nowMs += 15 * 60 * 1000;
      for (let i = 0; i < 4; i += 1) await sweep();
      const state = await view();
      assert.equal(state.status, "completed");
      assert.equal(state.counts.sent + state.counts.failed + state.counts.unknown, 100);
      assert.equal(state.counts.unknown, inFlight, "dispatch済みで結果不明のものはunknown(自動再送しない)");
      assert.ok(Object.values(perParticipant(remindersSent())).every((n) => n === 1), "どのparticipantにも2回は送られない");
    });

    test("sent 90 / failed 5 / unknown 5: targetCount==100が成立。failedだけ管理者操作で再送され、sent・unknownは変化しない", async () => {
      await importBatch("batchA", 100);
      const failing = new Set(["batchA-000003", "batchA-000010", "batchA-000020", "batchA-000030", "batchA-000040"]);
      const unknowns = new Set(["batchA-000004", "batchA-000011", "batchA-000021", "batchA-000031", "batchA-000041"]);
      behavior = (m) => {
        const id = m.metadata.participantId;
        if (failing.has(id)) return {outcome: "failed", errorCode: "mail-api-400"};
        if (unknowns.has(id)) return {outcome: "unknown", errorCode: "timeout"};
        return {outcome: "sent", messageId: `mid-${id}`};
      };
      await due();
      let state = await view();
      assert.deepEqual([state.status, state.targetCount, state.counts], ["completed", 100, {pending: 0, sending: 0, sent: 90, failed: 5, unknown: 5}]);
      assert.equal(state.counts.sent + state.counts.failed + state.counts.unknown, state.targetCount);
      const dispatched = sends.length;
      for (let i = 0; i < 3; i += 1) { await reconcile(); await sweep(); }
      assert.equal(sends.length, dispatched, "failed・unknownは自動再送されない");
      failing.clear();
      const retried = await api.retry(asAdmin({eventId: "event1"}));
      assert.equal(retried.retried, 5, "failedだけ");
      assert.equal(sends.length, dispatched, "retryはpendingへ戻すだけ");
      await api.start(asAdmin({eventId: "event1"})); // 管理者の明示操作でサーバーへ引き渡す
      await sweep();
      assert.equal(sends.length - dispatched, 5, "failedの5件だけが再送された");
      assert.ok(sends.slice(dispatched).every((m) => ["batchA-000003", "batchA-000010", "batchA-000020", "batchA-000030", "batchA-000040"].includes(m.metadata.participantId)));
      state = await view();
      assert.deepEqual(state.counts, {pending: 0, sending: 0, sent: 95, failed: 0, unknown: 5}, "sent 90は不変、unknown 5も不変");
      assert.equal(state.status, "completed");
    });

    test("sending leaseは維持される: lease有効中は別workerが奪わず、dispatch済みでlease切れならunknown(既存方式をreminderのjobでも使用)", async () => {
      await importBatch("batchA", 12);
      nowMs = T0;
      await reconcile();
      await send.engine.claimItem({db, jobId: JOB, participantId: "batchA-000002"}); // dispatch前
      const b = await send.engine.claimItem({db, jobId: JOB, participantId: "batchA-000003"});
      await send.engine.startDispatch({db, jobId: JOB, participantId: "batchA-000003", claimId: b.claimId}); // dispatch済み
      assert.equal((await get("mailDeliveries/batchA-000003_reminder")).status, "sending", "reminderの配送記録でclaimされる");
      await sweep();
      assert.equal(remindersSent().length, 10);
      assert.ok(!perParticipant(remindersSent())["batchA-000002"] && !perParticipant(remindersSent())["batchA-000003"], "lease有効中は奪わない");
      nowMs += 2 * 60 * 1000;
      await sweep();
      assert.equal(perParticipant(remindersSent())["batchA-000002"], 1, "dispatch前は再claimして送信");
      assert.ok(!perParticipant(remindersSent())["batchA-000003"]);
      assert.equal((await get("mailDeliveries/batchA-000003_reminder")).status, "unknown");
      assert.equal((await get("mailDeliveries/batchA-000003_reminder")).lastErrorCode, "lease-expired-after-dispatch");
      assert.equal((await view()).status, "completed");
    });

    test("保存則: completedは pending=0・sending=0・sent+failed+unknown==targetCount のときだけ。件数が壊れたらcompletedにしない(haltする)", async () => {
      await importBatch("batchA", 10);
      nowMs = T0;
      await reconcile();
      await db.doc(`sendJobs/${JOB}/items/batchA-000002`).delete();
      await sweep();
      const stored = await job();
      assert.notEqual(stored.status, "completed");
      assert.deepEqual([stored.dispatchActive, stored.dispatchHaltedReason], [false, "conservation-violated"]);
      const state = await view();
      assert.equal(state.conservation.consistent, false);
      const dispatched = sends.length;
      await sweep();
      assert.equal(sends.length, dispatched, "停止後は再処理されない");
    });

    test("保存則(正常): 全件がsent・failed・unknownのいずれかに存在し、欠落0", async () => {
      await importBatch("batchA", 30);
      behavior = (m) => (Number(m.metadata.participantId.slice(-6)) % 7 === 0 ? {outcome: "failed", errorCode: "mail-api-400"} : Number(m.metadata.participantId.slice(-6)) % 11 === 0 ? {outcome: "unknown", errorCode: "timeout"} : {outcome: "sent", messageId: "m"});
      await due();
      const state = await view();
      assert.equal(state.status, "completed");
      assert.equal(state.counts.sent + state.counts.failed + state.counts.unknown, 30);
      const items = await jobItems();
      assert.equal(items.length, 30);
      assert.ok(items.every((d) => ["sent", "failed", "unknown"].includes(d.data().status)), "状態が存在しないparticipantは0");
    });

    test("配送エンジンの上限はDELIVERY_LIMITSを共有(reminder専用の上限を持たない)。異常時はhaltする", async () => {
      assert.equal(send.worker.limits.chunkSize, DELIVERY_LIMITS.chunkSize);
      assert.equal(send.worker.limits.maxJobsPerSweep, DELIVERY_LIMITS.maxJobsPerSweep);
      const source = fs.readFileSync(path.join(__dirname, "..", "confirmed", "reminder_api.js"), "utf8").split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
      for (const key of ["chunkSize", "maxChunksPerRun", "runBudgetMs", "maxNoProgressRuns", "maxRunsPerActivation", "workerLeaseMs"]) assert.ok(!source.includes(key), `reminder_api.jsが独自に ${key} を持たない`);
      await importBatch("batchA", 5);
      makeApis({maxNoProgressRuns: 2});
      capable = {ok: false, missing: ["html"]};
      await due(3);
      assert.equal(sends.length, 0);
      assert.deepEqual([(await job()).dispatchActive, (await job()).dispatchHaltedReason], [false, "no-progress"]);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("手動開始(自動と同じジョブへ到達する)", () => {
    test("手動開始 → 自動(時刻到達)の順でも、ジョブは1つ・配送記録はparticipantあたり1件。手動開始は別便ではない", async () => {
      await importBatch("batchA", 20);
      const manual = await api.start(asAdmin({eventId: "event1"}));
      assert.deepEqual([manual.jobId, manual.dispatchActive, manual.alreadyExisted], [JOB, true, false]);
      nowMs = T0;
      await reconcile(); // 自動: 既存のジョブがあるので何もしない
      await sweep();
      assert.equal((await docs("sendJobs")).length, 1);
      assert.equal((await docs("mailDeliveries")).length, 20);
      assert.equal(remindersSent().length, 20);
      const again = await api.start(asAdmin({eventId: "event1"}));
      assert.equal(again.alreadyExisted, true);
      await sweep();
      assert.equal(remindersSent().length, 20, "手動開始を繰り返しても別便は送られない");
    });

    test("自動と手動が同時に実行されても、ジョブ1つ・targetCount1つ・配送記録1件ずつ", async () => {
      await importBatch("batchA", 30);
      nowMs = T0;
      const results = await Promise.all([reconcile(), api.start(asAdmin({eventId: "event1"})).catch((e) => e), reconcile(), api.start(asAdmin({eventId: "event1"})).catch((e) => e)]);
      assert.equal(results.length, 4);
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 1);
      assert.equal((await job()).targetCount, 30);
      assert.equal((await jobItems()).length, 30);
      assert.equal((await docs("mailDeliveries")).length, 30);
      await sweep();
      assert.equal(remindersSent().length, 30);
      assert.ok(Object.values(perParticipant(remindersSent())).every((n) => n === 1));
    });

    test("既存ジョブがある場合の手動開始は、sent・unknownをpendingへ戻さず、failedも自動では戻さない(再送は別の明示操作)", async () => {
      await importBatch("batchA", 12);
      behavior = (m) => (m.metadata.participantId === "batchA-000002" ? {outcome: "failed", errorCode: "mail-api-400"} : m.metadata.participantId === "batchA-000003" ? {outcome: "unknown", errorCode: "timeout"} : {outcome: "sent", messageId: "m"});
      await due();
      const before = JSON.stringify((await jobItems()).map((d) => [d.id, d.data().status]));
      const dispatched = sends.length;
      const result = await api.start(asAdmin({eventId: "event1"}));
      assert.equal(result.alreadyExisted, true);
      assert.equal(result.dispatchActive, undefined, "完了済みのジョブを再度有効化しない");
      await sweep();
      assert.equal(JSON.stringify((await jobItems()).map((d) => [d.id, d.data().status])), before);
      assert.equal(sends.length, dispatched);
    });

    test("手動開始(dispatch=false)はジョブの準備だけ。配送はしない", async () => {
      await importBatch("batchA", 4);
      const prepared = await api.start(asAdmin({eventId: "event1", dispatch: false}));
      assert.equal(prepared.status, "ready");
      assert.equal((await job()).dispatchActive, undefined);
      await sweep();
      assert.equal(sends.length, 0);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("設定(reminderEnabled / reminderSendAt / テンプレート)", () => {
    test("既定はreminderEnabled=false。設定の保存だけでは、ジョブも配送も作られない(定期実行が判断する)", async () => {
      await importBatch("batchA", 5);
      await seedEvent({reminderEnabled: undefined, reminderSendAt: undefined});
      const settings = await api.settings(asAdmin({eventId: "event1"}));
      assert.equal(settings.enabled, false);
      assert.equal(settings.sendAt, null);
      const saved = await api.update(asAdmin({eventId: "event1", reminderEnabled: true, reminderSendAt: new Date(T0 + 3600000).toISOString()}));
      assert.equal(saved.enabled, true);
      assert.equal((await docs("sendJobs")).length, 0, "保存だけではジョブを作らない");
      assert.equal(sends.length, 0);
      nowMs = T0 + 7200000;
      await reconcile();
      assert.equal((await docs("sendJobs")).length, 1, "時刻到達後の定期実行で作られる");
    });

    test("有効化には、送信予定日時・完全なテンプレート・イベント情報が必要(サーバー側で検証)", async () => {
      await seedEvent({reminderEnabled: false, reminderSendAt: undefined, reminderMailTemplate: undefined});
      const fail = async (data, code) => assert.equal((await api.update(asAdmin({eventId: "event1", ...data})).catch((e) => e)).details.code, code);
      await fail({reminderEnabled: true}, "send-at-required");
      await api.update(asAdmin({eventId: "event1", reminderSendAt: new Date(T0).toISOString()}));
      await fail({reminderEnabled: true}, "mail-not-ready");
      await api.update(asAdmin({eventId: "event1", template: REMINDER_TEMPLATE}));
      assert.equal((await get("events/event1")).reminderMailTemplate.version, 1);
      await api.update(asAdmin({eventId: "event1", reminderEnabled: true, reminderSendAt: new Date(T0 + 3600000).toISOString()}));
      assert.equal((await get("events/event1")).reminderEnabled, true);
    });

    test("過去の日時で有効化するには明示的な確認(acknowledgePast)が必要。イベント終了後は有効化できない", async () => {
      await seedEvent({reminderEnabled: false});
      nowMs = T0 + 3600000;
      const past = new Date(T0).toISOString();
      assert.equal((await api.update(asAdmin({eventId: "event1", reminderEnabled: true, reminderSendAt: past})).catch((e) => e)).details.code, "send-at-in-past");
      assert.equal((await get("events/event1")).reminderEnabled, false, "拒否では何も書かれない");
      await api.update(asAdmin({eventId: "event1", reminderEnabled: true, reminderSendAt: past, acknowledgePast: true}));
      assert.equal((await get("events/event1")).reminderEnabled, true);
      await seedEvent({reminderEnabled: false});
      nowMs = Date.parse(EVENT_END) + 1000;
      assert.equal((await api.update(asAdmin({eventId: "event1", reminderEnabled: true, acknowledgePast: true})).catch((e) => e)).details.code, "event-ended");
    });

    test("不正な入力(想定外のキー・不正な日時・型・空の更新・テンプレートの不備)は拒否される", async () => {
      await rejectsWith(api.update(asAdmin({eventId: "event1"})), "invalid-argument");
      await rejectsWith(api.update(asAdmin({eventId: "event1", reminderSendAt: "明日"})), "invalid-argument");
      await rejectsWith(api.update(asAdmin({eventId: "event1", reminderEnabled: "yes"})), "invalid-argument");
      await rejectsWith(api.update(asAdmin({eventId: "event1", extra: 1, reminderEnabled: true})), "invalid-argument");
      await rejectsWith(api.update(asAdmin({eventId: "event1", template: {subject: "", introBody: "a", closingBody: "b"}})), "invalid-argument");
      await rejectsWith(api.update(asAdmin({eventId: "event1", template: {...REMINDER_TEMPLATE, qrCode: "x"}})), "invalid-argument");
      await db.collection("events").doc("legacy1").set({eventId: "legacy1", eventName: "旧"});
      await rejectsWith(api.update(asAdmin({eventId: "legacy1", reminderEnabled: false})), "failed-precondition");
    });

    test("ジョブ作成後の設定変更(無効化・日時・テンプレート)は、作成済みジョブを止めも作り直しもしない。配送は状態のとおり継続する", async () => {
      await importBatch("batchA", 15);
      nowMs = T0;
      await reconcile();
      const created = await job();
      await api.update(asAdmin({eventId: "event1", reminderEnabled: false}));
      await api.update(asAdmin({eventId: "event1", reminderSendAt: new Date(T0 + 86400000).toISOString()}));
      await api.update(asAdmin({eventId: "event1", template: {...REMINDER_TEMPLATE, subject: "変更後"}}));
      const after = await job();
      assert.equal(after.dispatchActive, true, "無効化しても配送中のジョブは止まらない");
      assert.equal(after.templateVersion, created.templateVersion);
      await sweep();
      assert.equal((await view()).status, "completed");
      assert.equal(remindersSent().length, 15);
      assert.equal((await docs("sendJobs")).length, 1, "作り直されない");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("認可・個人情報・legacy", () => {
    test("設定・保存・プレビュー・手動開始・状態・失敗分再送のすべてで、未認証はunauthenticated・staffはpermission-denied・adminは成功", async () => {
      await importBatch("batchA", 4);
      await api.start(asAdmin({eventId: "event1", dispatch: false}));
      const calls = {
        settings: {eventId: "event1"}, update: {eventId: "event1", reminderEnabled: false}, preview: {eventId: "event1", participantId: "batchA-000002"},
        start: {eventId: "event1", dispatch: false}, job: {eventId: "event1"}, retry: {eventId: "event1"},
      };
      for (const [name, data] of Object.entries(calls)) {
        await rejectsWith(api[name]({data}), "unauthenticated");
        await rejectsWith(api[name](asStaff(data)), "permission-denied");
        await api[name](asAdmin(data)); // adminは成功(例外なし)
      }
      const index = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
      for (const name of ["getConfirmedReminderSettings", "updateConfirmedReminderSettings", "previewConfirmedReminderMail", "startConfirmedReminderDelivery", "getConfirmedReminderJob", "retryFailedConfirmedReminderMails"]) {
        // Phase 1B: 実際の公開設定は、対象イベント(data.eventId)のevent_manager以上(adminは全イベント)
        assert.match(index, new RegExp(`^exports\\.${name} = confirmedEventCallable\\("eventManager", EVENT_SCOPES\\.dataEventId, `, "m"), name);
      }
    });

    test("sendJobs・items・mailDeliveries・eventのリマインド設定にメールアドレス・氏名・publicIdを複製しない。schedulerの入力はイベントの標識だけ", async () => {
      await importBatch("batchA", 6);
      await due();
      const p = await get("participants/batchA-000002");
      const all = JSON.stringify([...(await docs("sendJobs")), ...(await jobItems()), ...(await docs("mailDeliveries"))].map((d) => d.data()));
      assert.ok(!all.includes("example.invalid") && !all.includes(p.name) && !all.includes(p.publicId));
      const list = await api.job(asAdmin({eventId: "event1"}));
      assert.ok(!JSON.stringify(list).includes("example.invalid"));
      assert.equal(reminder.reconcileDue.length, 0, "reconcileDueは任意のoptionsだけ(参加者情報を受け取らない)");
    });

    test("旧Scheduler(sendScheduledConfirmationMail)・旧mailJobsをリマインドに使わない。旧schedulerのコードにリマインドの概念が無い", async () => {
      const index = fs.readFileSync(path.join(__dirname, "..", "index.js"), "utf8");
      const legacy = index.slice(index.indexOf("exports.sendScheduledConfirmationMail"), index.indexOf("exports.registerWalkIn") > 0 ? undefined : undefined);
      const legacyBlock = legacy.slice(0, legacy.indexOf("exports.", 40));
      assert.ok(!/reminder/i.test(legacyBlock), "旧sendScheduledConfirmationMailにreminderは無い");
      for (const file of ["reminder_api.js", "reminder_targets.js"]) {
        const source = fs.readFileSync(path.join(__dirname, "..", "confirmed", file), "utf8");
        for (const token of ["mailJobs", "sendScheduledConfirmationMail", "participationConfirmed", "reconfirmEnabled", "attendanceResponse", "confirmationSendAt"]) {
          assert.ok(!source.includes(token), `${file} に旧概念 ${token} がある`);
        }
      }
    });

    test("Firestore Rulesは変更なし(reminderの状態はサーバー経由のみ)。eventsのconfirmedはクライアントから更新できない前提を維持", () => {
      const rules = fs.readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8");
      assert.ok(!/reminder/i.test(rules), "reminder専用の新しい許可を追加していない");
    });
  });

  test("外部通信0件: Emulator以外へのfetchは一度も行われない(送信は偽のtransportのみ。Cloud Tasks等も使わない)", async () => {
    await importBatch("batchA", 10);
    await due();
    await api.settings(asAdmin({eventId: "event1"}));
    assert.deepEqual(externalCalls, []);
  });
});
