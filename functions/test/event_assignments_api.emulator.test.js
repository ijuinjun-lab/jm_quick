// Phase 2: イベント単位の任命API(assignEventRole / removeEventRole / listEventAssignments)と担当イベントの取得(listMyEvents)を、
// 実際の公開設定(functions/index.jsのexport)で検証する。ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDK。
// Firebase Authは、既存ユーザーをメールアドレスで引く getUserByEmail だけを架空のユーザー一覧に差し替える(ユーザーの作成・変更は無い)。
// データはすべて完全な架空(メールは予約TLD .invalid)。外部通信はEmulator以外すべて遮断する。
const assert = require("node:assert/strict");
const path = require("node:path");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {buildImportRequest} = require("../test_support/import_request_builder");
const {makeTable} = require("../confirmed/test_support/synthetic");
const {assignmentDocId, getEventAccess} = require("../event_access");

const EV_A = "evAssignA0123456789";
const EV_B = "evAssignB0123456789";
const EV_LEGACY = "evAssignLegacy012345";
const outcome = (promise) => promise.then(() => "ok", (error) => error.code || String(error));
const detail = (promise) => promise.then(() => "ok", (error) => (error.details && error.details.code) || error.code);
const realFetch = globalThis.fetch;

// Firebase Authの既存ユーザー(架空)。uidはクライアントに見せない。
const AUTH_USERS = [
  {uid: "u-admin", email: "admin@example.invalid"},
  {uid: "u-admin2", email: "admin2@example.invalid"},
  {uid: "u-mgr-a", email: "manager.a@example.invalid"},
  {uid: "u-mgr-a2", email: "manager.a2@example.invalid"},
  {uid: "u-mgr-b", email: "manager.b@example.invalid"},
  {uid: "u-staff-1", email: "staff.one@example.invalid"},
  {uid: "u-staff-2", email: "staff.two@example.invalid"},
  {uid: "u-disabled", email: "disabled@example.invalid", disabled: true},
];

describe("イベント単位の任命API・担当イベント(実際のindex.js + Emulator)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  let authLookups;
  let unexpectedRequests;

  const as = (uid, data) => ({auth: {uid}, data});
  const call = (name, uid, data) => outcome(index[name].run(as(uid, data)));
  const run = (name, uid, data) => index[name].run(as(uid, data));
  const assign = (uid, eventId, email, role) => run("assignEventRole", uid, {eventId, email, role});
  const idOf = (eventId, uid) => assignmentDocId(eventId, uid);
  const stored = async (eventId, uid) => (await db.collection("eventAssignments").doc(idOf(eventId, uid)).get()).data();
  const rank = async (uid, eventId) => (await getEventAccess(db, uid, eventId)).rank;
  const seedEvent = (eventId, name, extra = {}) => db.collection("events").doc(eventId).set({
    eventId, eventName: name, senderName: "架空事務局", flow: "confirmed", contact: "架空事務局",
    startAt: env.Timestamp.fromDate(new Date(extra.start || "2026-11-30T01:00:00Z")), endAt: env.Timestamp.fromDate(new Date("2026-11-30T07:00:00Z")),
    venue: `${name}の会場`, venueInfo: {address: "架空県架空市1-2-3", access: "架空駅から徒歩5分"},
    programs: [{programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1}, {programId: "gamma", name: "トーク", order: 2}],
    winnerMailTemplate: {subject: "架空", introBody: "架空", closingBody: "架空", notesBody: null, version: 1, updatedBy: "u-admin"}, reminderEnabled: false,
  });

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    // firebase-admin/auth の getUserByEmail だけを差し替える(実際のFirebase Authへは接続しない)
    const authPath = require.resolve("firebase-admin/auth", {paths: [path.join(__dirname, "..")]});
    const fakeAuth = {
      async getUserByEmail(email) {
        authLookups.push(email);
        const user = AUTH_USERS.find((u) => u.email === email);
        if (!user) throw Object.assign(new Error("There is no user record corresponding to the provided identifier."), {code: "auth/user-not-found"});
        return {uid: user.uid, email: user.email, disabled: user.disabled === true, passwordHash: "must-not-be-stored", providerData: [{providerId: "password"}]};
      },
    };
    require.cache[authPath] = {id: authPath, filename: authPath, loaded: true, exports: {getAuth: () => fakeAuth}, children: [], paths: []};
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => { globalThis.fetch = realFetch; env?.stop(); });
  beforeEach(async () => {
    await env.clear();
    authLookups = [];
    unexpectedRequests = [];
    globalThis.fetch = async (url, init) => {
      if (String(url).startsWith(env.origin)) return realFetch(url, init);
      unexpectedRequests.push(String(url));
      throw new Error(`unexpected outbound request blocked by test: ${url}`);
    };
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("u-admin2").set({role: "admin", active: true});
    await seedEvent(EV_A, "架空イベントA", {start: "2026-11-30T01:00:00Z"});
    await seedEvent(EV_B, "架空イベントB", {start: "2026-10-01T01:00:00Z"});
    await db.collection("events").doc(EV_LEGACY).set({eventId: EV_LEGACY, eventName: "架空の従来イベント", venue: "架空", startAt: env.Timestamp.fromDate(new Date("2026-09-01T01:00:00Z"))});
  });

  describe("admin(system_admin)の任命", () => {
    test("event_manager・staffの任命、role変更、解除、再任命(assignedAtは最初の任命のまま、updatedAtだけ更新)", async () => {
      const created = await assign("u-admin", EV_A, "  Manager.A@Example.INVALID ", "event_manager");
      assert.deepEqual(Object.keys(created).sort(), ["active", "assignmentId", "changed", "email", "eventId", "previousRole", "role"]);
      assert.equal(created.email, "manager.a@example.invalid");
      assert.equal(created.assignmentId, idOf(EV_A, "u-mgr-a"));
      assert.equal(JSON.stringify(created).includes("u-mgr-a"), false, "uidを返さない");
      assert.deepEqual(authLookups, ["manager.a@example.invalid"], "前後の空白を除き小文字でAuthを検索");
      const first = await stored(EV_A, "u-mgr-a");
      assert.deepEqual(Object.keys(first).sort(), ["active", "assignedAt", "assignedBy", "email", "eventId", "role", "uid", "updatedAt", "updatedBy"]);
      assert.equal(first.role, "event_manager");
      assert.equal(first.assignedBy, "u-admin");
      assert.equal(await rank("u-mgr-a", EV_A), 2);

      assert.equal((await assign("u-admin", EV_A, "staff.one@example.invalid", "staff")).changed, true);
      assert.equal(await rank("u-staff-1", EV_A), 1);
      assert.equal((await assign("u-admin", EV_A, "staff.one@example.invalid", "staff")).changed, false, "同じ任命はno-op");

      // role変更(昇格)は同じドキュメント。rankが即反映される
      const promoted = await assign("u-admin2", EV_A, "staff.one@example.invalid", "event_manager");
      assert.equal(promoted.previousRole, "staff");
      assert.equal(await rank("u-staff-1", EV_A), 2);
      const before = await stored(EV_A, "u-staff-1");
      assert.equal(before.assignedBy, "u-admin", "assignedByは最初の任命者のまま");
      assert.equal(before.updatedBy, "u-admin2");

      // 解除(active=false・ドキュメントは残る)
      const removed = await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: idOf(EV_A, "u-staff-1")});
      assert.equal(removed.changed, true);
      const afterRemove = await stored(EV_A, "u-staff-1");
      assert.equal(afterRemove.active, false);
      assert.equal(afterRemove.role, "event_manager", "解除時のroleは記録として残る");
      assert.equal(await rank("u-staff-1", EV_A), 0, "解除後は即失効");
      assert.equal((await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: idOf(EV_A, "u-staff-1")})).changed, false, "二重解除はno-op");

      // 再任命: 同じドキュメントをactive=trueへ戻す。assignedAtは最初の任命時刻のまま
      await assign("u-admin", EV_A, "staff.one@example.invalid", "staff");
      const again = await stored(EV_A, "u-staff-1");
      assert.equal(again.active, true);
      assert.equal(again.role, "staff");
      assert.equal(again.assignedAt.toMillis(), before.assignedAt.toMillis());
      assert.ok(again.updatedAt.toMillis() >= afterRemove.updatedAt.toMillis());
      assert.equal(await rank("u-staff-1", EV_A), 1, "再任命で復活");
      assert.equal((await db.collection("eventAssignments").where("uid", "==", "u-staff-1").get()).size, 1, "1イベント・1ユーザー1ドキュメント");
    });

    test("存在しないAuthユーザー・無効なユーザー・存在しないイベント・legacyイベント・不正な入力は拒否され、何も作られない", async () => {
      assert.equal(await detail(assign("u-admin", EV_A, "nobody@example.invalid", "staff")), "user-not-found");
      assert.equal(await detail(assign("u-admin", EV_A, "disabled@example.invalid", "staff")), "user-disabled");
      assert.equal(await detail(assign("u-admin", "evNeverCreated0123", "staff.one@example.invalid", "staff")), "event-not-found");
      assert.equal(await detail(assign("u-admin", EV_LEGACY, "staff.one@example.invalid", "staff")), "event-not-confirmed");
      for (const [data, code] of [
        [{eventId: EV_A, email: "not-an-email", role: "staff"}, "invalid-email"],
        [{eventId: EV_A, email: "staff.one@example.invalid", role: "admin"}, "invalid-role"],
        [{eventId: EV_A, email: "staff.one@example.invalid", role: "system_admin"}, "invalid-role"],
        [{eventId: EV_A, email: "staff.one@example.invalid", role: "staff", uid: "u-staff-1"}, "unexpected-key"],
        [{eventId: EV_A, role: "staff"}, "missing-email"],
      ]) assert.equal(await detail(run("assignEventRole", "u-admin", data)), code, JSON.stringify(data));
      assert.equal((await db.collection("eventAssignments").get()).size, 0);
    });

    test("対象が既存のadmin(system_admin)なら、下位のassignmentを作らない(拒否)。自分自身も不可", async () => {
      assert.equal(await detail(assign("u-admin", EV_A, "admin2@example.invalid", "event_manager")), "target-is-system-admin");
      assert.equal(await detail(assign("u-admin", EV_A, "admin2@example.invalid", "staff")), "target-is-system-admin");
      assert.equal(await detail(assign("u-admin", EV_A, "admin@example.invalid", "staff")), "self-assignment");
      assert.equal((await db.collection("eventAssignments").get()).size, 0);
      assert.deepEqual((await db.collection("accessRoles").doc("u-admin2").get()).data(), {role: "admin", active: true}, "accessRolesは変更しない");
    });
  });

  describe("event_managerの任命", () => {
    beforeEach(async () => {
      await assign("u-admin", EV_A, "manager.a@example.invalid", "event_manager");
      await assign("u-admin", EV_A, "manager.a2@example.invalid", "event_manager");
      await assign("u-admin", EV_B, "manager.b@example.invalid", "event_manager");
    });

    test("自イベントのstaffを任命・解除できる。解除で受付権限が即失効し、再任命で復活する", async () => {
      const created = await assign("u-mgr-a", EV_A, "staff.one@example.invalid", "staff");
      assert.equal(created.role, "staff");
      assert.equal((await stored(EV_A, "u-staff-1")).assignedBy, "u-mgr-a");
      assert.equal(await rank("u-staff-1", EV_A), 1);
      // 実際の受付callableで確認するため、参加者を取り込む
      await index.commitConfirmedImport.run(as("u-admin", buildImportRequest({table: makeTable(2), eventId: EV_A, clientRequestId: "batchAssignA"})));
      const participant = (await db.collection("participants").where("eventId", "==", EV_A).get()).docs[0];
      const view = {eventId: EV_A, participantId: participant.id, publicId: participant.data().publicId};
      assert.equal(await call("getConfirmedReceptionView", "u-staff-1", view), "ok");
      await run("removeEventRole", "u-mgr-a", {eventId: EV_A, assignmentId: created.assignmentId});
      assert.equal(await call("getConfirmedReceptionView", "u-staff-1", view), "permission-denied", "解除後は即失効");
      await assign("u-mgr-a", EV_A, "staff.one@example.invalid", "staff");
      assert.equal(await call("getConfirmedReceptionView", "u-staff-1", view), "ok", "再任命で復活");
    });

    test("event_manager・admin相当の任命、他イベントへの任命、他のevent_managerの変更・解除は拒否", async () => {
      assert.equal(await detail(assign("u-mgr-a", EV_A, "staff.one@example.invalid", "event_manager")), "manager-can-assign-staff-only");
      assert.equal(await detail(assign("u-mgr-a", EV_A, "staff.one@example.invalid", "admin")), "invalid-role");
      assert.equal(await call("assignEventRole", "u-mgr-a", {eventId: EV_B, email: "staff.one@example.invalid", role: "staff"}), "permission-denied", "他イベント");
      // 他のevent_managerをstaffへ降格・解除できない
      assert.equal(await detail(assign("u-mgr-a", EV_A, "manager.a2@example.invalid", "staff")), "manager-cannot-change-manager");
      assert.equal(await detail(run("removeEventRole", "u-mgr-a", {eventId: EV_A, assignmentId: idOf(EV_A, "u-mgr-a2")})), "manager-can-remove-staff-only");
      assert.equal((await stored(EV_A, "u-mgr-a2")).role, "event_manager");
      assert.equal((await stored(EV_A, "u-mgr-a2")).active, true);
      assert.equal(await rank("u-staff-1", EV_B), 0);
    });

    test("自分自身の任命は変更・解除できない(staffへの降格も不可)", async () => {
      assert.equal(await detail(assign("u-mgr-a", EV_A, "manager.a@example.invalid", "staff")), "self-assignment");
      assert.equal(await detail(run("removeEventRole", "u-mgr-a", {eventId: EV_A, assignmentId: idOf(EV_A, "u-mgr-a")})), "self-assignment");
      assert.equal((await stored(EV_A, "u-mgr-a")).role, "event_manager");
      assert.equal(await rank("u-mgr-a", EV_A), 2);
    });

    test("他イベントの任命を自イベントとして解除しようとしても見つからない(他イベントの有無を推測させない)", async () => {
      await assign("u-admin", EV_B, "staff.two@example.invalid", "staff");
      assert.equal(await detail(run("removeEventRole", "u-mgr-a", {eventId: EV_A, assignmentId: idOf(EV_B, "u-staff-2")})), "assignment-not-found");
      assert.equal(await call("removeEventRole", "u-mgr-a", {eventId: EV_B, assignmentId: idOf(EV_B, "u-staff-2")}), "permission-denied");
      assert.equal((await stored(EV_B, "u-staff-2")).active, true);
      assert.equal(await detail(run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: "ea" + "0".repeat(64)})), "assignment-not-found");
      assert.equal(await detail(run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: "u-staff-2"})), "invalid-assignment-id");
    });

    test("無効化されたevent_managerは任命できない(解除後は即失効)", async () => {
      await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: idOf(EV_A, "u-mgr-a")});
      assert.equal(await call("assignEventRole", "u-mgr-a", {eventId: EV_A, email: "staff.one@example.invalid", role: "staff"}), "permission-denied");
      assert.equal(await call("listEventAssignments", "u-mgr-a", {eventId: EV_A}), "permission-denied");
      // 再任命(role変更も含む)でrankが即反映
      await assign("u-admin", EV_A, "manager.a@example.invalid", "staff");
      assert.equal(await rank("u-mgr-a", EV_A), 1);
      assert.equal(await call("assignEventRole", "u-mgr-a", {eventId: EV_A, email: "staff.one@example.invalid", role: "staff"}), "permission-denied", "staffへ変更されたので任命不可");
    });
  });

  describe("staff・未任命", () => {
    test("staffは任命・解除・一覧のすべてを拒否される(自イベントでも)", async () => {
      await assign("u-admin", EV_A, "staff.one@example.invalid", "staff");
      await assign("u-admin", EV_A, "staff.two@example.invalid", "staff");
      assert.equal(await call("assignEventRole", "u-staff-1", {eventId: EV_A, email: "staff.two@example.invalid", role: "staff"}), "permission-denied");
      assert.equal(await call("removeEventRole", "u-staff-1", {eventId: EV_A, assignmentId: idOf(EV_A, "u-staff-2")}), "permission-denied");
      assert.equal(await call("listEventAssignments", "u-staff-1", {eventId: EV_A}), "permission-denied");
      for (const uid of ["u-nobody", "u-mgr-b"]) {
        assert.equal(await call("assignEventRole", uid, {eventId: EV_A, email: "staff.two@example.invalid", role: "staff"}), "permission-denied", uid);
        assert.equal(await call("listEventAssignments", uid, {eventId: EV_A}), "permission-denied", uid);
      }
      assert.equal((await stored(EV_A, "u-staff-2")).active, true);
    });
  });

  describe("listEventAssignments", () => {
    test("有効な任命だけ・対象イベントだけ。返すのはassignmentId・role・active・email・isSelfだけ(uid・任命者は返さない)", async () => {
      await assign("u-admin", EV_A, "manager.a@example.invalid", "event_manager");
      await assign("u-admin", EV_A, "staff.one@example.invalid", "staff");
      await assign("u-admin", EV_A, "staff.two@example.invalid", "staff");
      await assign("u-admin", EV_B, "manager.b@example.invalid", "event_manager");
      await assign("u-admin", EV_B, "staff.one@example.invalid", "staff");
      await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: idOf(EV_A, "u-staff-2")});
      const result = await run("listEventAssignments", "u-mgr-a", {eventId: EV_A});
      assert.deepEqual(result, {eventId: EV_A, assignments: [
        {assignmentId: idOf(EV_A, "u-mgr-a"), role: "event_manager", active: true, email: "manager.a@example.invalid", isSelf: true},
        {assignmentId: idOf(EV_A, "u-staff-1"), role: "staff", active: true, email: "staff.one@example.invalid", isSelf: false},
      // Phase 4: 招待中の一覧も返す(この場面では招待なし)
      ], invitations: []});
      const text = JSON.stringify(result);
      for (const leaked of ["manager.b@", "staff.two@", EV_B, "u-admin", "u-mgr-a\"", "assignedBy", "uid"]) assert.equal(text.includes(leaked), false, leaked);
      assert.equal(await call("listEventAssignments", "u-mgr-a", {eventId: EV_B}), "permission-denied");
      assert.equal((await run("listEventAssignments", "u-admin", {eventId: EV_B})).assignments.length, 2, "adminは任意イベント");
      assert.equal(await detail(run("listEventAssignments", "u-admin", {eventId: EV_LEGACY})), "event-not-confirmed");
    });
  });

  describe("listMyEvents", () => {
    test("admin: confirmedイベント全件(legacyは含まない)。roleはsystem_admin相当(DBは変更しない)", async () => {
      const result = await run("listMyEvents", "u-admin", {});
      assert.equal(result.systemAdmin, true);
      assert.deepEqual(result.events.map((e) => [e.eventId, e.role]), [[EV_B, "system_admin"], [EV_A, "system_admin"]], "開催日時順");
      assert.deepEqual(Object.keys(result.events[0]).sort(), ["eventId", "eventName", "role", "startAt", "venue"]);
      assert.equal(result.events[0].startAt, "2026-10-01T01:00:00.000Z");
      assert.deepEqual((await db.collection("accessRoles").doc("u-admin").get()).data(), {role: "admin", active: true});
    });

    test("manager・staff: 有効な担当イベントだけ(複数可・無効は除外・他イベントは返さない・legacyは含まない)", async () => {
      await assign("u-admin", EV_A, "manager.a@example.invalid", "event_manager");
      await assign("u-admin", EV_B, "manager.a@example.invalid", "staff");
      await assign("u-admin", EV_B, "staff.one@example.invalid", "staff");
      await assign("u-admin", EV_A, "staff.two@example.invalid", "staff");
      await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: idOf(EV_A, "u-staff-2")});
      // legacyイベントへの任命は作れないが、万一存在しても返さない
      await db.collection("eventAssignments").doc(idOf(EV_LEGACY, "u-staff-1")).set({eventId: EV_LEGACY, uid: "u-staff-1", role: "staff", active: true});
      assert.deepEqual((await run("listMyEvents", "u-mgr-a", {})).events.map((e) => [e.eventId, e.role]), [[EV_B, "staff"], [EV_A, "event_manager"]]);
      const staffOne = await run("listMyEvents", "u-staff-1", {});
      assert.deepEqual(staffOne, {systemAdmin: false, events: [{eventId: EV_B, eventName: "架空イベントB", startAt: "2026-10-01T01:00:00.000Z", venue: "架空イベントBの会場", role: "staff"}]});
      assert.equal(await call("listMyEvents", "u-staff-2", {}), "permission-denied", "無効な任命だけのユーザーは権限なし");
      assert.equal(await call("listMyEvents", "u-nobody", {}), "permission-denied");
      assert.equal(await call("listMyEvents", undefined, {}), "unauthenticated");
      // getMyAccessRoleとの整合: 同じ担当イベント
      const me = await run("getMyAccessRole", "u-mgr-a", {});
      assert.deepEqual(me.assignments.map((a) => a.eventId).sort(), (await run("listMyEvents", "u-mgr-a", {})).events.map((e) => e.eventId).sort());
    });
  });

  test("Authの情報はuid・emailだけを使い、パスワード等を保存しない。外部通信はEmulator以外0", async () => {
    await assign("u-admin", EV_A, "staff.one@example.invalid", "staff");
    const doc = await stored(EV_A, "u-staff-1");
    assert.equal(JSON.stringify(doc).includes("must-not-be-stored"), false);
    assert.equal("providerData" in doc || "passwordHash" in doc || "disabled" in doc, false);
    assert.deepEqual(unexpectedRequests, []);
  });
});
