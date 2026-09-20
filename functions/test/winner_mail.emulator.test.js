// 当選メール(テンプレート・プレビュー・batch単位の送信ジョブ・二重送信防止)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続して検証する。
// メール送信は「偽のtransport」で、SendGrid・Cloud Runの実URLへの通信は一切ない。データはすべて架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {PNG} = require("pngjs");
const {skipReason, startAdminEmulator, failingDb} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, HEADERS, makeRecord, UNMAPPED_MARKER} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {createWinnerSendApi} = require("../confirmed/winner_send_api");
const {confirmedCallable} = require("../auth");
const {generateQrPng} = require("../qr_png");

const silent = {warn: () => {}};
const APP_BASE_URL = "https://app.invalid";
const LEGACY_COUNT_KEY = ["registered", "Count"].join("");
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const realFetch = globalThis.fetch;

const TEMPLATE = {subject: "【ご参加確定】架空イベント", introBody: "このたびは当選おめでとうございます。", closingBody: "当日お会いできるのを楽しみにしています。", notesBody: "駐車場はありません。"};
const VENUE = {address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分"};

describe("当選メール(Emulator + 実Admin SDK + 偽transport)", {skip: skipReason()}, () => {
  let env;
  let db;
  let mail; // {settings, update, preview}(認可つき)
  let send; // {create, process, retry}(認可つき) + engine
  let sends; // 偽transportが受け取った送信内容
  let capable;
  let behavior; // (message) => transportの結果
  let nowMs;
  let externalCalls;

  const clock = () => nowMs;
  const wrap = (level, handler) => {
    const callable = confirmedCallable(level, handler, {db, logger: silent});
    return (request) => callable.run(request);
  };
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});
  const transport = {
    async capabilities() { return capable; },
    async send(message) {
      sends.push(JSON.parse(JSON.stringify(message)));
      return behavior(message);
    },
  };

  function makeApis(options = {}) {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const winnerMail = createWinnerMailApi({getDb: () => options.db || db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL});
    const winnerSend = createWinnerSendApi({
      getDb: () => options.db || db, serverTimestamp, generateQrPng, getAppBaseUrl: () => APP_BASE_URL, getTransport: () => transport,
      engineOptions: {now: clock, leaseMs: 60000, concurrency: options.concurrency || 4},
    });
    return {
      mail: {settings: wrap("admin", winnerMail.getSettings), update: wrap("admin", winnerMail.updateTemplate), preview: wrap("admin", winnerMail.preview)},
      send: {create: wrap("admin", winnerSend.createJob), process: wrap("admin", winnerSend.processJob), retry: wrap("admin", winnerSend.retryFailed), engine: winnerSend.engine},
    };
  }

  // Firestoreはundefinedを書けないため、undefinedを指定したキーは「項目なし」として除く。
  const defined = (object) => Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));
  async function seedEvent(overrides = {}) {
    await db.collection("events").doc("event1").set(defined({
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場ホール", contact: "架空事務局 support@example.invalid", venueInfo: VENUE,
      programs: [{programId: "gamma", name: "トークセッション", order: 2}, {programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}],
      winnerMailTemplate: {...TEMPLATE, version: 1, updatedBy: "u-admin"},
      ...overrides,
    }));
  }
  const importApi = () => createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
  // Phase 5の実APIで取り込む(committedなbatchとparticipant・programAttendancesができる)
  async function importBatch(clientRequestId, tableOrN = 3, extra = {}) {
    const table = typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN;
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table, clientRequestId, ...extra})});
  }
  const docs = async (path, query) => (await (query ? query(db.collection(path)) : db.collection(path)).get()).docs;
  const count = async (path, query) => (await docs(path, query)).length;
  const get = async (path) => (await db.doc(path).get()).data();
  const collections = async () => (await db.listCollections()).map((c) => c.id).sort();
  const jobItems = (jobId) => docs(`sendJobs/${jobId}/items`);

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
    ({mail, send} = makeApis());
    sends = [];
    capable = {ok: true, missing: []};
    behavior = (message) => ({outcome: "sent", messageId: `mid-${sends.length}`});
    nowMs = Date.parse("2026-11-01T00:00:00Z");
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  // ---------------------------------------------------------------------------------------------
  describe("テンプレート設定(admin専用・confirmedイベントのみ)", () => {
    const update = (overrides = {}, actor = asAdmin) => mail.update(actor({eventId: "event1", template: TEMPLATE, venueInfo: VENUE, ...overrides}));

    test("adminは更新でき、event.winnerMailTemplateにversion・updatedBy・updatedAtが保存される(件名・冒頭文・締め文・注意事項)", async () => {
      await seedEvent({winnerMailTemplate: undefined, venueInfo: undefined});
      const result = await update({template: {...TEMPLATE, subject: "  新しい件名  "}});
      assert.deepEqual(result, {eventId: "event1", version: 1, changed: true});
      const event = await get("events/event1");
      assert.deepEqual([event.winnerMailTemplate.subject, event.winnerMailTemplate.introBody, event.winnerMailTemplate.closingBody, event.winnerMailTemplate.notesBody,
        event.winnerMailTemplate.version, event.winnerMailTemplate.updatedBy], ["新しい件名", TEMPLATE.introBody, TEMPLATE.closingBody, TEMPLATE.notesBody, 1, "u-admin"]);
      assert.ok(event.winnerMailTemplate.updatedAt && typeof event.winnerMailTemplate.updatedAt.toDate === "function");
      assert.deepEqual(event.venueInfo, VENUE);
      assert.equal(event.senderName, "架空事務局", "既存のsenderNameを再利用(新しい重複フィールドを作らない)");
    });

    test("staffは permission-denied、未認証は unauthenticated で、何も書き込まれない", async () => {
      const before = await get("events/event1");
      await rejectsWith(update({}, asStaff), "permission-denied");
      await rejectsWith(mail.update({data: {eventId: "event1", template: TEMPLATE}}), "unauthenticated");
      assert.deepEqual(await get("events/event1"), before);
    });

    test("legacyイベント・存在しないイベントは拒否され、何も書き込まれない", async () => {
      for (const flow of [undefined, "legacy", "confirmd"]) {
        await db.collection("events").doc("legacy1").set({eventId: "legacy1", eventName: "旧", ...(flow ? {flow} : {})});
        await rejectsWith(mail.update(asAdmin({eventId: "legacy1", template: TEMPLATE})), "failed-precondition");
        assert.equal((await get("events/legacy1")).winnerMailTemplate, undefined);
      }
      await rejectsWith(mail.update(asAdmin({eventId: "no-such", template: TEMPLATE})), "not-found");
    });

    test("空件名・空白のみ・長すぎる件名・本文の必須/上限を拒否する(何も書き込まれない)", async () => {
      const before = await get("events/event1");
      const bad = [{subject: ""}, {subject: "   "}, {subject: "あ".repeat(151)}, {subject: "件名\nBcc: x"}, {introBody: ""}, {closingBody: " "}, {introBody: "あ".repeat(2001)},
        {closingBody: "あ".repeat(2001)}, {notesBody: "あ".repeat(2001)}, {introBody: "a\u0000b"}];
      for (const change of bad) {
        await assert.rejects(update({template: {...TEMPLATE, ...change}}), (e) => e.code === "invalid-argument" && e.details.code === "invalid-template", JSON.stringify(change).slice(0, 40));
      }
      await assert.rejects(update({venueInfo: {address: "あ".repeat(301)}}), (e) => e.details.code === "invalid-venue-info");
      assert.deepEqual(await get("events/event1"), before);
    });

    test("QR・宛名・program情報・HTML等を管理者が自由入力する余地はない(未知キーを拒否)", async () => {
      for (const key of ["qr", "html", "recipientName", "programs", "webPassUrl", "eventName"]) {
        await rejectsWith(update({template: {...TEMPLATE, [key]: "x"}}), "invalid-argument");
      }
      await rejectsWith(mail.update(asAdmin({eventId: "event1", template: TEMPLATE, html: "<p>x</p>"})), "invalid-argument");
      await rejectsWith(mail.update(asAdmin({eventId: "event1", template: TEMPLATE, participants: []})), "invalid-argument");
    });

    test("同じ内容の再送(ネットワーク再試行)ではversionを進めず、内容が変われば+1になる", async () => {
      await seedEvent({winnerMailTemplate: undefined});
      assert.equal((await update()).version, 1);
      assert.deepEqual(await update(), {eventId: "event1", version: 1, changed: false});
      assert.deepEqual(await update({template: {...TEMPLATE, closingBody: "変更した締め文"}}), {eventId: "event1", version: 2, changed: true});
      assert.equal((await get("events/event1")).winnerMailTemplate.version, 2);
    });

    test("venueInfoを省略した更新は、既存の住所・アクセスを変えない。空にすると消える", async () => {
      await mail.update(asAdmin({eventId: "event1", template: {...TEMPLATE, subject: "件名2"}}));
      assert.deepEqual((await get("events/event1")).venueInfo, VENUE);
      await update({venueInfo: {address: "", access: ""}});
      assert.deepEqual((await get("events/event1")).venueInfo, {address: null, access: null});
    });

    test("getSettings: 現在の設定と、送信できる状態か(問題点)を返す。未設定なら template=null", async () => {
      await seedEvent({winnerMailTemplate: undefined, venueInfo: undefined});
      const before = await mail.settings(asAdmin({eventId: "event1"}));
      assert.equal(before.template, null);
      assert.equal(before.ready, false);
      assert.deepEqual(before.problems, ["template-not-configured"]);
      await update();
      const after = await mail.settings(asAdmin({eventId: "event1"}));
      assert.deepEqual([after.ready, after.template.version, after.template.subject, after.venueInfo], [true, 1, TEMPLATE.subject, VENUE]);
      await rejectsWith(mail.settings(asStaff({eventId: "event1"})), "permission-denied");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("プレビュー(実際に届くメールの完成形)", () => {
    const P1 = "batchA-000002";
    const preview = (participantId = P1, actor = asAdmin, eventId = "event1") => mail.preview(actor({eventId, participantId}));

    test("adminは、Firestoreの正本(event・participant・programAttendances・テンプレート)から完成形(subject・text・html・QR・URL)を得る", async () => {
      await importBatch("batchA", 3);
      const r = await preview();
      assert.equal(r.ready, true);
      assert.equal(r.subject, TEMPLATE.subject);
      assert.equal(r.templateVersion, 1);
      assert.equal(r.senderName, "架空事務局");
      for (const body of [r.text, r.html]) {
        assert.ok(body.includes("架空テスト001"), "participantの氏名(Firestore正本)");
        assert.ok(body.includes("プログラムA") && body.includes("トークセッション"));
        assert.ok(!body.includes("プログラムB"), "参加していないprogramは出ない");
      }
      assert.ok(r.text.includes("参加時間：10:00-11:00") && r.text.includes("参加人数：2名") && r.text.includes("参加人数：1名"));
      assert.ok(r.text.indexOf("プログラムA") < r.text.indexOf("トークセッション"), "event.programsのorder順");
      assert.equal(r.qrPayload, `${APP_BASE_URL}/reception?eventId=event1&participantId=${P1}&publicId=${(await get(`participants/${P1}`)).publicId}`);
      assert.equal(r.webPassUrl, `${APP_BASE_URL}/p/${P1}?publicId=${(await get(`participants/${P1}`)).publicId}`);
      assert.ok(r.text.includes(r.webPassUrl) && r.html.includes(r.webPassUrl));
      assert.ok(r.html.includes("cid:jm-quick-reception-qr"));
      assert.ok((await generateQrPng(r.qrPayload)).equals(Buffer.from(r.qrPngBase64, "base64")), "返すQR画像はqrPayloadから生成したもの");
      assert.deepEqual(r.missingOptional, []);
      assert.ok(!JSON.stringify(r).includes("p1@example.invalid") && !JSON.stringify(r).includes("synthetic"), "宛先メールアドレスは返さない");
      assert.ok(!JSON.stringify(r).includes(UNMAPPED_MARKER));
    });

    test("staffは permission-denied、未認証は unauthenticated", async () => {
      await importBatch("batchA", 2);
      await rejectsWith(preview(P1, asStaff), "permission-denied");
      await rejectsWith(mail.preview({data: {eventId: "event1", participantId: P1}}), "unauthenticated");
    });

    test("クライアントが氏名・人数・本文を偽装できない(未知のキーを拒否。表示は常にFirestoreの値)", async () => {
      await importBatch("batchA", 2);
      for (const extra of [{name: "偽名"}, {plannedCount: 99}, {programs: []}, {subject: "偽件名"}, {email: "x@example.invalid"}, {template: TEMPLATE}]) {
        await rejectsWith(mail.preview(asAdmin({eventId: "event1", participantId: P1, ...extra})), "invalid-argument");
      }
      await db.collection("participants").doc(P1).update({name: "Firestoreで変更された名前"});
      await db.collection("programAttendances").doc(`${P1}_alpha`).update({plannedCount: 5});
      const r = await preview();
      assert.ok(r.text.includes("Firestoreで変更された名前 様"));
      assert.ok(r.text.includes("参加人数：5名"));
    });

    test("テンプレート未設定・不完全は「未設定」として明確に返す(勝手な既定本文は使わない)", async () => {
      await importBatch("batchA", 2);
      await seedEvent({winnerMailTemplate: undefined});
      assert.deepEqual(await preview(), {ready: false, problems: ["template-not-configured"]});
      await seedEvent({winnerMailTemplate: {subject: " ", introBody: "a", closingBody: "b", version: 1}});
      assert.deepEqual(await preview(), {ready: false, problems: ["template-subject-invalid"]});
    });

    test("イベント情報(イベント名・開催日時・会場)の不足はメールを作らず、理由を返す", async () => {
      await importBatch("batchA", 2);
      await seedEvent({venue: "", startAt: null});
      assert.deepEqual(await preview(), {ready: false, problems: ["event-start-missing", "event-venue-missing"]});
    });

    test("任意項目(住所・アクセス・注意事項・問い合わせ先)が未設定でも作れ、そのセクションは出ない。「未設定」「null」も出ない", async () => {
      await importBatch("batchA", 2);
      await seedEvent({venueInfo: undefined, contact: "", winnerMailTemplate: {...TEMPLATE, notesBody: null, version: 1}});
      const r = await preview();
      assert.equal(r.ready, true);
      for (const forbidden of ["住所", "アクセス", "注意事項", "お問い合わせ先", "未設定", "null", "undefined"]) {
        assert.ok(!r.text.includes(forbidden) && !r.html.includes(forbidden), forbidden);
      }
      assert.deepEqual(r.missingOptional, ["contact", "address", "access", "notesBody"]);
    });

    test("participantが別イベントのもの・存在しない・無効(cancelled)・取込由来でない場合は拒否", async () => {
      await importBatch("batchA", 2);
      await db.collection("events").doc("event2").set({eventId: "event2", flow: "confirmed", eventName: "別", venue: "会場", startAt: env.Timestamp.fromDate(new Date("2026-12-01T01:00:00Z")),
        winnerMailTemplate: {...TEMPLATE, version: 1}, programs: [{programId: "alpha", name: "A", order: 0}]});
      await assert.rejects(preview(P1, asAdmin, "event2"), (e) => e.code === "failed-precondition" && e.details.code === "participant-event-mismatch");
      await rejectsWith(preview("batchA-000099"), "not-found");
      await rejectsWith(mail.preview(asAdmin({eventId: "event1", participantId: "bad_id"})), "invalid-argument");
      await db.collection("participants").doc(P1).update({status: "cancelled"});
      await assert.rejects(preview(), (e) => e.details.code === "participant-not-active");
      await db.collection("participants").doc("manual1").set({participantId: "manual1", eventId: "event1", name: "手動", publicId: "pub_0123456789abcdef0123456789abcdef", status: "active"});
      await assert.rejects(preview("manual1"), (e) => e.details.code === "participant-not-from-import");
      await rejectsWith(mail.preview(asAdmin({eventId: "no-such", participantId: P1})), "not-found");
      await db.collection("events").doc("legacyE").set({eventId: "legacyE", eventName: "旧"});
      await rejectsWith(mail.preview(asAdmin({eventId: "legacyE", participantId: P1})), "failed-precondition");
    });

    test("committedでないbatch由来のparticipantは、プレビュー対象外(committing・failed)", async () => {
      await importBatch("batchA", 2);
      for (const status of ["committing", "failed"]) {
        await db.collection("importBatches").doc("batchA").update({status});
        await assert.rejects(preview(), (e) => e.code === "failed-precondition" && e.details.code === "batch-not-committed", status);
      }
      await db.collection("importBatches").doc("batchA").update({status: "committed"});
      assert.equal((await preview()).ready, true);
    });

    test("attendanceが無いparticipant(承認されたreview行など)は、メールを作らず理由を返す", async () => {
      const table = makeTable(2, (i) => (i === 1 ? {"午前参加時間": "参加を希望しない", "午前参加人数": "", "トークショー": "参加を希望しない", "トークショー人数": ""} : {}));
      await importBatch("batchA", table, {approvedReviewRows: [2]});
      assert.deepEqual(await preview("batchA-000002"), {ready: false, problems: ["no-attendance"]});
      assert.equal((await preview("batchA-000003")).ready, true);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("送信ジョブの作成(batch単位・committedのみ)", () => {
    const create = (batchId = "batchA", actor = asAdmin) => send.create(actor({eventId: "event1", batchId}));

    test("committedなbatchだけ、adminだけが作成できる。作成では1通も送らない", async () => {
      await importBatch("batchA", 5);
      const job = await create();
      assert.deepEqual([job.jobId, job.status, job.targetCount, job.pendingCount, job.sentCount, job.templateVersion, job.batchSequence],
        ["winner-batchA", "ready", 5, 5, 0, 1, 1]);
      assert.equal(sends.length, 0);
      const stored = await get("sendJobs/winner-batchA");
      assert.deepEqual([stored.type, stored.createdBy, stored.batchId, stored.eventId, stored.completedAt], ["winner", "u-admin", "batchA", "event1", null]);
      await rejectsWith(create("batchA", asStaff), "permission-denied");
      await rejectsWith(send.create({data: {eventId: "event1", batchId: "batchA"}}), "unauthenticated");
    });

    test("committing・failedのbatchは拒否される(参加者は絶対に送信対象にならない)", async () => {
      await importBatch("batchA", 3);
      for (const status of ["committing", "failed"]) {
        await db.collection("importBatches").doc("batchA").update({status});
        await assert.rejects(create(), (e) => e.code === "failed-precondition" && e.details.code === "batch-not-committed" && e.details.status === status);
      }
      assert.equal(await count("sendJobs"), 0);
      assert.equal(await count("mailDeliveries"), 0);
    });

    test("存在しないbatch・別イベントのbatch・不正なIDは拒否", async () => {
      await importBatch("batchA", 2);
      await rejectsWith(create("nobatch"), "not-found");
      await rejectsWith(create("bad-id"), "invalid-argument");
      await rejectsWith(send.create(asAdmin({eventId: "event1", batchId: "batchA", extra: 1})), "invalid-argument");
      await seedEvent();
      await db.collection("events").doc("event2").set({eventId: "event2", flow: "confirmed", eventName: "別", venue: "会場", startAt: env.Timestamp.fromDate(new Date("2026-12-01T01:00:00Z")), winnerMailTemplate: {...TEMPLATE, version: 1}, programs: []});
      await assert.rejects(send.create(asAdmin({eventId: "event2", batchId: "batchA"})), (e) => e.details.code === "batch-event-mismatch");
      await db.collection("events").doc("legacyE").set({eventId: "legacyE", eventName: "旧"});
      await rejectsWith(send.create(asAdmin({eventId: "legacyE", batchId: "batchA"})), "failed-precondition");
    });

    test("テンプレート未設定・不完全、イベント情報の不足ではジョブを作成できない(勝手な既定本文で送らない)", async () => {
      await importBatch("batchA", 2);
      await seedEvent({winnerMailTemplate: undefined});
      await assert.rejects(create(), (e) => e.code === "failed-precondition" && e.details.code === "mail-not-ready" && e.details.problems[0] === "template-not-configured");
      await seedEvent({venue: ""});
      await assert.rejects(create(), (e) => e.details.problems.includes("event-venue-missing"));
      assert.equal(await count("sendJobs"), 0);
    });

    test("batch内の全created participantがitemsになり、mailDeliveriesも同数できる(保存則)。90人 → 90 items", async () => {
      await importBatch("batchA", 90);
      const job = await create();
      assert.equal(job.targetCount, 90);
      assert.equal((await jobItems("winner-batchA")).length, 90);
      assert.equal(await count("mailDeliveries", (c) => c.where("jobId", "==", "winner-batchA")), 90);
      assert.equal(await count("participants", (c) => c.where("importBatchId", "==", "batchA")), 90);
      const ids = new Set((await jobItems("winner-batchA")).map((d) => d.id));
      for (const d of await docs("participants", (c) => c.where("importBatchId", "==", "batchA"))) assert.ok(ids.has(d.id));
    });

    test("同一メール100participant → 100 items / 100 deliveries(人物の重複排除をしない)", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      const job = await create();
      assert.equal(job.targetCount, 100);
      assert.equal((await jobItems("winner-batchA")).length, 100);
      assert.equal(await count("mailDeliveries"), 100);
    });

    test("同一氏名100・同一sourceReference100でも、100 items(除外なし)", async () => {
      await importBatch("batchA", makeTable(100, () => ({"氏名": "架空同姓同名"})));
      assert.equal((await create()).targetCount, 100);
      await importBatch("batchB", makeTable(100, () => ({"rd": "R-SAME"})));
      assert.equal((await create("batchB")).targetCount, 100);
      assert.equal(await count("mailDeliveries"), 200);
    });

    test("別batchの同じ人物は、それぞれのbatchのジョブの対象になる(第1回は第1回のbatchだけ)", async () => {
      const table = makeTable(10);
      await importBatch("batchA", table);
      await importBatch("batchB", table);
      const first = await create("batchA");
      assert.equal(first.targetCount, 10);
      assert.equal(await count("mailDeliveries"), 10, "第1回のジョブは第1回の参加者だけ");
      const second = await create("batchB");
      assert.equal(second.targetCount, 10);
      assert.equal(await count("mailDeliveries"), 20);
      const firstItems = new Set((await jobItems("winner-batchA")).map((d) => d.id));
      for (const d of await jobItems("winner-batchB")) assert.ok(!firstItems.has(d.id));
    });

    test("参加者が欠けていれば(取込結果の件数と不一致)、ジョブを作成しない", async () => {
      await importBatch("batchA", 5);
      await db.collection("participants").doc("batchA-000004").delete();
      await assert.rejects(create(), (e) => e.code === "data-loss" && e.details.code === "participants-mismatch" && e.details.createdCount === 5 && e.details.found === 4);
      assert.equal(await count("sendJobs"), 0);
      assert.equal(await count("mailDeliveries"), 0);
    });

    test("有効でない(cancelled)参加者は、対象外として件数に記録される(target + excluded = created)", async () => {
      await importBatch("batchA", 6);
      await db.collection("participants").doc("batchA-000003").update({status: "cancelled"});
      const job = await create();
      assert.deepEqual([job.targetCount, job.excludedInactiveCount], [5, 1]);
      assert.equal((await jobItems("winner-batchA")).length, 5);
      assert.ok(!(await jobItems("winner-batchA")).some((d) => d.id === "batchA-000003"));
    });

    test("再作成は冪等: 同じbatchのジョブは1つだけ。作成後にテンプレートが変わっても既存ジョブは変わらない", async () => {
      await importBatch("batchA", 4);
      await create();
      await mail.update(asAdmin({eventId: "event1", template: {...TEMPLATE, subject: "変更後の件名"}}));
      const again = await create();
      assert.equal(again.alreadyExisted, true);
      assert.equal(again.templateVersion, 1);
      assert.equal(await count("sendJobs"), 1);
      assert.equal(await count("mailDeliveries"), 4);
      assert.equal((await get("sendJobs/winner-batchA")).snapshot.template.subject, TEMPLATE.subject);
    });

    test("ジョブ・item・deliveryにメールアドレス・氏名を複製しない(snapshotも個人情報なし)", async () => {
      await importBatch("batchA", 5);
      await create();
      const all = JSON.stringify([(await get("sendJobs/winner-batchA")), (await jobItems("winner-batchA")).map((d) => d.data()), (await docs("mailDeliveries")).map((d) => d.data())]);
      // 参加者のメールアドレス(synthetic{n}@...)・氏名・publicIdは、どこにも複製されない(eventの問い合わせ先は個人情報ではない)。
      assert.ok(!/synthetic\d+@/.test(all), "参加者のメールアドレス");
      assert.ok(!all.includes("架空テスト"), "参加者の氏名");
      assert.ok(!all.includes("pub_"), "publicId");
      assert.ok(!all.includes("かくうてすと") && !all.includes(UNMAPPED_MARKER));
    });

    test("準備の途中で失敗 → ジョブはreadyにならず処理できない。再実行で欠落なく完成する(件数・deliveryは増えない)", async () => {
      await importBatch("batchA", 20);
      const flaky = makeApis({db: failingDb(db, {failAtTransaction: 8}), concurrency: 1});
      await assert.rejects(flaky.send.create(asAdmin({eventId: "event1", batchId: "batchA"})), (e) => e.code === "internal" && e.details.code === "job-preparation-interrupted");
      assert.equal((await get("sendJobs/winner-batchA")).status, "preparing");
      await assert.rejects(send.process(asAdmin({jobId: "winner-batchA"})), (e) => e.code === "failed-precondition" && e.details.code === "job-not-ready");
      assert.equal(sends.length, 0);
      const partial = await count("mailDeliveries");
      assert.ok(partial > 0 && partial < 20);
      const job = await create();
      assert.deepEqual([job.status, job.targetCount, job.pendingCount], ["ready", 20, 20]);
      assert.equal(await count("mailDeliveries"), 20);
      assert.equal((await jobItems("winner-batchA")).length, 20);
    });

    test("旧mailJobsは使わない。participant本体に送信済み等の状態を持たせない(責務の分離)", async () => {
      await importBatch("batchA", 5);
      const before = (await docs("participants")).map((d) => [d.id, JSON.stringify(d.data())]);
      await create();
      await send.process(asAdmin({jobId: "winner-batchA"}));
      assert.deepEqual((await docs("participants")).map((d) => [d.id, JSON.stringify(d.data())]), before, "participantsは送信で一切変更されない");
      assert.equal(await count("mailJobs"), 0);
      assert.deepEqual(await collections(), ["accessRoles", "events", "importBatches", "mailDeliveries", "participants", "programAttendances", "sendJobs"]);
      for (const d of await docs("participants")) {
        for (const key of ["invitationSent", "invitationMailStatus", "winnerMailSent", "mailSent", "reconfirmationMailSent"]) assert.ok(!(key in d.data()), key);
      }
      assert.ok(!Object.keys((await get("sendJobs/winner-batchA"))).includes(LEGACY_COUNT_KEY));
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("送信処理・二重送信防止(mailDeliveriesが正本)", () => {
    const create = (batchId = "batchA") => send.create(asAdmin({eventId: "event1", batchId}));
    const processJob = (jobId = "winner-batchA", extra = {}, actor = asAdmin) => send.process(actor({jobId, ...extra}));
    const delivery = (participantId) => get(`mailDeliveries/${participantId}_winner`);
    const sendsTo = () => sends.reduce((acc, m) => ({...acc, [m.metadata.participantId]: (acc[m.metadata.participantId] || 0) + 1}), {});

    test("全員に1通ずつ送り、sent + failed + unknown = targetCount でジョブがcompletedになる", async () => {
      await importBatch("batchA", 30);
      await create();
      const result = await processJob();
      assert.deepEqual([result.status, result.sentCount, result.failedCount, result.unknownCount, result.pendingCount, result.sendingCount], ["completed", 30, 0, 0, 0, 0]);
      assert.equal(result.sentCount + result.failedCount + result.unknownCount, result.targetCount);
      assert.equal(sends.length, 30);
      assert.ok(Object.values(sendsTo()).every((n) => n === 1));
      const d = await delivery("batchA-000002");
      assert.deepEqual([d.status, d.jobId, d.templateVersion, d.attemptCount, d.claimId, d.leaseUntil], ["sent", "winner-batchA", 1, 1, null, null]);
      assert.ok(d.messageId.startsWith("mid-") && d.sentAt);
      assert.ok((await get("sendJobs/winner-batchA")).completedAt);
    });

    test("プレビューと実送信は同じ内容: subject・text・html・QR payload・Web参加証URL・QR画像がバイト単位で一致する", async () => {
      await importBatch("batchA", 5);
      await create();
      await processJob();
      for (const message of sends) {
        const participantId = message.metadata.participantId;
        const p = await mail.preview(asAdmin({eventId: "event1", participantId}));
        assert.equal(p.ready, true);
        assert.equal(message.subject, p.subject);
        assert.equal(message.text, p.text);
        assert.equal(message.html, p.html);
        assert.equal(message.attachments[0].contentBase64, p.qrPngBase64);
        assert.ok(message.text.includes(p.webPassUrl) && message.html.includes(p.webPassUrl));
        assert.ok((await generateQrPng(p.qrPayload)).equals(Buffer.from(message.attachments[0].contentBase64, "base64")));
        assert.equal(message.senderName, "架空事務局");
        assert.deepEqual(message.metadata, {app: "jm-quick", type: "winner", participantId, jobId: "winner-batchA"});
        assert.equal(message.to, (await get(`participants/${participantId}`)).email, "宛先はparticipantsの正本");
      }
    });

    test("QRのPNGは、その参加者の受付QRペイロードを符号化している(送信された画像をデコードして確認)", async () => {
      await importBatch("batchA", 2);
      await create();
      await processJob();
      const QRCode = require("qrcode");
      for (const message of sends) {
        const participant = await get(`participants/${message.metadata.participantId}`);
        const expected = `${APP_BASE_URL}/reception?eventId=event1&participantId=${message.metadata.participantId}&publicId=${participant.publicId}`;
        const image = PNG.sync.read(Buffer.from(message.attachments[0].contentBase64, "base64"));
        const qr = QRCode.create(expected, {errorCorrectionLevel: "M"});
        const scale = image.width / (qr.modules.size + 4);
        let mismatches = 0;
        for (let r = 0; r < qr.modules.size; r += 1) for (let c = 0; c < qr.modules.size; c += 1) {
          const i = (Math.floor((r + 2.5) * scale) * image.width + Math.floor((c + 2.5) * scale)) * 4;
          if ((image.data[i] < 128) !== Boolean(qr.modules.get(r, c))) mismatches += 1;
        }
        assert.equal(mismatches, 0);
      }
    });

    test("再処理しても sent は再送されない(通常再送不可)。送信内容も変わらない", async () => {
      await importBatch("batchA", 10);
      await create();
      await processJob();
      const first = sends.length;
      const result = await processJob();
      assert.equal(sends.length, first);
      assert.equal(result.processed, 0);
      assert.equal(result.status, "completed");
      const retried = await send.retry(asAdmin({jobId: "winner-batchA"}));
      assert.equal(retried.retried, 0);
      assert.equal(sends.length, first, "失敗が無ければ、再送準備しても何も送られない");
    });

    test("同時に複数のworkerが処理しても、各participantへの送信は1回だけ(二重dispatchしない)", async () => {
      await importBatch("batchA", 60);
      await create();
      const results = await Promise.all([processJob("winner-batchA", {limit: 200}), processJob("winner-batchA", {limit: 200}), processJob("winner-batchA", {limit: 200})]);
      assert.equal(sends.length, 60);
      assert.ok(Object.values(sendsTo()).every((n) => n === 1), JSON.stringify(sendsTo()));
      const final = await processJob();
      assert.deepEqual([final.status, final.sentCount], ["completed", 60]);
      assert.ok(results.reduce((sum, r) => sum + r.processed, 0) <= 60);
    });

    test("同一itemの同時claimは1つだけ成功する(lease有効中は他workerがclaimできない)", async () => {
      await importBatch("batchA", 3);
      await create();
      const claims = await Promise.all(Array.from({length: 10}, () => send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"})));
      assert.equal(claims.filter((c) => c.claimed).length, 1);
      assert.ok(claims.filter((c) => !c.claimed).every((c) => c.reason === "lease-active"));
      const d = await delivery("batchA-000002");
      assert.deepEqual([d.status, d.attemptCount], ["sending", 1]);
      assert.ok(d.leaseUntil.toMillis() > nowMs);
    });

    test("dispatch前にworkerが落ちた(確実に未送信) → lease期限後に安全に再claimでき、送信は1回だけ", async () => {
      await importBatch("batchA", 3);
      await create();
      const lost = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      assert.equal(lost.claimed, true);
      // 落ちた(何も送っていない)。lease有効中は他は取れず、processJobもこのitemを送らない。
      await processJob();
      assert.equal(sends.filter((m) => m.metadata.participantId === "batchA-000002").length, 0);
      assert.equal((await delivery("batchA-000002")).status, "sending");
      nowMs += 61000; // lease期限切れ
      const result = await processJob();
      assert.equal(sends.filter((m) => m.metadata.participantId === "batchA-000002").length, 1);
      assert.equal(result.status, "completed");
      assert.equal((await delivery("batchA-000002")).attemptCount, 2);
    });

    test("dispatchした後に結果が不明(lease期限切れ) → unknown。自動再送しない", async () => {
      await importBatch("batchA", 3);
      await create();
      const claim = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      assert.equal(await send.engine.startDispatch({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: claim.claimId}), true);
      // dispatchを始めた後で落ちた(送ったかどうか不明)
      nowMs += 61000;
      const result = await processJob();
      assert.equal(sends.filter((m) => m.metadata.participantId === "batchA-000002").length, 0, "自動再送しない");
      const d = await delivery("batchA-000002");
      assert.deepEqual([d.status, d.lastErrorCode], ["unknown", "lease-expired-after-dispatch"]);
      assert.deepEqual([result.status, result.unknownCount, result.sentCount], ["completed", 1, 2]);
      assert.equal(result.sentCount + result.failedCount + result.unknownCount, result.targetCount);
      // 何度処理・再送準備をしても送られない
      await processJob();
      await send.retry(asAdmin({jobId: "winner-batchA"}));
      await processJob();
      assert.equal(sends.filter((m) => m.metadata.participantId === "batchA-000002").length, 0);
      assert.equal((await delivery("batchA-000002")).status, "unknown");
    });

    test("遅れて届いた結果(同じclaimId)は、unknownを sent に確定できる。別のclaimIdの結果は適用されない", async () => {
      await importBatch("batchA", 2);
      await create();
      const claim = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      await send.engine.startDispatch({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: claim.claimId});
      nowMs += 61000;
      await processJob();
      assert.equal((await delivery("batchA-000002")).status, "unknown");
      assert.deepEqual(await send.engine.finishItem({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: "someone-else", outcome: "sent", messageId: "x"}), {applied: false});
      assert.equal((await delivery("batchA-000002")).status, "unknown");
      assert.deepEqual(await send.engine.finishItem({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: claim.claimId, outcome: "sent", messageId: "late-1"}), {applied: true});
      const d = await delivery("batchA-000002");
      assert.deepEqual([d.status, d.messageId], ["sent", "late-1"]);
    });

    test("claimが失われたworkerは、dispatchを開始できず送信しない", async () => {
      await importBatch("batchA", 2);
      await create();
      const first = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      nowMs += 61000; // lease期限切れ → 別workerが再claim
      const second = await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"});
      assert.equal(second.claimed, true);
      assert.equal(await send.engine.startDispatch({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: first.claimId}), false);
      assert.equal(await send.engine.startDispatch({db, jobId: "winner-batchA", participantId: "batchA-000002", claimId: second.claimId}), true);
    });

    test("送信が確実に拒否された(failed)分だけ、失敗分再送で送り直せる。sent・unknownは再送しない", async () => {
      await importBatch("batchA", 12);
      await create();
      const failing = new Set(["batchA-000003", "batchA-000005"]);
      const unknownIds = new Set(["batchA-000004"]);
      behavior = (message) => {
        const id = message.metadata.participantId;
        if (failing.has(id)) return {outcome: "failed", errorCode: "mail-api-400"};
        if (unknownIds.has(id)) return {outcome: "unknown", errorCode: "timeout"};
        return {outcome: "sent", messageId: `mid-${id}`};
      };
      const first = await processJob();
      assert.deepEqual([first.status, first.sentCount, first.failedCount, first.unknownCount], ["completed", 9, 2, 1]);
      assert.equal(first.sentCount + first.failedCount + first.unknownCount, first.targetCount);
      assert.equal((await delivery("batchA-000003")).lastErrorCode, "mail-api-400");
      const sentBefore = sends.length;
      // 失敗分を直して再送
      failing.clear();
      const retried = await send.retry(asAdmin({jobId: "winner-batchA"}));
      assert.equal(retried.retried, 2);
      assert.equal(retried.status, "ready", "再送待ちがあればcompletedではない");
      assert.deepEqual([retried.pendingCount, retried.unknownCount, retried.sentCount], [2, 1, 9]);
      const second = await processJob();
      assert.equal(sends.length - sentBefore, 2, "失敗した2件だけが再送される");
      assert.deepEqual(sends.slice(sentBefore).map((m) => m.metadata.participantId).sort(), ["batchA-000003", "batchA-000005"]);
      assert.deepEqual([second.status, second.sentCount, second.failedCount, second.unknownCount], ["completed", 11, 0, 1]);
      assert.equal((await delivery("batchA-000004")).status, "unknown", "unknownは自動再送されない");
      assert.equal((await delivery("batchA-000003")).attemptCount, 2);
    });

    test("transportが例外を投げた・不正な結果を返した場合は unknown(自動再送しない)", async () => {
      await importBatch("batchA", 4);
      await create();
      behavior = (message) => {
        const id = message.metadata.participantId;
        if (id === "batchA-000002") throw new Error("boom");
        if (id === "batchA-000003") return {outcome: "weird"};
        if (id === "batchA-000004") return undefined;
        return {outcome: "sent", messageId: "m"};
      };
      const result = await processJob();
      assert.deepEqual([result.sentCount, result.failedCount, result.unknownCount, result.status], [1, 0, 3, "completed"]);
      assert.equal((await delivery("batchA-000002")).lastErrorCode, "transport-exception");
    });

    test("mail-apiがQR付きメールに対応していなければ fail-closed(1通も送らず、状態も変えない)", async () => {
      await importBatch("batchA", 5);
      await create();
      capable = {ok: false, missing: ["html", "attachments"]};
      await assert.rejects(processJob(), (e) => e.code === "failed-precondition" && e.details.code === "mail-api-incapable" && e.details.missing.length === 2);
      assert.equal(sends.length, 0);
      const statuses = (await docs("mailDeliveries")).map((d) => d.data().status);
      assert.deepEqual([...new Set(statuses)], ["pending"]);
      capable = {ok: true, missing: []};
      assert.equal((await processJob()).sentCount, 5);
    });

    test("処理はadminだけ(staff・未認証は拒否)。失敗分再送もadminだけ", async () => {
      await importBatch("batchA", 3);
      await create();
      await rejectsWith(processJob("winner-batchA", {}, asStaff), "permission-denied");
      await rejectsWith(send.process({data: {jobId: "winner-batchA"}}), "unauthenticated");
      await rejectsWith(send.retry(asStaff({jobId: "winner-batchA"})), "permission-denied");
      await rejectsWith(send.retry({data: {jobId: "winner-batchA"}}), "unauthenticated");
      assert.equal(sends.length, 0);
      await rejectsWith(processJob("winner-nothing"), "not-found");
      await rejectsWith(processJob("bad"), "invalid-argument");
      await rejectsWith(processJob("winner-batchA", {limit: 0}), "invalid-argument");
      await rejectsWith(processJob("winner-batchA", {limit: 201}), "invalid-argument");
      await rejectsWith(send.process(asAdmin({jobId: "winner-batchA", to: "x@example.invalid"})), "invalid-argument");
    });

    test("limitで分割処理しても、pending/sendingが残る間はcompletedにならず、全件処理後にだけcompletedになる", async () => {
      await importBatch("batchA", 25);
      await create();
      const partial = await processJob("winner-batchA", {limit: 10});
      assert.deepEqual([partial.status, partial.sentCount, partial.pendingCount], ["ready", 10, 15]);
      assert.equal((await get("sendJobs/winner-batchA")).completedAt, null);
      const rest = await processJob("winner-batchA", {limit: 100});
      assert.deepEqual([rest.status, rest.sentCount, rest.pendingCount], ["completed", 25, 0]);
    });

    test("sending(lease有効)の項目が残っていれば completed にならない", async () => {
      await importBatch("batchA", 3);
      await create();
      await send.engine.claimItem({db, jobId: "winner-batchA", participantId: "batchA-000002"}); // 進行中のまま
      const result = await processJob();
      assert.deepEqual([result.status, result.sendingCount, result.sentCount, result.pendingCount], ["ready", 1, 2, 0]);
      assert.equal(result.sentCount + result.failedCount + result.unknownCount, 2);
      assert.notEqual(result.sentCount + result.failedCount + result.unknownCount, result.targetCount);
    });

    test("送信時に参加者が無効(cancelled)・存在しない場合は、送信せず failed(participant-unavailable)", async () => {
      await importBatch("batchA", 4);
      await create();
      await db.collection("participants").doc("batchA-000003").update({status: "cancelled"});
      await db.collection("participants").doc("batchA-000004").delete();
      const result = await processJob();
      assert.deepEqual([result.sentCount, result.failedCount], [2, 2]);
      assert.equal((await delivery("batchA-000003")).lastErrorCode, "participant-unavailable");
      assert.equal(sends.some((m) => ["batchA-000003", "batchA-000004"].includes(m.metadata.participantId)), false);
    });

    test("attendanceが無い参加者は、生成できないため送信せず failed(render-no-attendance)", async () => {
      const table = makeTable(3, (i) => (i === 1 ? {"午前参加時間": "参加を希望しない", "午前参加人数": "", "トークショー": "参加を希望しない", "トークショー人数": ""} : {}));
      await importBatch("batchA", table, {approvedReviewRows: [2]});
      await create();
      const result = await processJob();
      assert.deepEqual([result.sentCount, result.failedCount], [2, 1]);
      assert.equal((await delivery("batchA-000002")).lastErrorCode, "render-no-attendance");
      assert.ok(!sends.some((m) => m.metadata.participantId === "batchA-000002"));
    });

    test("templateVersion固定: ジョブ作成後にテンプレートを変更しても、処理中のジョブは作成時の文章のまま。次のbatchは新しいversion", async () => {
      await importBatch("batchA", 6);
      await importBatch("batchB", 6);
      await create("batchA");
      await processJob("winner-batchA", {limit: 3});
      await mail.update(asAdmin({eventId: "event1", template: {...TEMPLATE, subject: "第2回用の新しい件名", introBody: "新しい冒頭文"}}));
      await processJob("winner-batchA", {limit: 100});
      const first = sends.slice();
      assert.equal(first.length, 6);
      assert.ok(first.every((m) => m.subject === TEMPLATE.subject && m.text.includes(TEMPLATE.introBody) && !m.text.includes("新しい冒頭文")), "途中で文章が変わらない");
      assert.equal((await get("mailDeliveries/batchA-000002_winner")).templateVersion, 1);
      // 第2回batch: 新しいtemplateVersion
      const job2 = await create("batchB");
      assert.equal(job2.templateVersion, 2);
      await processJob("winner-batchB");
      const second = sends.slice(6);
      assert.equal(second.length, 6);
      assert.ok(second.every((m) => m.subject === "第2回用の新しい件名" && m.text.includes("新しい冒頭文")));
      assert.equal((await get("mailDeliveries/batchB-000002_winner")).templateVersion, 2);
      assert.equal((await get("mailDeliveries/batchA-000002_winner")).templateVersion, 1, "第1回の記録は旧versionのまま");
      assert.equal((await get("sendJobs/winner-batchA")).templateVersion, 1);
    });

    test("ジョブ作成後にeventの会場・イベント名が変わっても、既存ジョブのメールは作成時の内容(snapshot)で生成される", async () => {
      await importBatch("batchA", 2);
      await create();
      await db.collection("events").doc("event1").update({venue: "変更後の会場", eventName: "変更後のイベント名"});
      await processJob();
      assert.ok(sends.every((m) => m.text.includes("会場：架空会場ホール") && !m.text.includes("変更後")));
    });

    test("1件のメールの宛先メールは、送信の瞬間にparticipantsの正本から取得され、記録には残らない。ログにも出ない", async () => {
      const logged = [];
      const original = {log: console.log, error: console.error, warn: console.warn, info: console.info};
      for (const level of Object.keys(original)) console[level] = (...args) => logged.push(JSON.stringify(args));
      try {
        await importBatch("batchA", 3);
        await create();
        await processJob();
      } finally { Object.assign(console, original); }
      assert.ok(!logged.join("").includes("example.invalid"), "ログに宛先メールアドレスを出さない");
      const records = JSON.stringify([(await docs("mailDeliveries")).map((d) => d.data()), (await jobItems("winner-batchA")).map((d) => d.data()), await get("sendJobs/winner-batchA")]);
      assert.ok(!/synthetic\d@|example\.invalid.*synthetic/.test(records));
      assert.ok(!records.includes("p1@") && !/synthetic\d+@example/.test(records));
    });

    test("同一メール100participantでも、100通(各participantへ1通)を送り、sent=100でcompletedになる", async () => {
      await importBatch("batchA", makeTable(100, () => ({"メールアドレス": "same@example.invalid"})));
      await create();
      const result = await processJob("winner-batchA", {limit: 200});
      assert.deepEqual([result.targetCount, result.sentCount, result.status], [100, 100, "completed"]);
      assert.equal(sends.length, 100);
      assert.equal(new Set(sends.map((m) => m.metadata.participantId)).size, 100);
    });

    test("同一participantに複数の配送記録を作らない: winner配送の正本は1つ(participantId_winner)", async () => {
      await importBatch("batchA", 5);
      await create();
      await processJob();
      const ids = (await docs("mailDeliveries")).map((d) => d.id).sort();
      assert.deepEqual(ids, ["batchA-000002_winner", "batchA-000003_winner", "batchA-000004_winner", "batchA-000005_winner", "batchA-000006_winner"]);
      // 既に配送記録がある参加者は、別ジョブの対象に黙って含めない
      await db.collection("importBatches").doc("batchZ").set({eventId: "event1", status: "committed", createdCount: 1, sequence: 9});
      await db.collection("participants").doc("batchZ-000002").set({participantId: "batchZ-000002", eventId: "event1", status: "active", name: "架空", publicId: "pub_0123456789abcdef0123456789abcdef", email: "z@example.invalid", importBatchId: "batchZ"});
      await db.collection("mailDeliveries").doc("batchZ-000002_winner").set({status: "sent", jobId: "winner-old"});
      await assert.rejects(create("batchZ"), (e) => e.code === "failed-precondition" && e.details.code === "delivery-exists");
      assert.equal((await get("mailDeliveries/batchZ-000002_winner")).status, "sent", "既存の配送記録は上書きされない");
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("Phase 5の境界と実メール禁止", () => {
    test("import(commit)だけでは、送信ジョブも配送記録も作られず、メールは1通も送られない", async () => {
      await importBatch("batchA", 10);
      assert.equal(await count("sendJobs"), 0);
      assert.equal(await count("mailDeliveries"), 0);
      assert.equal(sends.length, 0);
    });

    test("外部通信0件: Emulator以外へのfetchは一度も行われない(送信は偽のtransportのみ)", async () => {
      await importBatch("batchA", 20);
      await send.create(asAdmin({eventId: "event1", batchId: "batchA"}));
      await send.process(asAdmin({jobId: "winner-batchA"}));
      await mail.preview(asAdmin({eventId: "event1", participantId: "batchA-000002"}));
      assert.deepEqual(externalCalls, []);
    });

    test("送信対象はcommittedなbatch由来のactive participantだけ(review未承認・error・除外はparticipantが無いので対象外)", async () => {
      const table = makeTable(6, (i) => (i === 2 ? {"午前参加時間": "22:20-22:20"} : i === 3 ? {"氏名": ""} : {}));
      await importBatch("batchA", table, {excludedRows: [{sourceRowNumber: 6, reason: "除外"}]});
      const job = await send.create(asAdmin({eventId: "event1", batchId: "batchA"}));
      const batch = await get("importBatches/batchA");
      assert.equal(job.targetCount, batch.createdCount);
      assert.deepEqual([batch.createdCount, batch.reviewPendingCount, batch.errorCount, batch.excludedByOperatorCount], [3, 1, 1, 1]);
      const ids = (await jobItems("winner-batchA")).map((d) => d.id).sort();
      assert.deepEqual(ids, ["batchA-000002", "batchA-000005", "batchA-000007"]);
    });
  });
});
