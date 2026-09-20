// ブートストラップCLI(set_access_role.js)のテスト。Firebase Admin SDKには接続せず、バックエンドはフェイク。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {parseArgs, buildPlan, run} = require("../set_access_role");

const BASE = ["--project", "demo-project-1", "--uid", "uid123", "--role", "admin", "--active", "true"];
const collect = () => { const lines = []; return {lines, out: (line) => lines.push(line)}; };
// バックエンドが1度でも生成・使用されたら失敗する(dry-runでは接続してはならない)。
const forbiddenBackend = () => { throw new Error("バックエンドへ接続してはいけません"); };

function fakeBackend({authUser = {exists: true, email: "someone@example.invalid"}, existing = null, otherAdmins = 1} = {}) {
  const calls = [];
  const backend = {
    calls,
    async getAuthUser() { calls.push("getAuthUser"); return authUser; },
    async getAccessRole() { calls.push("getAccessRole"); return existing; },
    async countOtherActiveAdmins() { calls.push("countOtherActiveAdmins"); return otherAdmins; },
    async writeAccessRole(data, isNew) { calls.push(["write", data, isNew]); },
  };
  return backend;
}

test("必須引数(--project/--uid/--role/--active)が1つでも欠けると実行を拒否する", async () => {
  const drop = (flag) => { const i = BASE.indexOf(flag); return [...BASE.slice(0, i), ...BASE.slice(i + 2)]; };
  for (const flag of ["--project", "--uid", "--role", "--active"]) {
    const {lines, out} = collect();
    assert.equal(await run({argv: drop(flag), out, createBackend: forbiddenBackend}), 2, flag);
    assert.ok(lines.some((l) => l.startsWith("エラー")), flag);
  }
  assert.equal(await run({argv: [], out: () => {}, createBackend: forbiddenBackend}), 2);
});

test("不正な値(project形式・uid形式・role・active)を拒否する", async () => {
  const cases = [["--project", "A"], ["--project", "bad_id"], ["--project", "x/y"], ["--uid", "a/b"], ["--uid", "a b"], ["--uid", "x".repeat(129)],
    ["--role", "owner"], ["--role", "Admin"], ["--role", "superuser"], ["--active", "yes"], ["--active", "1"], ["--active", "True"]];
  for (const [flag, value] of cases) {
    const argv = [...BASE];
    argv[argv.indexOf(flag) + 1] = value;
    assert.equal(await run({argv, out: () => {}, createBackend: forbiddenBackend}), 2, `${flag} ${value}`);
  }
});

test("メールアドレスからの検索はできない(--email等の未知オプションは拒否)", async () => {
  for (const extra of [["--email", "a@example.invalid"], ["--find-by-email", "x"], ["--unknown"], ["stray"]]) {
    assert.equal(await run({argv: [...BASE, ...extra], out: () => {}, createBackend: forbiddenBackend}), 2, extra.join(" "));
  }
  assert.ok(!Object.keys(parseArgs(BASE).options).includes("email"));
});

test("引数の重複・値の欠落を拒否する", () => {
  assert.ok(parseArgs([...BASE, "--role", "staff"]).errors.length > 0);
  assert.ok(parseArgs(["--project"]).errors.length > 0);
  assert.ok(parseArgs(["--project", "--uid", "u"]).errors.length > 0);
  assert.ok(parseArgs(["--apply=yes"]).errors.length > 0);
  assert.deepEqual(parseArgs(["--project=demo-project-1"]).options, {project: "demo-project-1"});
});

test("既定はdry-run: バックエンド(Firebase)へ接続せず、何も書き込まず、対象を表示する", async () => {
  const {lines, out} = collect();
  assert.equal(await run({argv: BASE, env: {}, out, createBackend: forbiddenBackend}), 0);
  const text = lines.join("\n");
  assert.match(text, /DRY-RUN/);
  assert.match(text, /対象プロジェクトID: demo-project-1/);
  assert.match(text, /書き込み先: 実Firestore\(プロジェクト demo-project-1\)/);
  assert.match(text, /対象UID: uid123/);
  assert.match(text, /role=admin active=true/);
  assert.match(text, /何も変更していません/);
  assert.match(text, /--apply --confirm-project demo-project-1/);
});

test("dry-runはFirebase Admin SDKを読み込まない(loadAdminが呼ばれない)", async () => {
  const {createAdminBackend} = require("../set_access_role");
  let loaded = 0;
  assert.equal(await run({argv: BASE, env: {}, out: () => {}, createBackend: (plan) => createAdminBackend(plan, () => { loaded += 1; return {}; })}), 0);
  assert.equal(loaded, 0);
});

test("--applyだけでは書き込まない。--project と同じ値の --confirm-project が必須", async () => {
  for (const extra of [["--apply"], ["--apply", "--confirm-project", "other-project"], ["--apply", "--confirm-project"]]) {
    const backend = fakeBackend();
    assert.equal(await run({argv: [...BASE, ...extra], out: () => {}, createBackend: () => backend}), 2, extra.join(" "));
    assert.deepEqual(backend.calls, []);
  }
  assert.equal(await run({argv: [...BASE, "--confirm-project", "other-project"], out: () => {}, createBackend: forbiddenBackend}), 2);
});

test("--apply + --confirm-project: 新規作成(role/active/email、書込みは1回)", async () => {
  const backend = fakeBackend();
  const {lines, out} = collect();
  const argv = [...BASE, "--display-name", "架空管理者", "--apply", "--confirm-project", "demo-project-1"];
  assert.equal(await run({argv, env: {}, out, createBackend: () => backend}), 0);
  assert.deepEqual(backend.calls[0], "getAuthUser");
  const write = backend.calls.find((c) => Array.isArray(c));
  assert.deepEqual(write, ["write", {role: "admin", active: true, email: "someone@example.invalid", displayName: "架空管理者"}, true]);
  assert.equal(backend.calls.filter((c) => Array.isArray(c)).length, 1);
  assert.match(lines.join("\n"), /警告: 実Firestoreへ書き込みます/);
  assert.match(lines.join("\n"), /完了: accessRoles\/uid123 を作成しました/);
});

test("--applyでも、Firebase Authに存在しないUIDは書き込まない", async () => {
  const backend = fakeBackend({authUser: {exists: false, email: null}});
  const {lines, out} = collect();
  assert.equal(await run({argv: [...BASE, "--apply", "--confirm-project", "demo-project-1"], out, createBackend: () => backend}), 1);
  assert.ok(!backend.calls.some((c) => Array.isArray(c)));
  assert.match(lines.join("\n"), /存在しません/);
});

test("エミュレータ指定(FIRESTORE_EMULATOR_HOST)のときは書き込み先にそれを表示し、実Firestore警告を出さない", async () => {
  const {lines, out} = collect();
  assert.equal(await run({argv: BASE, env: {FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080"}, out, createBackend: forbiddenBackend}), 0);
  assert.match(lines.join("\n"), /書き込み先: Firestore Emulator \(127\.0\.0\.1:8080\)/);
  const applyLines = collect();
  await run({argv: [...BASE, "--apply", "--confirm-project", "demo-project-1"], env: {FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080"}, out: applyLines.out, createBackend: () => fakeBackend()});
  assert.ok(!applyLines.lines.join("\n").includes("実Firestoreへ書き込みます"));
});

test("最後の有効なadminを外す操作は拒否(--allow-remove-last-admin が必要)", async () => {
  const existing = {role: "admin", active: true};
  const argv = ["--project", "demo-project-1", "--uid", "uid123", "--role", "staff", "--active", "true", "--apply", "--confirm-project", "demo-project-1"];
  const blocked = fakeBackend({existing, otherAdmins: 0});
  assert.equal(await run({argv, out: () => {}, createBackend: () => blocked}), 1);
  assert.ok(!blocked.calls.some((c) => Array.isArray(c)));
  const deactivate = fakeBackend({existing, otherAdmins: 0});
  assert.equal(await run({argv: [...BASE.slice(0, 6), "--active", "false", "--apply", "--confirm-project", "demo-project-1"], out: () => {}, createBackend: () => deactivate}), 1);
  const allowed = fakeBackend({existing, otherAdmins: 0});
  assert.equal(await run({argv: [...argv, "--allow-remove-last-admin"], out: () => {}, createBackend: () => allowed}), 0);
  const others = fakeBackend({existing, otherAdmins: 2});
  assert.equal(await run({argv, out: () => {}, createBackend: () => others}), 0);
});

test("既存の設定を更新する場合は新規作成ではなく更新として書き込む(createdAtを上書きしない)", async () => {
  const backend = fakeBackend({existing: {role: "staff", active: false}});
  assert.equal(await run({argv: [...BASE, "--apply", "--confirm-project", "demo-project-1"], out: () => {}, createBackend: () => backend}), 0);
  assert.equal(backend.calls.find((c) => Array.isArray(c))[2], false);
});

test("buildPlanは対象を組み立てるだけで副作用がない", () => {
  const built = buildPlan(parseArgs(BASE).options, {});
  assert.equal(built.ok, true);
  assert.deepEqual([built.plan.project, built.plan.uid, built.plan.role, built.plan.active, built.plan.apply],
    ["demo-project-1", "uid123", "admin", true, false]);
});
