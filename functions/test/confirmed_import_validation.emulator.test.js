// 取込前の検証(validateConfirmedImport)と、commitConfirmedImport単体でのサーバー側の保証(Emulator + 実Admin SDK)。
//  - 検証は何も書き込まない。行の判定はpreviewと同じ
//  - 新しい取込回は、検証が返した expectedImportSequence と validationFingerprint を、採番と同じトランザクションの中で照合する
//    (古い・未来の番号、別のCSV、検証後に変わった重複状態は、何も書かずに拒否。同じ番号で作られる取込回は1つだけ)
//  - エラー行が1件でもあれば拒否。既存参加者・CSV内のメール重複は、それぞれ明示的な許可が必要
//  - 同じCSVを第2回として取り込める。第1回のbatch・participants・programAttendances・sendJob・mailDeliveriesは変わらない
// データはすべて架空。メールは予約TLD .invalid のみ。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {approvalKeysOf} = require("../test_support/validated_commit");
const {createImportApi} = require("../confirmed/import_api");
const {confirmedCallable} = require("../auth");
const {makeTable, syntheticMapping, NOT_ATTENDING} = require("../confirmed/test_support/synthetic");

const silent = {warn: () => {}};
const FIRST = "bfirst0000000000000000000000000";
const SECOND = "bsecond000000000000000000000000";
const codeOf = (e) => String((e && e.details && e.details.code) || (e && e.code) || e) + (e && typeof e.code === "number" ? `:${e.message}` : "");
const outcome = (promise) => promise.then((r) => (r.idempotentReplay ? "replay" : `created:${r.sequence}`), (e) => codeOf(e));
const topCode = (promise) => promise.then(() => "ok", (e) => e.code);
const tally = (list) => list.reduce((m, x) => ({...m, [x]: (m[x] || 0) + 1}), {});

describe("CSV取込の検証とcommitのサーバー側の保証(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let api;
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const request = (table, options = {}) => buildImportRequest({table, ...options});
  // 管理画面と同じ順序: 検証 → (確認) → commit。commitには検証が返した番号と指紋と、許可の鍵(現在の検証結果の鍵)を付ける。
  async function validated(table, options = {}, acks = {}) {
    const data = request(table, options);
    const v = await api.validate(asAdmin(data));
    return {v, data: {...data, expectedImportSequence: v.expectedImportSequence, validationFingerprint: v.validationFingerprint,
      approvalKeys: approvalKeysOf(v), ...acks}};
  }
  const ACK_ALL = {acknowledgeExistingEmailDuplicates: true, acknowledgeCsvEmailDuplicates: true};

  async function snapshotOf(collection) {
    const docs = (await db.collection(collection).get()).docs;
    return Object.fromEntries(docs.map((d) => [d.id, JSON.stringify(d.data())]));
  }
  async function everything() {
    const result = {};
    for (const name of ["events", "importBatches", "participants", "programAttendances", "sendJobs", "mailDeliveries"]) result[name] = await snapshotOf(name);
    return result;
  }
  const count = async (name) => (await db.collection(name).get()).size;
  const importSequence = async () => (await db.collection("events").doc("event1").get()).data().importSequence || 0;
  async function reset() {
    await env.clear();
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
      programs: [{programId: "alpha", name: "A", order: 0}, {programId: "beta", name: "B", order: 1}, {programId: "gamma", name: "C", order: 2}],
    });
  }
  // 第1回(10件)を取り込み、送信済みの配送履歴を模したデータを置く。
  async function firstRound() {
    const table = makeTable(10);
    const {data} = await validated(table, {clientRequestId: FIRST});
    const first = await api.commit(asAdmin(data));
    assert.deepEqual([first.status, first.sequence, first.createdCount], ["committed", 1, 10]);
    await db.collection("sendJobs").doc(`winner-${FIRST}`).set({eventId: "event1", batchId: FIRST, status: "completed", targetCount: 10, sentCount: 10});
    const ids = (await db.collection("participants").where("importBatchId", "==", FIRST).get()).docs.map((d) => d.id);
    for (const id of ids) await db.collection("mailDeliveries").doc(`${id}_winner`).set({eventId: "event1", jobId: `winner-${FIRST}`, status: "sent"});
    return {table, ids};
  }

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    const raw = createImportApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp()});
    const wrap = (handler) => {
      const callable = confirmedCallable("admin", handler, {db, logger: silent});
      return (req) => callable.run(req);
    };
    api = {validate: wrap(raw.validate), preview: wrap(raw.preview), commit: wrap(raw.commit)};
  });
  after(() => env?.stop());
  beforeEach(reset);

  test("K: 検証は何回(20並列)実行しても書き込まない。行の判定はpreviewと同じ。応答に氏名・メールを含めない", async () => {
    await firstRound();
    const table = makeTable(5, (i) => ({2: {"メールアドレス": "broken"}, 3: {"区分": "その他"}}[i] || {}));
    const before = await everything();
    const results = await Promise.all(Array.from({length: 20}, () => api.validate(asAdmin(request(table, {clientRequestId: SECOND})))));
    const p = await api.preview(asAdmin(request(table, {clientRequestId: SECOND})));
    assert.deepEqual(await everything(), before, "検証・プレビューでFirestoreは変わらない");
    const v = results[0];
    assert.ok(results.every((r) => r.validationFingerprint === v.validationFingerprint), "同じ状態なら同じ指紋");
    assert.deepEqual([v.totalRows, v.okCount, v.warningCount, v.errorCount], [5, 0, 4, 1]);
    assert.deepEqual(v.rows.map((r) => [r.sourceRowNumber, r.classification]), p.rows.map((r) => [r.sourceRowNumber, r.classification]));
    assert.ok(!JSON.stringify(v).includes("@example.invalid"), "応答にメールアドレスを含めない");
    assert.ok(!JSON.stringify(v).includes("架空テスト"), "応答に氏名を含めない");
    assert.ok(!JSON.stringify(v).includes("createdEmailHashes"), "取込回のハッシュを返さない");
  });

  test("同じCSVを第2回として取り込む: 取込済みの回と次の回を示し、許可なしは拒否、許可すれば新しいbatch。第1回は不変・再送は冪等", async () => {
    const {table, ids: firstIds} = await firstRound();
    const firstState = await everything();
    const {v, data} = await validated(table, {clientRequestId: FIRST});
    assert.deepEqual(v.existingBatch, {status: "committed", sequence: 1});
    assert.deepEqual(v.importedBatches, [{sequence: 1, status: "committed"}]);
    assert.equal(v.expectedImportSequence, 2);
    assert.equal(v.existingEmailDuplicateCount, 10);
    assert.equal(v.existingActiveParticipantCount, 10);
    assert.equal(v.errorCount, 0);

    const secondData = {...data, clientRequestId: SECOND};
    await assert.rejects(api.commit(asAdmin(secondData)), (e) => codeOf(e) === "existing-email-duplicates-unacknowledged" && e.details.count === 10);
    assert.deepEqual(await everything(), firstState, "許可のないcommitは何も書かない");
    const second = await api.commit(asAdmin({...secondData, acknowledgeExistingEmailDuplicates: true}));
    assert.deepEqual([second.status, second.sequence, second.label, second.createdCount], ["committed", 2, "第2回", 10]);

    const after = await everything();
    for (const name of ["participants", "programAttendances", "sendJobs", "mailDeliveries"]) {
      for (const [id, doc] of Object.entries(firstState[name])) assert.equal(after[name][id], doc, `${name}/${id} は変わらない`);
    }
    assert.equal(after.importBatches[FIRST], firstState.importBatches[FIRST], "第1回のbatchは変わらない");
    const secondIds = (await db.collection("participants").where("importBatchId", "==", SECOND).get()).docs.map((d) => d.id);
    assert.equal(secondIds.length, 10);
    assert.ok(secondIds.every((id) => id.startsWith(`${SECOND}-`) && !firstIds.includes(id)), "第2回は新しいparticipantId");
    assert.equal(Object.keys(after.mailDeliveries).length, 10, "取込ではメールの配送記録を作らない");

    // 再送(同じ第2回の要求)は冪等。第1回の再送も冪等。参加者は増えない
    assert.equal((await api.commit(asAdmin({...secondData, acknowledgeExistingEmailDuplicates: true}))).idempotentReplay, true);
    assert.equal((await api.commit(asAdmin(request(table, {clientRequestId: FIRST})))).idempotentReplay, true, "既存の取込回の再送は検証の番号・指紋なしでも従来どおり");
    assert.equal(await count("participants"), 20);
    // 再検証すると、取込済みの回は第1回・第2回、次は第3回(第3回以降も作れる)
    const again = await api.validate(asAdmin(request(table, {clientRequestId: FIRST})));
    assert.deepEqual(again.importedBatches.map((b) => b.sequence), [1, 2]);
    assert.equal(again.expectedImportSequence, 3);
    assert.equal(again.existingEmailDuplicateCount, 10);
  });

  test("A: 同じ第2回の要求を20並列でcommit → batchは1つ・参加者は10件だけ追加・取込回の番号は+1だけ", async () => {
    const {table} = await firstRound();
    const {data} = await validated(table, {clientRequestId: FIRST}, ACK_ALL);
    const second = {...data, clientRequestId: SECOND};
    const results = await Promise.all(Array.from({length: 20}, () => outcome(api.commit(asAdmin(second)))));
    assert.ok(results.every((r) => r === "created:2" || r === "replay"), JSON.stringify(tally(results)));
    assert.equal(await count("importBatches"), 2);
    assert.equal(await count("participants"), 20);
    assert.equal(await importSequence(), 2);
    assert.equal((await db.collection("importBatches").doc(SECOND).get()).data().status, "committed");
  });

  test("B: 同じメールを含む別々のCSVを、どちらも許可なしで同時にcommit(20組) → 未承認の重複は1件も作られない", async () => {
    for (let round = 0; round < 20; round++) {
      await reset();
      const x = await validated(makeTable(2), {clientRequestId: "bRACEX", fileHash: "d".repeat(64)});
      const y = await validated(makeTable(2, (i) => ({"氏名": `別CSV${i}`})), {clientRequestId: "bRACEY", fileHash: "e".repeat(64)});
      assert.equal(x.v.existingEmailDuplicateCount + y.v.existingEmailDuplicateCount, 0, "検証時点では重複0");
      const [a, b] = await Promise.all([outcome(api.commit(asAdmin(x.data))), outcome(api.commit(asAdmin(y.data)))]);
      const created = [a, b].filter((r) => r.startsWith("created"));
      assert.equal(created.length, 1, `round ${round}: ${a} / ${b}`);
      assert.ok([a, b].includes("import-state-changed"), `round ${round}: もう一方は再検証を求められる (${a} / ${b})`);
      assert.equal(await count("participants"), 2, "同じメールの参加者は作られていない");
      // 拒否された側が再検証すると重複が見え、許可なしでは取り込めない
      const loser = a.startsWith("created") ? y : x;
      const re = await validated(loser.data === x.data ? makeTable(2) : makeTable(2, (i) => ({"氏名": `別CSV${i}`})),
        {clientRequestId: loser.data.clientRequestId, fileHash: loser.data.fileHash});
      assert.equal(re.v.existingEmailDuplicateCount, 2);
      assert.equal(await outcome(api.commit(asAdmin(re.data))), "existing-email-duplicates-unacknowledged");
      assert.equal(await count("participants"), 2);
    }
  });

  test("C: 同じメールを含む別々のCSVでも、再検証して重複を明示的に許可すれば、意図的な重複として取り込める", async () => {
    const x = await validated(makeTable(2), {clientRequestId: "bACKX", fileHash: "d".repeat(64)}, ACK_ALL);
    const y = await validated(makeTable(2, (i) => ({"氏名": `別CSV${i}`})), {clientRequestId: "bACKY", fileHash: "e".repeat(64)}, ACK_ALL);
    const [a, b] = await Promise.all([outcome(api.commit(asAdmin(x.data))), outcome(api.commit(asAdmin(y.data)))]);
    assert.deepEqual([a, b].sort(), ["created:1", "import-state-changed"], "許可があっても、検証時から状態が変わった側は再検証が必要");
    const loserTable = a === "created:1" ? makeTable(2, (i) => ({"氏名": `別CSV${i}`})) : makeTable(2);
    const loserOptions = a === "created:1" ? {clientRequestId: "bACKY", fileHash: "e".repeat(64)} : {clientRequestId: "bACKX", fileHash: "d".repeat(64)};
    const re = await validated(loserTable, loserOptions, ACK_ALL);
    assert.equal(re.v.existingEmailDuplicateCount, 2);
    assert.equal(re.v.expectedImportSequence, 2);
    assert.equal(await outcome(api.commit(asAdmin(re.data))), "created:2");
    assert.equal(await count("participants"), 4);
  });

  test("D: 管理者A/Bが同じ「次は第2回」で、別々のbatchを同時にcommit → 成功は最大1つ、もう一方は再検証を求められ、勝手に第3回にならない", async () => {
    const {table} = await firstRound();
    const {data} = await validated(table, {clientRequestId: FIRST}, ACK_ALL);
    const browsers = [{...data, clientRequestId: "bBROWSERA00000000000000000000"}, {...data, clientRequestId: "bBROWSERB00000000000000000000", sourceFileName: "copy.csv"}];
    const results = await Promise.all(browsers.map((b) => outcome(api.commit(asAdmin(b)))));
    assert.deepEqual([...results].sort(), ["created:2", "import-state-changed"]);
    const loser = browsers[results.indexOf("import-state-changed")];
    assert.equal(await count("importBatches"), 2);
    assert.equal(await count("participants"), 20);
    assert.equal(await importSequence(), 2);
    // 負けた側が再検証すると「次は第3回」。改めて確認すればcommitできる(第3回は禁止しない)
    const again = await validated(table, {clientRequestId: FIRST}, ACK_ALL);
    assert.equal(again.v.expectedImportSequence, 3);
    assert.equal(await outcome(api.commit(asAdmin({...again.data, clientRequestId: loser.clientRequestId, sourceFileName: loser.sourceFileName}))), "created:3");
  });

  test("E/F: 古い番号・未来の番号・使用済みの番号は、何も書かずに拒否(指紋を作り直しても同じ)", async () => {
    const {table} = await firstRound();
    const {data} = await validated(table, {clientRequestId: FIRST}, ACK_ALL);
    const before = await everything();
    for (const seq of [1, 3, 100]) {
      assert.equal(await outcome(api.commit(asAdmin({...data, clientRequestId: SECOND, expectedImportSequence: seq}))), "import-state-changed", `seq ${seq}`);
    }
    for (const bad of [0, -1, "2", null, 1.5]) {
      assert.equal(await topCode(api.commit(asAdmin({...data, clientRequestId: SECOND, expectedImportSequence: bad}))), "invalid-argument", JSON.stringify(bad));
    }
    assert.deepEqual(await everything(), before);
    assert.equal(await importSequence(), 1);
  });

  test("G: 検証していないCSV + 許可だけ → 拒否。別のCSVの指紋・改ざんした指紋でも拒否(何も書かない)", async () => {
    const {table} = await firstRound();
    const before = await everything();
    const other = makeTable(3, (i) => ({"氏名": `未検証${i}`}));
    const unvalidated = {...request(other, {clientRequestId: "bUNVALIDATED", fileHash: "c".repeat(64)}), ...ACK_ALL};
    assert.equal(await outcome(api.commit(asAdmin(unvalidated))), "validation-required");
    assert.equal(await outcome(api.commit(asAdmin({...unvalidated, expectedImportSequence: 2}))), "validation-required");
    const {data: validatedFirst} = await validated(table, {clientRequestId: FIRST}, ACK_ALL);
    assert.equal(await outcome(api.commit(asAdmin({...unvalidated, expectedImportSequence: 2, validationFingerprint: validatedFirst.validationFingerprint}))),
      "import-state-changed", "別のCSVの指紋");
    assert.equal(await outcome(api.commit(asAdmin({...unvalidated, expectedImportSequence: 2, validationFingerprint: "f".repeat(64)}))), "import-state-changed");
    assert.equal(await topCode(api.commit(asAdmin({...unvalidated, expectedImportSequence: 2, validationFingerprint: "x"}))), "invalid-argument");
    // 検証した内容でも、列の対応・CSVを変えれば指紋が合わない
    const changedRows = {...validatedFirst, clientRequestId: SECOND, rows: validatedFirst.rows.map((r, i) => (i === 0 ? {...r, values: r.values.map((v, j) => (j === 1 ? "変更" : v))} : r))};
    assert.equal(await outcome(api.commit(asAdmin(changedRows))), "import-state-changed");
    assert.deepEqual(await everything(), before);
  });

  test("H: 正常10行 + error1行 → 未解決なら何も書かずに拒否。管理者がerror行を明示的に除外し再検証すれば、取込予定10・除外1で取り込める", async () => {
    const table = makeTable(11, (i) => (i === 11 ? {"メールアドレス": "broken"} : {}));
    const {v, data} = await validated(table, {clientRequestId: "bWITHERROR"}, ACK_ALL);
    assert.equal(v.errorCount, 1);
    assert.deepEqual(v.errorRows, [12]);
    const before = await everything();
    assert.equal(await outcome(api.commit(asAdmin(data))), "import-has-errors");
    // 検証せずに除外だけを付けても通らない(除外は検証の指紋に含まれる)
    assert.equal(await outcome(api.commit(asAdmin({...data, excludedRows: [{sourceRowNumber: 12, reason: "エラー行"}]}))), "import-state-changed");
    assert.deepEqual(await everything(), before);
    assert.deepEqual([await count("importBatches"), await count("participants"), await count("programAttendances"), await importSequence()], [0, 0, 0, 0]);
    const excluded = await validated(table, {clientRequestId: "bWITHERROR", excludedRows: [{sourceRowNumber: 12, reason: "エラー行"}]}, ACK_ALL);
    assert.deepEqual([excluded.v.errorCount, excluded.v.excludedRowCount, excluded.v.importRowCount], [0, 1, 10]);
    assert.equal(await outcome(api.commit(asAdmin(excluded.data))), "created:1");
    assert.equal(await count("participants"), 10);
  });

  test("I/J: CSV内のメール重複 → 許可なしは何も書かずに拒否、許可すれば別参加者として取り込む(既存参加者との重複の許可とは別)", async () => {
    const table = makeTable(3, (i) => (i <= 2 ? {"メールアドレス": "same@example.invalid"} : {}));
    const {v, data} = await validated(table, {clientRequestId: "bINTERNAL"});
    assert.deepEqual([v.csvEmailDuplicateCount, v.existingEmailDuplicateCount], [2, 0]);
    assert.deepEqual(v.csvDuplicateRows, [2, 3]);
    const before = await everything();
    assert.equal(await outcome(api.commit(asAdmin(data))), "csv-email-duplicates-unacknowledged");
    assert.equal(await outcome(api.commit(asAdmin({...data, acknowledgeExistingEmailDuplicates: true}))), "csv-email-duplicates-unacknowledged",
      "既存参加者との重複の許可では代わりにならない");
    assert.deepEqual(await everything(), before);
    assert.equal(await outcome(api.commit(asAdmin({...data, acknowledgeCsvEmailDuplicates: true}))), "created:1");
    assert.equal(await count("participants"), 3);
  });

  test("検証の後に参加者が増えた(別の取込が同じメールを追加) → 許可していても古い検証ではcommitできず、再検証で重複が見える", async () => {
    const table = makeTable(3, (i) => ({"メールアドレス": `late${i}@example.invalid`}));
    const {v, data} = await validated(table, {clientRequestId: "bLATE"}, ACK_ALL);
    assert.equal(v.existingEmailDuplicateCount, 0);
    const other = await validated(makeTable(1, () => ({"メールアドレス": "late2@example.invalid"})), {clientRequestId: "bOTHER", fileHash: "e".repeat(64)});
    assert.equal(await outcome(api.commit(asAdmin(other.data))), "created:1");
    assert.equal(await outcome(api.commit(asAdmin(data))), "import-state-changed");
    const again = await validated(table, {clientRequestId: "bLATE"});
    assert.deepEqual(again.v.existingDuplicateRows, [3]);
    assert.equal(await outcome(api.commit(asAdmin(again.data))), "existing-email-duplicates-unacknowledged");
    assert.equal(await outcome(api.commit(asAdmin({...again.data, acknowledgeExistingEmailDuplicates: true}))), "created:2");
  });

  test("取込中(まだ参加者が書かれていない)の取込回のメールも、既存として数える", async () => {
    await db.collection("importBatches").doc("bINFLIGHT").set({
      eventId: "event1", sequence: 1, status: "committing",
      createdEmailHashes: [require("../confirmed/import_validation").emailHash("event1", "synthetic1@example.invalid")],
    });
    await db.collection("events").doc("event1").update({importSequence: 1});
    const {v, data} = await validated(makeTable(2), {clientRequestId: "bNEXT"});
    assert.deepEqual(v.existingDuplicateRows, [2]);
    assert.equal(await outcome(api.commit(asAdmin(data))), "existing-email-duplicates-unacknowledged");
  });

  test("途中で止まった取込回を続きから完了する場合、その取込回自身の参加者は重複に数えない。続きからの完了に検証の番号・指紋は要らない", async () => {
    const table = makeTable(3);
    const {data} = await validated(table, {clientRequestId: FIRST});
    await api.commit(asAdmin(data));
    await db.collection("importBatches").doc(FIRST).update({status: "failed"});
    const resuming = await api.validate(asAdmin(request(table, {clientRequestId: FIRST})));
    assert.equal(resuming.existingBatch.status, "failed");
    assert.equal(resuming.existingEmailDuplicateCount, 0);
    const other = await api.validate(asAdmin(request(table, {clientRequestId: SECOND})));
    assert.equal(other.existingEmailDuplicateCount, 3, "別の取込回から見れば、既存の有効な参加者");
    const resumed = await api.commit(asAdmin(request(table, {clientRequestId: FIRST})));
    assert.equal(resumed.status, "committed");
    assert.equal(await count("participants"), 3);
  });

  // ---- 検証画面での対処(許可・修正・今回の取込から除外) -------------------------------------------------
  // 不参加のprogramの人数を無視するmapping(SIPPO形式と同じ扱い)。
  const ignoringMapping = () => {
    const base = syntheticMapping();
    return {...base, programs: base.programs.map((p) => ({...p, ignoreCountWhenNotAttending: true}))};
  };
  // 匿名fixture(行番号 = i + 1): A正常 / Bメール不正 / C人数不正 / Derror(氏名なし) / E既存メール重複 /
  // F・F'CSV内メール重複 / G不参加+残存人数 / H修正すると既存メールと重複
  const handlingTable = () => makeTable(9, (i) => ({
    2: {"メールアドレス": "broken-b"},
    3: {"午前参加人数": "二人"},
    4: {"氏名": ""},
    5: {"メールアドレス": "existing@example.invalid"},
    6: {"メールアドレス": "dup-f@example.invalid"},
    7: {"メールアドレス": "dup-f@example.invalid"},
    8: {"午後参加時間": NOT_ATTENDING, "午後参加人数": "2"},
    9: {"メールアドレス": "broken-h"},
  }[i] || {}));
  const HANDLING = {
    corrections: [
      {sourceRowNumber: 3, column: "メールアドレス", value: "fixed-b@example.invalid"},
      {sourceRowNumber: 4, column: "午前参加人数", value: "2"},
      {sourceRowNumber: 10, column: "メールアドレス", value: "existing@example.invalid"},
    ],
    excludedRows: [{sourceRowNumber: 5, reason: "氏名が無いため今回は除外"}],
  };
  async function seedExisting() {
    const {data} = await validated(makeTable(1, () => ({"メールアドレス": "existing@example.invalid", "氏名": "既存の架空参加者"})),
      {clientRequestId: "bEXISTING", fileHash: "9".repeat(64)});
    assert.equal(await outcome(api.commit(asAdmin(data))), "created:1");
  }

  test("対処E2E: 検証 → 修正・除外・許可 → 再検証 → プレビュー → commit。原本・管理者の対処・最終値を区別して監査に残る", async () => {
    await seedExisting();
    const mapping = ignoringMapping();
    const table = handlingTable();
    // 1. 対処前の検証: error 4件(B・C・D・H)。commitできない
    const first = await validated(table, {mapping, clientRequestId: "bHANDLED"}, ACK_ALL);
    assert.deepEqual(first.v.errorRows, [3, 4, 5, 10]);
    assert.equal(first.v.errorCount, 4);
    assert.equal(await outcome(api.commit(asAdmin(first.data))), "import-has-errors");
    // 2. 修正・除外して再検証: 修正値でサーバーが判定し直す(修正しただけで正常扱いにはしない)
    const handled = await validated(table, {mapping, clientRequestId: "bHANDLED", ...HANDLING});
    const v = handled.v;
    assert.deepEqual([v.errorCount, v.excludedRowCount, v.correctedRowCount, v.importRowCount], [0, 1, 3, 8]);
    assert.deepEqual(v.existingDuplicateRows, [6, 10], "E と、修正したHが既存参加者と重複(修正で新しい警告が出る)");
    assert.deepEqual(v.csvDuplicateRows, [6, 7, 8, 10], "EとHは修正後にCSV内でも同じメール");
    assert.deepEqual(v.ignoredCountRows, [9]);
    assert.deepEqual(v.rows.find((r) => r.sourceRowNumber === 4).findings, [], "人数を2に修正したCは正常");
    assert.equal(v.rows.find((r) => r.sourceRowNumber === 3).corrected, true);
    assert.equal(v.rows.find((r) => r.sourceRowNumber === 5).excluded, true);
    // 3. プレビューは最終的に取り込まれる内容
    const {expectedImportSequence: _e, validationFingerprint: _f, approvalKeys: _k, ...previewData} = handled.data;
    const p = await api.preview(asAdmin(previewData));
    assert.deepEqual(p.decisionSummary, {originalRows: 9, correctedRows: 3, excludedRows: 1, importRows: 8});
    assert.deepEqual(p.rows.map((r) => [r.sourceRowNumber, r.classification]), v.rows.map((r) => [r.sourceRowNumber, r.classification]));
    // 4. 許可が足りなければ拒否(それぞれ別の許可)。不参加の残存人数(9行目)は参考情報で、許可は要らない
    const before = await everything();
    for (const [acks, code] of [
      [{}, "existing-email-duplicates-unacknowledged"],
      [{acknowledgeExistingEmailDuplicates: true}, "csv-email-duplicates-unacknowledged"],
    ]) assert.equal(await outcome(api.commit(asAdmin({...handled.data, ...acks}))), code);
    assert.deepEqual(await everything(), before);
    // 5. すべて許可してcommit
    const done = await api.commit(asAdmin({...handled.data, ...ACK_ALL}));
    assert.deepEqual([done.status, done.sequence, done.createdCount, done.excludedByOperatorCount, done.errorCount], ["committed", 2, 8, 1, 0]);
    const participant = async (row) => (await db.collection("participants").doc(`bHANDLED-${String(row).padStart(6, "0")}`).get());
    assert.equal((await participant(3)).data().email, "fixed-b@example.invalid", "修正後の値で作られる");
    assert.equal((await db.collection("programAttendances").doc("bHANDLED-000004_alpha").get()).data().plannedCount, 2);
    assert.equal((await participant(5)).exists, false, "除外した行は作られない");
    assert.equal((await db.collection("programAttendances").doc("bHANDLED-000009_beta").get()).exists, false, "無視した人数でattendanceは作られない");
    const rows = Object.fromEntries((await db.collection("importBatches").doc("bHANDLED").collection("rows").get()).docs.map((d) => [d.id, d.data()]));
    assert.deepEqual([rows["3"].resolution, rows["3"].corrections], ["modified", [{column: "メールアドレス", originalValue: "broken-b", correctedValue: "fixed-b@example.invalid"}]]);
    assert.deepEqual([rows["5"].resolution, rows["5"].result, rows["5"].excludedReason, rows["5"].classification], ["excluded", "excluded", "氏名が無いため今回は除外", "error"]);
    assert.deepEqual([rows["6"].resolution, rows["6"].allowedWarnings], ["allowed", ["email-duplicate-existing", "email-duplicate-in-csv"]]);
    assert.deepEqual(rows["7"].allowedWarnings, ["email-duplicate-in-csv"]);
    assert.deepEqual([rows["9"].resolution, rows["9"].allowedWarnings], ["none", []], "参考情報(残存人数)は許可の対象ではない");
    assert.deepEqual([rows["10"].resolution, rows["10"].allowedWarnings], ["modified", ["email-duplicate-existing", "email-duplicate-in-csv"]]);
    assert.deepEqual([rows["2"].resolution, rows["2"].corrections], ["none", []]);
    const batch = (await db.collection("importBatches").doc("bHANDLED").get()).data();
    assert.deepEqual([batch.correctedRowCount, batch.excludedByOperatorCount, batch.allowedWarningCounts],
      [3, 1, {review: 0, existingEmailDuplicates: 2, csvEmailDuplicates: 4}]);
    assert.ok(!JSON.stringify(done).includes("fixed-b@example.invalid"), "commitの応答には修正値を含めない");
    // 6. 同じ要求の再送は冪等
    assert.equal(await outcome(api.commit(asAdmin({...handled.data, ...ACK_ALL}))), "replay");
  });

  test("修正・除外の改ざん: 実在しない行・空行・ヘッダー・修正できない列・重複・変化なしは拒否。検証していない修正・除外はcommitできない", async () => {
    const table = makeTable(3);
    table.records.push(table.headers.map(() => "")); // 5行目は空レコード
    const bad = async (extra) => topCode(api.validate(asAdmin(request(table, extra))));
    const c = (sourceRowNumber, column, value) => ({corrections: [{sourceRowNumber, column, value}]});
    for (const extra of [
      c(99, "メールアドレス", "x@example.invalid"), c(5, "メールアドレス", "x@example.invalid"), c(1, "メールアドレス", "x@example.invalid"),
      c(2, "かな", "かえた"), c(2, "区分", "その他"), c(2, "メールアドレス", "synthetic1@example.invalid"),
      {corrections: [{sourceRowNumber: 2, column: "氏名", value: "a"}, {sourceRowNumber: 2, column: "氏名", value: "b"}]},
      {corrections: [{sourceRowNumber: 2, column: "氏名", value: "a", note: "x"}]},
      {excludedRows: [{sourceRowNumber: 99, reason: "x"}]}, {excludedRows: [{sourceRowNumber: 5, reason: "x"}]},
      {excludedRows: [{sourceRowNumber: 1, reason: "x"}]}, {excludedRows: [{sourceRowNumber: 2, reason: "x"}, {sourceRowNumber: 2, reason: "y"}]},
      {excludedRows: [{sourceRowNumber: 2, reason: " "}]},
    ]) assert.equal(await bad(extra), "invalid-argument", JSON.stringify(extra));
    // 検証(修正なし)の指紋で、修正・除外を付けたcommitは通らない
    const {data} = await validated(table, {clientRequestId: "bTAMPER"});
    const before = await everything();
    assert.equal(await outcome(api.commit(asAdmin({...data, corrections: [{sourceRowNumber: 2, column: "氏名", value: "別人"}]}))), "import-state-changed");
    assert.equal(await outcome(api.commit(asAdmin({...data, excludedRows: [{sourceRowNumber: 2, reason: "x"}]}))), "import-state-changed");
    // 修正して検証した指紋で、修正値だけ差し替えたcommitも通らない
    const corrected = await validated(table, {clientRequestId: "bTAMPER", corrections: [{sourceRowNumber: 2, column: "氏名", value: "修正A"}]});
    assert.equal(await outcome(api.commit(asAdmin({...corrected.data, corrections: [{sourceRowNumber: 2, column: "氏名", value: "修正B"}]}))), "import-state-changed");
    assert.deepEqual(await everything(), before);
  });

  test("修正・除外・許可を含む同じ第2回の要求を20並列でcommit → batchは1つ・参加者は取込予定分だけ・番号は+1", async () => {
    await seedExisting();
    const handled = await validated(handlingTable(), {mapping: ignoringMapping(), clientRequestId: "bPARALLEL", ...HANDLING},
      {...ACK_ALL, acknowledgeIgnoredCounts: true});
    const results = await Promise.all(Array.from({length: 20}, () => outcome(api.commit(asAdmin(handled.data)))));
    assert.ok(results.every((r) => r === "created:2" || r === "replay"), JSON.stringify(tally(results)));
    assert.equal(await count("importBatches"), 2);
    assert.equal(await count("participants"), 1 + 8);
    assert.equal(await importSequence(), 2);
  });

  test("修正・除外を含む別々のbatchが同じ「次の回」で同時にcommit → 成功は1つ、もう一方は再検証を求められる", async () => {
    await seedExisting();
    const acks = {...ACK_ALL, acknowledgeIgnoredCounts: true};
    const a = await validated(handlingTable(), {mapping: ignoringMapping(), clientRequestId: "bCONFLICTA", ...HANDLING}, acks);
    const b = await validated(handlingTable(), {mapping: ignoringMapping(), clientRequestId: "bCONFLICTB", sourceFileName: "copy.csv", ...HANDLING}, acks);
    const results = await Promise.all([outcome(api.commit(asAdmin(a.data))), outcome(api.commit(asAdmin(b.data)))]);
    assert.deepEqual([...results].sort(), ["created:2", "import-state-changed"]);
    assert.equal(await count("participants"), 1 + 8);
  });

  // ---- 参考情報(不参加+残存人数)と、行を修正したときの許可の無効化 --------------------------------------------
  // 検証済みの要求に、指定した許可(と許可の鍵)を付ける。keysFrom: 許可の鍵を取る検証の応答(古い検証を渡すと古い許可になる)。
  const withApprovals = ({v, data}, acks = {}, keysFrom = v) => ({...data, approvalKeys: approvalKeysOf(keysFrom), ...acks});
  const residual = (rows) => (i) => (rows.includes(i) ? {"午後参加時間": NOT_ATTENDING, "午後参加人数": "2"} : {});
  const attendanceIds = async (batchId) => (await db.collection("programAttendances").where("importBatchId", "==", batchId).get()).docs.map((d) => d.id).sort();

  test("A: 不参加+残存人数だけのCSV → 参考情報として見える・許可なしでプレビュー/commitできる・不参加programのattendanceは作らない", async () => {
    const table = makeTable(3, residual([2]));
    const {v, data} = await validated(table, {mapping: ignoringMapping(), clientRequestId: "bRESIDUAL"});
    assert.deepEqual([v.okCount, v.warningCount, v.errorCount, v.infoCount], [2, 0, 0, 1]);
    assert.deepEqual(v.ignoredCountRows, [3]);
    assert.deepEqual(v.reviewRows, []);
    const row = v.rows.find((r) => r.sourceRowNumber === 3);
    assert.deepEqual([row.result, row.classification, row.findings], ["info", "ready", [{code: "not-attending-count-ignored", severity: "info", programId: "beta"}]]);
    assert.equal(row.approvalKeys, undefined, "参考情報には許可の鍵が無い(許可は要らない)");
    assert.deepEqual(approvalKeysOf(v), []);
    const {expectedImportSequence: _e, validationFingerprint: _f, approvalKeys: _k, ...previewData} = data;
    const p = await api.preview(asAdmin(previewData));
    assert.equal(p.rows.find((r) => r.sourceRowNumber === 3).classification, "ready");
    // 確認(acknowledgeIgnoredCounts)も許可の鍵も付けずにcommitできる
    const {approvalKeys: _none, ...plain} = data;
    assert.equal(await outcome(api.commit(asAdmin(plain))), "created:1");
    const ids = await attendanceIds("bRESIDUAL");
    assert.ok(ids.includes("bRESIDUAL-000003_alpha") && ids.includes("bRESIDUAL-000003_gamma"));
    assert.ok(!ids.includes("bRESIDUAL-000003_beta"), "人数が残っていても不参加のprogramは参加扱いにしない");
    assert.equal(ids.filter((id) => id.endsWith("_beta")).length, 0);
  });

  test("B: 本番10件相当(第2回): 既存メール重複10件・残存人数の参考情報3件 → 重複10件の許可だけでcommitできる", async () => {
    const {table: firstTable} = await firstRound();
    assert.equal(firstTable.records.length, 10);
    const table = makeTable(10, residual([3, 5, 8]));
    const handled = await validated(table, {mapping: ignoringMapping(), clientRequestId: SECOND});
    const {v} = handled;
    assert.deepEqual([v.existingEmailDuplicateCount, v.csvEmailDuplicateCount, v.errorCount, v.reviewRows.length], [10, 0, 0, 0]);
    assert.deepEqual(v.ignoredCountRows, [4, 6, 9]);
    assert.equal(v.findingCounts["not-attending-count-ignored"], 3);
    assert.deepEqual([v.okCount, v.warningCount, v.infoCount], [0, 10, 0], "重複の警告がある行は警告(参考情報は所見として残る)");
    for (const n of [4, 6, 9]) {
      assert.ok(v.rows.find((r) => r.sourceRowNumber === n).findings.some((f) => f.code === "not-attending-count-ignored" && f.severity === "info"));
    }
    // 許可が必要なのは、既存メール重複10件だけ(参考情報の鍵は無い)
    assert.equal(approvalKeysOf(v).length, 10);
    assert.ok(v.rows.every((r) => Object.keys(r.approvalKeys || {}).join() === "existingDuplicate"));
    const before = await everything();
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(handled)))), "existing-email-duplicates-unacknowledged");
    assert.deepEqual(await everything(), before);
    const done = await api.commit(asAdmin(withApprovals(handled, {acknowledgeExistingEmailDuplicates: true})));
    assert.deepEqual([done.status, done.sequence, done.createdCount], ["committed", 2, 10]);
    const ids = await attendanceIds(SECOND);
    assert.equal(ids.filter((id) => id.endsWith("_beta")).length, 0, "残存人数の行も不参加のまま");
    assert.equal(ids.length, 20);
  });

  test("C: reviewを許可 → 同じ行を修正 → 古い許可では取り込めない(改ざんした直接呼び出しも拒否)。新しい検証結果で改めて許可すれば取り込める", async () => {
    const table = makeTable(3, (i) => (i === 2 ? {"午前参加時間": "朝のどこか"} : {}));
    const first = await validated(table, {clientRequestId: "bREVIEW"});
    assert.deepEqual(first.v.reviewRows, [3]);
    // 1. 同じ確認理由のまま氏名だけ修正
    const sameReason = await validated(table, {clientRequestId: "bREVIEW", corrections: [{sourceRowNumber: 3, column: "氏名", value: "修正した架空氏名"}]});
    assert.deepEqual(sameReason.v.reviewRows, [3]);
    const before = await everything();
    const stale = withApprovals(sameReason, {approvedReviewRows: [3]}, first.v);
    const err = await api.commit(asAdmin(stale)).then(() => null, (e) => e);
    assert.deepEqual([codeOf(err), err.details.count], ["approvals-outdated", 1]);
    // 2. 確認理由が変わる修正(時間枠を空にする)
    const otherReason = await validated(table, {clientRequestId: "bREVIEW", corrections: [{sourceRowNumber: 3, column: "午前参加時間", value: ""}]});
    assert.deepEqual(otherReason.v.reviewRows, [3]);
    assert.notDeepEqual(otherReason.v.rows.find((r) => r.sourceRowNumber === 3).findings, first.v.rows.find((r) => r.sourceRowNumber === 3).findings);
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(otherReason, {approvedReviewRows: [3]}, first.v)))), "approvals-outdated");
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(otherReason, {approvedReviewRows: [3]}, sameReason.v)))), "approvals-outdated");
    assert.deepEqual(await everything(), before, "古い許可のcommitは何も書かない");
    // 3. 新しい検証結果で改めて許可
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(otherReason, {approvedReviewRows: [3]})))), "created:1");
  });

  test("D: 既存メール重複を許可 → メールを別の既存参加者のメールへ修正 → 古い許可は無効(同じ種類の警告でも内容が変わった)", async () => {
    const {data: seed} = await validated(makeTable(2, (i) => ({"メールアドレス": `existing${i}@example.invalid`})), {clientRequestId: "bEXISTING2", fileHash: "8".repeat(64)});
    assert.equal(await outcome(api.commit(asAdmin(seed))), "created:1");
    const table = makeTable(2, (i) => (i === 1 ? {"メールアドレス": "existing1@example.invalid"} : {}));
    const first = await validated(table, {clientRequestId: "bDUPFIX"});
    assert.deepEqual(first.v.existingDuplicateRows, [2]);
    const moved = await validated(table, {clientRequestId: "bDUPFIX", corrections: [{sourceRowNumber: 2, column: "メールアドレス", value: "existing2@example.invalid"}]});
    assert.deepEqual(moved.v.existingDuplicateRows, [2]);
    const ack = {acknowledgeExistingEmailDuplicates: true};
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(moved, ack, first.v)))), "approvals-outdated");
    // 許可(acknowledge)だけで鍵が無い直接呼び出しも拒否(全体の許可だけでは迂回できない)
    assert.equal(await outcome(api.commit(asAdmin({...moved.data, ...ack, approvalKeys: []}))), "approvals-outdated");
    assert.equal(await count("importBatches"), 1);
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(moved, ack)))), "created:2");
  });

  test("E/H: CSV内重複を許可 → 対象行を修正(相手が変わる) → 古い許可は無効。修正していない相手の行も改めて許可が必要", async () => {
    const table = makeTable(3, (i) => (i <= 2 ? {"メールアドレス": "pair@example.invalid"} : {}));
    const first = await validated(table, {clientRequestId: "bCSVDUP"});
    assert.deepEqual(first.v.csvDuplicateRows, [2, 3]);
    const ack = {acknowledgeCsvEmailDuplicates: true};
    // 4行目を同じメールへ修正: 2・3行目は修正していないが、重複の相手が変わった
    const widened = await validated(table, {clientRequestId: "bCSVDUP", corrections: [{sourceRowNumber: 4, column: "メールアドレス", value: "pair@example.invalid"}]});
    assert.deepEqual(widened.v.csvDuplicateRows, [2, 3, 4]);
    const err = await api.commit(asAdmin(withApprovals(widened, ack, first.v))).then(() => null, (e) => e);
    assert.deepEqual([codeOf(err), err.details.count], ["approvals-outdated", 3]);
    // 3行目自体を別の重複へ修正しても、古い許可は流用できない
    const table4 = makeTable(4, (i) => (i <= 2 ? {"メールアドレス": "pair@example.invalid"} : i === 3 ? {"メールアドレス": "pair2@example.invalid"} : {}));
    const before4 = await validated(table4, {clientRequestId: "bCSVDUP4"});
    const swapped = await validated(table4, {clientRequestId: "bCSVDUP4", corrections: [{sourceRowNumber: 5, column: "メールアドレス", value: "pair2@example.invalid"}]});
    assert.deepEqual([before4.v.csvDuplicateRows, swapped.v.csvDuplicateRows], [[2, 3], [2, 3, 4, 5]]);
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(swapped, ack, before4.v)))), "approvals-outdated");
    assert.equal(await count("importBatches"), 0);
    assert.equal(await outcome(api.commit(asAdmin(withApprovals(widened, ack)))), "created:1");
  });

  test("F: 古い許可の鍵を別の行・別の取込へ流用しても、許可が必要な警告は迂回できない", async () => {
    const table = makeTable(3, (i) => (i === 1 || i === 3 ? {"午前参加時間": "朝のどこか"} : {}));
    const {v, data} = await validated(table, {clientRequestId: "bTAMPER"});
    assert.deepEqual(v.reviewRows, [2, 4]);
    const key2 = v.rows.find((r) => r.sourceRowNumber === 2).approvalKeys.review;
    // 2行目の鍵だけで2行とも許可したことにする → 4行目は未承認の警告
    assert.equal(await outcome(api.commit(asAdmin({...data, approvedReviewRows: [2, 4], approvalKeys: [key2]}))), "approvals-outdated");
    // 別のCSV(同じ行番号・同じ確認理由・氏名だけ違う)の鍵は使えない
    const other = await validated(makeTable(3, (i) => (i === 1 || i === 3 ? {"午前参加時間": "朝のどこか", "氏名": "別人"} : {})), {clientRequestId: "bTAMPER"});
    assert.equal(await outcome(api.commit(asAdmin({...data, approvedReviewRows: [2, 4], approvalKeys: approvalKeysOf(other.v)}))), "approvals-outdated");
    // 実在しない鍵を混ぜても通らない。現在の鍵なら通る(余分な鍵は無視)
    assert.equal(await outcome(api.commit(asAdmin({...data, approvedReviewRows: [2, 4], approvalKeys: ["f".repeat(64)]}))), "approvals-outdated");
    assert.equal(await count("importBatches"), 0);
    assert.equal(await outcome(api.commit(asAdmin({...data, approvedReviewRows: [2, 4], approvalKeys: [...approvalKeysOf(v), "f".repeat(64)]}))), "created:1");
  });

  test("G: 問題が消える修正 → 再検証後は許可が要らない(古い許可も不要)", async () => {
    await seedExisting();
    const table = makeTable(3, (i) => ({1: {"午前参加時間": "朝のどこか"}, 2: {"メールアドレス": "existing@example.invalid"},
      3: {"メールアドレス": "synthetic1@example.invalid"}}[i]));
    const first = await validated(table, {clientRequestId: "bSOLVED"});
    assert.deepEqual([first.v.reviewRows, first.v.existingDuplicateRows, first.v.csvDuplicateRows], [[2], [3], [2, 4]]);
    const fixed = await validated(table, {clientRequestId: "bSOLVED", corrections: [
      {sourceRowNumber: 2, column: "午前参加時間", value: "10:00-11:00"},
      {sourceRowNumber: 3, column: "メールアドレス", value: "new3@example.invalid"},
      {sourceRowNumber: 4, column: "メールアドレス", value: "new4@example.invalid"},
    ]});
    assert.deepEqual([fixed.v.warningCount, fixed.v.errorCount, approvalKeysOf(fixed.v)], [0, 0, []]);
    const {approvalKeys: _k, ...plain} = fixed.data;
    assert.equal(await outcome(api.commit(asAdmin(plain))), "created:2");
  });

  test("許可・番号・指紋の型は厳密。previewと検証では受け付けない", async () => {
    const {data} = await validated(makeTable(1), {});
    for (const [key, value] of [["acknowledgeExistingEmailDuplicates", "yes"], ["acknowledgeCsvEmailDuplicates", 1], ["validationFingerprint", 42]]) {
      assert.equal(await topCode(api.commit(asAdmin({...data, [key]: value}))), "invalid-argument", key);
    }
    for (const key of ["acknowledgeExistingEmailDuplicates", "expectedImportSequence", "validationFingerprint"]) {
      assert.equal(await topCode(api.preview(asAdmin({...request(makeTable(1)), [key]: data[key] ?? true}))), "invalid-argument");
      assert.equal(await topCode(api.validate(asAdmin({...request(makeTable(1)), [key]: data[key] ?? true}))), "invalid-argument");
    }
    assert.equal(await count("importBatches"), 0);
  });
});
