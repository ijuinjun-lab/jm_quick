// Phase 10D: Firestoreの最終閉鎖。未認証・認証済み(accessRolesなし)・staff相当・admin相当のどのクライアントSDKからも、
// 業務データのcollectionを get / list / create / update / delete できないことを、ローカルEmulator(localhostのみ)で確認する。
// 権限の判断はサーバー(Admin SDK)側で行い、Rules側は request.auth の有無にも role の見かけにも依存しない(全面拒否)。
// データはすべて完全な架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

// 業務データを持つ全collection(サブcollection含む)。ここに無いcollectionが増えたら、静的検査が失敗して気付ける。
const DOCS = [
  ["events", "e1", {eventId: "e1", eventName: "架空", flow: "confirmed", winnerMailTemplate: {subject: "秘密"}, senderName: "秘密の送信者", contact: "秘密の連絡先", venueInfo: {address: "秘密"}, reminderSendAt: "x", importSequence: 2}],
  ["participants", "p1", {participantId: "p1", eventId: "e1", publicId: "pub_secret_0123456789abcdef0123", name: "架空 花子", kana: "かくう", email: "secret@example.invalid", sourceReference: "SRC-秘密"}],
  ["checkIns", "p1", {participantId: "p1", eventId: "e1", checkedIn: false}],
  ["mailJobs", "j1", {eventId: "e1", type: "invitation", status: "queued"}],
  ["mailJobs/j1/items", "p1", {status: "pending"}],
  ["mailLogs", "l1", {participantId: "p1", eventId: "e1", type: "invitation"}],
  ["walkInRegistrations", "w1", {eventId: "e1", participantId: "p1", email: "secret@example.invalid"}],
  ["accessRoles", "u-admin", {role: "admin", active: true}],
  ["eventAssignments", "ea-fixture", {eventId: "e1", uid: "u-staff", role: "staff", active: true, email: "secret@example.invalid"}],
  ["eventInvitations", "ei-fixture", {eventId: "e1", email: "secret@example.invalid", role: "staff", status: "pending", tokenHash: "x"}],
  ["importBatches", "b1", {eventId: "e1", status: "committed"}],
  ["importBatches/b1/rows", "r1", {result: "created"}],
  ["sendJobs", "s1", {eventId: "e1", status: "ready"}],
  ["sendJobs/s1/items", "p1", {status: "pending"}],
  ["mailDeliveries", "d1", {participantId: "p1", status: "sent"}],
  ["programAttendances", "a1", {eventId: "e1", participantId: "p1", programId: "a", plannedCount: 1}],
  ["programAttendances/a1/history", "h1", {action: "check-in"}],
  ["rateLimits", "rl1", {policy: "viewIp", count: 1}],
  ["unknownCollection", "x1", {anything: true}],
];

describe("Firestore Rules(Phase 10D): 全collectionを、どのクライアントからも直接read/writeできない(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const CLIENTS = [
    ["未認証", undefined],
    ["認証済み(accessRolesなし)", unsignedToken("u-nobody", {})],
    ["staff相当", unsignedToken("u-staff", {role: "staff"})],
    ["admin相当", unsignedToken("u-admin", {role: "admin", admin: true})],
  ];

  before(async () => {
    emu = await startEmulator();
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    for (const [collection, id, data] of DOCS) await emu.seed(`${collection}/${id}`, data);
    await emu.seed("accessRoles/u-staff", {role: "staff", active: true});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    test(`${label}: get・list・create・update・deleteのすべてが拒否される(全${DOCS.length}collection)`, async () => {
      for (const [collection, id, data] of DOCS) {
        const path = `${collection}/${id}`;
        assert.equal(await emu.get(path, token), 403, `${label}: GET ${path}`);
        assert.equal(await emu.list(collection, token), 403, `${label}: LIST ${collection}`);
        assert.equal(await emu.create(collection, `new-${id}`, data, token), 403, `${label}: CREATE ${collection}`);
        assert.equal(await emu.update(path, {touched: true}, token), 403, `${label}: UPDATE ${path}`);
        assert.equal(await emu.set(path, data, token), 403, `${label}: SET ${path}`);
        assert.equal(await emu.remove(path, token), 403, `${label}: DELETE ${path}`);
      }
    });
  }

  test("拒否だけでなく、実際に何も変わっていない(オーナー権限で確認)", async () => {
    for (const [collection, id] of DOCS) assert.equal(await emu.get(`${collection}/${id}`, "owner"), 200, `${collection}/${id}が残っている`);
    for (const [collection, id] of DOCS) assert.equal(await emu.get(`${collection}/new-${id}`, "owner"), 404, `${collection}/new-${id}は作られていない`);
  });

  test("Rulesの静的検査: 公開allow(if true)・request.authだけの許可・ワイルドカードのallowが0件。matchした全collectionが read, write: if false のみ", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const code = rules.split("\n").filter((line) => !line.trim().startsWith("//")).join("\n");
    assert.doesNotMatch(code, /if\s+true/);
    assert.doesNotMatch(code, /request\.auth/, "request.authに依存した許可が無い");
    assert.doesNotMatch(code, /match\s+\/\{[^}]*=\*\*\}/);
    const allows = code.match(/allow[^;]*;/g) || [];
    assert.equal(allows.length, 18, "match 18か所(サブcollection含む。Phase 1AでeventAssignments、Phase 4でeventInvitationsを追加)");
    assert.deepEqual([...new Set(allows)], ["allow read, write: if false;"]);
    // DOCSの全collection(先頭のcollection)に、明示のmatchがある(未知のcollectionだけがdefault deny)
    const matched = new Set([...code.matchAll(/match \/(\w+)\/\{/g)].map((m) => m[1]));
    for (const [collection] of DOCS.filter(([c]) => c !== "unknownCollection")) assert.ok(matched.has(collection.split("/")[0]), `${collection}のmatch`);
    for (const required of ["events", "participants", "checkIns", "mailJobs", "mailLogs", "walkInRegistrations", "accessRoles", "eventAssignments", "eventInvitations", "importBatches", "sendJobs", "mailDeliveries", "programAttendances", "rateLimits"]) {
      assert.ok(matched.has(required), `${required}の明示のmatch`);
    }
  });
});
