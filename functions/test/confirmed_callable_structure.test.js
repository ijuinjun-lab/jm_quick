// 新方式(flow=confirmed)のcallableは、認可(confirmedCallable)を通らないと公開できないことを、構造(ソース)で固定する。
//  - functions/index.js のexportは「従来方式(この一覧に固定)」か「confirmedCallable(アクセスレベル, ...)」のどちらかだけ
//  - functions/confirmed/ には onCall / onRequest / onSchedule / Firebase を持ち込まない(ハンドラは純粋関数。公開はindex.jsで認可つきのみ)
//  - functions/ 直下のうち、auth.js と index.js 以外は onCall/onRequest を使わない(認可を迂回する公開経路を作らない)
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {test} = require("node:test");

const FUNCTIONS_DIR = path.join(__dirname, "..");
const index = fs.readFileSync(path.join(FUNCTIONS_DIR, "index.js"), "utf8");

// Phase 4時点の従来方式(legacy)のexport。認証は付けていない(旧JM Quickの認証はPhase 10)。増やさない。
const LEGACY_EXPORTS = ["sendParticipantMail", "registerWalkIn", "sendScheduledConfirmationMail", "startBulkInvitationMail",
  "startBulkReconfirmationMail", "processBulkMailJobs", "deleteParticipant", "deleteEvent"];
const ACCESS_LEVELS = ["admin", "staffOrAdmin", "authenticated"];
// ログインなしで公開してよいのは、参加者本人の「参加証の閲覧(読み取り専用)」だけ。増やさない。
const PUBLIC_PASS_EXPORTS = ["getConfirmedParticipantPass"];

const exportsInIndex = [...index.matchAll(/^exports\.(\w+)\s*=\s*(.*)$/gm)].map((m) => ({name: m[1], rhs: m[2]}));

test("index.jsのexportは、従来方式の固定一覧か confirmedCallable(アクセスレベル, ...) のどちらかだけ", () => {
  assert.ok(exportsInIndex.length >= LEGACY_EXPORTS.length + 1);
  for (const {name, rhs} of exportsInIndex) {
    if (LEGACY_EXPORTS.includes(name)) continue;
    if (PUBLIC_PASS_EXPORTS.includes(name)) {
      assert.match(rhs, /^confirmedPublicPassCallable\(passApi\.getPass\)/, name);
      continue;
    }
    const match = /^confirmedCallable\("(\w+)"/.exec(rhs);
    assert.ok(match, `${name} は認可なしで公開されています。新方式の管理系callableは confirmedCallable() で定義してください`);
    assert.ok(ACCESS_LEVELS.includes(match[1]), `${name} のアクセスレベルが不正: ${match[1]}`);
  }
});

test("従来方式のexportが増えていない(新しいcallableを認可なしで足す抜け道を作らない)", () => {
  const legacyFound = exportsInIndex.filter((e) => !/^confirmedCallable\(/.test(e.rhs) && !PUBLIC_PASS_EXPORTS.includes(e.name)).map((e) => e.name).sort();
  assert.deepEqual(legacyFound, [...LEGACY_EXPORTS].sort());
});

test("当選者CSV取込のpreview・commitはadmin専用(staffは実行できない)", () => {
  for (const name of ["previewConfirmedImport", "commitConfirmedImport"]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedCallable\("admin", importApi\.(preview|commit)/, name);
  }
});

test("当選メール(テンプレート・プレビュー・送信ジョブ)のcallableはすべてadmin専用", () => {
  const names = ["getConfirmedWinnerMailSettings", "updateConfirmedWinnerMailTemplate", "previewConfirmedWinnerMail", "createConfirmedWinnerMailJob",
    "processConfirmedWinnerMailJob", "retryFailedConfirmedWinnerMails"];
  for (const name of names) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedCallable\("admin", /, name);
  }
});

test("公開の参加証callableは1つだけで、ログイン不要なのは参加証の閲覧のみ。受付の表示・実行はstaffOrAdmin", () => {
  const publicOnes = exportsInIndex.filter((e) => /^confirmedPublicPassCallable\(/.test(e.rhs)).map((e) => e.name);
  assert.deepEqual(publicOnes, PUBLIC_PASS_EXPORTS);
  for (const [name, handler] of [["getConfirmedReceptionView", "getReceptionView"], ["checkInConfirmedProgram", "checkIn"]]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, new RegExp(`^confirmedCallable\\("staffOrAdmin", passApi\\.${handler}\\)`), name);
  }
});

test("公開の参加証callableのハンドラは読み取り専用(getPassの中にFirestoreへの書込みが無い)", () => {
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "pass_api.js"), "utf8"));
  const start = source.indexOf("async function getPass(");
  const end = source.indexOf("async function getReceptionView(");
  assert.ok(start > 0 && end > start);
  assert.doesNotMatch(source.slice(start, end), /\.(set|update|create|delete|add)\(|runTransaction|\.batch\(|serverTimestamp\(/);
});

test("getMyAccessRoleはstaffOrAdmin(ログイン済みで、accessRolesが有効なstaff/adminのみ)", () => {
  const found = exportsInIndex.find((e) => e.name === "getMyAccessRole");
  assert.ok(found);
  assert.match(found.rhs, /^confirmedCallable\("staffOrAdmin", getMyAccessRoleHandler\)/);
});

function listJs(dir) {
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? listJs(full) : (full.endsWith(".js") ? [full] : []);
  });
}
const strip = (text) => text.split("\n").filter((line) => !line.trim().startsWith("//")).join("\n");

test("functions/confirmed/ にはcallable・Firebaseを持ち込まない(公開はindex.jsのconfirmedCallableだけ)", () => {
  const forbidden = /\bonCall\b|\bonRequest\b|\bonSchedule\b|firebase-functions|firebase-admin|getFirestore/;
  for (const file of listJs(path.join(FUNCTIONS_DIR, "confirmed"))) {
    assert.doesNotMatch(strip(fs.readFileSync(file, "utf8")), forbidden, path.relative(FUNCTIONS_DIR, file));
  }
});

test("functions/直下で onCall/onRequest を使ってよいのは auth.js(confirmedCallableの実装)と従来のindex.jsだけ", () => {
  const roots = fs.readdirSync(FUNCTIONS_DIR).filter((n) => n.endsWith(".js"));
  for (const name of roots) {
    if (name === "auth.js" || name === "index.js") continue;
    assert.doesNotMatch(strip(fs.readFileSync(path.join(FUNCTIONS_DIR, name), "utf8")), /\bonCall\b|\bonRequest\b/, name);
  }
  const authSource = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "auth.js"), "utf8"));
  assert.equal((authSource.match(/\bonCall\(/g) || []).length, 1, "auth.jsのonCallはconfirmedCallable内の1か所だけ");
  assert.doesNotMatch(authSource, /\bonRequest\b/);
});

test("confirmedCallableの中で、認可(guard)がハンドラより前に実行される", () => {
  const source = fs.readFileSync(path.join(FUNCTIONS_DIR, "auth.js"), "utf8");
  const body = source.slice(source.indexOf("function defineCallable"));
  assert.ok(body.indexOf("await guard(") > 0 && body.indexOf("await guard(") < body.indexOf("handler({identity"));
});

test("index.jsの新方式callableに、認可を通さないonCall直書きが無い(旧8関数以外のonCall)", () => {
  const onCallExports = exportsInIndex.filter((e) => /^onCall\(/.test(e.rhs) || /^onSchedule\(/.test(e.rhs)).map((e) => e.name).sort();
  assert.deepEqual(onCallExports, [...LEGACY_EXPORTS].sort());
});
