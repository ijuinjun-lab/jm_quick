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
// 従来方式の受付API(staffOrAdmin)。Phase 1Bでもlegacyの認可は変更しない。
// getEventKind(Phase 10D。受付QRの入口の振り分け専用でkindだけを返す)はlegacyとconfirmedの両方を扱うため、Phase 1Bで
// eventStaffOrLegacyStaff(従来のstaff/admin、または対象イベントのstaff以上)にした(下のテスト)。
const LEGACY_API_STAFF = ["getLegacyReceptionView", "checkInLegacyParticipant", "updateLegacyAttendedCount"];
// ログインなしで呼べる従来方式の公開入口(publicCapabilityCallable)。増やさない。参加者本人のcapability(participantId+publicId)か当日参加登録だけ。
const PUBLIC_CAPABILITY_EXPORTS = ["registerWalkIn", "getLegacyParticipantPage", "confirmLegacyParticipation", "answerLegacyReconfirmation"];
const ACCESS_LEVELS = ["admin", "staffOrAdmin", "authenticated", "systemAdmin"];
// Phase 1B: イベント単位の認可(confirmedEventCallable)。resolverはevent_scope.jsのEVENT_SCOPESだけ。
const EVENT_ACCESS_LEVELS = ["eventManager", "eventStaff", "eventStaffOrLegacyStaff"];
const EVENT_SCOPE_RESOLVERS = ["dataEventId", "sendJobEventId"];
const EVENT_CALLABLE = /^confirmedEventCallable\("(\w+)", EVENT_SCOPES\.(\w+), /;
// ログインなしで公開してよいのは、参加者本人の「参加証の閲覧(読み取り専用)」だけ。増やさない。
const PUBLIC_PASS_EXPORTS = ["getConfirmedParticipantPass"];
// confirmedの内部の定期実行(ブラウザ・callableから起動できない)。増やす場合は、認可のない入口にならないことを確認する。
const INTERNAL_SCHEDULED_EXPORTS = ["sweepConfirmedMailDelivery", ...LEGACY_SCHEDULED_EXPORTS];

const exportsInIndex = [...index.matchAll(/^exports\.(\w+)\s*=\s*(.*)$/gm)].map((m) => ({name: m[1], rhs: m[2]}));

test("index.jsのexportは、Scheduler・公開入口(固定一覧)・confirmedCallable(アクセスレベル, ...) のいずれかだけ", () => {
  assert.ok(exportsInIndex.length >= 46);
  for (const {name, rhs} of exportsInIndex) {
    if (INTERNAL_SCHEDULED_EXPORTS.includes(name)) {
      assert.match(rhs, /^onSchedule\(/, name);
      continue;
    }
    if (PUBLIC_PASS_EXPORTS.includes(name)) {
      assert.match(rhs, /^confirmedPublicPassCallable\(limitedByParticipant\(VIEW_LIMITS, passApi\.getPass\), PUBLIC_SECRETS\)/, name);
      continue;
    }
    if (PUBLIC_CAPABILITY_EXPORTS.includes(name)) {
      assert.match(rhs, /^publicCapabilityCallable\(/, name);
      continue;
    }
    const event = EVENT_CALLABLE.exec(rhs);
    if (event) {
      assert.ok(EVENT_ACCESS_LEVELS.includes(event[1]), `${name} のイベント単位のアクセスレベルが不正: ${event[1]}`);
      assert.ok(EVENT_SCOPE_RESOLVERS.includes(event[2]), `${name} の対象イベントのresolverが不正: ${event[2]}`);
      continue;
    }
    const match = /^confirmedCallable\("(\w+)"/.exec(rhs);
    assert.ok(match, `${name} は認可なしで公開されています。管理系callableは confirmedCallable() / confirmedEventCallable() で定義してください`);
    assert.ok(ACCESS_LEVELS.includes(match[1]), `${name} のアクセスレベルが不正: ${match[1]}`);
  }
});

test("Phase 10C: 認証なしで呼べるcallableは固定一覧だけ(従来の管理・メール・削除は認証なしでは呼べない)", () => {
  const unauthenticated = exportsInIndex.filter((e) => !/^confirmed(Event)?Callable\(/.test(e.rhs) && !INTERNAL_SCHEDULED_EXPORTS.includes(e.name)).map((e) => e.name).sort();
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
  // Phase 1B: getEventKindは従来のstaff/adminを通したまま、対象イベントのstaff以上も通す(kindだけを返す読み取り)
  assert.match(exportsInIndex.find((e) => e.name === "getEventKind").rhs,
    /^confirmedEventCallable\("eventStaffOrLegacyStaff", EVENT_SCOPES\.dataEventId, legacyApi\.getEventKind, /);
});

test("当選者CSV取込のpreview・commitは対象イベントのevent_manager以上(Phase 1B。staffは実行できない)", () => {
  for (const name of ["previewConfirmedImport", "commitConfirmedImport"]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedEventCallable\("eventManager", EVENT_SCOPES\.dataEventId, importApi\.(preview|commit)/, name);
  }
});

test("当選メール(テンプレート・プレビュー・送信ジョブ)・前日リマインドのcallableはすべて対象イベントのevent_manager以上(Phase 1B)", () => {
  const names = ["getConfirmedWinnerMailSettings", "updateConfirmedWinnerMailTemplate", "previewConfirmedWinnerMail", "createConfirmedWinnerMailJob",
    "processConfirmedWinnerMailJob", "retryFailedConfirmedWinnerMails", "listConfirmedWinnerMailBatches", "getConfirmedWinnerMailJob", "startConfirmedWinnerMailDelivery",
    // 前日リマインド(Phase 9B)も同じ
    "getConfirmedReminderSettings", "updateConfirmedReminderSettings", "previewConfirmedReminderMail", "startConfirmedReminderDelivery",
    "getConfirmedReminderJob", "retryFailedConfirmedReminderMails"];
  for (const name of names) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, /^confirmedEventCallable\("eventManager", EVENT_SCOPES\.(dataEventId|sendJobEventId), /, name);
  }
});

// Phase 1B: jobIdで指定するAPIは、sendJobs/{jobId}.eventId(正本)を対象イベントとして認可する。クライアントのeventIdは受け付けない。
test("Phase 1B: jobId系の当選メールAPIはsendJobEventIdで認可し、ハンドラはeventIdを入力として受け付けない", () => {
  const JOB_ID_APIS = [["processConfirmedWinnerMailJob", "processJob"], ["retryFailedConfirmedWinnerMails", "retryFailed"],
    ["startConfirmedWinnerMailDelivery", "startDelivery"], ["getConfirmedWinnerMailJob", "getJob"]];
  for (const [name, handler] of JOB_ID_APIS) {
    assert.match(exportsInIndex.find((e) => e.name === name).rhs,
      new RegExp(`^confirmedEventCallable\\("eventManager", EVENT_SCOPES\\.sendJobEventId, winnerSendApi\\.${handler}[,)]`), name);
  }
  const jobIdOnes = exportsInIndex.filter((e) => /EVENT_SCOPES\.sendJobEventId/.test(e.rhs)).map((e) => e.name).sort();
  assert.deepEqual(jobIdOnes, JOB_ID_APIS.map(([name]) => name).sort());
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "winner_send_api.js"), "utf8"));
  for (const handler of ["processJob", "retryFailed", "startDelivery", "getJob"]) {
    const start = source.indexOf(`async function ${handler}(`);
    assert.ok(start > 0, handler);
    const firstParse = source.slice(start, source.indexOf("\n  }\n", start));
    assert.match(firstParse, /parseKeys\(data, \["jobId"/, `${handler}はjobIdで指定する`);
    assert.doesNotMatch(firstParse, /parseKeys\(data, \[[^\]]*"eventId"/, `${handler}はeventIdを受け付けない(想定外のキーとして拒否)`);
  }
  const scope = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "event_scope.js"), "utf8"));
  const body = scope.slice(scope.indexOf("async function sendJobEventId("), scope.indexOf("const EVENT_SCOPES"));
  assert.match(body, /db\.collection\("sendJobs"\)\.doc\(data\.jobId\)\.get\(\)/);
  assert.match(body, /eventId: job\.eventId/);
  assert.doesNotMatch(body, /data\.eventId|data\.role/, "クライアントが名乗るeventId・roleは使わない");
  assert.doesNotMatch(scope, /\.(set|update|create|delete|add)\(|runTransaction|serverTimestamp/, "resolverは読み取りのみ");
});

// Phase 1B: participant・batch・attendanceが対象イベントに属することは、各ハンドラが正本で照合する(guardはdata.eventIdで認可するため)。
test("Phase 1B: dataEventIdで認可するハンドラは、participant・batch・attendance・既存取込回の所属イベントを正本で照合する", () => {
  const read = (file) => strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", file), "utf8"));
  const pass = read("pass_api.js");
  assert.match(pass, /if \(eventId !== undefined && participant\.eventId !== eventId\) return "event-mismatch";/);
  assert.equal((pass.match(/attendance\.eventId !== input\.eventId/g) || []).length, 2, "受付・訂正/取消のtransactionで、attendanceのeventIdを照合");
  for (const handler of ["getReceptionView", "checkIn", "correct", "cancel"]) {
    const start = pass.indexOf(`async function ${handler}(`);
    assert.match(pass.slice(start, start + 400), /input\.eventId === undefined/, `${handler}: eventIdは必須`);
  }
  assert.match(read("winner_mail_api.js"), /participant\.eventId !== request\.eventId\) throw new ApiError\("failed-precondition", "参加者がこのイベントのものではありません。"/);
  assert.match(read("winner_mail_api.js"), /batchSnapshot\.data\(\)\.eventId !== request\.eventId/);
  assert.match(read("send_jobs.js"), /if \(batch\.eventId !== eventId\) throw new ApiError\("failed-precondition", "取込回がこのイベントのものではありません。"/);
  assert.match(read("reminder_api.js"), /if \(!targets\.includes\(request\.participantId\)\)/, "リマインドのプレビューは対象イベントの送信対象だけ");
  assert.match(read("import_commit.js"), /if \(existing\.eventId !== eventId \|\| existing\.requestHash !== hash\)/);
  assert.match(read("import_api.js"), /existingBatch: existing\.exists && existing\.data\(\)\.eventId === request\.eventId \?/, "別イベントの取込回の情報をpreviewで返さない");
});

test("公開の参加証callableは1つだけで、ログイン不要なのは参加証の閲覧のみ。受付の表示・実行は対象イベントのstaff以上(Phase 1B)", () => {
  const publicOnes = exportsInIndex.filter((e) => /^confirmedPublicPassCallable\(/.test(e.rhs)).map((e) => e.name);
  assert.deepEqual(publicOnes, PUBLIC_PASS_EXPORTS);
  for (const [name, handler] of [["getConfirmedReceptionView", "getReceptionView"], ["checkInConfirmedProgram", "checkIn"]]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, new RegExp(`^confirmedEventCallable\\("eventStaff", EVENT_SCOPES\\.dataEventId, passApi\\.${handler}\\)`), name);
  }
});

test("公開の参加証callableのハンドラは読み取り専用(getPassの中にFirestoreへの書込みが無い)", () => {
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "pass_api.js"), "utf8"));
  const start = source.indexOf("async function getPass(");
  const end = source.indexOf("async function getReceptionView(");
  assert.ok(start > 0 && end > start);
  assert.doesNotMatch(source.slice(start, end), /\.(set|update|create|delete|add)\(|runTransaction|\.batch\(|serverTimestamp\(/);
});

test("受付の訂正・取消は対象イベントのstaff以上(Phase 1Bで開放。他イベントは不可)", () => {
  for (const [name, handler] of [["correctConfirmedProgramAttendance", "correct"], ["cancelConfirmedProgramCheckIn", "cancel"]]) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.ok(found, `${name}が見つかりません`);
    assert.match(found.rhs, new RegExp(`^confirmedEventCallable\\("eventStaff", EVENT_SCOPES\\.dataEventId, passApi\\.${handler}\\)`), name);
  }
});

// Phase 1A: getMyAccessRoleは、イベント単位の権限だけのユーザーも自分の権限を確認できるよう、入口をauthenticatedにした。
// 権限の有無はハンドラがFirestoreの正本(accessRoles・eventAssignments)で判定する(何も無ければpermission-denied)。
test("Phase 1A: getMyAccessRoleはauthenticated(ハンドラがaccessRoles・eventAssignmentsで判定)。authenticatedはこの1本だけ", () => {
  const found = exportsInIndex.find((e) => e.name === "getMyAccessRole");
  assert.ok(found);
  assert.match(found.rhs, /^confirmedCallable\("authenticated", getMyAccessRoleHandler\);$/);
  assert.match(index, /const getMyAccessRoleHandler = createGetMyAccessRoleHandler\(\{getDb: getFirestore\}\);/);
  // Phase 2: listMyEvents(本人の担当イベントだけを返す。権限が何も無ければpermission-denied)もauthenticated
  const authenticatedOnes = exportsInIndex.filter((e) => /^confirmedCallable\("authenticated"/.test(e.rhs)).map((e) => e.name);
  assert.deepEqual(authenticatedOnes, ["getMyAccessRole", "listMyEvents"]);
  assert.match(exportsInIndex.find((e) => e.name === "listMyEvents").rhs, /^confirmedCallable\("authenticated", assignmentApi\.listMyEvents, /);
  const handler = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "access_role.js"), "utf8"));
  assert.match(handler, /throw new ApiError\("permission-denied"/, "権限が何も無ければ拒否する");
  assert.doesNotMatch(handler, /\.(set|update|create|delete|add)\(|runTransaction|\.batch\(|serverTimestamp/, "読み取りのみ");
});

// Phase 1B: 正式な認可マップ(全export)。confirmed業務はイベント単位(eventManager / eventStaff)、イベント作成はsystemAdmin。
// legacy・Scheduler・公開参加証は意図して従来のまま(下のallowlist)。変更するときは、この表を意図して書き換える。
const E_MANAGER = "confirmedEventCallable:eventManager:dataEventId";
const E_MANAGER_JOB = "confirmedEventCallable:eventManager:sendJobEventId";
const E_STAFF = "confirmedEventCallable:eventStaff:dataEventId";
const AUTHORIZATION_MAP_PHASE_1B = {
  sendParticipantMail: "confirmedCallable:admin",
  registerWalkIn: "publicCapabilityCallable",
  sendScheduledConfirmationMail: "onSchedule",
  startBulkInvitationMail: "confirmedCallable:admin",
  startBulkReconfirmationMail: "confirmedCallable:admin",
  processBulkMailJobs: "onSchedule",
  deleteParticipant: "confirmedCallable:admin",
  deleteEvent: "confirmedCallable:admin",
  getMyAccessRole: "confirmedCallable:authenticated",
  previewConfirmedImport: E_MANAGER,
  commitConfirmedImport: E_MANAGER,
  createConfirmedEvent: "confirmedCallable:systemAdmin",
  getConfirmedEventSummary: E_MANAGER,
  getConfirmedWinnerMailSettings: E_MANAGER,
  updateConfirmedWinnerMailTemplate: E_MANAGER,
  previewConfirmedWinnerMail: E_MANAGER,
  createConfirmedWinnerMailJob: E_MANAGER,
  processConfirmedWinnerMailJob: E_MANAGER_JOB,
  retryFailedConfirmedWinnerMails: E_MANAGER_JOB,
  startConfirmedWinnerMailDelivery: E_MANAGER_JOB,
  getConfirmedReminderSettings: E_MANAGER,
  updateConfirmedReminderSettings: E_MANAGER,
  previewConfirmedReminderMail: E_MANAGER,
  startConfirmedReminderDelivery: E_MANAGER,
  getConfirmedReminderJob: E_MANAGER,
  retryFailedConfirmedReminderMails: E_MANAGER,
  sweepConfirmedMailDelivery: "onSchedule",
  listConfirmedWinnerMailBatches: E_MANAGER,
  getConfirmedWinnerMailJob: E_MANAGER_JOB,
  getConfirmedParticipantPass: "confirmedPublicPassCallable",
  getConfirmedReceptionView: E_STAFF,
  checkInConfirmedProgram: E_STAFF,
  correctConfirmedProgramAttendance: E_STAFF,
  cancelConfirmedProgramCheckIn: E_STAFF,
  listLegacyEvents: "confirmedCallable:admin",
  getLegacyEventAdminView: "confirmedCallable:admin",
  createLegacyEvent: "confirmedCallable:admin",
  updateLegacyEventSettings: "confirmedCallable:admin",
  createLegacyParticipant: "confirmedCallable:admin",
  getEventKind: "confirmedEventCallable:eventStaffOrLegacyStaff:dataEventId",
  getLegacyReceptionView: "confirmedCallable:staffOrAdmin",
  checkInLegacyParticipant: "confirmedCallable:staffOrAdmin",
  updateLegacyAttendedCount: "confirmedCallable:staffOrAdmin",
  getLegacyParticipantPage: "publicCapabilityCallable",
  confirmLegacyParticipation: "publicCapabilityCallable",
  answerLegacyReconfirmation: "publicCapabilityCallable",
  // Phase 2: イベント単位の任命(対象イベントのevent_manager以上。managerはstaffだけ等はハンドラが確認)と、本人の担当イベント
  assignEventRole: E_MANAGER,
  removeEventRole: E_MANAGER,
  listEventAssignments: E_MANAGER,
  listMyEvents: "confirmedCallable:authenticated",
};
// 従来のadmin / staffOrAdminのまま意図して残すもの(legacy業務・legacyのメール/削除。listLegacyEventsは全件一覧でsystem管理者専用)。
const OLD_LEVEL_ALLOWLIST = [...LEGACY_ADMIN_EXPORTS, ...LEGACY_API_ADMIN, ...LEGACY_API_STAFF].sort();

const authorizationOf = (rhs) => {
  const event = /^confirmedEventCallable\("(\w+)", EVENT_SCOPES\.(\w+),/.exec(rhs);
  if (event) return `confirmedEventCallable:${event[1]}:${event[2]}`;
  const match = /^(\w+)\((?:"(\w+)")?/.exec(rhs);
  return match[1] + (match[2] ? `:${match[2]}` : "");
};

test("Phase 1B: 全exportの入口・認可レベル・対象イベントのresolverが正式マップと一致する(callableの追加・削除も無い)", () => {
  const current = Object.fromEntries(exportsInIndex.map(({name, rhs}) => [name, authorizationOf(rhs)]));
  assert.deepEqual(current, AUTHORIZATION_MAP_PHASE_1B);
  assert.equal(exportsInIndex.length, 50);
});

test("Phase 1B: confirmed業務に従来のadmin/staffOrAdminが残っていない(残すのはlegacyの明示allowlistだけ)", () => {
  const oldLevel = exportsInIndex.filter((e) => /^confirmedCallable\("(admin|staffOrAdmin)"/.test(e.rhs)).map((e) => e.name).sort();
  assert.deepEqual(oldLevel, OLD_LEVEL_ALLOWLIST);
  for (const name of oldLevel) assert.doesNotMatch(name, /Confirmed/, `${name}: confirmed業務が従来のレベルのまま`);
  // confirmed業務(名前にConfirmedを含むcallable)は、公開参加証・systemAdminのイベント作成以外はすべてイベント単位
  for (const {name, rhs} of exportsInIndex.filter((e) => /Confirmed/.test(e.name) && !/^onSchedule\(/.test(e.rhs))) {
    if (name === "getConfirmedParticipantPass") continue;
    if (name === "createConfirmedEvent") { assert.match(rhs, /^confirmedCallable\("systemAdmin", /); continue; }
    assert.match(rhs, EVENT_CALLABLE, `${name}はイベント単位の認可`);
  }
});

test("Phase 1B: イベント単位の認可はresolver必須で、guardはクライアントのrole・scopeを信用せず、ハンドラより前に実行される", () => {
  const authSource = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "auth.js"), "utf8"));
  const guard = authSource.slice(authSource.indexOf("function eventGuard("), authSource.indexOf("const GUARDS") > authSource.indexOf("function eventGuard(") ? authSource.indexOf("const GUARDS") : authSource.indexOf("function defineCallable"));
  assert.ok(guard.length > 200);
  assert.doesNotMatch(guard, /request\.data\.(role|eventRole|systemAdmin|uid)|data\.role|auth\.token/, "本文・トークンのrole等を読まない");
  assert.match(guard, /const \{uid\} = requireAuthenticated\(request\)/);
  assert.match(guard, /getEventAccess\(database, uid, scope\.eventId\)/, "判定はevent_access.js(Firestore正本)");
  const define = authSource.slice(authSource.indexOf("function confirmedEventCallable("));
  assert.match(define, /Object\.values\(eventScopes\(\)\)\.includes\(resolver\)/, "resolverはevent_scope.jsの一覧だけ");
  assert.match(define, /defineCallable\(eventGuard\(access, resolver\), handler, options\)/, "guardつきのdefineCallable(ハンドラより前にguard)");
  assert.match(authSource, /if \(Object\.prototype\.hasOwnProperty\.call\(EVENT_ACCESS_LEVELS, access\)\) \{\s*throw new Error/, "confirmedCallableではイベント単位のレベルを使えない");
});

test("Phase 1A/1B/2: イベント単位の権限helper(event_access.js)は読み取り専用。使うのはauth.js(guard)・event_scope.js・getMyAccessRole・任命API(assignment_api.js)だけ", () => {
  // ドキュメントIDのハッシュ計算(crypto の .update)だけは除いて検査する。
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "event_access.js"), "utf8")).replace(/createHash\("sha256"\)\.update\(/g, "");
  assert.doesNotMatch(source, /\.(set|update|create|delete|add)\(|runTransaction|\.batch\(|serverTimestamp|\bonCall\b|\bonRequest\b/);
  const sources = [
    ...fs.readdirSync(FUNCTIONS_DIR).filter((n) => n.endsWith(".js")).map((n) => path.join(FUNCTIONS_DIR, n)),
    ...["confirmed", "legacy", "tools"].flatMap((dir) => listJs(path.join(FUNCTIONS_DIR, dir))),
  ].filter((file) => !file.includes(`${path.sep}test${path.sep}`) && !file.includes(`${path.sep}test_support${path.sep}`));
  const users = sources.filter((file) => /require\("\.\.?\/(\.\.\/)?event_access"\)/.test(fs.readFileSync(file, "utf8")))
    .map((file) => path.relative(FUNCTIONS_DIR, file));
  assert.deepEqual(users.sort(), ["auth.js", "event_scope.js", path.join("confirmed", "access_role.js"), path.join("confirmed", "assignment_api.js")].sort());
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

// Phase 10D: ログインなしで呼べるcallableは、この5本だけ(増やす・減らす・入口の種類を変えると失敗する)。
const FIXED_PUBLIC_FIVE = ["getConfirmedParticipantPass", "registerWalkIn", "getLegacyParticipantPage", "confirmLegacyParticipation", "answerLegacyReconfirmation"];

test("Phase 10D: ログイン不要のcallableは意図した5本だけ", () => {
  const publicOnes = exportsInIndex.filter((e) => /^(confirmedPublicPassCallable|publicCapabilityCallable)\(/.test(e.rhs)).map((e) => e.name);
  assert.deepEqual(publicOnes.sort(), [...FIXED_PUBLIC_FIVE].sort());
  assert.deepEqual(exportsInIndex.filter((e) => !/^confirmed(Event)?Callable\(/.test(e.rhs) && !/^onSchedule\(/.test(e.rhs)).map((e) => e.name).sort(), [...FIXED_PUBLIC_FIVE].sort());
});

test("Phase 10D: 公開5本は、参加者単位のrate limit(または当日参加登録専用のrate limit)とrate limit用Secretを必ず通る", () => {
  for (const name of FIXED_PUBLIC_FIVE.filter((n) => n !== "registerWalkIn")) {
    const found = exportsInIndex.find((e) => e.name === name);
    assert.match(found.rhs, /limitedByParticipant\((VIEW|UPDATE)_LIMITS, /, `${name}: 参加者単位のrate limit`);
    assert.match(found.rhs, /PUBLIC_SECRETS\)/, `${name}: rate limit用のSecret`);
  }
  // 閲覧は閲覧用、状態更新は更新用の(より厳しい)上限
  assert.match(exportsInIndex.find((e) => e.name === "getConfirmedParticipantPass").rhs, /VIEW_LIMITS/);
  assert.match(exportsInIndex.find((e) => e.name === "getLegacyParticipantPage").rhs, /VIEW_LIMITS/);
  assert.match(exportsInIndex.find((e) => e.name === "confirmLegacyParticipation").rhs, /UPDATE_LIMITS/);
  assert.match(exportsInIndex.find((e) => e.name === "answerLegacyReconfirmation").rhs, /UPDATE_LIMITS/);
  const start = index.indexOf("exports.registerWalkIn");
  const end = index.indexOf("exports.sendScheduledConfirmationMail");
  const walkIn = index.slice(start, end);
  assert.match(walkIn, /rateLimiter\.check\(RATE_LIMIT_POLICIES\.walkInIp/);
  assert.match(walkIn, /rateLimiter\.check\(RATE_LIMIT_POLICIES\.walkInTarget/);
  assert.match(walkIn, /WALK_IN_EVENT_LIMIT/);
  assert.match(walkIn, /secrets: \[mailApiKey, rateLimitKey\]/);
  // rate limitは、入力の検証・メール送信より前(IP → 入力の検証 → 宛先 → transaction)
  assert.ok(walkIn.indexOf("walkInIp") < walkIn.indexOf("parseWalkIn") && walkIn.indexOf("parseWalkIn") < walkIn.indexOf("walkInTarget"));
  assert.ok(walkIn.indexOf("walkInTarget") < walkIn.indexOf("runTransaction") && walkIn.indexOf("runTransaction") < walkIn.indexOf("/v1/mail/send"));
});

test("Phase 10D: 公開入口はApp Checkを強制する(プラットフォームのenforceAppCheck=true と、ハンドラ前のrequireAppCheck)", () => {
  const authSource = fs.readFileSync(path.join(FUNCTIONS_DIR, "auth.js"), "utf8");
  assert.match(authSource, /PUBLIC_CALLABLE_OPTIONS = Object\.freeze\(\{[^}]*enforceAppCheck: true/);
  assert.match(authSource, /function publicCallable\([^)]*\) \{[\s\S]*?requireAppCheck\(request, guardOptions\)/);
  // 公開入口は、この2つのラッパーだけがpublicCallableを使う
  assert.equal((authSource.match(/publicCallable\(/g) || []).length, 3, "定義1 + 2つのラッパー");
  assert.doesNotMatch(authSource, /enforceAppCheck: false/);
});

test("Phase 10D: rate limitの上限値はpublic_limits.jsに集約され、他のファイルに散在しない", () => {
  const limitsSource = fs.readFileSync(path.join(FUNCTIONS_DIR, "public_limits.js"), "utf8");
  assert.match(limitsSource, /WALK_IN_EVENT_LIMIT = \d+/);
  for (const file of ["index.js", "rate_limit.js", "auth.js", path.join("legacy", "legacy_api.js")]) {
    const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, file), "utf8"));
    assert.doesNotMatch(source, /windowMs\s*[:=]\s*\d/, `${file}: 時間窓の数値`);
    assert.doesNotMatch(source, /limit\s*[:=]\s*\d+\s*[,}]/, `${file}: 上限の数値`);
    assert.doesNotMatch(source, /walkInCount\s*>=\s*\d/, `${file}: walk-in上限の数値`);
  }
});

// Phase 11A: 新方式イベントの作成はadmin専用の1本(createConfirmedEvent)。公開callableは増やさない。Phase 1B: systemAdmin(=有効なadmin)。
test("Phase 11A: createConfirmedEventはsystemAdmin専用で、legacyの作成(createLegacyEvent)とは別のcallable。公開callableは5本のまま", () => {
  const found = exportsInIndex.find((e) => e.name === "createConfirmedEvent");
  assert.ok(found, "createConfirmedEventが見つかりません");
  assert.match(found.rhs, /^confirmedCallable\("systemAdmin", eventCreateApi\.createEvent/);
  const legacy = exportsInIndex.find((e) => e.name === "createLegacyEvent");
  assert.notEqual(found.rhs, legacy.rhs);
  const publicOnes = exportsInIndex.filter((e) => /^(confirmedPublicPassCallable|publicCapabilityCallable)\(/.test(e.rhs));
  assert.equal(publicOnes.length, 5);
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "event_create_api.js"), "utf8"));
  assert.doesNotMatch(source, /\b(tx|ref|db)\.(set|update|delete)\(|\bmerge\b/, "createのみ(set/update/merge/deleteで既存イベントを上書きしない)");
  assert.match(source, /tx\.create\(/);
  for (const forbidden of ["winnerMailTemplate:", "reminderMailTemplate:", "reminderSendAt:", "sendJobs", "mailDeliveries", "mailLogs", "fetch("]) {
    assert.equal(source.includes(forbidden), false, `作成APIはメール関連を作らない: ${forbidden}`);
  }
});

// Phase 11B: 取込画面のイベント表示用に、admin専用の読み取りcallableを1本だけ追加した(既存のadmin APIにprogram一覧を返すものが無いため)。公開callableは増やさない。
test("Phase 11B: getConfirmedEventSummaryは読み取りだけのcallable(Phase 1B: 対象イベントのevent_manager以上)。取込のpreview/commitは既存のまま。公開callableは5本のまま", () => {
  const found = exportsInIndex.find((e) => e.name === "getConfirmedEventSummary");
  assert.ok(found, "getConfirmedEventSummaryが見つかりません");
  assert.match(found.rhs, /^confirmedEventCallable\("eventManager", EVENT_SCOPES\.dataEventId, eventCreateApi\.getSummary/);
  const publicOnes = exportsInIndex.filter((e) => /^(confirmedPublicPassCallable|publicCapabilityCallable)\(/.test(e.rhs));
  assert.equal(publicOnes.length, 5);
  assert.equal(exportsInIndex.some((e) => /^(previewConfirmedImport|commitConfirmedImport)$/.test(e.name) && !/^confirmedEventCallable\("eventManager", EVENT_SCOPES\.dataEventId, /.test(e.rhs)), false);
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "event_create_api.js"), "utf8"));
  const body = source.slice(source.indexOf("async function getSummary"), source.indexOf("return {createEvent, getSummary}"));
  assert.ok(body.length > 100);
  assert.doesNotMatch(body, /\.(set|update|delete|create)\(|\btx\b|runTransaction|serverTimestamp/, "概要APIは読み取りだけ");
  assert.doesNotMatch(body, /participants|email|publicId|sendJobs|mailDeliveries/, "個人情報・メール関連を読まない");
});

// Phase 2: 任命API。ドキュメントIDはevent_access.jsのassignmentDocIdだけで作り、Firebase Authのユーザーは作らない・変更しない。
test("Phase 2: 任命APIはassignmentDocIdでIDを作り、Authユーザーを作成・変更しない。解除は物理削除しない(active=false)", () => {
  const source = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, "confirmed", "assignment_api.js"), "utf8"));
  assert.match(source, /const id = assignmentDocId\(request\.eventId, user\.uid\);/);
  const docCalls = [...source.matchAll(/collection\(EVENT_ASSIGNMENTS_COLLECTION\)\.doc\(([^)]*)\)/g)].map((m) => m[1]);
  assert.deepEqual(docCalls, ["id", "request.assignmentId"], "IDは決定的なassignmentDocId、または一覧が返したassignmentId(形式・中身を検証)だけ");
  assert.match(source, /ASSIGNMENT_ID_PATTERN = \/\^ea\[0-9a-f\]\{64\}\$\//);
  assert.doesNotMatch(source, /`\$\{[^}]*\}_\$\{[^}]*\}`/, "{eventId}_{uid}の連結でIDを作らない");
  assert.doesNotMatch(source, /\.delete\(|tx\.set\(|\bmerge\b/, "物理削除・上書き(set/merge)をしない");
  assert.match(source, /tx\.update\(ref, \{active: false, updatedAt: serverTimestamp\(\), updatedBy: identity\.uid\}\)/);
  for (const file of ["index.js", path.join("confirmed", "assignment_api.js")]) {
    const text = strip(fs.readFileSync(path.join(FUNCTIONS_DIR, file), "utf8"));
    assert.doesNotMatch(text, /\b(createUser|updateUser|deleteUser|setCustomUserClaims|importUsers)\(/, `${file}: Authユーザーを作成・変更しない`);
  }
  assert.match(index, /await getAuth\(\)\.getUserByEmail\(email\)/, "既存のAuthユーザーをメールアドレスで検索するだけ");
});
