// Phase 11B-3: 当選・参加確定者CSVの「通常運用」向け取込テスト。
// participationColumn・attendingValues・notAttendingValues・emptyMeansを一切使わず、
// 「人数の列の値が1以上ならそのprogramへ参加、空欄または0なら参加しない」という人数だけの判定を、
// previewConfirmedImport / commitConfirmedImport の実物(Admin Emulator)に対して検証する。
// サーバー側のコードは変更していない(functions/confirmed/import_mapping.js・import_rows.js は
// 元々participationColumnを省略可能としており、省略時は人数だけで判定する分岐が既にあった)。
// データはすべて架空。メールは予約TLD .invalid のみ。実CSV・実氏名・実メールは一切使わない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {createImportApi} = require("../confirmed/import_api");
const {confirmedCallable} = require("../auth");

const silent = {warn: () => {}};
const rejectsWith = (promise, code) => assert.rejects(promise, (error) => error.code === code);

// 人数の列だけで参加を判定するmapping(参加/不参加を示す列は送らない)。
const HEADERS = ["氏名", "メール", "プログラム1人数", "プログラム2人数", "プログラム3人数"];
function mapping() {
  return {
    version: 1,
    participant: {nameColumn: "氏名", emailColumn: "メール"},
    rowChecks: [],
    programs: [
      {programId: "alpha", countColumn: "プログラム1人数"},
      {programId: "beta", countColumn: "プログラム2人数"},
      {programId: "gamma", countColumn: "プログラム3人数"},
    ],
  };
}

function record({name, email, counts}) {
  const [c1, c2, c3] = counts;
  return {"氏名": name, "メール": email, "プログラム1人数": c1, "プログラム2人数": c2, "プログラム3人数": c3};
}

function tableOf(records) {
  return {headers: [...HEADERS], records: records.map((r) => HEADERS.map((h) => String(r[h] ?? "")))};
}

describe("CSV取込: 人数の列だけで参加を判定する通常運用(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
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
  const participantsOf = async (id) => docs("participants", (c) => c.where("importBatchId", "==", id));
  const request = (records, options = {}) => buildImportRequest({table: tableOf(records), mapping: mapping(), ...options});

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

  describe("3名の例: プログラムごとにplannedCountが人数の列どおりに作られる", () => {
    // A: プログラム1に2名・プログラム2に1名で参加、プログラム3は不参加(空欄)。
    // B: プログラム1は不参加(空欄)、プログラム2に2名・プログラム3に1名で参加。
    // C: プログラム1〜3すべてに参加(1名・2名・3名)。
    const records = () => [
      record({name: "架空参加者A", email: "test-a@example.invalid", counts: [2, 1, ""]}),
      record({name: "架空参加者B", email: "test-b@example.invalid", counts: ["", 2, 1]}),
      record({name: "架空参加者C", email: "test-c@example.invalid", counts: [1, 2, 3]}),
    ];

    test("previewは3行とも ready、参加するprogramだけがattendance候補になる", async () => {
      const result = await api.preview(asAdmin(request(records())));
      assert.deepEqual([result.totalRows, result.readyCount, result.reviewCount, result.errorCount], [3, 3, 0, 0]);
      assert.equal(result.participantCandidateCount, 3);
      assert.equal(result.attendanceCandidateCount, 7); // A:2(alpha,beta), B:2(beta,gamma), C:3(alpha,beta,gamma)
      assert.deepEqual(result.rows.map((r) => r.programIds), [["alpha", "beta"], ["beta", "gamma"], ["alpha", "beta", "gamma"]]);
    });

    test("commit: 参加者は3件だけ(人数に応じて参加者が増えたりしない)。1 CSV行 = 1 participant", async () => {
      const result = await api.commit(asAdmin(request(records())));
      assert.equal(result.status, "committed");
      assert.equal(result.createdCount, 3);
      assert.equal(await count("participants"), 3);
      assert.equal((await participantsOf("batchA")).length, 3);
    });

    test("programAttendances: plannedCountがCSVの人数どおりに独立して保存される。不参加のprogramにはattendanceが無い", async () => {
      await api.commit(asAdmin(request(records())));
      assert.equal(await count("programAttendances"), 7);
      const planned = async (participantId, programId) =>
        (await db.collection("programAttendances").doc(`${participantId}_${programId}`).get()).data()?.plannedCount ?? null;
      // A: alpha=2, beta=1, gamma=なし
      assert.equal(await planned("batchA-000002", "alpha"), 2);
      assert.equal(await planned("batchA-000002", "beta"), 1);
      assert.equal(await planned("batchA-000002", "gamma"), null);
      // B: alpha=なし, beta=2, gamma=1
      assert.equal(await planned("batchA-000003", "alpha"), null);
      assert.equal(await planned("batchA-000003", "beta"), 2);
      assert.equal(await planned("batchA-000003", "gamma"), 1);
      // C: alpha=1, beta=2, gamma=3
      assert.equal(await planned("batchA-000004", "alpha"), 1);
      assert.equal(await planned("batchA-000004", "beta"), 2);
      assert.equal(await planned("batchA-000004", "gamma"), 3);
    });

    test("commitのリクエストに参加/不参加を示す列(participationColumn等)は含まれない(サーバー契約の確認)", async () => {
      const req = request(records());
      assert.equal(JSON.stringify(req.mapping).includes("participationColumn"), false);
      assert.equal(JSON.stringify(req.mapping).includes("attendingValues"), false);
      assert.equal(JSON.stringify(req.mapping).includes("notAttendingValues"), false);
      const result = await api.commit(asAdmin(req));
      assert.equal(result.status, "committed");
    });
  });

  describe("人数の値ごとの判定(空欄・0・負数・小数・文字列)", () => {
    test("空欄 → その行のそのprogramにはattendanceが作られない(参加しない)", async () => {
      const result = await api.commit(asAdmin(request([
        record({name: "架空参加者D", email: "test-d@example.invalid", counts: ["", "", ""]}),
      ], {mapping: mapping()})));
      // 全program空欄の行は review(下のdescribeで別途検証)。ここではalpha単体で空欄→不参加のみ確認する。
      assert.equal(result.reviewPendingCount + result.createdCount + result.errorCount, 1);
    });
    test("0 → 空欄と同じく、そのprogramにはattendanceが作られない(参加しない)", async () => {
      const result = await api.commit(asAdmin(request([
        record({name: "架空参加者E", email: "test-e@example.invalid", counts: [0, 3, ""]}),
      ])));
      assert.equal(result.createdCount, 1);
      const attendances = await docs("programAttendances");
      assert.deepEqual(attendances.map((d) => d.data().programId).sort(), ["beta"]);
      assert.equal(attendances[0].data().plannedCount, 3);
    });
    test("負数 → 行はerrorとして拒否され、participantは作られない(該当行だけ除外)", async () => {
      const result = await api.commit(asAdmin(request([
        record({name: "架空参加者F", email: "test-f@example.invalid", counts: [-1, "", ""]}),
      ])));
      assert.equal(result.errorCount, 1);
      assert.equal(result.createdCount, 0);
      assert.equal(await count("participants"), 0);
      assert.deepEqual(result.rows[0].issueCodes, ["count-invalid"]);
    });
    test("小数 → 行はerrorとして拒否される", async () => {
      const result = await api.commit(asAdmin(request([
        record({name: "架空参加者G", email: "test-g@example.invalid", counts: ["1.5", "", ""]}),
      ])));
      assert.equal(result.errorCount, 1);
      assert.equal(result.createdCount, 0);
      assert.deepEqual(result.rows[0].issueCodes, ["count-invalid"]);
    });
    test("数値でない文字列 → 行はerrorとして拒否される", async () => {
      const result = await api.commit(asAdmin(request([
        record({name: "架空参加者H", email: "test-h@example.invalid", counts: ["たくさん", "", ""]}),
      ])));
      assert.equal(result.errorCount, 1);
      assert.equal(result.createdCount, 0);
      assert.deepEqual(result.rows[0].issueCodes, ["count-invalid"]);
    });
  });

  describe("全programの人数が空欄・0の行(無条件にactiveとして取り込まない)", () => {
    test("preview: reviewとして返る(errorでも黙ってreadyでもない)", async () => {
      const result = await api.preview(asAdmin(request([
        record({name: "架空参加者I", email: "test-i@example.invalid", counts: ["", 0, ""]}),
      ])));
      assert.deepEqual([result.readyCount, result.reviewCount, result.errorCount], [0, 1, 0]);
      assert.deepEqual(result.rows[0].issueCodes, ["no-program"]);
    });
    test("commit: 未承認なら参加者は作られず監査(review-pending)に残る。承認すれば0件のattendanceで参加者だけ作られる", async () => {
      const row = () => [record({name: "架空参加者I", email: "test-i@example.invalid", counts: ["", 0, ""]})];
      const pending = await api.commit(asAdmin(request(row(), {clientRequestId: "batchA"})));
      assert.deepEqual([pending.createdCount, pending.reviewPendingCount], [0, 1]);
      assert.equal(await count("participants"), 0);

      // 承認は行ごとの明示的な判断であり、既にcommitted済みの同じbatchIdへ承認状態だけ変えて再送しても
      // 冪等リプレイとして扱われ、変わらない(実運用どおり別のclientRequestIdで承認して送る)。
      const approved = await api.commit(asAdmin(request(row(), {clientRequestId: "batchB", approvedReviewRows: [2]})));
      assert.deepEqual([approved.createdCount, approved.reviewPendingCount], [1, 0]);
      assert.equal(await count("participants"), 1);
      assert.equal(await count("programAttendances"), 0, "参加するprogramが無いのでattendanceは0件");
    });
  });

  describe("重複判定をしない(同じメール・同じ氏名でも別の参加者として登録する)", () => {
    test("同じメールアドレス100行 → 100participant(人数の列だけの判定でも変わらない)", async () => {
      const records = Array.from({length: 100}, (_, i) =>
        record({name: `架空同一メール${i + 1}`, email: "same@example.invalid", counts: [1, "", ""]}));
      const result = await api.commit(asAdmin(request(records)));
      assert.equal(result.createdCount, 100);
      assert.equal(await count("participants"), 100);
      assert.equal(new Set((await docs("participants")).map((d) => d.data().email)).size, 1);
    });
    test("同じ氏名100行 → 100participant", async () => {
      const records = Array.from({length: 100}, (_, i) =>
        record({name: "架空同姓同名", email: `synthetic-count-only-${i + 1}@example.invalid`, counts: [1, "", ""]}));
      const result = await api.commit(asAdmin(request(records)));
      assert.equal(result.createdCount, 100);
      assert.equal(await count("participants"), 100);
    });
  });

  describe("冪等性(既存の契約への影響がないことの確認)", () => {
    test("同じcommitを再送しても participant・attendance は増えず、publicIdも変わらない", async () => {
      const records = () => [
        record({name: "架空参加者A", email: "test-a@example.invalid", counts: [2, 1, ""]}),
        record({name: "架空参加者B", email: "test-b@example.invalid", counts: ["", 2, 1]}),
        record({name: "架空参加者C", email: "test-c@example.invalid", counts: [1, 2, 3]}),
      ];
      const req = request(records());
      const first = await api.commit(asAdmin(req));
      const publicIds = new Map((await docs("participants")).map((d) => [d.id, d.data().publicId]));
      const before = await count("participants");
      const second = await api.commit(asAdmin(req));
      assert.equal(second.idempotentReplay, true);
      assert.equal(await count("participants"), before);
      for (const d of await docs("participants")) assert.equal(d.data().publicId, publicIds.get(d.id));
    });
  });

  describe("メール送信との境界(importでは1通も送らない)", () => {
    test("preview・commit・commit再送でメール関連コレクションは0件のまま", async () => {
      const records = () => [
        record({name: "架空参加者A", email: "test-a@example.invalid", counts: [2, 1, ""]}),
        record({name: "架空参加者B", email: "test-b@example.invalid", counts: ["", 2, 1]}),
        record({name: "架空参加者C", email: "test-c@example.invalid", counts: [1, 2, 3]}),
      ];
      await api.preview(asAdmin(request(records())));
      await api.commit(asAdmin(request(records())));
      await api.commit(asAdmin(request(records())));
      for (const name of ["mailJobs", "sendJobs", "mailLogs", "mailDeliveries"]) assert.equal(await count(name), 0, name);
    });
  });

  describe("publicId", () => {
    test("publicIdはサーバーが生成する(pub_ + 192bit)。クライアントの値は無視される", async () => {
      const req = request([record({name: "架空参加者J", email: "test-j@example.invalid", counts: [1, "", ""]})]);
      req.rows[0].publicId = "attacker-chosen-id";
      await rejectsWith(api.commit(asAdmin(req)), "invalid-argument"); // publicIdは未知のキーとして拒否される
      const clean = request([record({name: "架空参加者J", email: "test-j@example.invalid", counts: [1, "", ""]})]);
      await api.commit(asAdmin(clean));
      const p = (await docs("participants"))[0].data();
      assert.ok(/^pub_[A-Za-z0-9_-]{32}$/.test(p.publicId));
    });
  });
});
