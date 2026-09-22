// Phase 11B-4: 今年度の正式CSVフォーマット(sipposample形式)向けの自動判定mapping(lib/confirmed/import_profile.dart
// の buildMappingFromProfile が組み立てるのと同じ形)を、previewConfirmedImport / commitConfirmedImport の実物
// (Admin Emulator)に対して検証する。サーバー側のコード(import_mapping.js・import_rows.js等)は変更していない
// (participationColumn等は元々存在した機能で、今回はクライアントが自動的に設定するようになっただけ)。
// データはすべて架空。メールは予約TLD .invalid のみ。実CSV・実氏名・実メールは一切使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {createImportApi} = require("../confirmed/import_api");
const {confirmedCallable} = require("../auth");

const silent = {warn: () => {}};
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const NOT_ATTENDING = "参加を希望しない";
const ATTENDING = "参加を希望する";

// lib/confirmed/import_profile.dart の sipposample2026Profile と同じ列名・同じmapping形状。
const HEADERS = ["区分", "rd", "氏名", "かな", "メールアドレス", "都道府県", "性別", "年代",
  "午前参加時間", "午前参加人数", "午前相談", "午後参加時間", "午後参加人数", "午後相談",
  "トークショー", "トークショー人数", "キャンセル待希望枠", "キャンセル待希望人数", "登録日時", "備考"];

function sippoMapping() {
  return {
    version: 1,
    participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス", registeredAtColumn: "登録日時"},
    programs: [
      {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NOT_ATTENDING],
        emptyMeans: "notAttending", slotColumn: "午前参加時間", slotFormat: "timeRange", countColumn: "午前参加人数"},
      {programId: "program-2", participationColumn: "午後参加時間", notAttendingValues: [NOT_ATTENDING],
        emptyMeans: "notAttending", slotColumn: "午後参加時間", slotFormat: "timeRange", countColumn: "午後参加人数"},
      {programId: "program-3", participationColumn: "トークショー", attendingValues: [ATTENDING],
        notAttendingValues: [NOT_ATTENDING], emptyMeans: "notAttending", countColumn: "トークショー人数"},
    ],
  };
}

function defaults(i) {
  return {
    "区分": "新規申込", "rd": `R${i}`, "氏名": `架空参加者${i}`, "かな": "かくうさんかしゃ",
    "メールアドレス": `sippo${i}@example.invalid`, "都道府県": "架空県", "性別": "未回答", "年代": "未回答",
    "午前参加時間": "10:00-11:00", "午前参加人数": "1", "午前相談": "",
    "午後参加時間": NOT_ATTENDING, "午後参加人数": "", "午後相談": "",
    "トークショー": NOT_ATTENDING, "トークショー人数": "",
    "キャンセル待希望枠": "", "キャンセル待希望人数": "",
    "登録日時": "2026年01月02日 03時04分05秒", "備考": "この値は取り込まれない",
  };
}

function makeRecord(i, overrides = {}) {
  const values = {...defaults(i), ...overrides};
  return HEADERS.map((h) => values[h]);
}

function makeTable(n, overridesFor = () => ({})) {
  return {headers: [...HEADERS], records: Array.from({length: n}, (_, k) => makeRecord(k + 1, overridesFor(k + 1)))};
}

describe("CSV取込: 今年度の正式フォーマット(sipposample形式)を自動判定するmapping(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;

  const makeApi = () => {
    const api = createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
    const wrap = (level, handler) => {
      const callable = confirmedCallable(level, handler, {db, logger: silent});
      return (request) => callable.run(request);
    };
    return {preview: wrap("admin", api.preview), commit: wrap("admin", api.commit)};
  };
  let api;
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});

  async function seedEvent(overrides = {}) {
    const program = (programId, name, order) => ({programId, name, order});
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント(sipposample形式)", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
      programs: [program("program-1", "午前の譲渡会", 0), program("program-2", "午後の譲渡会", 1), program("program-3", "トークショー", 2)],
      ...overrides,
    });
  }
  async function docs(path, query) {
    const ref = query ? query(db.collection(path)) : db.collection(path);
    return (await ref.get()).docs;
  }
  const count = async (path, query) => (await docs(path, query)).length;
  const participantsOf = async (id) => docs("participants", (c) => c.where("importBatchId", "==", id));
  const request = (tableOrN, options = {}) => buildImportRequest({
    table: typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN, mapping: sippoMapping(), ...options,
  });

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await seedEvent();
    api = makeApi();
  });

  test("90行相当のCSVを、mapping操作なしでpreviewできる(全行ready)", async () => {
    const result = await api.preview(asAdmin(request(90)));
    assert.deepEqual([result.totalRows, result.readyCount, result.reviewCount, result.errorCount], [90, 90, 0, 0]);
    assert.equal(result.participantCandidateCount, 90);
  });

  test("氏名・かな・メールが自動取得され、午前参加時間/午前参加人数からprogram-1、午後参加時間/午後参加人数からprogram-2、トークショー/トークショー人数からprogram-3のattendanceが作られる。1人が3program参加してもparticipantは1件・attendanceは3件", async () => {
    const table = makeTable(1, () => ({
      "午前参加時間": "10:00-11:00", "午前参加人数": "2",
      "午後参加時間": "13:00-14:00", "午後参加人数": "1",
      "トークショー": ATTENDING, "トークショー人数": "2",
    }));
    const result = await api.commit(asAdmin(request(table)));
    assert.equal(result.status, "committed");
    assert.equal(result.createdCount, 1, "人数が2でもparticipantは1件");
    assert.equal(await count("participants"), 1);
    assert.equal(await count("programAttendances"), 3, "1人が3program参加してもattendanceは3件");
    const p = (await docs("participants"))[0].data();
    assert.equal(p.name, "架空参加者1");
    assert.equal(p.kana, "かくうさんかしゃ");
    assert.equal(p.email, "sippo1@example.invalid");
    const alpha = (await db.collection("programAttendances").doc(`${p.participantId}_program-1`).get()).data();
    const beta = (await db.collection("programAttendances").doc(`${p.participantId}_program-2`).get()).data();
    const gamma = (await db.collection("programAttendances").doc(`${p.participantId}_program-3`).get()).data();
    assert.deepEqual([alpha.plannedCount, alpha.slotLabel], [2, "10:00-11:00"]);
    assert.deepEqual([beta.plannedCount, beta.slotLabel], [1, "13:00-14:00"]);
    assert.deepEqual([gamma.plannedCount, gamma.slotLabel], [2, null], "トークショーには時間枠が無い");
  });

  test("「参加を希望しない」の行はattendanceを作らない(不参加)", async () => {
    const table = makeTable(1, () => ({
      "午前参加時間": NOT_ATTENDING, "午前参加人数": "",
      "午後参加時間": NOT_ATTENDING, "午後参加人数": "",
      "トークショー": NOT_ATTENDING, "トークショー人数": "",
    }));
    const result = await api.preview(asAdmin(request(table)));
    // 3programすべて不参加(かつ他に問題が無い)行は「参加するprogramが無い」としてreview(黙ってactiveにしない)
    assert.deepEqual([result.readyCount, result.reviewCount, result.errorCount], [0, 1, 0]);
    assert.deepEqual(result.rows[0].issueCodes, ["no-program"]);
  });

  test("空欄の行もattendanceを作らない(不参加)", async () => {
    const table = makeTable(1, () => ({
      "午前参加時間": "", "午前参加人数": "", "午後参加時間": "", "午後参加人数": "", "トークショー": "", "トークショー人数": "",
    }));
    const result = await api.preview(asAdmin(request(table)));
    assert.deepEqual([result.readyCount, result.reviewCount, result.errorCount], [0, 1, 0]);
    assert.deepEqual(result.rows[0].issueCodes, ["no-program"]);
  });

  test("参加するprogramなのに人数が空・0・不正 → review/error(黙ってplannedCountを補わない)", async () => {
    const empty = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加人数": ""})))));
    assert.equal(empty.rows[0].classification, "review");
    assert.deepEqual(empty.rows[0].issueCodes, ["attending-count-missing"]);

    const zero = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加人数": "0"})))));
    assert.equal(zero.rows[0].classification, "error");
    assert.deepEqual(zero.rows[0].issueCodes, ["count-invalid"]);

    const negative = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加人数": "-1"})))));
    assert.equal(negative.rows[0].classification, "error");
    assert.deepEqual(negative.rows[0].issueCodes, ["count-invalid"]);

    const decimal = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加人数": "1.5"})))));
    assert.equal(decimal.rows[0].classification, "error");
    assert.deepEqual(decimal.rows[0].issueCodes, ["count-invalid"]);

    const text = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加人数": "たくさん"})))));
    assert.equal(text.rows[0].classification, "error");
    assert.deepEqual(text.rows[0].issueCodes, ["count-invalid"]);
  });

  test("22:20-22:20のような値も「有効な時間枠文字列」として参加の意思ありと扱う(時間枠自体の問題はreview)", async () => {
    const result = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加時間": "22:20-22:20"})))));
    assert.equal(result.rows[0].classification, "review");
    assert.deepEqual(result.rows[0].issueCodes, ["slot-zero-length"]);
    assert.deepEqual(result.rows[0].programIds, ["program-1"], "参加の意思はあるのでattendance候補は作られる");
  });

  test("slotLabelは参加者ごとに独立している", async () => {
    const table = makeTable(2, (i) => ({"午前参加時間": i === 1 ? "09:00-09:30" : "15:00-15:45", "午前参加人数": "1"}));
    await api.commit(asAdmin(request(table)));
    const rows = await docs("programAttendances");
    const labels = rows.map((d) => d.data().slotLabel).sort();
    assert.deepEqual(labels, ["09:00-09:30", "15:00-15:45"]);
  });

  test("必要なheaderが欠落していれば拒否される(unexpected-column・column-missingはクライアント側で先に検出するが、サーバーも安全に拒否する)", async () => {
    const data = request(1);
    const i = data.headers.indexOf("午前参加時間");
    data.headers.splice(i, 1);
    data.rows.forEach((r) => r.values.splice(i, 1));
    await rejectsWith(api.preview(asAdmin(data)), "invalid-argument");
  });

  test("列順が変わってもheader名で解決できる", async () => {
    const table = makeTable(1);
    const shuffledHeaders = [...table.headers].reverse();
    const shuffledRecords = table.records.map((r) => [...r].reverse());
    const shuffled = {headers: shuffledHeaders, records: shuffledRecords};
    const result = await api.preview(asAdmin(request(shuffled)));
    assert.equal(result.readyCount, 1);
  });

  test("1 CSV行 = 1 participant。同一メール100行・同一氏名100行はどちらも100participant(重複統合なし)", async () => {
    const r1 = await api.commit(asAdmin(request(makeTable(100, () => ({"メールアドレス": "same@example.invalid"})))));
    assert.equal(r1.createdCount, 100);
    assert.equal(await count("participants"), 100);
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await seedEvent();
    const r2 = await api.commit(asAdmin(request(makeTable(100, () => ({"氏名": "架空同姓同名"})))));
    assert.equal(r2.createdCount, 100);
    assert.equal(await count("participants"), 100);
  });

  test("rd(参照コード)・備考は取り込まない(参照コードはこのprofileでは未指定、備考は保存先が無い)", async () => {
    await api.commit(asAdmin(request(makeTable(3, (i) => ({"rd": `R-SECRET-${i}`, "備考": "秘密の自由記述"})))));
    const all = JSON.stringify((await docs("participants")).map((d) => d.data()));
    assert.ok(!all.includes("R-SECRET"));
    assert.ok(!all.includes("秘密の自由記述"));
  });

  test("batch1をcommit後にbatch2をcommitしても、batch1のparticipantは不変。各batchは独立したimportBatch", async () => {
    const batch1 = await api.commit(asAdmin(request(makeTable(5), {clientRequestId: "batchA", label: "第1回"})));
    assert.equal(batch1.createdCount, 5);
    const batch1Participants = (await participantsOf("batchA")).map((d) => d.id).sort();

    const batch2 = await api.commit(asAdmin(request(makeTable(3, (i) => ({"メールアドレス": `round2-${i}@example.invalid`})), {clientRequestId: "batchB", label: "第2回"})));
    assert.equal(batch2.createdCount, 3);

    assert.deepEqual((await participantsOf("batchA")).map((d) => d.id).sort(), batch1Participants, "batch1のparticipantは変わらない");
    assert.equal(await count("participants"), 8, "batch1(5) + batch2(3) が両方保持される");
    assert.equal(await count("importBatches"), 2);
  });

  test("再commit(同じ内容の再送)で二重作成なし(冪等性)", async () => {
    const data = request(makeTable(10));
    const first = await api.commit(asAdmin(data));
    const second = await api.commit(asAdmin(data));
    assert.equal(first.idempotentReplay, false);
    assert.equal(second.idempotentReplay, true);
    assert.equal(await count("participants"), 10);
  });

  test("取込だけではメールは1通も送られない(メール関連コレクションは0件のまま)", async () => {
    await api.preview(asAdmin(request(20)));
    await api.commit(asAdmin(request(20)));
    for (const name of ["mailJobs", "sendJobs", "mailLogs", "mailDeliveries"]) assert.equal(await count(name), 0, name);
  });

  test("publicIdはparticipantごとに1つ、サーバーが生成する(pub_ + 192bit)", async () => {
    await api.commit(asAdmin(request(30)));
    const ids = (await docs("participants")).map((d) => d.data().publicId);
    assert.equal(new Set(ids).size, 30);
    assert.ok(ids.every((id) => /^pub_[A-Za-z0-9_-]{32}$/.test(id)));
  });
});
