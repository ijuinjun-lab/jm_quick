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

// Phase 10C: 従来方式(legacy)にも認証なしの管理系callableは残さない。従来の8関数のうち、
//   - sendParticipantMail / startBulk*Mail / deleteParticipant / deleteEvent は admin専用(confirmedCallable("admin"))になった
//   - registerWalkIn は公開のまま(publicCapabilityCallable。入力・状態・件数をサーバーで制限)
//   - sendScheduledConfirmationMail / processBulkMailJobs は内部のScheduler(認証ラッパーなし。legacy専用guardのまま)
const LEGACY_ADMIN_EXPORTS = ["sendParticipantMail", "startBulkInvitationMail", "startBulkReconfirmationMail", "deleteParticipant", "deleteEvent"];
const LEGACY_SCHEDULED_EXPORTS = ["sendScheduledConfirmationMail", "processBulkMailJobs"];
// 従来方式の管理・受付API(Phase 10C)
const LEGACY_API_ADMIN = ["listLegacyEvents", "getLegacyEventAdminView", "createLegacyEvent", "updateLegacyEventSettings", "createLegacyParticipant"];
const LEGACY_API_STAFF = ["getLegacyReceptionView", "checkInLegacyParticipant", "updateLegacyAttendedCount"];
// ログインなしで呼べる従来方式の公開入口(publicCapabilityCallable)。増やさない。参加者本人のcapability(participantId+publicId)か当日参加登録だけ。
const PUBLIC_CAPABILITY_EXPORTS = ["registerWalkIn", "getLegacyParticipantPage", "confirmLegacyParticipation", "answerLegacyReconfirmation"];
const ACCESS_LEVELS = ["admin", "staffOrAdmin", "authenticated"];
// ログインなしで公開してよいのは、参加者本人の「参加証の閲覧(読み取り専用)」だけ。増やさない。
const PUBLIC_PASS_EXPORTS = ["getConfirmedParticipantPass"];
// confirmedの内部の定期実行(ブラウザ・callableから起動できない)。増やす場合は、認可のない入口にならないことを確認する。
const INTERNAL_SCHEDULED_EXPORTS = ["sweepConfirmedMailDelivery", ...LEGACY_SCHEDULED_EXPORTS];

const exportsInIndex = [...index.matchAll(/^exports\.(\w+)\s*=\s*(.*)$/gm)].map((m) => ({name: m[1], rhs: m[2]}));

test("index.jsのexportは、Scheduler・公開入口(固定一覧)・confirmedCallable(アクセスレベル, ...) のいずれかだけ", () => {
  assert.ok(exportsInIndex.length >= 32);
  for (const {name, rhs} of exportsInIndex) {
    if (INTERNAL_SCHEDULED_EXPORTS.includes(name)) {
      assert.match(rhs, /^onSchedule\(/, name);
      continue;
    }
    if (PUBLIC_PASS_EXPORTS.includes(name)) {
      assert.match(rhs, /^confirmedPublicPassCallable\(passApi\.getPass\)/, name);
      continue;
    }
    if (PUBLIC_CAPABILITY_EXPORTS.includes(name)) {
      assert.match(rhs, /^publicCapabilityCallable\(/, name);
      continue;
    }
    const match = /^confirmedCallable\("(\w+)"/.exec(rhs);
    assert.ok(match, `${name} は認可なしで公開されています。管理系callableは confirmedCallable() で定義してください`);
    assert.ok(ACCESS_LEVELS.includes(match[1]), `${name} のアクセスレベルが不正: ${match[1]}`);
  }
});

test("Phase 10C: 認証なしで呼べるcallableは固定一覧だけ(従来の管理・メール・削除は認証なしでは呼べない)", () => {
  const unauthenticated = exportsInIndex.filter((e) => !/^confirmedCallable\(/.test(e.rhs) && !INTERNAL_SCHEDULED_EXPORTS.includes(e.name)).map((e) => e.name).sort();
  assert.deepEqual(unauthenticated, [...PUBLIC_PASS_EXPORTS, ...PUBLIC_CAPABILITY_EXPORTS].sort());
  assert.doesNotMatch(index, /\bonCall\(/, "index.jsにonCall直書き(認可なしの入口)が無い");
});

test("Phase 10C: 従来方式のメール送信・一括メール・削除はadmin専用、管理APIはadmin、受付APIはstaffOrAdmin", () => {
  for (const name of [...LEGACY_ADMIN_EXPORTS, ...LEGACY_API_ADMIN]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedCallable\("admin"/, name);
  }
  for (const name of LEGACY_API_STAFF) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedCallable\("staffOrAdmin"/, name);
  }
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
    "processConfirmedWinnerMailJob", "retryFailedConfirmedWinnerMails", "listConfirmedWinnerMailBatches", "getConfirmedWinnerMailJob", "startConfirmedWinnerMailDelivery",
    // 前日リマインド(Phase 9B)もすべてadmin専用
    "getConfirmedReminderSettings", "updateConfirmedReminderSettings", "previewConfirmedReminderMail", "startConfirmedReminderDelivery",
    "getConfirmedReminderJob", "retryFailedConfirmedReminderMails"];
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

test("受付の訂正・取消はadmin専用(staffは初回受付のみ)", () => {
  for (const [name, handler] of [["correctConfirmedProgramAttendance", "correct"], ["cancelConfirmedProgramCheckIn", "cancel"]]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, new RegExp(`^confirmedCallable\\("admin", passApi\\.${handler}\\)`), name);
  }
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

test("index.jsにonCall/onRequest直書きが無い(callableの入口はauth.jsの1か所だけ)", () => {
  const onCallExports = exportsInIndex.filter((e) => /^onCall\(/.test(e.rhs) || /^onRequest\(/.test(e.rhs)).map((e) => e.name);
  assert.deepEqual(onCallExports, []);
});

test("functions/legacy/ にはcallable・Firebaseを持ち込まない(公開はindex.jsの認可つき入口だけ)", () => {
  const forbidden = /\bonCall\b|\bonRequest\b|\bonSchedule\b|firebase-functions|firebase-admin|getFirestore/;
  for (const file of listJs(path.join(FUNCTIONS_DIR, "legacy"))) {
    assert.doesNotMatch(strip(fs.readFileSync(file, "utf8")), forbidden, path.relative(FUNCTIONS_DIR, file));
  }
});
