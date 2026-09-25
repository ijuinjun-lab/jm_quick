// Phase 1A: イベント単位の権限(3階層)の判定helper(event_access.js)と、getMyAccessRoleのハンドラを、
// ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDKで検証する(実Firestoreへは接続しない)。
//   admin(accessRoles。概念上のsystem_admin) > event_manager(eventAssignments) > staff(eventAssignments)
// データはすべて完全な架空(メールは予約TLD .invalid)。判定は読み取りのみで、helperはFirestoreへ書き込まない。
const assert = require("node:assert/strict");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {
  EVENT_ASSIGNMENTS_COLLECTION, ROLE_RANK, ASSIGNABLE_ROLES, assignmentDocId, rankOf, isAssignableRole,
  getAssignment, listAssignmentsForUser, listAssignmentsForEvent, getEventAccess, hasEventRole, getAccessSummary,
} = require("../event_access");
const {createGetMyAccessRoleHandler} = require("../confirmed/access_role");

const silent = {warn() {}, info() {}, error() {}};
const EV_A = "evFixtureA0123456789";
const EV_B = "evFixtureB0123456789";

describe("イベント単位の権限helper(Emulator + 実Admin SDK)", {skip: skipReason()}, () => {
  let env;
  let db;

  const seedRole = (uid, data) => db.collection("accessRoles").doc(uid).set(data);
  const seedAssignment = (eventId, uid, role, active = true, extra = {}) =>
    db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(assignmentDocId(eventId, uid)).set({
      eventId, uid, role, active, email: `${uid}@example.invalid`, assignedBy: "u-admin",
      assignedAt: env.FieldValue.serverTimestamp(), updatedAt: env.FieldValue.serverTimestamp(), ...extra,
    });
  const access = async (uid, eventId) => {
    const result = await getEventAccess(db, uid, eventId);
    return {rank: result.rank, role: result.role, systemAdmin: result.systemAdmin};
  };
  const roles = async (uid, eventId) => ({
    admin: await hasEventRole(db, uid, eventId, "admin"),
    manager: await hasEventRole(db, uid, eventId, "event_manager"),
    staff: await hasEventRole(db, uid, eventId, "staff"),
  });

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
  });
  after(() => env?.stop());
  beforeEach(async () => {
    await env.clear();
    await seedRole("u-admin", {role: "admin", active: true, email: "admin@example.invalid"});
    await seedRole("u-admin-off", {role: "admin", active: false});
    await seedRole("u-legacy-staff", {role: "staff", active: true});
    await seedAssignment(EV_A, "u-manager", "event_manager");
    await seedAssignment(EV_A, "u-staff", "staff");
    await seedAssignment(EV_A, "u-off", "event_manager", false);
    await seedAssignment(EV_A, "u-unknown", "owner");
  });

  describe("role rank・role validation", () => {
    test("admin=3 > event_manager=2 > staff=1。未知のroleは0", () => {
      assert.deepEqual(ROLE_RANK, {admin: 3, event_manager: 2, staff: 1});
      for (const role of ["system_admin", "owner", "Admin", "", null, undefined, "__proto__", "toString"]) assert.equal(rankOf(role), 0, String(role));
    });
    test("eventAssignmentsに保存できるroleはevent_managerとstaffだけ(admin・system_adminは保存しない)", () => {
      assert.deepEqual([...ASSIGNABLE_ROLES], ["event_manager", "staff"]);
      for (const role of ["admin", "system_admin", "owner", "", null]) assert.equal(isAssignableRole(role), false, String(role));
    });
    test("ドキュメントIDは決定的で、\"_\"を含むeventId・uidの組でも衝突しない。不正な形式では作らない", () => {
      assert.equal(assignmentDocId(EV_A, "u1"), assignmentDocId(EV_A, "u1"));
      assert.match(assignmentDocId(EV_A, "u1"), /^ea[0-9a-f]{64}$/);
      assert.notEqual(assignmentDocId("a_b", "c"), assignmentDocId("a", "b_c"));
      for (const [eventId, uid] of [["", "u1"], [EV_A, ""], ["a/b", "u1"], [EV_A, "u/1"], [EV_A, null], [123, "u1"], ["x".repeat(129), "u1"]]) {
        assert.equal(assignmentDocId(eventId, uid), null, `${eventId} ${uid}`);
      }
    });
  });

  describe("admin(accessRoles。概念上のsystem_admin)", () => {
    test("有効なadminは、eventAssignments無しで任意のイベントにrank 3(event_manager・staffの権限も包含)", async () => {
      for (const eventId of [EV_A, EV_B, "evNeverCreated"]) {
        assert.deepEqual(await access("u-admin", eventId), {rank: 3, role: "admin", systemAdmin: true});
        assert.deepEqual(await roles("u-admin", eventId), {admin: true, manager: true, staff: true});
      }
      assert.deepEqual(await listAssignmentsForUser(db, "u-admin", {includeInactive: true}), [], "adminのassignmentは不要");
    });
    test("無効なadmin(active=false)は拒否", async () => {
      assert.deepEqual(await access("u-admin-off", EV_A), {rank: 0, role: null, systemAdmin: false});
      assert.deepEqual(await roles("u-admin-off", EV_A), {admin: false, manager: false, staff: false});
    });
    test("activeが真偽値のtrueでない・role表記が違うadminは拒否", async () => {
      await seedRole("u-str", {role: "admin", active: "true"});
      await seedRole("u-upper", {role: "Admin", active: true});
      await seedRole("u-sys", {role: "system_admin", active: true});
      for (const uid of ["u-str", "u-upper", "u-sys"]) assert.equal((await access(uid, EV_A)).rank, 0, uid);
    });
    test("従来のaccessRolesのstaffは、どのイベントの権限にもならない(fail-closed。イベント単位の任命が必要)", async () => {
      assert.deepEqual(await access("u-legacy-staff", EV_A), {rank: 0, role: null, systemAdmin: false});
      assert.equal(await hasEventRole(db, "u-legacy-staff", EV_A, "staff"), false);
    });
  });

  describe("event_manager", () => {
    test("自分のイベントでmanager権限。staff権限も包含する(staffとして重複登録しなくてよい)", async () => {
      assert.deepEqual(await access("u-manager", EV_A), {rank: 2, role: "event_manager", systemAdmin: false});
      assert.deepEqual(await roles("u-manager", EV_A), {admin: false, manager: true, staff: true});
      assert.deepEqual((await listAssignmentsForUser(db, "u-manager")).map((a) => a.role), ["event_manager"], "assignmentは1件だけ");
    });
    test("他のイベントでは拒否", async () => {
      assert.deepEqual(await roles("u-manager", EV_B), {admin: false, manager: false, staff: false});
    });
  });

  describe("staff", () => {
    test("自分のイベントでstaff権限", async () => {
      assert.deepEqual(await access("u-staff", EV_A), {rank: 1, role: "staff", systemAdmin: false});
      assert.equal(await hasEventRole(db, "u-staff", EV_A, "staff"), true);
    });
    test("manager権限・admin権限は拒否", async () => {
      assert.deepEqual(await roles("u-staff", EV_A), {admin: false, manager: false, staff: true});
    });
    test("他のイベントでは拒否", async () => {
      assert.deepEqual(await roles("u-staff", EV_B), {admin: false, manager: false, staff: false});
    });
  });

  describe("無効・不整合なassignmentは拒否", () => {
    test("active=false", async () => {
      assert.deepEqual(await roles("u-off", EV_A), {admin: false, manager: false, staff: false});
      assert.equal((await getAssignment(db, EV_A, "u-off")).active, false, "取得はできる(判定では拒否)");
    });
    test("activeが真偽値でない(文字列\"true\"・未設定)", async () => {
      await seedAssignment(EV_A, "u-str", "staff", "true");
      await db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(assignmentDocId(EV_A, "u-noactive")).set({eventId: EV_A, uid: "u-noactive", role: "staff"});
      for (const uid of ["u-str", "u-noactive"]) assert.equal((await access(uid, EV_A)).rank, 0, uid);
    });
    test("未知のrole(owner・admin・system_admin)", async () => {
      await seedAssignment(EV_A, "u-assigned-admin", "admin");
      await seedAssignment(EV_A, "u-assigned-sys", "system_admin");
      for (const uid of ["u-unknown", "u-assigned-admin", "u-assigned-sys"]) {
        assert.deepEqual(await roles(uid, EV_A), {admin: false, manager: false, staff: false}, uid);
      }
    });
    test("assignmentが存在しない", async () => {
      assert.deepEqual(await roles("u-nobody", EV_A), {admin: false, manager: false, staff: false});
      assert.equal(await getAssignment(db, EV_A, "u-nobody"), null);
    });
    test("ドキュメントIDとフィールドのeventId・uidが一致しない", async () => {
      // 正式なID(EV_B, u-staff)の中身が、別のイベント・別のユーザーを名乗っている
      await db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(assignmentDocId(EV_B, "u-staff")).set({eventId: EV_A, uid: "u-staff", role: "event_manager", active: true});
      await db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(assignmentDocId(EV_B, "u-victim")).set({eventId: EV_B, uid: "u-attacker", role: "event_manager", active: true});
      // 正式でないID({eventId}_{uid}の単純連結)
      await db.collection(EVENT_ASSIGNMENTS_COLLECTION).doc(`${EV_B}_u-forged`).set({eventId: EV_B, uid: "u-forged", role: "event_manager", active: true});
      assert.equal((await access("u-staff", EV_B)).rank, 0, "別イベントを名乗る中身");
      assert.equal((await access("u-victim", EV_B)).rank, 0, "別ユーザーの中身");
      assert.equal((await access("u-attacker", EV_B)).rank, 0);
      assert.equal((await access("u-forged", EV_B)).rank, 0, "正式でないID");
      assert.deepEqual((await listAssignmentsForEvent(db, EV_B, {includeInactive: true})), [], "一覧にも出ない");
      assert.equal((await access("u-staff", EV_A)).rank, 1, "本来のEV_Aのstaff権限は変わらない");
    });
    test("不正な形式のuid・eventIdはFirestoreを読む前に拒否", async () => {
      for (const [uid, eventId] of [["u/x", EV_A], ["u-admin", "a/b"], ["", EV_A], ["u-admin", ""], [null, EV_A], ["u-admin", null]]) {
        assert.equal((await access(uid, eventId)).rank, 0, `${uid} ${eventId}`);
      }
    });
    test("要求roleの指定誤り(未知のrole)は例外(黙って許可も拒否もしない)", async () => {
      for (const minimum of ["system_admin", "owner", "", undefined]) {
        await assert.rejects(hasEventRole(db, "u-admin", EV_A, minimum), /unknown minimum role/, String(minimum));
      }
    });
  });

  describe("一覧", () => {
    test("uid別・eventId別。既定は有効なものだけ、includeInactiveで無効も含む(不整合・未知roleは常に除外)", async () => {
      await seedAssignment(EV_B, "u-manager", "staff");
      assert.deepEqual((await listAssignmentsForUser(db, "u-manager")).map((a) => [a.eventId, a.role]), [[EV_A, "event_manager"], [EV_B, "staff"]]);
      assert.deepEqual((await listAssignmentsForEvent(db, EV_A)).map((a) => [a.uid, a.role]), [["u-manager", "event_manager"], ["u-staff", "staff"]]);
      assert.deepEqual((await listAssignmentsForEvent(db, EV_A, {includeInactive: true})).map((a) => [a.uid, a.active]),
        [["u-manager", true], ["u-off", false], ["u-staff", true]]);
      assert.deepEqual(await listAssignmentsForEvent(db, "a/b"), []);
      assert.deepEqual(await listAssignmentsForUser(db, "u/x"), []);
    });
    test("一覧の結果にemail・assignedByは含めない(判定に使う最小の形)", async () => {
      const [first] = await listAssignmentsForUser(db, "u-manager");
      assert.deepEqual(Object.keys(first).sort(), ["active", "eventId", "role", "uid"]);
    });
  });

  describe("getAccessSummary / getMyAccessRoleハンドラ", () => {
    const handler = () => createGetMyAccessRoleHandler({getDb: () => db, logger: silent});
    const my = (uid) => handler()({identity: {uid}});

    test("admin: 従来のrole=adminに加えsystemAdmin=true", async () => {
      assert.deepEqual(await my("u-admin"), {authenticated: true, role: "admin", systemAdmin: true, assignments: []});
    });
    test("従来のstaff: role=staff・systemAdmin=false(互換)", async () => {
      assert.deepEqual(await my("u-legacy-staff"), {authenticated: true, role: "staff", systemAdmin: false, assignments: []});
    });
    test("event_manager・staffのassignment: 本人の有効な担当イベントだけ", async () => {
      await seedAssignment(EV_B, "u-staff", "staff");
      await seedAssignment(EV_B, "u-staff-other", "event_manager");
      assert.deepEqual(await my("u-manager"), {authenticated: true, role: null, systemAdmin: false, assignments: [{eventId: EV_A, role: "event_manager"}]});
      assert.deepEqual(await my("u-staff"), {authenticated: true, role: null, systemAdmin: false,
        assignments: [{eventId: EV_A, role: "staff"}, {eventId: EV_B, role: "staff"}]});
    });
    test("無効なassignmentだけ・未知roleだけ・何も無いユーザーはpermission-denied(従来と同じ応答)", async () => {
      for (const uid of ["u-off", "u-unknown", "u-nobody", "u-admin-off"]) {
        await assert.rejects(my(uid), (e) => e.isApiError === true && e.code === "permission-denied" && e.message === "この操作を行う権限がありません。", uid);
      }
    });
    test("getAccessSummaryは読み取りのみ(呼び出しの前後でデータが変わらない)", async () => {
      const snapshot = async () => (await Promise.all([db.collection("accessRoles").get(), db.collection(EVENT_ASSIGNMENTS_COLLECTION).get()]))
        .flatMap((s) => s.docs.map((d) => [d.ref.path, JSON.stringify(d.data()), d.updateTime.toMillis()])).sort();
      const before = await snapshot();
      for (const uid of ["u-admin", "u-manager", "u-staff", "u-nobody"]) await getAccessSummary(db, uid);
      for (const uid of ["u-admin", "u-manager", "u-staff"]) await getEventAccess(db, uid, EV_A);
      assert.deepEqual(await snapshot(), before);
    });
  });
});
