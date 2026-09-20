// 新方式の当選者CSV取込API(preview / commit)の統合テスト。
// ローカルのFirestore Emulator(localhostのみ)に実際のFirebase Admin SDKを接続して、transaction・並行実行・
// 部分失敗からの復旧を本物のFirestoreの挙動で検証する。実Firestore・実メール・外部通信は一切使わない。
// データはすべて架空(メールは予約TLD .invalid)。実CSVのデータは一切使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator, failingDb, dbWithWrongParticipantCount} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable, syntheticMapping, HEADERS, makeRecord, UNMAPPED_MARKER, NOT_ATTENDING} = require("../confirmed/test_support/synthetic");
const {createImportApi} = require("../confirmed/import_api");
const {confirmedCallable} = require("../auth");

const silent = {warn: () => {}};
const LEGACY_COUNT_KEY = ["registered", "Count"].join("");
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);
const realFetch = globalThis.fetch;

describe("新方式CSV取込API(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;
  let calls; // 外部通信の記録(Emulator以外へのfetch)

  const makeApi = (options = {}) => {
    const api = createImportApi({
      getDb: () => options.db || db,
      serverTimestamp: () => env.FieldValue.serverTimestamp(),
      concurrency: options.concurrency,
    });
    // confirmedCallable(認可つきcallable)を、.run で呼び出せる関数にする(認可はindex.jsの公開経路と同じ仕組み)
    const wrap = (level, handler) => {
      const callable = confirmedCallable(level, handler, {db, logger: silent});
      return (request) => callable.run(request);
    };
    return {preview: wrap("admin", api.preview), commit: wrap("admin", api.commit)};
  };
  let api;
  const asAdmin = (data) => ({auth: {uid: "u-admin"}, data});
  const asStaff = (data) => ({auth: {uid: "u-staff"}, data});

  async function seedEvent(overrides = {}) {
    const program = (programId, order) => ({programId, name: `架空プログラム${programId}`, order});
    await db.collection("events").doc("event1").set({
      eventId: "event1", eventName: "架空イベント", flow: "confirmed",
      startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
      programs: [program("alpha", 0), program("beta", 1), program("gamma", 2)],
      ...overrides,
    });
  }
  async function docs(path, query) {
    const ref = query ? query(db.collection(path)) : db.collection(path);
    return (await ref.get()).docs;
  }
  const count = async (path, query) => (await docs(path, query)).length;
  async function allCollectionCounts() {
    const collections = await db.listCollections();
    const result = {};
    for (const collection of collections) result[collection.id] = (await collection.get()).size;
    return result;
  }
  const batch = async (id) => (await db.collection("importBatches").doc(id).get()).data();
  const rowsOf = async (id) => (await db.collection("importBatches").doc(id).collection("rows").get()).docs.map((d) => d.data());
  const participantsOf = async (id) => docs("participants", (c) => c.where("importBatchId", "==", id));
  const request = (tableOrN, options = {}) => buildImportRequest({
    table: typeof tableOrN === "number" ? makeTable(tableOrN) : tableOrN, ...options,
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
    calls = [];
    globalThis.fetch = async (url, ...rest) => {
      if (!String(url).startsWith(env.origin)) calls.push(String(url));
      return realFetch(url, ...rest);
    };
  });

  describe("認可(admin専用)", () => {
    for (const name of ["preview", "commit"]) {
      test(`${name}: 未認証は unauthenticated で拒否され、何も書き込まれない`, async () => {
        const before = await allCollectionCounts();
        await rejectsWith(api[name]({data: request(3)}), "unauthenticated");
        assert.deepEqual(await allCollectionCounts(), before);
      });
      test(`${name}: staffは permission-denied で拒否され、何も書き込まれない`, async () => {
        const before = await allCollectionCounts();
        await rejectsWith(api[name](asStaff(request(3))), "permission-denied");
        assert.deepEqual(await allCollectionCounts(), before);
      });
      test(`${name}: accessRolesなし・無効(active=false)のユーザーは拒否される`, async () => {
        await db.collection("accessRoles").doc("u-off").set({role: "admin", active: false});
        await rejectsWith(api[name]({auth: {uid: "u-off"}, data: request(3)}), "permission-denied");
        await rejectsWith(api[name]({auth: {uid: "u-nobody"}, data: request(3)}), "permission-denied");
      });
    }
    test("preview: adminは成功する", async () => {
      const result = await api.preview(asAdmin(request(3)));
      assert.equal(result.totalRows, 3);
    });
    test("commit: adminは成功し、本文でroleやuidを偽装しても無視される(監査にはサーバー確定のUID)", async () => {
      const table = makeTable(3, (i) => (i === 2 ? {"区分": "変更申込"} : {}));
      const data = request(table, {approvedReviewRows: [3], extra: {}});
      const result = await api.commit(asAdmin(data));
      assert.equal(result.status, "committed");
      const approved = (await rowsOf("batchA")).find((r) => r.sourceRowNumber === 3);
      assert.equal(approved.approvedBy, "u-admin");
      // 本文にuid/role/participantを混ぜたリクエストは、未知のキーとして拒否される(信用しない)
      await rejectsWith(api.commit(asAdmin({...request(2, {clientRequestId: "batchB"}), createdBy: "attacker"})), "invalid-argument");
      await rejectsWith(api.commit(asAdmin({...request(2, {clientRequestId: "batchC"}), participants: [{name: "偽装"}]})), "invalid-argument");
    });
  });

  describe("eventの再確認(クライアントのeventは信用しない)", () => {
    for (const name of ["preview", "commit"]) {
      test(`${name}: 存在しないeventは not-found、書込みなし`, async () => {
        await rejectsWith(api[name](asAdmin(request(3, {eventId: "no-such-event"}))), "not-found");
        assert.equal(await count("importBatches"), 0);
      });
      test(`${name}: legacyイベント(flowなし・legacy)は failed-precondition で拒否、書込みなし`, async () => {
        for (const flow of [undefined, "legacy", "confirmd"]) {
          await db.collection("events").doc("legacyEvent").set({eventId: "legacyEvent", eventName: "旧", ...(flow ? {flow} : {}),
            programs: [{programId: "alpha", name: "x"}]});
          await rejectsWith(api[name](asAdmin(request(3, {eventId: "legacyEvent"}))), "failed-precondition");
        }
        assert.equal(await count("importBatches"), 0);
        assert.equal(await count("participants"), 0);
      });
      test(`${name}: event.programsに無いprogramIdのmappingは failed-precondition(program-not-in-event)`, async () => {
        const mapping = syntheticMapping();
        mapping.programs[0].programId = "zeta";
        await assert.rejects(api[name](asAdmin(request(makeTable(3), {mapping}))), (error) =>
          error.code === "failed-precondition" && error.details.code === "program-not-in-event" && error.details.programIds[0] === "zeta");
        assert.equal(await count("importBatches"), 0);
        assert.equal(await count("participants"), 0);
      });
    }
    test("commit: event側の情報でしか判断しない(eventDateはevent.startAtの日本時間の日付)", async () => {
      await seedEvent({startAt: env.Timestamp.fromDate(new Date("2026-12-24T20:00:00Z"))}); // JSTでは12/25
      await api.commit(asAdmin(request(makeTable(1, () => ({"午前参加時間": "10:00-11:00"})))));
      const alpha = (await docs("programAttendances")).map((d) => d.data()).find((d) => d.programId === "alpha");
      assert.equal(alpha.startAt.toDate().toISOString(), "2025-12-25T01:00:00.000Z".replace("2025", "2026"));
    });
    test("timeRangeを使うmappingでeventに開始日時が無ければ failed-precondition", async () => {
      await seedEvent({startAt: null});
      await assert.rejects(api.commit(asAdmin(request(2))), (e) => e.code === "failed-precondition" && e.details.code === "event-start-missing");
    });
  });

  describe("dry-run(preview): Firestoreへ一切書き込まない", () => {
    test("何も書き込まず、件数と行ごとの分類を返す", async () => {
      const table = makeTable(10, (i) => (i === 3 ? {"氏名": ""} : i === 5 ? {"午前参加時間": "22:20-22:20"} : {}));
      const before = await allCollectionCounts();
      const result = await api.preview(asAdmin(request(table)));
      assert.deepEqual(await allCollectionCounts(), before, "コレクションの文書数が変わらない");
      assert.equal(await count("importBatches"), 0);
      assert.deepEqual([result.totalRecords, result.totalRows, result.readyCount, result.reviewCount, result.errorCount, result.blankRecordCount],
        [10, 10, 8, 1, 1, 0]);
      assert.equal(result.readyCount + result.reviewCount + result.errorCount, result.totalRows);
      assert.equal(result.rows.length, 10);
      assert.deepEqual(result.rows[2], {sourceRowNumber: 4, importRecordId: "batchA-000004", classification: "error",
        issueCodes: ["name-missing"], programIds: ["alpha", "gamma"]});
      assert.equal(result.rows[4].classification, "review");
      assert.deepEqual(result.rows[4].issueCodes, ["slot-zero-length"]);
      assert.equal(result.participantCandidateCount, 9);
      assert.equal(result.attendanceCandidateCount, 20);
    });
    test("レスポンスに氏名・メール・かな・自由記述を含めない(行の突合はsourceRowNumberで行う)", async () => {
      const result = await api.preview(asAdmin(request(makeTable(5, () => ({"メールアドレス": "秘密@example.invalid"})))));
      const text = JSON.stringify(result);
      for (const forbidden of ["架空テスト", "synthetic", "秘密", "かくうてすと", UNMAPPED_MARKER, "example.invalid", "@"]) {
        assert.ok(!text.includes(forbidden), forbidden);
      }
      assert.deepEqual(Object.keys(result.rows[0]).sort(), ["classification", "importRecordId", "issueCodes", "programIds", "sourceRowNumber"]);
    });
    test("空レコードは件数に出る(黙って捨てない)", async () => {
      const table = makeTable(4);
      table.records.splice(2, 0, HEADERS.map(() => ""));
      const result = await api.preview(asAdmin(request(table)));
      assert.deepEqual([result.totalRecords, result.totalRows, result.blankRecordCount, result.blankRecordNumbers], [5, 4, 1, [4]]);
    });
    test("同じファイル(ハッシュ)が取込済みなら参考情報として知らせるが、止めない(人物の重複判定ではない)", async () => {
      await api.commit(asAdmin(request(3)));
      const result = await api.preview(asAdmin(request(3, {clientRequestId: "batchB"})));
      assert.deepEqual(result.sameFileBatches, [{batchId: "batchA", sequence: 1, status: "committed"}]);
      assert.equal(result.readyCount, 3);
      const same = await api.preview(asAdmin(request(3)));
      assert.deepEqual(same.existingBatch, {status: "committed", sequence: 1});
    });
    test("キャンセル待ちを含む列をmappingすると警告を返す", async () => {
      const mapping = syntheticMapping();
      mapping.programs[2].countColumn = "キャンセル待希望人数";
      const result = await api.preview(asAdmin(request(makeTable(2), {mapping})));
      assert.deepEqual(result.mappingWarnings, [{code: "waitlist-column", column: "キャンセル待希望人数"}]);
    });
  });

  describe("欠落防止: 人物の重複判定をしない(1 CSVデータ行 → 1 import record → 原則1 participant)", () => {
    test("100行入力 → 100行すべてが監査に存在し、100participant・全行のattendanceが作られる", async () => {
      const result = await api.commit(asAdmin(request(100)));
      assert.equal(result.status, "committed");
      assert.equal(result.rows.length, 100);
      assert.equal((await rowsOf("batchA")).length, 100);
      assert.deepEqual((await rowsOf("batchA")).map((r) => r.sourceRowNumber).sort((a, b) => a - b), Array.from({length: 100}, (_, k) => k + 2));
      assert.equal((await participantsOf("batchA")).length, 100);
      assert.equal(await count("programAttendances"), 200); // alpha + gamma × 100
      assert.deepEqual([result.createdCount, result.reviewPendingCount, result.errorCount, result.excludedByOperatorCount], [100, 0, 0, 0]);
    });
    test("同じメールアドレス100行 → 100participant(すべてready)", async () => {
      const result = await api.commit(asAdmin(request(makeTable(100, () => ({"メールアドレス": "same@example.invalid"})))));
      assert.equal(result.createdCount, 100);
      const participants = await participantsOf("batchA");
      assert.equal(participants.length, 100);
      assert.equal(new Set(participants.map((d) => d.data().email)).size, 1);
      assert.equal(new Set(participants.map((d) => d.id)).size, 100);
    });
    test("同じrd 100行 → 100participant。rdは参照情報(sourceReference)として保持するだけ", async () => {
      const result = await api.commit(asAdmin(request(makeTable(100, () => ({"rd": "R-SAME"})))));
      assert.equal(result.createdCount, 100);
      const participants = (await participantsOf("batchA")).map((d) => d.data());
      assert.equal(participants.length, 100);
      assert.ok(participants.every((p) => p.sourceReference === "R-SAME"));
    });
    test("同じ氏名100行 → 100participant", async () => {
      const result = await api.commit(asAdmin(request(makeTable(100, () => ({"氏名": "架空同姓同名"})))));
      assert.equal(result.createdCount, 100);
      assert.equal((await participantsOf("batchA")).length, 100);
    });
    test("別batchで同一人物 → 両方登録される(過去のbatchとの照合・skipをしない)", async () => {
      const table = makeTable(30);
      const first = await api.commit(asAdmin(request(table, {clientRequestId: "batchA"})));
      const second = await api.commit(asAdmin(request(table, {clientRequestId: "batchB"})));
      assert.deepEqual([first.createdCount, second.createdCount], [30, 30]);
      assert.equal(await count("participants"), 60);
      const ids = (await docs("participants")).map((d) => d.id);
      assert.equal(new Set(ids).size, 60, "participantIdはbatchごとに別");
      assert.ok(ids.includes("batchA-000010") && ids.includes("batchB-000010"));
      assert.equal(await count("programAttendances"), 120);
    });
    test("participantIdは importRecordId(batchId + 行番号)で、再現できる", async () => {
      await api.commit(asAdmin(request(5)));
      const ids = (await participantsOf("batchA")).map((d) => d.id).sort();
      assert.deepEqual(ids, ["batchA-000002", "batchA-000003", "batchA-000004", "batchA-000005", "batchA-000006"]);
    });
  });

  describe("review / error / operator除外(黙って除外しない。すべて監査に残る)", () => {
    const tableWithProblems = () => makeTable(6, (i) => (i === 2 ? {"午前参加時間": "22:20-22:20"} // review
      : i === 3 ? {"氏名": ""} // error
        : i === 4 ? {"午後参加時間": NOT_ATTENDING, "午後参加人数": "3"} // review
          : {}));

    test("review未承認 → participantを作らず、行は監査(review-pending)に残る", async () => {
      const result = await api.commit(asAdmin(request(tableWithProblems())));
      assert.deepEqual([result.createdCount, result.reviewPendingCount, result.errorCount, result.excludedByOperatorCount], [3, 2, 1, 0]);
      const rows = await rowsOf("batchA");
      const pending = rows.filter((r) => r.result === "review-pending").map((r) => r.sourceRowNumber).sort();
      assert.deepEqual(pending, [3, 5]);
      assert.ok(pending.every((n) => !rows.find((r) => r.sourceRowNumber === n).participantId));
      const participantIds = (await participantsOf("batchA")).map((d) => d.id);
      assert.ok(!participantIds.includes("batchA-000003") && !participantIds.includes("batchA-000005"));
      assert.equal(rows.find((r) => r.sourceRowNumber === 3).classification, "review");
      assert.deepEqual(rows.find((r) => r.sourceRowNumber === 3).issueCodes, ["slot-zero-length"]);
    });
    test("review明示承認 → participant作成 + 承認記録(approvedBy=サーバー確定のUID・approvedAt)", async () => {
      const result = await api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [3]})));
      assert.deepEqual([result.createdCount, result.reviewPendingCount, result.errorCount], [4, 1, 1]);
      const row = (await rowsOf("batchA")).find((r) => r.sourceRowNumber === 3);
      assert.deepEqual([row.result, row.classification, row.approvedReview, row.approvedBy, row.participantId],
        ["created", "review", true, "u-admin", "batchA-000003"]);
      assert.ok(row.approvedAt && typeof row.approvedAt.toDate === "function");
      assert.ok((await participantsOf("batchA")).some((d) => d.id === "batchA-000003"));
      // 承認された行のattendanceは、原文のslotLabelのまま(不自然な時間も補正しない)・startAt/endAtなし
      const alpha = (await db.collection("programAttendances").doc("batchA-000003_alpha").get()).data();
      assert.deepEqual([alpha.slotLabel, alpha.startAt, alpha.endAt], ["22:20-22:20", null, null]);
    });
    test("承認していないreview行は、他の行を承認しても作られない(承認は行ごとの明示的な判断)", async () => {
      await api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [3]})));
      const rows = await rowsOf("batchA");
      assert.equal(rows.find((r) => r.sourceRowNumber === 5).result, "review-pending");
      assert.equal(rows.find((r) => r.sourceRowNumber === 5).approvedReview, false);
    });
    test("error行は承認できない(承認してもparticipantは作られず、リクエスト全体が拒否され、何も書かれない)", async () => {
      await assert.rejects(api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [4]}))),
        (e) => e.code === "invalid-argument" && e.details.code === "error-row-cannot-be-approved" && e.details.sourceRowNumber === 4);
      assert.equal(await count("importBatches"), 0);
      assert.equal(await count("participants"), 0);
      const preview = await api.preview(asAdmin(request(tableWithProblems())));
      assert.equal(preview.rows.find((r) => r.sourceRowNumber === 4).classification, "error");
    });
    test("readyの行・存在しない行は承認できない", async () => {
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [2]}))), "invalid-argument");
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [99]}))), "invalid-argument");
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [3, 3]}))), "invalid-argument");
      assert.equal(await count("importBatches"), 0);
    });
    test("operator除外 → participantを作らず、除外記録(行番号・UID・時刻・理由)が監査に残る", async () => {
      const result = await api.commit(asAdmin(request(tableWithProblems(), {excludedRows: [
        {sourceRowNumber: 2, reason: "主催者へ確認済み"}, {sourceRowNumber: 3, reason: "重複の連絡あり"}, {sourceRowNumber: 4, reason: "エラー行を送らない"}]})));
      assert.deepEqual([result.createdCount, result.reviewPendingCount, result.errorCount, result.excludedByOperatorCount], [2, 1, 0, 3]);
      const rows = await rowsOf("batchA");
      const excluded = rows.filter((r) => r.excludedByOperator).sort((a, b) => a.sourceRowNumber - b.sourceRowNumber);
      assert.deepEqual(excluded.map((r) => [r.sourceRowNumber, r.result, r.excludedBy, r.excludedReason]),
        [[2, "excluded", "u-admin", "主催者へ確認済み"], [3, "excluded", "u-admin", "重複の連絡あり"], [4, "excluded", "u-admin", "エラー行を送らない"]]);
      assert.ok(excluded.every((r) => r.excludedAt && typeof r.excludedAt.toDate === "function" && r.participantId === null));
      const ids = (await participantsOf("batchA")).map((d) => d.id);
      assert.ok(!ids.includes("batchA-000002") && !ids.includes("batchA-000003") && !ids.includes("batchA-000004"));
      assert.equal(excluded[0].classification, "ready", "元の分類も監査に残る");
    });
    test("承認と除外を同じ行に指定するのは矛盾として拒否、除外の理由は必須", async () => {
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {approvedReviewRows: [3], excludedRows: [{sourceRowNumber: 3, reason: "x"}]}))), "invalid-argument");
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {excludedRows: [{sourceRowNumber: 3, reason: " "}]}))), "invalid-argument");
      await rejectsWith(api.commit(asAdmin(request(tableWithProblems(), {excludedRows: [{sourceRowNumber: 99, reason: "x"}]}))), "invalid-argument");
      assert.equal(await count("importBatches"), 0);
    });
    test("created + reviewPending + error + excluded (+ blank) は全レコード数と一致する", async () => {
      const table = tableWithProblems();
      table.records.push(HEADERS.map(() => ""), makeRecord(7), makeRecord(8, {"氏名": " "}));
      const result = await api.commit(asAdmin(request(table, {approvedReviewRows: [3], excludedRows: [{sourceRowNumber: 5, reason: "除外"}]})));
      const {createdCount: c, reviewPendingCount: r, errorCount: e, excludedByOperatorCount: x, blankRecordCount: b} = result;
      assert.deepEqual([c, r, e, x, b], [5, 0, 2, 1, 1]);
      assert.equal(c + r + e + x, result.totalRows);
      assert.equal(c + r + e + x + b, result.totalRecords);
      assert.equal(result.totalRecords, 9);
      assert.equal(result.rows.length, 9, "空レコードも監査に残る");
      assert.equal(result.rows.find((row) => row.sourceRowNumber === 8).result, "blank");
      const stored = await batch("batchA");
      assert.deepEqual([stored.createdCount, stored.reviewPendingCount, stored.errorCount, stored.excludedByOperatorCount, stored.blankRecordCount], [5, 0, 2, 1, 1]);
    });
    test("error行が含まれていても、他の行は登録され、errorは登録されない", async () => {
      const result = await api.commit(asAdmin(request(tableWithProblems())));
      const errorRow = result.rows.find((row) => row.sourceRowNumber === 4);
      assert.deepEqual([errorRow.result, errorRow.participantId, errorRow.classification], ["error", null, "error"]);
      assert.deepEqual(errorRow.issueCodes, ["name-missing"]);
    });
  });

  describe("冪等性(clientRequestId = batchId)", () => {
    test("同じcommitを再送しても participant・attendance・監査行は増えず、publicIdも変わらない", async () => {
      const data = request(makeTable(20));
      const first = await api.commit(asAdmin(data));
      const publicIds = new Map((await docs("participants")).map((d) => [d.id, d.data().publicId]));
      const counts = await allCollectionCounts();
      const second = await api.commit(asAdmin(data));
      assert.deepEqual(await allCollectionCounts(), counts, "文書数が増えない");
      assert.equal(second.idempotentReplay, true);
      assert.equal(first.idempotentReplay, false);
      const {idempotentReplay: _a, ...firstRest} = first;
      const {idempotentReplay: _b, ...secondRest} = second;
      assert.deepEqual(secondRest, firstRest, "既存の結果をそのまま返す");
      for (const d of await docs("participants")) assert.equal(d.data().publicId, publicIds.get(d.id));
      assert.equal((await batch("batchA")).sequence, 1);
    });
    test("commit成功後に応答が届かず再試行 → 同一結果(3回再送しても同じ)", async () => {
      const data = request(makeTable(10, (i) => (i === 3 ? {"氏名": ""} : {})), {approvedReviewRows: []});
      const results = [];
      for (let attempt = 0; attempt < 3; attempt += 1) results.push(await api.commit(asAdmin(data)));
      assert.deepEqual(results.map((r) => [r.sequence, r.createdCount, r.errorCount, r.status]), [[1, 9, 1, "committed"], [1, 9, 1, "committed"], [1, 9, 1, "committed"]]);
      assert.equal(await count("participants"), 9);
      assert.equal(await count("importBatches"), 1);
    });
    test("同じclientRequestIdを同時に2回送っても participant は増えない", async () => {
      const data = request(makeTable(30));
      const [a, b] = await Promise.all([api.commit(asAdmin(data)), api.commit(asAdmin(data))]);
      assert.equal(a.status, "committed");
      assert.equal(b.status, "committed");
      assert.equal(await count("participants"), 30);
      assert.equal(await count("programAttendances"), 60);
      assert.equal((await rowsOf("batchA")).length, 30);
      assert.equal((await db.collection("events").doc("event1").get()).data().importSequence, 1);
    });
    test("同一batchId + 異なる内容(値・判断・ファイル・event)は拒否され、既存の結果は変わらない", async () => {
      const table = makeTable(5);
      await api.commit(asAdmin(request(table)));
      const before = await allCollectionCounts();
      const changedRow = makeTable(5, (i) => (i === 2 ? {"氏名": "別の架空名"} : {}));
      const variants = [request(changedRow), request(makeTable(6)), request(table, {excludedRows: [{sourceRowNumber: 2, reason: "x"}]}),
        request(table, {fileHash: "b".repeat(64)}), request(table, {label: "別のラベル"}), request(table, {sourceFileName: "other.csv"})];
      for (const variant of variants) {
        await assert.rejects(api.commit(asAdmin(variant)), (e) => e.code === "already-exists" && e.details.code === "batch-content-mismatch");
      }
      assert.deepEqual(await allCollectionCounts(), before);
      assert.equal((await participantsOf("batchA")).find((d) => d.id === "batchA-000002").data().name, "架空テスト001");
    });
    test("別のeventを対象に同じclientRequestIdを送っても拒否される", async () => {
      await api.commit(asAdmin(request(3)));
      await db.collection("events").doc("event2").set({eventId: "event2", flow: "confirmed", startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
        programs: [{programId: "alpha"}, {programId: "beta"}, {programId: "gamma"}]});
      await rejectsWith(api.commit(asAdmin(request(3, {eventId: "event2"}))), "already-exists");
    });
  });

  describe("部分失敗からの復旧(途中で失敗してもcommittedにならない。同じclientRequestIdで続行できる)", () => {
    const TOTAL = 40;
    const failingApi = (failAtTransaction) => makeApi({db: failingDb(db, {failAtTransaction}), concurrency: 1});

    test("途中失敗 → batchはcommittedにならず、participantは一部だけ。再実行すると欠落なく完了し、既存のpublicIdは不変", async () => {
      const data = request(makeTable(TOTAL));
      await assert.rejects(failingApi(21).commit(asAdmin(data)), (e) => e.code === "internal" && e.details.code === "commit-interrupted");
      const midBatch = await batch("batchA");
      assert.notEqual(midBatch.status, "committed");
      assert.equal(midBatch.status, "failed");
      const partial = await participantsOf("batchA");
      assert.equal(partial.length, 19, "20回目までの行だけ(残りは未登録)");
      assert.ok(partial.length > 0 && partial.length < TOTAL);
      const publicIds = new Map(partial.map((d) => [d.id, d.data().publicId]));

      const result = await api.commit(asAdmin(data));
      assert.equal(result.status, "committed");
      assert.equal(result.createdCount, TOTAL);
      assert.equal(result.rows.length, TOTAL);
      const all = await participantsOf("batchA");
      assert.equal(all.length, TOTAL, "欠落なく、重複なく完了");
      assert.equal(new Set(all.map((d) => d.id)).size, TOTAL);
      assert.equal(await count("programAttendances"), TOTAL * 2);
      for (const d of all) if (publicIds.has(d.id)) assert.equal(d.data().publicId, publicIds.get(d.id), "再試行でpublicIdが変わらない");
      const final = await batch("batchA");
      assert.equal(final.status, "committed");
      assert.equal(final.sequence, 1, "再実行でsequenceが増えない");
      assert.equal((await db.collection("events").doc("event1").get()).data().importSequence, 1);
    });
    test("最後のcommitted更新だけ失敗 → 全行は書き込み済みだがcommittedにならず、再実行でcommittedになる(participantは増えない)", async () => {
      const data = request(makeTable(10));
      const lastCall = 1 + 10 + 1; // 開始 + 各行 + committed更新
      await assert.rejects(failingApi(lastCall).commit(asAdmin(data)), (e) => e.code === "internal");
      assert.notEqual((await batch("batchA")).status, "committed");
      assert.equal((await participantsOf("batchA")).length, 10);
      const result = await api.commit(asAdmin(data));
      assert.equal(result.status, "committed");
      assert.equal(await count("participants"), 10);
    });
    test("最初(batch作成)で失敗 → 何も書かれず、再実行で通常どおり完了", async () => {
      const data = request(makeTable(5));
      await assert.rejects(failingApi(1).commit(asAdmin(data)), /injected failure/);
      assert.equal(await count("participants"), 0);
      assert.equal(await count("importBatches"), 0);
      const result = await api.commit(asAdmin(data));
      assert.equal(result.sequence, 1);
      assert.equal(result.createdCount, 5);
    });
    test("失敗中のbatchはcommittedではないため、後続Phaseの送信対象の条件(status=committed)を満たさない", async () => {
      await assert.rejects(failingApi(10).commit(asAdmin(request(makeTable(20)))), (e) => e.code === "internal");
      const stored = await batch("batchA");
      assert.ok(["failed", "committing"].includes(stored.status));
      assert.equal(stored.createdCount, null, "件数は確定するまで入らない");
      assert.equal(await count("importBatches", (c) => c.where("status", "==", "committed")), 0);
    });
    test("失敗途中に承認・除外の判断を変えた再実行は拒否される(内容が違う)", async () => {
      const table = makeTable(10, (i) => (i === 3 ? {"区分": "変更申込"} : {}));
      await assert.rejects(failingApi(5).commit(asAdmin(request(table))), (e) => e.code === "internal");
      await rejectsWith(api.commit(asAdmin(request(table, {approvedReviewRows: [4]}))), "already-exists");
    });
    test("再実行時に、別の取込の同じIDのデータ(監査行なし)があれば、上書きせず失敗する", async () => {
      await db.collection("participants").doc("batchA-000003").set({foreign: true});
      await assert.rejects(api.commit(asAdmin(request(makeTable(5)))), (e) => e.code === "failed-precondition" && e.details.code === "record-id-conflict");
      assert.equal((await db.collection("participants").doc("batchA-000003").get()).data().foreign, true);
      assert.notEqual((await batch("batchA")).status, "committed");
    });
    test("書き込み済みの行のデータがすべて消えた場合は、その行を書き直して欠落なく完了する", async () => {
      const data = request(makeTable(6));
      await assert.rejects(failingApi(5).commit(asAdmin(data)), (e) => e.code === "internal");
      const rows = await rowsOf("batchA");
      const target = rows[0];
      await db.collection("importBatches").doc("batchA").collection("rows").doc(String(target.sourceRowNumber)).delete();
      await db.collection("participants").doc(target.participantId).delete();
      for (const programId of ["alpha", "gamma"]) await db.collection("programAttendances").doc(`${target.participantId}_${programId}`).delete();
      const result = await api.commit(asAdmin(data));
      assert.equal(result.status, "committed");
      assert.equal(result.createdCount, 6);
      assert.equal(await count("participants"), 6);
    });
    test("保存則が破れている(参加者の件数が合わない)場合はcommittedにせず、data-lossで失敗する", async () => {
      const lying = makeApi({db: dbWithWrongParticipantCount(db, 0)});
      await assert.rejects(lying.commit(asAdmin(request(makeTable(6)))), (e) => e.code === "data-loss" &&
        e.details.code === "conservation-violated" && e.details.problems.includes("participant-count-mismatch"));
      const stored = await batch("batchA");
      assert.equal(stored.status, "failed");
      assert.equal(stored.failureReason, "conservation-violated");
      assert.equal(await count("importBatches", (c) => c.where("status", "==", "committed")), 0);
    });
  });

  describe("sequence(eventのカウンタをtransactionで採番)", () => {
    test("同時に複数のbatchをcommitしても sequence が重複しない(1,2,3,4,5)", async () => {
      const ids = ["batchA", "batchB", "batchC", "batchD", "batchE"];
      const results = await Promise.all(ids.map((id) => api.commit(asAdmin(request(makeTable(15), {clientRequestId: id})))));
      assert.deepEqual(results.map((r) => r.sequence).sort(), [1, 2, 3, 4, 5]);
      assert.equal((await db.collection("events").doc("event1").get()).data().importSequence, 5);
      const stored = await Promise.all(ids.map((id) => batch(id)));
      assert.deepEqual(stored.map((b) => b.sequence).sort(), [1, 2, 3, 4, 5]);
      assert.equal(await count("participants"), 75);
    });
    test("sequenceはクライアントの指定を信用しない(サーバーが採番)。labelは既定で「第N回」", async () => {
      await assert.rejects(api.commit(asAdmin({...request(3), sequence: 99})), (e) => e.code === "invalid-argument");
      const first = await api.commit(asAdmin(request(2, {clientRequestId: "batchA"})));
      const second = await api.commit(asAdmin(request(2, {clientRequestId: "batchB", label: "追加分"})));
      assert.deepEqual([first.sequence, first.label, second.sequence, second.label], [1, "第1回", 2, "追加分"]);
    });
    test("別イベントのsequenceは独立している", async () => {
      await db.collection("events").doc("event2").set({eventId: "event2", flow: "confirmed", startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")),
        programs: [{programId: "alpha"}, {programId: "beta"}, {programId: "gamma"}]});
      const a = await api.commit(asAdmin(request(2, {clientRequestId: "batchA", eventId: "event1"})));
      const b = await api.commit(asAdmin(request(2, {clientRequestId: "batchB", eventId: "event2"})));
      assert.deepEqual([a.sequence, b.sequence], [1, 1]);
    });
  });

  describe("Firestoreに保存される内容", () => {
    test("participant: 指定の項目を持ち、旧人数フィールドは無く、schemaVersion=2・status=active・registrationType=winner", async () => {
      await api.commit(asAdmin(request(makeTable(1, () => ({"rd": " REF-9 ", "登録日時": "2026年03月04日 05時06分07秒", "かな": " かな ", "氏名": "  架空　太郎 "})))));
      const p = (await db.collection("participants").doc("batchA-000002").get()).data();
      assert.deepEqual(Object.keys(p).sort(), ["createdAt", "email", "eventId", "importBatchId", "importRow", "kana", "name", "participantId",
        "publicId", "registrationType", "schemaVersion", "sourceReference", "sourceRegisteredAt", "status", "updatedAt"]);
      assert.deepEqual([p.eventId, p.name, p.kana, p.email, p.sourceReference, p.schemaVersion, p.status, p.registrationType, p.importBatchId, p.importRow, p.participantId],
        ["event1", "架空　太郎", "かな", "synthetic1@example.invalid", "REF-9", 2, "active", "winner", "batchA", 2, "batchA-000002"]);
      assert.equal(p.sourceRegisteredAt.toDate().toISOString(), "2026-03-03T20:06:07.000Z");
      assert.ok(!(LEGACY_COUNT_KEY in p));
    });
    test("programAttendance: IDは{participantId}_{programId}。plannedCountを保持し、受付は未実施の初期状態", async () => {
      await api.commit(asAdmin(request(makeTable(2, (i) => (i === 2 ? {"午後参加時間": "14:00-15:30", "午後参加人数": "3", "午前参加人数": "４人"} : {})))));
      const alpha = (await db.collection("programAttendances").doc("batchA-000002_alpha").get()).data();
      assert.deepEqual(Object.keys(alpha).sort(), ["attendedCount", "checkedIn", "checkedInAt", "checkedInBy", "endAt", "eventId", "importBatchId",
        "participantId", "plannedCount", "programId", "slotLabel", "startAt", "updatedAt"]);
      assert.deepEqual([alpha.eventId, alpha.participantId, alpha.programId, alpha.plannedCount, alpha.slotLabel, alpha.checkedIn, alpha.checkedInAt, alpha.attendedCount, alpha.checkedInBy],
        ["event1", "batchA-000002", "alpha", 2, "10:00-11:00", false, null, null, null]);
      assert.equal(alpha.startAt.toDate().toISOString(), "2026-11-30T01:00:00.000Z");
      assert.equal(alpha.endAt.toDate().toISOString(), "2026-11-30T02:00:00.000Z");
      const beta = (await db.collection("programAttendances").doc("batchA-000003_beta").get()).data();
      assert.deepEqual([beta.plannedCount, beta.slotLabel, beta.endAt.toDate().toISOString()], [3, "14:00-15:30", "2026-11-30T06:30:00.000Z"]);
      assert.equal((await db.collection("programAttendances").doc("batchA-000003_alpha").get()).data().plannedCount, 4, "全角数字の人数");
      const gamma = (await db.collection("programAttendances").doc("batchA-000002_gamma").get()).data();
      assert.deepEqual([gamma.slotLabel, gamma.startAt, gamma.plannedCount], [null, null, 1]);
      assert.equal((await db.collection("programAttendances").doc("batchA-000002_beta").get()).exists, false, "不参加のprogramのattendanceは作られない");
    });
    test("行の監査と応答に個人情報(氏名・メール・かな・自由記述)を複製しない", async () => {
      const result = await api.commit(asAdmin(request(makeTable(8, (i) => (i === 3 ? {"氏名": ""} : {})))));
      const rows = await rowsOf("batchA");
      const serialized = JSON.stringify([rows, result, await batch("batchA")]);
      for (const forbidden of ["架空テスト", "synthetic1", "かくうてすと", UNMAPPED_MARKER, "example.invalid", "@"]) {
        assert.ok(!serialized.includes(forbidden), forbidden);
      }
      assert.deepEqual(Object.keys(rows[0]).sort(), ["approvedAt", "approvedBy", "approvedReview", "classification", "createdAt", "excludedAt", "excludedBy",
        "excludedByOperator", "excludedReason", "importRecordId", "issueCodes", "participantId", "programIds", "result", "sourceRowNumber"]);
    });
    test("importBatchの項目", async () => {
      await api.commit(asAdmin(request(makeTable(4, (i) => (i === 2 ? {"氏名": ""} : {})), {sourceFileName: "list1.csv", fileHash: "c".repeat(64), label: "第1回"})));
      const b = await batch("batchA");
      assert.deepEqual([b.eventId, b.sequence, b.label, b.sourceFileName, b.fileHash, b.mappingVersion, b.totalRows, b.createdCount, b.reviewPendingCount,
        b.errorCount, b.excludedByOperatorCount, b.blankRecordCount, b.createdBy, b.status],
        ["event1", 1, "第1回", "list1.csv", "c".repeat(64), 3, 4, 3, 0, 1, 0, 0, "u-admin", "committed"]);
      assert.ok(b.createdAt && b.completedAt);
      assert.ok(!("skipped" + "Count" in b));
    });
    test("publicIdは推測困難(pub_ + 192bit)で、全participantで異なる", async () => {
      await api.commit(asAdmin(request(100)));
      const ids = (await docs("participants")).map((d) => d.data().publicId);
      assert.equal(new Set(ids).size, 100);
      assert.ok(ids.every((id) => /^pub_[A-Za-z0-9_-]{32}$/.test(id)));
    });
    test("旧人数フィールドは、participant・attendance・監査・batch・eventのどこにも書かれない(plannedCountだけが人数の正本)", async () => {
      await api.commit(asAdmin(request(makeTable(10, (i) => (i === 2 ? {"氏名": ""} : {})))));
      const scan = async (path) => (await docs(path)).flatMap((d) => Object.keys(d.data()));
      const keys = [...await scan("participants"), ...await scan("programAttendances"), ...await scan("importBatches"), ...await scan("events"),
        ...(await rowsOf("batchA")).flatMap((r) => Object.keys(r))];
      assert.ok(keys.length > 0);
      assert.ok(!keys.includes(LEGACY_COUNT_KEY));
      assert.ok(keys.includes("plannedCount"));
    });
    test("未マップの列の内容(自由記述など)はどこにも保存されない(データ最小化)", async () => {
      await api.commit(asAdmin(request(makeTable(5))));
      const all = JSON.stringify([(await docs("participants")).map((d) => d.data()), (await docs("programAttendances")).map((d) => d.data())]);
      for (const unmapped of [UNMAPPED_MARKER, "架空県", "9名"]) assert.ok(!all.includes(unmapped), unmapped);
    });
  });

  describe("リクエストの検証(サーバーは受け取った値を信用しない)", () => {
    const rejects = async (mutate, expectedCode) => {
      const data = request(makeTable(5));
      mutate(data);
      await assert.rejects(api.commit(asAdmin(data)), (e) => e.code === "invalid-argument" && (!expectedCode || e.details.code === expectedCode));
      assert.equal(await count("importBatches"), 0);
      assert.equal(await count("participants"), 0);
    };
    test("未マップの列を送ると拒否(データ最小化) / 必要な列が無くても拒否", async () => {
      await rejects((d) => { d.headers.push("都道府県"); d.rows.forEach((r) => r.values.push("架空県")); }, "unexpected-column");
      await rejects((d) => { const i = d.headers.indexOf("氏名"); d.headers.splice(i, 1); d.rows.forEach((r) => r.values.splice(i, 1)); }, "column-missing");
    });
    test("行を1つ落として送る(欠落)と、行のつじつまが合わないため拒否される", async () => {
      await rejects((d) => { d.rows.splice(2, 1); }, "record-accounting-mismatch");
      await rejects((d) => { d.totalRecords = 4; }, "record-accounting-mismatch");
      await rejects((d) => { d.rows[1].rowNumber = 2; }, "duplicate-record-number");
      await rejects((d) => { d.blankRecordNumbers.push(3); }, "duplicate-record-number");
    });
    test("行を「空レコード」と偽って隠すことはできず、空と申告した行は監査に空として必ず残る", async () => {
      const data = request(makeTable(5));
      const hidden = data.rows.splice(2, 1)[0];
      data.blankRecordNumbers.push(hidden.rowNumber);
      const result = await api.commit(asAdmin(data));
      const row = result.rows.find((r) => r.sourceRowNumber === hidden.rowNumber);
      assert.equal(row.result, "blank");
      assert.equal(result.blankRecordCount, 1);
      assert.equal(result.createdCount, 4);
    });
    test("不正な入力(型・上限・ID・ハッシュ・mapping)を拒否する", async () => {
      await rejects((d) => { d.clientRequestId = "a-b"; }, "invalid-client-request-id");
      await rejects((d) => { d.clientRequestId = ""; }, "invalid-client-request-id");
      await rejects((d) => { d.eventId = "a/b"; }, "invalid-event-id");
      await rejects((d) => { d.fileHash = "xyz"; }, "invalid-file-hash");
      await rejects((d) => { d.mapping = {}; }, "invalid-mapping");
      await rejects((d) => { d.mapping = {...d.mapping, identity: {strategy: "email"}}; }, "invalid-mapping");
      await rejects((d) => { d.rows[0].values = [1, 2]; }, "invalid-row");
      await rejects((d) => { d.rows = "x"; }, "invalid-rows");
      await rejects((d) => { d.blankRecordNumbers = [1]; }, "invalid-blank-record-numbers");
      await rejects((d) => { d.unexpected = true; }, "unknown-key");
      await rejects((d) => { d.rows[0].email = "x@example.invalid"; }, "unknown-key");
      await assert.rejects(api.commit(asAdmin(null)), (e) => e.code === "invalid-argument");
      await assert.rejects(api.commit(asAdmin("x")), (e) => e.code === "invalid-argument");
    });
    test("値の個数がheadersと違う行は、捨てずにreviewとして残る", async () => {
      const data = request(makeTable(4));
      data.rows[1].values = data.rows[1].values.slice(0, 5);
      const result = await api.commit(asAdmin(data));
      const row = result.rows.find((r) => r.sourceRowNumber === 3);
      assert.equal(row.classification, "review");
      assert.ok(row.issueCodes.includes("row-length-mismatch"));
      assert.equal(result.reviewPendingCount, 1);
      assert.equal(result.totalRows, 4);
    });
    test("previewはapprovedReviewRows・excludedRows(commitでの判断)を受け付けない", async () => {
      await rejectsWith(api.preview(asAdmin({...request(3), approvedReviewRows: [2]})), "invalid-argument");
      await rejectsWith(api.preview(asAdmin({...request(3), excludedRows: []})), "invalid-argument");
    });
    test("commitはpreviewの結果を信用しない: クライアントが分類・participantを送っても無視できず、拒否される", async () => {
      await rejectsWith(api.commit(asAdmin({...request(3), classification: "ready", rows: request(3).rows})), "invalid-argument");
      await rejectsWith(api.commit(asAdmin({...request(3), previewResult: {readyCount: 3}})), "invalid-argument");
      // サーバーは値から自分で分類する: メールが壊れた行は、クライアントが何と言おうとerror
      const data = request(makeTable(3, (i) => (i === 2 ? {"メールアドレス": "壊れた値"} : {})));
      const result = await api.commit(asAdmin(data));
      assert.equal(result.rows.find((r) => r.sourceRowNumber === 3).result, "error");
      assert.equal(await count("participants"), 2);
    });
  });

  describe("メール送信との境界(importでは1通も送らない)", () => {
    test("import(preview・commit・再試行)でメール送信0件: メール関連のコレクションは作られず、外部通信もない", async () => {
      await api.preview(asAdmin(request(20)));
      await api.commit(asAdmin(request(20)));
      await api.commit(asAdmin(request(20)));
      const collections = (await db.listCollections()).map((c) => c.id).sort();
      assert.deepEqual(collections, ["accessRoles", "events", "importBatches", "participants", "programAttendances"]);
      for (const name of ["mailJobs", "sendJobs", "mailLogs", "mailDeliveries"]) assert.equal(await count(name), 0, name);
      assert.deepEqual(calls, [], "Emulator以外への通信がない");
      const participants = (await docs("participants")).map((d) => d.data());
      assert.ok(participants.every((p) => !("invitationSent" in p) && !("invitationMailStatus" in p)));
    });
    test("committed後の状態だけが送信対象になる境界: statusとparticipantのimportBatchIdで結び付けられる", async () => {
      await api.commit(asAdmin(request(3)));
      const committed = await docs("importBatches", (c) => c.where("status", "==", "committed"));
      assert.equal(committed.length, 1);
      const linked = await participantsOf(committed[0].id);
      assert.equal(linked.length, 3);
    });
  });

  after(() => { globalThis.fetch = realFetch; });
});
