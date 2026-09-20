// accessRoles(権限の正本)は、クライアントSDKから一切read/writeできないことを、ローカルEmulatorで検証する。
// 未認証・admin相当・staff相当のいずれからも、読めず、作成・更新・削除できない(admin自身も自分のroleを書き換えられない)。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

describe("Firestore Rules: accessRoles(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  const admin = unsignedToken("u-admin", {role: "admin", admin: true, email: "admin@example.invalid"});
  const staff = unsignedToken("u-staff", {role: "staff", email: "staff@example.invalid"});
  const CLIENTS = [["未認証", undefined], ["admin相当(ログイン済み・roleクレームあり)", admin], ["staff相当(ログイン済み)", staff]];

  before(async () => {
    emu = await startEmulator();
    // 対照実験: テスト用ルールで「署名なしJWTがrequest.authとして認識される」ことを先に確認する。
    // (認識されていなければ、以降の「拒否」テストは未認証扱いで通ってしまい、意味を持たないため)
    await emu.loadRules(`rules_version = '2';
service cloud.firestore { match /databases/{database}/documents {
  match /probe/{id} { allow read: if request.auth != null && request.auth.uid == id; }
} }`);
    await emu.seed("probe/u-admin", {ok: true});
    assert.equal(await emu.get("probe/u-admin", admin), 200, "adminトークンが認識される");
    assert.equal(await emu.get("probe/u-admin", staff), 403, "別UIDのトークンは拒否される");
    assert.equal(await emu.get("probe/u-admin"), 403, "未認証は拒否される");
    // 本番のRulesへ切り替える。
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    await emu.seed("accessRoles/u-admin", {role: "admin", active: true, email: "admin@example.invalid"});
    await emu.seed("accessRoles/u-staff", {role: "staff", active: true, email: "staff@example.invalid"});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(label, () => {
      test("他人のaccessRolesをget", async () => assert.equal(await emu.get("accessRoles/u-admin", token), 403));
      test("自分のaccessRolesをget(自分のroleも読めない)", async () => {
        assert.equal(await emu.get("accessRoles/u-staff", token), 403);
        assert.equal(await emu.get("accessRoles/u-admin", token), 403);
      });
      test("存在しないUIDのget", async () => assert.equal(await emu.get("accessRoles/nobody", token), 403));
      test("list(全権限の列挙)", async () => assert.equal(await emu.list("accessRoles", token), 403));
      test("create(自分自身をadminにする)", async () => {
        assert.equal(await emu.create("accessRoles", "u-new", {role: "admin", active: true}, token), 403);
        assert.equal(await emu.set("accessRoles/u-staff", {role: "admin", active: true}, token), 403);
      });
      test("update(role・activeの書き換え)", async () => {
        assert.equal(await emu.update("accessRoles/u-staff", {role: "admin"}, token), 403);
        assert.equal(await emu.update("accessRoles/u-admin", {active: false}, token), 403);
        assert.equal(await emu.update("accessRoles/u-admin", {role: "staff"}, token), 403);
      });
      test("delete", async () => {
        assert.equal(await emu.remove("accessRoles/u-admin", token), 403);
        assert.equal(await emu.remove("accessRoles/u-staff", token), 403);
      });
    });
  }

  test("拒否された書込みが実際には反映されていない(オーナー権限で確認)", async () => {
    // "Bearer owner"(Rulesバイパス)で読み、値が変わっていないことを確認する。
    const response = await fetch(`${emu.base}/accessRoles/u-staff`, {headers: {Authorization: "Bearer owner"}});
    assert.equal(response.status, 200);
    const doc = await response.json();
    assert.equal(doc.fields.role.stringValue, "staff");
    assert.equal(doc.fields.active.booleanValue, true);
    assert.equal((await fetch(`${emu.base}/accessRoles/u-new`, {headers: {Authorization: "Bearer owner"}})).status, 404);
  });

  test("Rulesの静的検査: accessRoles のブロックは allow read, write: if false のみ", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const block = rules.match(/match \/accessRoles\/\{[^}]+\}\s*\{([^}]*)\}/);
    assert.ok(block, "accessRolesのmatchが必要");
    assert.deepEqual(block[1].match(/allow[^;]*;/g), ["allow read, write: if false;"]);
    assert.doesNotMatch(rules, /match\s+\/\{[^}]*=\*\*\}/);
  });
});
