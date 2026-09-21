// confirmedのWeb参加証(公開・読み取り専用)とprogram別受付(staff/admin)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続して検証する。実Firestore・メール送信は一切ない。
// データはすべて架空(メールは予約TLD .invalid)。実CSVの参加者は使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, makeRecord, HEADERS, UNMAPPED_MARKER} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {createWinnerMailApi} = require("../confirmed/winner_mail_api");
const {createPassApi} = require("../confirmed/pass_api");
const {buildMailSnapshot} = require("../confirmed/mail_view_model");
const {renderWinnerMail} = require("../confirmed/mail_render");
const {receptionQrPayload, webPassUrl} = require("../confirmed/pass_urls");
const {loadAttendances} = require("../confirmed/winner_mail_message");
const {confirmedCallable, confirmedPublicPassCallable} = require("../auth");
const {publicRequest} = require("../test_support/app_check");
const {generateQrPng} = require("../qr_png");

const silent = {warn: () => {}, info: () => {}};
const APP_BASE_URL = "https://app.invalid";
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const errorOf = async (promise) => { try { await promise; } catch (error) { return {code: error.code, message: error.message, details: error.details}; } assert.fail("拒否されるはず"); };

describe("Web参加証・program別受付(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let pass; // 公開
  let view; // staff/admin
  let checkIn;
  let rateLimitCalls;
  let realFetch;
  let externalCalls;

  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const get = async (path) => (await db.doc(path).get()).data();
  const docs = async (path) => (await db.collection(path).get()).docs;

  function makeApis() {
    const serverTimestamp = () => env.FieldValue.serverTimestamp();
    const api = createPassApi({
      getDb: () => db, serverTimestamp, getAppBaseUrl: () => APP_BASE_URL, logger: silent,
      checkRateLimit: async (info) => { rateLimitCalls.push(info.kind); },
    });
    const publicCallable = confirmedPublicPassCallable(api.getPass, {logger: silent});
    const staffView = confirmedCallable("staffOrAdmin", api.getReceptionView, {db, logger: silent});
    const staffCheckIn = confirmedCallable("staffOrAdmin", api.checkIn, {db, logger: silent});
    pass = (data) => publicCallable.run(publicRequest({data}));
    view = (request) => staffView.run(request);
    checkIn = (request) => staffCheckIn.run(request);
  }

  async function seedEvent(overrides = {}) {
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
      venue: "架空会場ホール", contact: "架空事務局 support@example.invalid", venueInfo: {address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分"},
      programs: [{programId: "gamma", name: "トークセッション", order: 2}, {programId: "alpha", name: "譲渡会(ねこ)", order: 0}, {programId: "beta", name: "譲渡会(いぬ)", order: 1}],
      winnerMailTemplate: {subject: "件名", introBody: "冒頭", closingBody: "締め", notesBody: null, version: 1, updatedBy: "u-admin"},
      ...overrides,
    });
  }
  const importApi = () => createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
  // 3programすべてに参加する架空参加者(午前=alpha 2名・午後=beta 3名・トーク=gamma 1名)+ 午後不参加の参加者を取り込む
  async function importBatch(clientRequestId = "batchA", records) {
    const table = records ? {headers: HEADERS, records} : makeTable(3);
    return importApi().commit({identity: {uid: "u-admin"}, data: buildImportRequest({table, clientRequestId})});
  }
  const threeProgramRecord = (i) => makeRecord(i, {"午後参加時間": "13:00-14:00", "午後参加人数": "3"});
  async function participants() { return (await docs("participants")).map((d) => d.data()).sort((a, b) => a.importRow - b.importRow); }
  const idsOf = (p) => ({participantId: p.participantId, publicId: p.publicId});
  const receptionData = (p, extra = {}) => ({eventId: p.eventId, ...idsOf(p), ...extra});

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    realFetch = globalThis.fetch;
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("u-staff").set({role: "staff", active: true});
    await db.collection("accessRoles").doc("u-off").set({role: "staff", active: false});
    await seedEvent();
    rateLimitCalls = [];
    makeApis();
    externalCalls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) externalCalls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  // ---------------------------------------------------------------------------------------------
  describe("Web参加証(公開・読み取り専用)", () => {
    let p; // 3program参加者
    let other;
    let twoPrograms; // 午後不参加(2program)の参加者
    beforeEach(async () => {
      await importBatch("batchA", [threeProgramRecord(1), threeProgramRecord(2), makeRecord(3)]);
      [p, other, twoPrograms] = await participants();
    });

    test("正しい participantId + publicId で参加証を取得できる(イベント名・参加者名・program・QR・Web参加証URL)", async () => {
      const result = await pass(idsOf(p));
      assert.equal(result.eventName, "架空イベント");
      assert.equal(result.participantName, p.name);
      assert.equal(result.dateTimeText, "2026年11月30日(月) 10:00〜16:00");
      assert.equal(result.venue, "架空会場ホール");
      assert.equal(result.address, "〒000-0000 架空県架空市1-2-3");
      assert.equal(result.access, "架空駅から徒歩5分");
      assert.equal(result.webPassUrl, `${APP_BASE_URL}/p/${p.participantId}?publicId=${p.publicId}`);
      assert.deepEqual(rateLimitCalls, ["pass"], "rate limitのフックが呼ばれる(Phase 10で実装を渡せる)");
    });

    test("participantIdだけ・publicIdだけ・空・想定外のキーでは取得できない", async () => {
      for (const data of [{participantId: p.participantId}, {publicId: p.publicId}, {}, {participantId: p.participantId, publicId: ""},
        {...idsOf(p), extra: 1}, null, "x", [], {participantId: 123, publicId: p.publicId}]) {
        await rejectsWith(pass(data), "not-found");
      }
    });

    test("存在しないparticipant・誤ったpublicId・別participantのpublicId・形式不正は、すべて完全に同じ応答(存在を推測できない)", async () => {
      const cases = {
        missing: {participantId: "nothere-000002", publicId: p.publicId},
        wrong: {participantId: p.participantId, publicId: "pub_" + "x".repeat(30)},
        others: {participantId: p.participantId, publicId: other.publicId},
        malformed: {participantId: p.participantId, publicId: "short"},
        badId: {participantId: "../x", publicId: p.publicId},
      };
      const errors = [];
      for (const data of Object.values(cases)) errors.push(await errorOf(pass(data)));
      for (const error of errors) assert.deepEqual(error, errors[0]);
      assert.equal(errors[0].code, "not-found");
      assert.equal(errors[0].message, "参加証を確認できませんでした。");
      assert.equal(errors[0].details, undefined);
    });

    test("inactive・legacy(schemaVersionなし)・legacyイベント・failed/committingのbatch由来は、存在しない場合と同じ応答", async () => {
      const baseline = await errorOf(pass({participantId: "nothere-000002", publicId: p.publicId}));
      const unavailable = async (label, mutate, restore) => {
        await mutate();
        assert.deepEqual(await errorOf(pass(idsOf(p))), baseline, label);
        await restore();
        await pass(idsOf(p)); // 元に戻せば再び取得できる(この失敗が他の条件のせいではない)
      };
      await unavailable("cancelled", () => db.doc(`participants/${p.participantId}`).update({status: "cancelled"}), () => db.doc(`participants/${p.participantId}`).update({status: "active"}));
      await unavailable("legacy schema", () => db.doc(`participants/${p.participantId}`).update({schemaVersion: 1}), () => db.doc(`participants/${p.participantId}`).update({schemaVersion: 2}));
      await unavailable("legacy event", () => db.doc("events/event1").update({flow: "legacy"}), () => db.doc("events/event1").update({flow: "confirmed"}));
      await unavailable("event flow unset", () => db.doc("events/event1").update({flow: env.FieldValue.delete()}), () => db.doc("events/event1").update({flow: "confirmed"}));
      await unavailable("unknown flow", () => db.doc("events/event1").update({flow: "confirmd"}), () => db.doc("events/event1").update({flow: "confirmed"}));
      for (const status of ["failed", "committing"]) {
        await unavailable(`batch ${status}`, () => db.doc("importBatches/batchA").update({status}), () => db.doc("importBatches/batchA").update({status: "committed"}));
      }
      await unavailable("batch missing", async () => { await db.doc("participants/" + p.participantId).update({importBatchId: "no-such-batch"}); },
        () => db.doc(`participants/${p.participantId}`).update({importBatchId: "batchA"}));
      await unavailable("batch of another event", () => db.doc("importBatches/batchA").update({eventId: "other-event"}), () => db.doc("importBatches/batchA").update({eventId: "event1"}));
    });

    test("committedなbatchの参加者は取得でき、importBatchIdを持たない参加者(将来の手動追加等)も有効な条件を満たせば取得できる", async () => {
      await pass(idsOf(p));
      await db.doc(`participants/${p.participantId}`).update({importBatchId: env.FieldValue.delete()});
      await pass(idsOf(p));
    });

    test("メールアドレス・かな・sourceReference・importBatchId・監査情報・管理情報を返さない", async () => {
      const result = await pass(idsOf(p));
      // participantId(取込レコードID)自体は、従来のQR・URLにも含まれる識別子。それを除いた部分にbatchIdが現れないことを確認する
      const text = JSON.stringify(result).split(p.participantId).join("<pid>");
      const stored = await get(`participants/${p.participantId}`);
      for (const secret of [stored.email, stored.kana, stored.sourceReference, stored.importBatchId, "batchA", UNMAPPED_MARKER, "example.invalid", "u-admin", "importRow", "sourceReference"]) {
        if (secret) assert.ok(!text.includes(String(secret)), `参加証に含めてはならない値: ${String(secret).slice(0, 12)}`);
      }
      assert.deepEqual(Object.keys(result).sort(), ["access", "address", "dateTimeText", "eventName", "participantName", "programs", "qrPayload", "venue", "webPassUrl"]);
      for (const program of result.programs) {
        const keys = Object.keys(program).sort();
        assert.deepEqual(keys.filter((k) => k !== "timeText"), ["checkedIn", "name", "plannedCount", "programId"], "timeTextは時間があるprogramだけ");
      }
    });

    test("3programなら3件すべて返り、表示順はevent.programsのorder(Firestoreの取得順ではない)、plannedCountはそのまま", async () => {
      const result = await pass(idsOf(p));
      assert.deepEqual(result.programs.map((x) => [x.programId, x.name, x.plannedCount]),
        [["alpha", "譲渡会(ねこ)", 2], ["beta", "譲渡会(いぬ)", 3], ["gamma", "トークセッション", 1]]);
      assert.equal(result.programs.length, (await loadAttendances(db, p.participantId, "event1")).length, "取得件数と表示件数が一致");
      // orderを入れ替えると、表示順も入れ替わる(programIdや作成順ではなくorderが正本)
      await db.doc("events/event1").update({programs: [{programId: "gamma", name: "トークセッション", order: 0}, {programId: "alpha", name: "譲渡会(ねこ)", order: 5}, {programId: "beta", name: "譲渡会(いぬ)", order: 3}]});
      assert.deepEqual((await pass(idsOf(p))).programs.map((x) => x.programId), ["gamma", "beta", "alpha"]);
    });

    test("参加するprogramだけ表示される(午後不参加の参加者は2件)", async () => {
      const result = await pass(idsOf(twoPrograms));
      assert.deepEqual(result.programs.map((x) => x.programId), ["alpha", "gamma"]);
    });

    test("時間表示: slotLabel → attendanceの時間 → programの時間 → 表示しない(時刻を補完しない)", async () => {
      const att = (id) => db.doc(`programAttendances/${p.participantId}_${id}`);
      const timeOf = async (programId) => (await pass(idsOf(p))).programs.find((x) => x.programId === programId);
      // slotLabelがあれば最優先
      await att("alpha").update({slotLabel: "10:00-10:40", startAt: new Date("2026-11-30T05:00:00Z"), endAt: new Date("2026-11-30T06:00:00Z")});
      assert.equal((await timeOf("alpha")).timeText, "10:00-10:40");
      // slotLabelなし・attendanceの時間あり
      await att("alpha").update({slotLabel: null});
      assert.equal((await timeOf("alpha")).timeText, "14:00〜15:00");
      // どちらもなし・programの時間あり
      await att("beta").update({slotLabel: null, startAt: null, endAt: null});
      await db.doc("events/event1").update({programs: [{programId: "gamma", name: "トークセッション", order: 2}, {programId: "alpha", name: "譲渡会(ねこ)", order: 0},
        {programId: "beta", name: "譲渡会(いぬ)", order: 1, startAt: new Date("2026-11-30T02:00:00Z"), endAt: new Date("2026-11-30T03:00:00Z")}]});
      assert.equal((await timeOf("beta")).timeText, "11:00〜12:00");
      // どこにも時間がなければ、時間の欄そのものを返さない
      await att("gamma").update({slotLabel: null, startAt: null, endAt: null});
      const gamma = await timeOf("gamma");
      assert.equal("timeText" in gamma, false);
      assert.ok(!JSON.stringify(gamma).includes("null"));
    });

    test("QR payloadは Phase 6 の receptionQrPayload と完全に一致し、何度取得しても変わらない", async () => {
      const expected = receptionQrPayload({appBaseUrl: APP_BASE_URL, eventId: "event1", participantId: p.participantId, publicId: p.publicId});
      const first = await pass(idsOf(p));
      assert.equal(first.qrPayload, expected);
      assert.equal(first.qrPayload, `${APP_BASE_URL}/reception?eventId=event1&participantId=${p.participantId}&publicId=${p.publicId}`, "従来の受付QRと互換");
      for (let i = 0; i < 3; i += 1) assert.equal((await pass(idsOf(p))).qrPayload, expected);
      assert.equal(first.webPassUrl, webPassUrl({appBaseUrl: APP_BASE_URL, eventId: "event1", participantId: p.participantId, publicId: p.publicId}));
    });

    test("読み取り専用: 参加証の取得ではFirestoreに何も書き込まれない(受付状態・publicIdも不変)", async () => {
      const snapshot = async () => JSON.stringify(await Promise.all(["participants", "programAttendances", "events", "importBatches"].map(async (c) => (await docs(c)).map((d) => [d.id, d.data()]))));
      const before = await snapshot();
      for (let i = 0; i < 3; i += 1) await pass(idsOf(p));
      assert.equal(await snapshot(), before);
      assert.deepEqual((await db.listCollections()).map((c) => c.id).sort(), ["accessRoles", "events", "importBatches", "participants", "programAttendances"]);
    });

    test("参加証には受付状態(checkedIn)が反映されるが、受付時刻・人数・受付者は返さない", async () => {
      await checkIn(asStaff({...receptionData(p), programId: "alpha", attendedCount: 1}));
      const result = await pass(idsOf(p));
      assert.deepEqual(result.programs.map((x) => x.checkedIn), [true, false, false]);
      assert.ok(!JSON.stringify(result).includes("u-staff"));
      assert.ok(!("attendedCount" in result.programs[0]) && !("checkedInAt" in result.programs[0]));
    });

    test("participant一覧・他participantを取得する経路が無い(応答は1人分だけ)", async () => {
      const text = JSON.stringify(await pass(idsOf(p)));
      assert.ok(!text.includes(other.participantId) && !text.includes(other.publicId) && !text.includes(other.name));
    });

    test("外部通信・メール送信は発生しない", async () => {
      await pass(idsOf(p));
      assert.deepEqual(externalCalls, []);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("Phase 6の当選メールとの整合(メールQR・Web参加証・受付の3経路)", () => {
    test("メールのview modelと参加証のprogram名・時間・plannedCount・QR・Web参加証URLが完全に一致し、QRは同じ受付・参加証へ到達する", async () => {
      await importBatch("batchA", [threeProgramRecord(1), makeRecord(2)]);
      const [p, q] = await participants();
      const built = buildMailSnapshot("event1", await get("events/event1"));
      assert.ok(built.ok, JSON.stringify(built));
      for (const target of [p, q]) {
        const attendances = await loadAttendances(db, target.participantId, "event1");
        const mail = await renderWinnerMail({snapshot: built.snapshot, participant: {participantId: target.participantId, name: target.name, publicId: target.publicId}, attendances, appBaseUrl: APP_BASE_URL, generateQrPng});
        assert.ok(mail.ok, JSON.stringify(mail));
        const result = await pass(idsOf(target));
        assert.deepEqual(result.programs.map((x) => ({programId: x.programId, name: x.name, timeText: x.timeText, plannedCount: x.plannedCount})),
          mail.viewModel.programs.map((x) => ({programId: x.programId, name: x.name, timeText: x.timeText === null ? undefined : x.timeText, plannedCount: x.plannedCount})));
        assert.equal(result.qrPayload, mail.qrPayload, "Web参加証のQR = メールのQR");
        assert.equal(result.webPassUrl, mail.webPassUrl);
        assert.equal(result.participantName, mail.viewModel.recipientName);
        assert.ok(mail.text.includes(mail.webPassUrl), "メール本文の「QRが表示されない場合」のURL");

        // メールのQR(=受付URL)を読み取る → そのparticipantの受付画面へ到達する
        const qr = new URL(mail.qrPayload);
        assert.equal(qr.pathname, "/reception");
        const reception = await view(asStaff({eventId: qr.searchParams.get("eventId"), participantId: qr.searchParams.get("participantId"), publicId: qr.searchParams.get("publicId")}));
        assert.equal(reception.participantName, target.name);
        assert.deepEqual(reception.programs.map((x) => [x.programId, x.name, x.plannedCount]), result.programs.map((x) => [x.programId, x.name, x.plannedCount]));
        // メールの「QRが表示されない場合」のURL → 同じparticipantのWeb参加証へ到達する
        const web = new URL(mail.webPassUrl);
        assert.equal(web.pathname, `/p/${target.participantId}`);
        const viaUrl = await pass({participantId: web.pathname.split("/")[2], publicId: web.searchParams.get("publicId")});
        assert.equal(viaUrl.participantName, target.name);
        assert.equal(viaUrl.qrPayload, mail.qrPayload);
      }
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("受付画面の表示(getConfirmedReceptionView: staff/adminのみ)", () => {
    let p;
    let other;
    beforeEach(async () => {
      await importBatch("batchA", [threeProgramRecord(1), threeProgramRecord(2)]);
      [p, other] = await participants();
    });

    test("未認証・権限なし・無効なaccessRolesは拒否される(publicIdを知っていても受付画面は読めない)", async () => {
      await rejectsWith(view({data: receptionData(p)}), "unauthenticated");
      await rejectsWith(view({auth: {uid: "u-nobody"}, data: receptionData(p)}), "permission-denied");
      await rejectsWith(view({auth: {uid: "u-off"}, data: receptionData(p)}), "permission-denied");
    });

    test("staffもadminも取得でき、3program全件が表示順どおり・受付状態つきで返る。メールアドレス等は返らない", async () => {
      for (const actor of [asStaff, asAdmin]) {
        const result = await view(actor(receptionData(p)));
        assert.equal(result.eventName, "架空イベント");
        assert.equal(result.participantName, p.name);
        assert.deepEqual(result.programs.map((x) => [x.programId, x.name, x.plannedCount, x.checkedIn]),
          [["alpha", "譲渡会(ねこ)", 2, false], ["beta", "譲渡会(いぬ)", 3, false], ["gamma", "トークセッション", 1, false]]);
        assert.equal(result.programs.length, (await loadAttendances(db, p.participantId, "event1")).length);
        const stored = await get(`participants/${p.participantId}`);
        const text = JSON.stringify(result).split(p.participantId).join("<pid>");
        for (const secret of [stored.email, stored.kana, stored.sourceReference, "batchA", UNMAPPED_MARKER, p.publicId]) assert.ok(!text.includes(String(secret)));
      }
    });

    test("participantId/publicIdの不一致・eventIdの不一致・無効な参加者は「受付できません」(理由コードつき)で拒否される", async () => {
      const code = async (data) => (await errorOf(view(asStaff(data)))).details.code;
      assert.equal(await code({...receptionData(p), publicId: other.publicId}), "public-id-mismatch");
      assert.equal(await code({...receptionData(p), publicId: "pub_" + "y".repeat(30)}), "public-id-mismatch");
      assert.equal(await code({...receptionData(p), eventId: "event2"}), "event-mismatch");
      assert.equal(await code({...receptionData(p), participantId: "batchA-999999"}), "participant-missing");
      await db.doc(`participants/${p.participantId}`).update({status: "cancelled"});
      assert.equal(await code(receptionData(p)), "participant-not-active");
      await db.doc(`participants/${p.participantId}`).update({status: "active"});
      await db.doc("importBatches/batchA").update({status: "failed"});
      assert.equal(await code(receptionData(p)), "batch-not-committed");
      const error = await errorOf(view(asStaff(receptionData(p))));
      assert.equal(error.message, "この参加証は受付できません。");
      await rejectsWith(view(asStaff({participantId: p.participantId, publicId: p.publicId})), "invalid-argument");
      await rejectsWith(view(asStaff({...receptionData(p), plannedCount: 9})), "invalid-argument");
    });

    test("legacyイベント・flow未設定・未知のflowの参加者は受付画面に出ない", async () => {
      for (const flow of ["legacy", "confirmd", undefined]) {
        await db.doc("events/event1").update({flow: flow === undefined ? env.FieldValue.delete() : flow});
        assert.equal((await errorOf(view(asStaff(receptionData(p))))).details.code, "event-not-confirmed");
      }
    });

    test("受付状態はprogramごとに独立して表示される", async () => {
      await checkIn(asStaff({...receptionData(p), programId: "alpha", attendedCount: 1}));
      const result = await view(asStaff(receptionData(p)));
      assert.deepEqual(result.programs.map((x) => [x.programId, x.checkedIn]), [["alpha", true], ["beta", false], ["gamma", false]]);
      assert.equal(result.programs[0].attendedCount, 1);
      assert.equal(result.programs[0].plannedCount, 2, "予定人数と実来場人数は別");
      assert.match(result.programs[0].checkedInAt, /^\d{4}-\d{2}-\d{2}T/);
      assert.ok(!("attendedCount" in result.programs[1]) && !("checkedInAt" in result.programs[1]));
    });

    test("表示は読み取り専用(書込みなし)", async () => {
      const before = JSON.stringify((await docs("programAttendances")).map((d) => [d.id, d.data()]));
      await view(asStaff(receptionData(p)));
      assert.equal(JSON.stringify((await docs("programAttendances")).map((d) => [d.id, d.data()])), before);
    });
  });

  // ---------------------------------------------------------------------------------------------
  describe("program別受付(checkInConfirmedProgram)", () => {
    let p;
    let other;
    const att = (participant, programId) => get(`programAttendances/${participant.participantId}_${programId}`);
    const doCheckIn = (participant, programId, attendedCount, actor = asStaff, extra = {}) =>
      checkIn(actor({...receptionData(participant), programId, attendedCount, ...extra}));

    beforeEach(async () => {
      await importBatch("batchA", [threeProgramRecord(1), threeProgramRecord(2)]);
      [p, other] = await participants();
    });

    test("staffが受付でき、checkedIn・attendedCount・checkedInBy(認証UID)・checkedInAt(サーバー時刻)が保存される", async () => {
      const startedAt = Date.now();
      const result = await doCheckIn(p, "alpha", 2);
      assert.equal(result.alreadyCheckedIn, false);
      assert.equal(result.program.programId, "alpha");
      assert.equal(result.program.checkedIn, true);
      assert.equal(result.program.attendedCount, 2);
      const stored = await att(p, "alpha");
      assert.equal(stored.checkedIn, true);
      assert.equal(stored.attendedCount, 2);
      assert.equal(stored.checkedInBy, "u-staff");
      const at = stored.checkedInAt.toDate().getTime();
      assert.ok(at >= startedAt - 5000 && at <= Date.now() + 5000, "サーバー時刻(現在時刻付近)");
      assert.equal(result.program.checkedInAt, stored.checkedInAt.toDate().toISOString());
    });

    test("adminも受付でき、checkedInByはadminのUID。クライアントが送った uid・role・checkedInBy は使われない(拒否される)", async () => {
      await doCheckIn(p, "beta", 3, asAdmin);
      assert.equal((await att(p, "beta")).checkedInBy, "u-admin");
      for (const extra of [{checkedInBy: "u-forged"}, {uid: "u-admin"}, {role: "admin"}, {checkedInAt: "2020-01-01T00:00:00Z"}]) {
        await rejectsWith(doCheckIn(p, "gamma", 1, asStaff, extra), "invalid-argument");
      }
      assert.equal((await att(p, "gamma")).checkedIn, false);
    });

    test("未認証・権限なし・無効なaccessRoles・publicIdだけを知る第三者は受付できない(何も書き込まれない)", async () => {
      const before = JSON.stringify((await docs("programAttendances")).map((d) => [d.id, d.data()]));
      const data = {...receptionData(p), programId: "alpha", attendedCount: 2};
      await rejectsWith(checkIn({data}), "unauthenticated");
      await rejectsWith(checkIn({auth: {uid: "u-nobody"}, data}), "permission-denied");
      await rejectsWith(checkIn({auth: {uid: "u-off"}, data}), "permission-denied");
      assert.equal(JSON.stringify((await docs("programAttendances")).map((d) => [d.id, d.data()])), before);
      assert.deepEqual((await db.listCollections()).map((c) => c.id).includes("checkIns"), false);
    });

    test("参加者本人の公開参加証callableには、受付・変更の入口が無い(publicIdは閲覧専用)", async () => {
      // 公開callableに受付用の入力を渡しても、拒否される(想定外のキー)か、受付状態を変えない
      await rejectsWith(pass({...idsOf(p), programId: "alpha", attendedCount: 2}), "not-found");
      await pass(idsOf(p));
      assert.equal((await att(p, "alpha")).checkedIn, false);
      assert.equal(await docs("programAttendances").then((list) => list.filter((d) => d.data().checkedIn).length), 0);
    });

    test("participantId/publicId/eventId/programIdの不一致は拒否され、何も変わらない", async () => {
      const denied = async (data) => (await errorOf(checkIn(asStaff({...receptionData(p), programId: "alpha", attendedCount: 2, ...data})))).details?.code;
      assert.equal(await denied({publicId: other.publicId}), "public-id-mismatch");
      assert.equal(await denied({eventId: "event2"}), "event-mismatch");
      assert.equal(await denied({participantId: other.participantId}), "public-id-mismatch");
      // program不一致: このparticipantのattendanceが無いprogram / 存在しないprogram / 形式不正
      const q = await participants();
      const noBeta = q.find((x) => x.participantId !== p.participantId);
      await db.doc(`programAttendances/${noBeta.participantId}_beta`).delete();
      assert.equal((await errorOf(checkIn(asStaff({...receptionData(noBeta), programId: "beta", attendedCount: 1})))).details.code, "attendance-missing");
      assert.equal(await denied({programId: "zeta"}), "attendance-missing");
      await rejectsWith(checkIn(asStaff({...receptionData(p), programId: "Bad Id", attendedCount: 1})), "invalid-argument");
      for (const programId of ["alpha", "beta", "gamma"]) assert.equal((await att(p, programId)).checkedIn, false);
      assert.equal((await att(other, "alpha")).checkedIn, false);
    });

    test("attendanceのownerが食い違うデータ(別participant/別eventのdoc)では受付できない", async () => {
      await db.doc(`programAttendances/${p.participantId}_alpha`).update({participantId: other.participantId});
      assert.equal((await errorOf(doCheckIn(p, "alpha", 1))).details.code, "attendance-mismatch");
      await db.doc(`programAttendances/${p.participantId}_alpha`).update({participantId: p.participantId, eventId: "event2"});
      assert.equal((await errorOf(doCheckIn(p, "alpha", 1))).details.code, "attendance-mismatch");
    });

    test("plannedCountをクライアントから偽装・変更できない(キーは拒否・保存値は不変)。attendedCountとplannedCountは別", async () => {
      await rejectsWith(doCheckIn(p, "alpha", 2, asStaff, {plannedCount: 50}), "invalid-argument");
      assert.equal((await att(p, "alpha")).plannedCount, 2);
      assert.equal((await att(p, "alpha")).checkedIn, false);
      // 予定2名 → 実際1名。plannedCountは2のまま、attendedCountだけ1
      await doCheckIn(p, "alpha", 1);
      const stored = await att(p, "alpha");
      assert.deepEqual([stored.plannedCount, stored.attendedCount], [2, 1]);
      // 予定より多くても(当日の増員)attendedCountとして保存できるが、plannedCountは変わらない
      await doCheckIn(p, "beta", 5);
      assert.deepEqual([(await att(p, "beta")).plannedCount, (await att(p, "beta")).attendedCount], [3, 5]);
    });

    test("attendedCountは1以上の整数で上限あり(0・負・小数・文字列・巨大な値・未指定は拒否)", async () => {
      for (const value of [0, -1, 1.5, "2", null, undefined, 1000, Number.MAX_SAFE_INTEGER, NaN]) {
        await rejectsWith(checkIn(asStaff({...receptionData(p), programId: "alpha", attendedCount: value})), "invalid-argument");
      }
      assert.equal((await att(p, "alpha")).checkedIn, false);
      await doCheckIn(p, "alpha", 999);
      assert.equal((await att(p, "alpha")).attendedCount, 999);
    });

    test("programごとに独立: A受付でAだけtrue → 続けてB受付でA・Btrue・Cはfalse。別participantには影響しない", async () => {
      const states = async (participant) => Promise.all(["alpha", "beta", "gamma"].map(async (id) => (await att(participant, id)).checkedIn));
      await doCheckIn(p, "alpha", 2);
      assert.deepEqual(await states(p), [true, false, false]);
      await doCheckIn(p, "beta", 3);
      assert.deepEqual(await states(p), [true, true, false]);
      assert.deepEqual(await states(other), [false, false, false]);
      assert.equal((await att(p, "gamma")).attendedCount, null);
      assert.equal((await att(p, "gamma")).checkedInBy, null);
      // 受付画面でも同じ
      assert.deepEqual((await view(asStaff(receptionData(p)))).programs.map((x) => x.checkedIn), [true, true, false]);
    });

    test("二重受付: 既存のcheckedInAt・attendedCount・checkedInByを上書きせず、alreadyCheckedIn=trueで現在の受付情報を返す", async () => {
      await doCheckIn(p, "alpha", 2, asStaff);
      const first = await att(p, "alpha");
      const again = await doCheckIn(p, "alpha", 1, asAdmin);
      assert.equal(again.alreadyCheckedIn, true);
      assert.equal(again.program.attendedCount, 2, "現在の受付情報(先に受付した人数)を返す");
      const second = await att(p, "alpha");
      assert.deepEqual(second, first, "ドキュメント全体が不変");
      assert.equal(second.checkedInBy, "u-staff");
      assert.equal((await docs(`programAttendances/${p.participantId}_alpha/history`)).length, 1, "履歴も増えない");
    });

    test("同時に100件の受付要求(2端末・staff/admin混在)を出しても、成立するのは1回だけ", async () => {
      const results = await Promise.all(Array.from({length: 100}, (_, i) => doCheckIn(p, "alpha", (i % 5) + 1, i % 2 === 0 ? asStaff : asAdmin)));
      const winners = results.filter((r) => r.alreadyCheckedIn === false);
      assert.equal(winners.length, 1, "受付が成立したのは1回だけ");
      assert.equal(results.filter((r) => r.alreadyCheckedIn === true).length, 99);
      const stored = await att(p, "alpha");
      assert.equal(stored.attendedCount, winners[0].program.attendedCount, "保存されたのは勝った要求の人数");
      // 全員が、確定した同じ受付情報を返される(上書きされたものが混ざらない)
      assert.ok(results.every((r) => r.program.attendedCount === stored.attendedCount && r.program.checkedInAt === winners[0].program.checkedInAt));
      assert.equal((await docs(`programAttendances/${p.participantId}_alpha/history`)).length, 1);
      assert.equal((await att(p, "beta")).checkedIn, false);
    });

    test("受付履歴: 誰が・いつ・どのprogramを・何名で(before/after)。メールアドレス・氏名を複製しない", async () => {
      await doCheckIn(p, "gamma", 2, asAdmin);
      const history = await docs(`programAttendances/${p.participantId}_gamma/history`);
      assert.equal(history.length, 1);
      const h = history[0].data();
      assert.equal(h.action, "check-in");
      assert.equal(h.changedBy, "u-admin");
      assert.equal(h.programId, "gamma");
      assert.equal(h.participantId, p.participantId);
      assert.deepEqual(h.before, {checkedIn: false, attendedCount: null});
      assert.deepEqual(h.after, {checkedIn: true, attendedCount: 2});
      assert.ok(h.changedAt && typeof h.changedAt.toDate === "function");
      const stored = await get(`participants/${p.participantId}`);
      const text = JSON.stringify(h);
      for (const secret of [stored.email, stored.name, stored.kana, "example.invalid"]) assert.ok(!text.includes(secret));
    });

    test("cancelled・legacy(schemaVersion)・failed/committingのbatch・legacyイベント・未知flowの参加者は受付できず、何も書き込まれない", async () => {
      const attempt = async (label, mutate, restore) => {
        await mutate();
        await assert.rejects(doCheckIn(p, "alpha", 1), (error) => error.code === "failed-precondition", label);
        assert.equal((await att(p, "alpha")).checkedIn, false, label);
        await restore();
      };
      await attempt("cancelled", () => db.doc(`participants/${p.participantId}`).update({status: "cancelled"}), () => db.doc(`participants/${p.participantId}`).update({status: "active"}));
      await attempt("schema", () => db.doc(`participants/${p.participantId}`).update({schemaVersion: 1}), () => db.doc(`participants/${p.participantId}`).update({schemaVersion: 2}));
      for (const status of ["failed", "committing"]) {
        await attempt(status, () => db.doc("importBatches/batchA").update({status}), () => db.doc("importBatches/batchA").update({status: "committed"}));
      }
      for (const flow of ["legacy", "confirmd"]) await attempt(flow, () => db.doc("events/event1").update({flow}), () => db.doc("events/event1").update({flow: "confirmed"}));
      await attempt("program removed", () => db.doc("events/event1").update({programs: [{programId: "beta", name: "譲渡会(いぬ)", order: 1}, {programId: "gamma", name: "トークセッション", order: 2}]}), async () => {});
      assert.equal((await docs(`programAttendances/${p.participantId}_alpha/history`)).length, 0);
    });

    test("旧checkInsを受付の正本にしない: 新方式の受付ではcheckInsに何も書かれず、旧の人数フィールドも使われない", async () => {
      await doCheckIn(p, "alpha", 2);
      assert.equal((await docs("checkIns")).length, 0);
      const participant = await get(`participants/${p.participantId}`);
      assert.ok(!Object.keys(participant).some((key) => /registeredCount/i.test(key)));
    });

    test("後から受付画面を開き直すと「受付済み」になり、同じQRの再読込でも受付済みが分かる", async () => {
      await doCheckIn(p, "alpha", 2);
      const result = await view(asStaff(receptionData(p)));
      assert.equal(result.programs[0].checkedIn, true);
      assert.equal(result.programs[0].attendedCount, 2);
    });

    test("外部通信・メール送信は発生しない", async () => {
      await doCheckIn(p, "alpha", 2);
      await view(asStaff(receptionData(p)));
      await pass(idsOf(p));
      assert.deepEqual(externalCalls, []);
    });
  });
});
