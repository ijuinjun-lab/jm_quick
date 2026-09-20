// 認証基盤(functions/auth.js)のテスト。Firestoreはメモリ上のフェイク、外部通信なし。
// 認可は「Firebase Auth UID + accessRoles/{uid}.active === true + role(admin|staff)」だけで決まり、
// リクエスト本文・トークン内のemail/roleは一切信用しないことを確認する。
const assert = require("node:assert/strict");
const {afterEach, describe, test} = require("node:test");
const {FakeFirestore} = require("../test_support/fake_firestore");
const {loadIndex, stubFetch} = require("../test_support/load_index");
const {requireAuthenticated, requireAdmin, requireStaffOrAdmin, confirmedCallable, ACCESS_LEVELS} = require("../auth");

const silent = {warn: () => {}};
const roles = (seed) => new FakeFirestore(Object.fromEntries(
  Object.entries(seed).map(([uid, data]) => [`accessRoles/${uid}`, data])));
const as = (uid, extra = {}) => ({auth: {uid, ...(extra.auth || {})}, data: extra.data});
const code = (error) => error.code;
const rejectsWith = (promise, expected) => assert.rejects(promise, (error) => code(error) === expected);

describe("requireAuthenticated", () => {
  test("未認証(auth無し)は unauthenticated で拒否", () => {
    for (const request of [{}, {auth: null}, {auth: {}}, {auth: {uid: ""}}, {auth: {uid: 123}}, undefined, null]) {
      assert.throws(() => requireAuthenticated(request), (error) => code(error) === "unauthenticated");
    }
  });
  test("ログイン済みならUIDを返す(UIDはrequest.authからのみ)", () => {
    assert.deepEqual(requireAuthenticated({auth: {uid: "u1"}, data: {uid: "attacker"}}), {uid: "u1"});
  });
});

describe("accessRoles による認可", () => {
  const db = () => roles({
    adminUser: {role: "admin", active: true},
    staffUser: {role: "staff", active: true},
    inactiveAdmin: {role: "admin", active: false},
    stringActive: {role: "admin", active: "true"},
    noActive: {role: "admin"},
    unknownRole: {role: "owner", active: true},
    upperRole: {role: "Admin", active: true},
    emptyRole: {role: "", active: true},
    noRole: {active: true},
  });

  test("accessRolesが無いユーザーは拒否(permission-denied)", async () => {
    await rejectsWith(requireStaffOrAdmin(as("nobody"), {db: db(), logger: silent}), "permission-denied");
    await rejectsWith(requireAdmin(as("nobody"), {db: db(), logger: silent}), "permission-denied");
  });

  test("未認証はstaffOrAdmin/adminとも unauthenticated(Firestoreを読まない)", async () => {
    const fake = db();
    let reads = 0;
    const original = fake.collection.bind(fake);
    fake.collection = (name) => { reads += 1; return original(name); };
    await rejectsWith(requireStaffOrAdmin({}, {db: fake, logger: silent}), "unauthenticated");
    await rejectsWith(requireAdmin({auth: null}, {db: fake, logger: silent}), "unauthenticated");
    assert.equal(reads, 0);
  });

  test("active=false・activeが真偽値のtrueでない(文字列・欠落)は拒否", async () => {
    for (const uid of ["inactiveAdmin", "stringActive", "noActive"]) {
      await rejectsWith(requireStaffOrAdmin(as(uid), {db: db(), logger: silent}), "permission-denied");
      await rejectsWith(requireAdmin(as(uid), {db: db(), logger: silent}), "permission-denied");
    }
  });

  test("未知のrole(owner・大文字・空・欠落)は拒否", async () => {
    for (const uid of ["unknownRole", "upperRole", "emptyRole", "noRole"]) {
      await rejectsWith(requireStaffOrAdmin(as(uid), {db: db(), logger: silent}), "permission-denied");
      await rejectsWith(requireAdmin(as(uid), {db: db(), logger: silent}), "permission-denied");
    }
  });

  test("staff は requireStaffOrAdmin に成功し、requireAdmin は拒否される", async () => {
    assert.deepEqual(await requireStaffOrAdmin(as("staffUser"), {db: db(), logger: silent}), {uid: "staffUser", role: "staff"});
    await rejectsWith(requireAdmin(as("staffUser"), {db: db(), logger: silent}), "permission-denied");
  });

  test("admin は requireAdmin と requireStaffOrAdmin の両方に成功する(adminはstaff操作を包含)", async () => {
    assert.deepEqual(await requireAdmin(as("adminUser"), {db: db(), logger: silent}), {uid: "adminUser", role: "admin"});
    assert.deepEqual(await requireStaffOrAdmin(as("adminUser"), {db: db(), logger: silent}), {uid: "adminUser", role: "admin"});
  });

  test("拒否の理由は呼び出し側に区別されない(未登録・無効・不明role・staffのadmin操作が同一の応答)", async () => {
    const errors = [];
    for (const [uid, guard] of [["nobody", requireStaffOrAdmin], ["inactiveAdmin", requireStaffOrAdmin],
      ["unknownRole", requireStaffOrAdmin], ["staffUser", requireAdmin]]) {
      errors.push(await guard(as(uid), {db: db(), logger: silent}).catch((e) => e));
    }
    assert.equal(new Set(errors.map((e) => `${e.code}|${e.message}`)).size, 1);
    assert.equal(errors[0].code, "permission-denied");
  });

  test("拒否の詳細理由はサーバーログにだけ残る(トークン・emailは記録しない)", async () => {
    const logs = [];
    await requireStaffOrAdmin(as("inactiveAdmin", {auth: {token: {email: "x@example.invalid"}}}), {db: db(), logger: {warn: (...a) => logs.push(a)}}).catch(() => {});
    assert.equal(logs.length, 1);
    assert.deepEqual(logs[0][1], {uid: "inactiveAdmin", reason: "inactive"});
    assert.ok(!JSON.stringify(logs).includes("example.invalid"));
  });
});

describe("リクエスト本文・トークンの偽装は無効", () => {
  const db = () => roles({staffUser: {role: "staff", active: true}, adminUser: {role: "admin", active: true}, nobody2: {role: "staff", active: false}});

  test("本文にrole:'admin'を入れても、staffはadmin操作を実行できない", async () => {
    const request = as("staffUser", {data: {role: "admin", isAdmin: true, admin: true}});
    await rejectsWith(requireAdmin(request, {db: db(), logger: silent}), "permission-denied");
    assert.equal((await requireStaffOrAdmin(request, {db: db(), logger: silent})).role, "staff");
  });

  test("本文に別のUID(adminのUID)を入れても、判定は認証済みの自分のUIDで行われる", async () => {
    const request = as("staffUser", {data: {uid: "adminUser", userId: "adminUser", targetUid: "adminUser"}});
    const identity = await requireStaffOrAdmin(request, {db: db(), logger: silent});
    assert.deepEqual(identity, {uid: "staffUser", role: "staff"});
    await rejectsWith(requireAdmin(request, {db: db(), logger: silent}), "permission-denied");
  });

  test("本文のemailでadminになりすませない(emailは認可キーではない)", async () => {
    const request = as("staffUser", {data: {email: "admin@example.invalid"}, auth: {token: {email: "admin@example.invalid"}}});
    await rejectsWith(requireAdmin(request, {db: db(), logger: silent}), "permission-denied");
  });

  test("IDトークン内のroleクレーム・emailクレームは信用しない(accessRolesだけが正本)", async () => {
    const request = {auth: {uid: "staffUser", token: {role: "admin", admin: true, email: "admin@example.invalid", email_verified: true}}};
    await rejectsWith(requireAdmin(request, {db: db(), logger: silent}), "permission-denied");
    const noDoc = {auth: {uid: "ghost", token: {role: "admin", admin: true}}};
    await rejectsWith(requireStaffOrAdmin(noDoc, {db: db(), logger: silent}), "permission-denied");
  });

  test("active=falseのユーザーは、本文・トークンでadminを主張しても拒否", async () => {
    const request = {auth: {uid: "nobody2", token: {role: "admin"}}, data: {role: "admin", active: true}};
    await rejectsWith(requireStaffOrAdmin(request, {db: db(), logger: silent}), "permission-denied");
  });

  test("文書パスを壊すUID(/ など)は、Firestoreを読む前に拒否する", async () => {
    const fake = db();
    let reads = 0;
    const original = fake.collection.bind(fake);
    fake.collection = (name) => { reads += 1; return original(name); };
    for (const uid of ["a/b", "../adminUser", "a b", "x".repeat(129), "日本語"]) {
      await rejectsWith(requireStaffOrAdmin({auth: {uid}}, {db: fake, logger: silent}), "permission-denied");
    }
    assert.equal(reads, 0);
  });

  test("認可の判定部分(requireAuthenticated〜GUARDS)はrequest.data・トークンのクレームを読まない", () => {
    const source = require("node:fs").readFileSync(require.resolve("../auth"), "utf8");
    const start = source.indexOf("function requireAuthenticated");
    const end = source.indexOf("const GUARDS");
    assert.ok(start > 0 && end > start, "判定部分が見つかりません");
    const code = source.slice(start, end).split("\n").filter((line) => !line.trim().startsWith("//")).join("\n");
    assert.doesNotMatch(code, /request\.data|request\.body|request\.rawRequest|\.token\b|\.email\b|\.claims\b/);
    assert.match(code, /request\.auth\.uid/, "UIDはrequest.authから取得している");
  });
});

describe("confirmedCallable(認可を通らないハンドラは実行されない)", () => {
  const db = () => roles({staffUser: {role: "staff", active: true}, adminUser: {role: "admin", active: true}});

  test("アクセスレベル未指定・不正・ハンドラ無しは、定義時に例外(認可なしでは公開できない)", () => {
    for (const bad of [undefined, null, "", "public", "Admin", "constructor", "__proto__", "toString"]) {
      assert.throws(() => confirmedCallable(bad, () => ({})), /invalid access level/, String(bad));
    }
    assert.throws(() => confirmedCallable("admin", undefined), /handler required/);
    assert.deepEqual(Object.values(ACCESS_LEVELS).sort(), ["admin", "authenticated", "staffOrAdmin"]);
  });

  test("拒否されたときハンドラは一度も実行されない", async () => {
    let calls = 0;
    const admin = confirmedCallable("admin", () => { calls += 1; return {ok: true}; }, {db: db(), logger: silent});
    const either = confirmedCallable("staffOrAdmin", () => { calls += 1; return {ok: true}; }, {db: db(), logger: silent});
    await rejectsWith(admin.run({}), "unauthenticated");
    await rejectsWith(admin.run(as("staffUser")), "permission-denied");
    await rejectsWith(admin.run(as("ghost")), "permission-denied");
    await rejectsWith(either.run({}), "unauthenticated");
    await rejectsWith(either.run(as("ghost")), "permission-denied");
    assert.equal(calls, 0);
  });

  test("許可されたときだけ実行され、identityはサーバー側で確定した値(本文の値ではない)", async () => {
    const seen = [];
    const admin = confirmedCallable("admin", ({identity, data}) => { seen.push({identity, data}); return {ok: true}; }, {db: db(), logger: silent});
    assert.deepEqual(await admin.run(as("adminUser", {data: {role: "staff", uid: "someone"}})), {ok: true});
    assert.deepEqual(seen[0].identity, {uid: "adminUser", role: "admin"});
    assert.deepEqual(seen[0].data, {role: "staff", uid: "someone"}, "本文は信用できない入力としてそのまま渡る");
  });

  test("authenticatedレベルは、ログイン済みなら(accessRoles無しでも)通り、未認証は拒否", async () => {
    const level = confirmedCallable("authenticated", ({identity}) => identity, {db: db(), logger: silent});
    assert.deepEqual(await level.run(as("anyone")), {uid: "anyone"});
    await rejectsWith(level.run({}), "unauthenticated");
  });
});

describe("getMyAccessRole(最初の認証callable)", () => {
  let net;
  afterEach(() => net?.restore());
  const load = (seed) => {
    const db = roles(seed);
    net = stubFetch();
    return {db, index: loadIndex(db)};
  };

  test("adminはrole=adminだけを返す(返却は authenticated と role のみ・副作用なし)", async () => {
    const {db, index} = load({adminUser: {role: "admin", active: true, email: "admin@example.invalid", displayName: "架空管理者"}});
    const result = await index.getMyAccessRole.run(as("adminUser"));
    assert.deepEqual(result, {authenticated: true, role: "admin"});
    assert.deepEqual(Object.keys(result).sort(), ["authenticated", "role"]);
    assert.equal(db.writes.length, 0, "書込みなし");
    assert.equal(net.calls.length, 0, "外部通信なし");
    assert.ok(!JSON.stringify(result).includes("example.invalid"), "メールアドレスは返さない");
  });

  test("staffはrole=staffを返す。本文でadminを主張しても結果は変わらない", async () => {
    const {index} = load({staffUser: {role: "staff", active: true}});
    assert.deepEqual(await index.getMyAccessRole.run(as("staffUser", {data: {role: "admin", uid: "adminUser"}})),
      {authenticated: true, role: "staff"});
  });

  test("未認証は unauthenticated、accessRolesなし・active=false・未知roleは permission-denied", async () => {
    const {index} = load({inactive: {role: "admin", active: false}, weird: {role: "root", active: true}});
    await rejectsWith(index.getMyAccessRole.run({}), "unauthenticated");
    for (const uid of ["ghost", "inactive", "weird"]) {
      await assert.rejects(index.getMyAccessRole.run(as(uid)), (e) => code(e) === "permission-denied");
    }
  });
});
