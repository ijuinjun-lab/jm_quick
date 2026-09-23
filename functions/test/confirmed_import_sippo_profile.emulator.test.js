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
const {createPassApi} = require("../confirmed/pass_api");
const {confirmedCallable} = require("../auth");

const silent = {warn: () => {}};
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const NOT_ATTENDING = "参加を希望しない";
const ATTENDING = "参加を希望する";

// lib/confirmed/import_profile.dart の sipposample2026Profile と同じ列名・同じmapping形状。
const HEADERS = ["区分", "rd", "氏名", "かな", "メールアドレス", "都道府県", "性別", "年代",
  "午前参加時間", "午前参加人数", "午前相談", "午後参加時間", "午後参加人数", "午後相談",
  "トークショー", "トークショー人数", "キャンセル待希望枠", "キャンセル待希望人数", "登録日時", "備考"];

// Phase 11G: 午前/午後参加時間はslotFormat="label"(文字列としてそのまま保持。開始・終了時刻としての
// 妥当性検証はしない)。実CSV(sipposample1.csv、本番E2Eで確認)には「22:20-22:20」のような、主催者の
// 確定参加者リスト上の時間枠の表示値が含まれ、これをtimeRangeとして厳密検証するとslot-zero-length・
// slot-reversedが大量に発生し、37/90行が不要にreview化されていた(読み取り専用監査で確認済み)。
//
// Phase 11H: 3programすべてignoreCountWhenNotAttending: true(functions/confirmed/import_mapping.js・
// import_rows.js に追加した、既定false・後方互換のオプション)。実CSVには、参加意思の列では明確に
// 「参加を希望しない」でありながら、不参加と判定したprogramの人数列に値が残っている行が5/90件あった
// (読み取り専用監査で確認。全5件で他の少なくとも1つのprogramには明確な参加があった)。SIPPO形式では
// 参加意思の列を唯一の正本とし、不参加と判定したprogramの人数列は無視する(このprofileだけの設定。
// ignoreCountWhenNotAttendingを指定しないprogram・profileでは、既存のnot-attending-count-present
// 検出は変更していない。下の「汎用の安全チェックは維持される」テストで確認する)。
function sippoMapping() {
  return {
    version: 1,
    participant: {nameColumn: "氏名", kanaColumn: "かな", emailColumn: "メールアドレス", registeredAtColumn: "登録日時"},
    programs: [
      {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NOT_ATTENDING],
        emptyMeans: "notAttending", slotColumn: "午前参加時間", slotFormat: "label", countColumn: "午前参加人数",
        ignoreCountWhenNotAttending: true},
      {programId: "program-2", participationColumn: "午後参加時間", notAttendingValues: [NOT_ATTENDING],
        emptyMeans: "notAttending", slotColumn: "午後参加時間", slotFormat: "label", countColumn: "午後参加人数",
        ignoreCountWhenNotAttending: true},
      {programId: "program-3", participationColumn: "トークショー", attendingValues: [ATTENDING],
        notAttendingValues: [NOT_ATTENDING], emptyMeans: "notAttending", countColumn: "トークショー人数",
        ignoreCountWhenNotAttending: true},
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
    const passApi = createPassApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
    const wrap = (level, handler) => {
      const callable = confirmedCallable(level, handler, {db, logger: silent});
      return (request) => callable.run(request);
    };
    return {
      preview: wrap("admin", api.preview),
      commit: wrap("admin", api.commit),
      checkIn: wrap("staffOrAdmin", passApi.checkIn),
    };
  };
  let api;
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});

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
    await db.collection("accessRoles").doc("u-staff").set({role: "staff", active: true});
    await seedEvent();
    api = makeApi();
  });

  test("90行相当のCSVを、mapping操作なしでpreviewできる(全行ready)", async () => {
    const result = await api.preview(asAdmin(request(90)));
    assert.deepEqual([result.totalRows, result.readyCount, result.reviewCount, result.errorCount], [90, 90, 0, 0]);
    assert.equal(result.participantCandidateCount, 90);
  });

  // Phase 11G: 本番E2Eで確認した実CSV(sipposample1.csv、90行)と同じ比率の「時間枠の表示値」パターンを
  // 架空データで再現したfixture(実CSVの値はコピーしない。読み取り専用監査で確認した現象の再現のみ)。
  // A: 午前参加時間="22:20-22:20"(開始=終了に見える値)21件 + 午後="21:20-21:20" 2件 = 23件
  // B: 午後参加時間="22:20-21:20"(逆転に見える値)8件
  // C: 「参加を希望しない」なのに人数が入っている(データ矛盾)3件
  // D: A・Bのパターンと、Cのパターンが同じ行に同時発生 3件
  // 残り53件は通常の参加(defaults()どおり)。合計90行。
  function sipposampleLikeTable() {
    const overridesFor = (i) => {
      if (i >= 1 && i <= 21) return {"午前参加時間": "22:20-22:20", "午前参加人数": "2"};
      if (i >= 22 && i <= 23) return {"午後参加時間": "21:20-21:20", "午後参加人数": "2"};
      if (i >= 24 && i <= 31) return {"午後参加時間": "22:20-21:20", "午後参加人数": "2"};
      if (i >= 32 && i <= 34) {
        // 実CSVの行10・54・58と同じ構造: 午前は不参加(矛盾なし)、午後は不参加なのに人数が残る(データ矛盾。
        // SIPPO profileでは無視する)、トークショーは明確に参加(他のprogramに明確な参加がある、という
        // 読み取り専用監査で確認した実際のパターン)。
        return {
          "午前参加時間": NOT_ATTENDING, "午前参加人数": "",
          "午後参加時間": NOT_ATTENDING, "午後参加人数": "2",
          "トークショー": ATTENDING, "トークショー人数": "2",
        };
      }
      if (i >= 35 && i <= 37) {
        // 午前は「22:20-22:20」に見える値だが参加の意思あり(label化により問題なし)、
        // 午後は「参加を希望しない」なのに人数が入っている(データ矛盾)、という2つのパターンが同じ行に発生。
        return {"午前参加時間": "22:20-22:20", "午前参加人数": "2", "午後参加時間": NOT_ATTENDING, "午後参加人数": "2"};
      }
      return {};
    };
    return makeTable(90, overridesFor);
  }

  test("Phase 11H: 実CSVと同じ比率のfixture(90行)で、時間枠だけを理由とするreviewは0件、"
    + "不参加programの人数は無視されるためnot-attending-count-presentも発生しない(全90行ready)", async () => {
    const result = await api.preview(asAdmin(request(sipposampleLikeTable())));
    // 推測でハードコードせず、実ロジック(サーバーのplanImportRows)の結果をそのまま検証する。
    assert.deepEqual(
      [result.totalRows, result.readyCount, result.reviewCount, result.errorCount],
      [90, 90, 0, 0],
    );
    assert.deepEqual(result.issueCounts, {});
    assert.ok(!("slot-zero-length" in result.issueCounts), "slot-zero-lengthは発生しない");
    assert.ok(!("slot-reversed" in result.issueCounts), "slot-reversedは発生しない");
    assert.ok(!("not-attending-count-present" in result.issueCounts),
      "SIPPO profileではignoreCountWhenNotAttendingにより不参加programの人数は無視される");
  });

  test("Phase 11H: 上記fixtureをcommitしても、不参加と判定したprogramにはattendance・plannedCountが作られない"
    + "(参加意思の列だけが正本。人数は無視される)", async () => {
    const result = await api.commit(asAdmin(request(sipposampleLikeTable())));
    assert.equal(result.status, "committed");
    assert.equal(result.createdCount, 90);
    // C・D行(32〜37、架空データのため氏名は「架空参加者32」〜「架空参加者37」)は、午後が「参加を希望しない」
    // なのに人数=2が残っているが、program-2のattendanceは作られない(不参加のprogramは人数を使わない)。
    for (let i = 32; i <= 37; i++) {
      const participant = (await docs("participants")).find((d) => d.data().name === `架空参加者${i}`);
      const beta = await db.collection("programAttendances").doc(`${participant.id}_program-2`).get();
      assert.equal(beta.exists, false, `行${i}: 不参加と判定したprogram-2にattendanceを作らない`);
    }
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

  test("Phase 11G: 時間枠はlabelとして保持するため、22:20-22:20(開始=終了に見える値)もreadyになる(slot-zero-lengthは発生しない)", async () => {
    const result = await api.preview(asAdmin(request(makeTable(1, () => ({"午前参加時間": "22:20-22:20"})))));
    assert.equal(result.rows[0].classification, "ready");
    assert.deepEqual(result.rows[0].issueCodes, []);
    assert.deepEqual(result.rows[0].programIds, ["program-1"]);
    const committed = await api.commit(asAdmin(request(makeTable(1, () => ({"午前参加時間": "22:20-22:20"})))));
    assert.equal(committed.createdCount, 1);
    const attendance = (await docs("programAttendances"))[0].data();
    assert.deepEqual([attendance.slotLabel, attendance.startAt, attendance.endAt], ["22:20-22:20", null, null]);
  });

  test("Phase 11G: 22:20-21:20(逆転に見える値)もlabelとして保持し、slot-reversedは発生しない", async () => {
    const result = await api.preview(asAdmin(request(makeTable(1, () => ({"午後参加時間": "22:20-21:20", "午後参加人数": "2"})))));
    assert.equal(result.rows[0].classification, "ready");
    assert.deepEqual(result.rows[0].issueCodes, []);
    const committed = await api.commit(asAdmin(request(makeTable(1, () => ({"午後参加時間": "22:20-21:20", "午後参加人数": "2"})))));
    assert.equal(committed.createdCount, 1);
    const beta = (await docs("programAttendances")).find((d) => d.data().programId === "program-2").data();
    assert.deepEqual([beta.slotLabel, beta.startAt, beta.endAt, beta.plannedCount], ["22:20-21:20", null, null, 2]);
  });

  test("Phase 11G: 21:20-21:20(開始=終了に見える値。別の時刻)も同様にreadyのままlabelとして保持する", async () => {
    const result = await api.preview(asAdmin(request(makeTable(1, () => ({"午後参加時間": "21:20-21:20", "午後参加人数": "2"})))));
    assert.equal(result.rows[0].classification, "ready");
    assert.deepEqual(result.rows[0].issueCodes, []);
  });

  test("Phase 11H: SIPPO profileでは、「参加を希望しない」なのに人数が入っていてもreview化しない"
    + "(参加意思の列を正本とし、不参加と判定したprogramの人数は無視する。plannedCount・attendanceも作らない)", async () => {
    // 午前は不参加(矛盾なし)、午後は不参加なのに人数が残る(データ矛盾。SIPPO profileでは無視)、
    // トークショーは明確に参加(実CSVで確認した実際のパターンと同じ構造。他のprogramへの参加はある)。
    const table = makeTable(1, () => ({
      "午前参加時間": NOT_ATTENDING, "午前参加人数": "",
      "午後参加時間": NOT_ATTENDING, "午後参加人数": "2",
      "トークショー": ATTENDING, "トークショー人数": "2",
    }));
    const result = await api.preview(asAdmin(request(table)));
    assert.equal(result.rows[0].classification, "ready");
    assert.deepEqual(result.rows[0].issueCodes, []);
    assert.deepEqual(result.rows[0].programIds, ["program-3"], "不参加と判定した午前・午後にはattendance候補を作らない(人数は無視)");
    const committed = await api.commit(asAdmin(request(table)));
    assert.equal(committed.createdCount, 1);
    assert.equal(await count("programAttendances"), 1, "参加したトークショーだけattendanceが作られる");
  });

  test("Phase 11H: SIPPO profileでも、全programが不参加(かつ矛盾以外に問題が無い)行は、"
    + "無条件にactiveとして取り込まず引き続きreview(no-program。既存の別の安全チェックで、今回変更していない)", async () => {
    const table = makeTable(1, () => ({
      "午前参加時間": NOT_ATTENDING, "午前参加人数": "",
      "午後参加時間": NOT_ATTENDING, "午後参加人数": "2", // 矛盾は無視されるが、他に参加が無ければno-program
      "トークショー": NOT_ATTENDING, "トークショー人数": "",
    }));
    const result = await api.preview(asAdmin(request(table)));
    assert.equal(result.rows[0].classification, "review");
    assert.deepEqual(result.rows[0].issueCodes, ["no-program"]);
  });

  test("Phase 11H: 汎用の安全チェック(not-attending-count-present)は、ignoreCountWhenNotAttendingを"
    + "指定しないprogram・profileでは変更していない(SIPPO profile以外は従来どおりreviewに残す)", async () => {
    // sippoMapping()をそのまま使わず、ignoreCountWhenNotAttendingを指定しない(=既定false)独立したmappingで検証する。
    // これはSIPPO以外の一般的なprofileを想定した確認であり、汎用Functionsの安全チェックが緩んでいないことの証明。
    const genericMapping = {
      version: 1,
      participant: {nameColumn: "氏名", emailColumn: "メールアドレス"},
      programs: [
        {programId: "program-1", participationColumn: "午前参加時間", notAttendingValues: [NOT_ATTENDING],
          emptyMeans: "notAttending", countColumn: "午前参加人数"}, // ignoreCountWhenNotAttendingを指定しない(既定false)
      ],
    };
    const table = makeTable(1, () => ({"午前参加時間": NOT_ATTENDING, "午前参加人数": "2"}));
    const result = await api.preview(asAdmin(request(table, {mapping: genericMapping})));
    assert.equal(result.rows[0].classification, "review");
    assert.deepEqual(result.rows[0].issueCodes, ["not-attending-count-present"]);
    assert.deepEqual(result.rows[0].programIds, []);
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

  test("Phase 11H: ignoreCountWhenNotAttendingは真偽値でなければ拒否される(不正なmappingは受理しない)", async () => {
    const data = request(1);
    data.mapping.programs[0].ignoreCountWhenNotAttending = "yes";
    await assert.rejects(api.preview(asAdmin(data)), (e) =>
      e.code === "invalid-argument" && e.details.code === "invalid-mapping");
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

  test("Phase 11G回帰: 当日のQR受付(既存・無変更のcheckIn)は、CSV取込時のplannedCountを変更せず、attendedCountだけを実参加人数として保存する", async () => {
    // 予定4名(CSVの人数)で取込 → 当日は2名だけ来場、というplannedCount≠attendedCountの典型例。
    await api.commit(asAdmin(request(makeTable(1, () => ({"午前参加時間": "22:20-22:20", "午前参加人数": "4"})))));
    const before = (await docs("participants"))[0].data();
    const attendanceBefore = (await db.collection("programAttendances").doc(`${before.participantId}_program-1`).get()).data();
    assert.deepEqual([attendanceBefore.plannedCount, attendanceBefore.slotLabel, attendanceBefore.checkedIn, attendanceBefore.attendedCount],
      [4, "22:20-22:20", false, null], "取込直後はplannedCount=4・未受付(attendedCountはまだ無い)");

    const outcome = await api.checkIn(asStaff({
      eventId: "event1", participantId: before.participantId, publicId: before.publicId,
      programId: "program-1", attendedCount: 2,
    }));
    assert.equal(outcome.alreadyCheckedIn, false);
    assert.deepEqual([outcome.program.plannedCount, outcome.program.attendedCount], [4, 2]);

    const attendanceAfter = (await db.collection("programAttendances").doc(`${before.participantId}_program-1`).get()).data();
    assert.deepEqual(
      [attendanceAfter.plannedCount, attendanceAfter.slotLabel, attendanceAfter.checkedIn, attendanceAfter.attendedCount],
      [4, "22:20-22:20", true, 2],
      "受付後もplannedCountは4のまま変わらず、attendedCountだけが実参加人数(2)として記録される",
    );
  });
});
