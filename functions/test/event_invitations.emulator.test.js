// Phase 4: 未登録の人をイベント管理者・スタッフとして招待する正式導線を、実際の公開設定(functions/index.jsのexport)で検証する。
// ローカルのFirestore Emulator(localhostのみ)+ 実際のFirebase Admin SDK。Firebase Authは、招待で使う4つの操作
// (getUserByEmail / getUser)だけをメモリ上の架空のユーザー一覧へ差し替える。
// 招待メールは架空のmail-api(https://mail-api.invalid)のスタブが受け取るだけで、実メールは送らない。外部通信はそれ以外すべて遮断する。
// データはすべて完全な架空(メールは予約TLD .invalid)。
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const path = require("node:path");
const {after, before, beforeEach, describe, test} = require("node:test");
const {skipReason, startAdminEmulator} = require("../test_support/emulator_admin");
const {loadIndex} = require("../test_support/load_index");
const {assignmentDocId, getEventAccess} = require("../event_access");
const {createInvitationApi, invitationDocId, hashToken} = require("../confirmed/invitation_api");

const EV_A = "evInviteA0123456789";
const EV_B = "evInviteB0123456789";
const EV_LEGACY = "evInviteLegacy01234";
const outcome = (promise) => promise.then(() => "ok", (error) => error.code || String(error));
const detail = (promise) => promise.then(() => "ok", (error) => (error.details && error.details.code) || error.code);
const realFetch = globalThis.fetch;

describe("招待(未登録の人をイベント管理者・スタッフとして招待する。実際のindex.js + Emulator)", {skip: skipReason()}, () => {
  let env;
  let db;
  let index;
  let users; // 架空のFirebase Authユーザー {uid, email}
  let authCalls;
  let mails;
  let mailBehavior;
  let unexpected;
  let authPath;
  let originalAuthModule;
  let beforeGetUser;

  const as = (uid, data) => ({auth: uid ? {uid} : undefined, data, app: {appId: "test-app"}, rawRequest: {ip: "192.0.2.10", headers: {}}});
  const publicCall = (name, data, {appCheck = true} = {}) =>
    index[name].run({data, app: appCheck ? {appId: "test-app"} : undefined, rawRequest: {ip: "192.0.2.10", headers: {}}});
  const run = (name, uid, data) => index[name].run(as(uid, data));
  const call = (name, uid, data) => outcome(run(name, uid, data));
  const invite = (uid, eventId, email, role) => run("inviteEventRole", uid, {eventId, email, role});
  const tokenOf = (mail) => /\/invite\?token=([A-Za-z0-9_-]{43})/.exec(mail.text)[1];
  const lastToken = () => tokenOf(mails[mails.length - 1]);
  const invitationDoc = async (eventId, email) => (await db.collection("eventInvitations").doc(invitationDocId(eventId, email)).get()).data();
  const rank = async (uid, eventId) => (await getEventAccess(db, uid, eventId)).rank;
  const assignmentCount = async () => (await db.collection("eventAssignments").get()).size;
  const addUser = (uid, email) => users.push({uid, email});
  const seedEvent = (eventId, name, extra = {}) => db.collection("events").doc(eventId).set({
    eventId, eventName: name, flow: "confirmed", venue: "架空会場", startAt: env.Timestamp.fromDate(new Date("2026-11-30T01:00:00Z")), ...extra,
  });

  before(async () => {
    env = await startAdminEmulator();
    db = env.db;
    authPath = require.resolve("firebase-admin/auth", {paths: [path.join(__dirname, "..")]});
    originalAuthModule = require.cache[authPath];
    const notFound = () => Object.assign(new Error("no user"), {code: "auth/user-not-found"});
    const fakeAuth = {
      async getUserByEmail(email) {
        authCalls.push(["getUserByEmail", email]);
        const user = users.find((u) => u.email === email);
        if (!user) throw notFound();
        return {uid: user.uid, email: user.email, disabled: false};
      },
      async getUser(uid) {
        authCalls.push(["getUser", uid]);
        if (beforeGetUser) await beforeGetUser(uid);
        const user = users.find((u) => u.uid === uid);
        if (!user) throw notFound();
        return {uid: user.uid, email: user.email};
      },
    };
    require.cache[authPath] = {id: authPath, filename: authPath, loaded: true, exports: {getAuth: () => fakeAuth}, children: [], paths: []};
    index = loadIndex(db, {FieldValue: env.FieldValue});
  });
  after(() => {
    globalThis.fetch = realFetch;
    if (originalAuthModule) require.cache[authPath] = originalAuthModule;
    else if (authPath) delete require.cache[authPath];
    env?.stop();
  });
  beforeEach(async () => {
    await env.clear();
    users = [
      {uid: "u-admin", email: "admin@example.invalid"},
      {uid: "u-admin2", email: "admin2@example.invalid"},
      {uid: "u-mgr-a", email: "manager.a@example.invalid"},
      {uid: "u-mgr-b", email: "manager.b@example.invalid"},
      {uid: "u-staff-a", email: "staff.a@example.invalid"},
      {uid: "u-registered", email: "registered@example.invalid"},
      {uid: "u-other", email: "other@example.invalid"},
    ];
    authCalls = [];
    beforeGetUser = null;
    mails = [];
    unexpected = [];
    mailBehavior = () => ({status: 200, body: {ok: true, messageId: `mid-${mails.length}`}});
    globalThis.fetch = async (url, init) => {
      const text = String(url);
      if (text.startsWith(env.origin)) return realFetch(url, init);
      if (text === "https://mail-api.invalid/v1/mail/send") {
        mails.push(JSON.parse(init.body));
        const {status, body} = await mailBehavior();
        return {status, ok: status === 200, json: async () => body};
      }
      unexpected.push(text);
      throw new Error(`unexpected outbound request blocked by test: ${text}`);
    };
    await db.collection("accessRoles").doc("u-admin").set({role: "admin", active: true});
    await db.collection("accessRoles").doc("u-admin2").set({role: "admin", active: true});
    await seedEvent(EV_A, "犬猫譲渡会・トークショー(架空)");
    await seedEvent(EV_B, "架空イベントB");
    await db.collection("events").doc(EV_LEGACY).set({eventId: EV_LEGACY, eventName: "架空の従来イベント"});
    // 既存の任命(Phase 2と同じ正式な方式で作る)
    await run("assignEventRole", "u-admin", {eventId: EV_A, email: "manager.a@example.invalid", role: "event_manager"});
    await run("assignEventRole", "u-admin", {eventId: EV_B, email: "manager.b@example.invalid", role: "event_manager"});
    await run("assignEventRole", "u-admin", {eventId: EV_A, email: "staff.a@example.invalid", role: "staff"});
  });

  describe("招待メール・招待の正本", () => {
    test("システム管理者が未登録の人をイベント管理者として招待: メール1通、tokenはhashだけ保存、任命はまだ作らない", async () => {
      const before = await assignmentCount();
      const result = await invite("u-admin", EV_A, "  New.Manager@Example.INVALID ", "event_manager");
      assert.deepEqual(Object.keys(result).sort(), ["email", "eventId", "expiresAt", "result", "role"]);
      assert.equal(result.result, "invited");
      assert.equal(result.email, "new.manager@example.invalid");
      assert.equal(mails.length, 1);
      const mail = mails[0];
      assert.equal(mail.to, "new.manager@example.invalid");
      assert.equal(mail.subject, "JM Quickへのご招待");
      for (const part of ["JM Quickへ招待されました。", "犬猫譲渡会・トークショー(架空)", "役割: イベント管理者", "https://app.invalid/invite?token=", "有効期限", "何も操作する必要はありません"]) {
        assert.ok(mail.text.includes(part), part);
      }
      assert.equal(/パスワード[:：]/.test(mail.text), false, "パスワードを書かない");
      assert.equal(mail.html, undefined);
      assert.equal(mail.attachments, undefined, "QR・添付なし(当選メールとは別の用途)");
      const token = tokenOf(mail);
      const doc = await invitationDoc(EV_A, "new.manager@example.invalid");
      assert.equal(doc.status, "pending");
      assert.equal(doc.role, "event_manager");
      assert.equal(doc.tokenHash, hashToken(token));
      assert.equal(JSON.stringify(doc).includes(token), false, "tokenの平文を保存しない");
      assert.equal(doc.mailStatus, "sent");
      assert.ok(doc.expiresAt - Date.now() > 6.9 * 24 * 3600 * 1000 && doc.expiresAt - Date.now() <= 7 * 24 * 3600 * 1000, "有効期限は7日");
      assert.equal(await assignmentCount(), before, "招待しただけでは任命を作らない");
      assert.equal((await db.collection("sendJobs").get()).size, 0, "当選メールの送信ジョブは使わない");
      assert.equal(authCalls.some(([name]) => name === "createUser"), false, "招待の時点ではAuthユーザーを作らない");
    });

    test("登録済みのメールアドレスは招待せず、従来どおり即任命(メールは送らない)", async () => {
      const result = await invite("u-admin", EV_A, "registered@example.invalid", "event_manager");
      assert.equal(result.result, "assigned");
      assert.equal(mails.length, 0);
      assert.equal(await rank("u-registered", EV_A), 2);
      assert.equal((await db.collection("eventInvitations").get()).size, 0);
    });

    test("tokenは推測できない(32バイトの乱数)。再招待でtokenは作り直され、古いリンクは使えない", async () => {
      await invite("u-admin", EV_A, "new.person@example.invalid", "staff");
      const first = lastToken();
      await invite("u-admin", EV_A, "new.person@example.invalid", "staff");
      const second = lastToken();
      assert.notEqual(first, second);
      assert.equal(Buffer.from(second, "base64url").length, 32);
      assert.deepEqual(await publicCall("getEventInvitation", {token: first}), {status: "invalid"});
      assert.equal((await publicCall("getEventInvitation", {token: second})).status, "pending");
      assert.equal((await db.collection("eventInvitations").get()).size, 1, "同じイベント・同じメールアドレスは1件");
      // 推測したtoken(形式だけ正しい乱数)・不正な形式は無効
      assert.deepEqual(await publicCall("getEventInvitation", {token: crypto.randomBytes(32).toString("base64url")}), {status: "invalid"});
      assert.deepEqual(await publicCall("getEventInvitation", {token: "short"}), {status: "invalid"});
      assert.deepEqual(await publicCall("getEventInvitation", {token: hashToken(second)}), {status: "invalid"}, "hashをtokenとして使えない");
    });

    test("招待メールを送れなかった場合はエラー(招待は送信失敗として記録)", async () => {
      mailBehavior = () => ({status: 400, body: {ok: false}});
      assert.equal(await detail(invite("u-admin", EV_A, "new.person@example.invalid", "staff")), "invitation-mail-failed");
      assert.equal((await invitationDoc(EV_A, "new.person@example.invalid")).mailStatus, "failed");
    });
  });

  describe("招待の権限", () => {
    test("event_managerは自イベントのstaffだけを招待できる。event_manager・他イベント・staffからの招待は拒否", async () => {
      assert.equal((await invite("u-mgr-a", EV_A, "new.staff@example.invalid", "staff")).result, "invited");
      assert.equal(await detail(invite("u-mgr-a", EV_A, "new.manager@example.invalid", "event_manager")), "manager-can-assign-staff-only");
      assert.equal(await call("inviteEventRole", "u-mgr-a", {eventId: EV_B, email: "new.x@example.invalid", role: "staff"}), "permission-denied");
      assert.equal(await call("inviteEventRole", "u-staff-a", {eventId: EV_A, email: "new.x@example.invalid", role: "staff"}), "permission-denied");
      assert.equal(await call("inviteEventRole", "u-nobody", {eventId: EV_A, email: "new.x@example.invalid", role: "staff"}), "permission-denied");
      assert.equal(await detail(invite("u-admin", EV_A, "new.x@example.invalid", "admin")), "invalid-role");
      assert.equal(await detail(invite("u-admin", EV_A, "new.x@example.invalid", "system_admin")), "invalid-role");
      assert.equal(mails.length, 1, "拒否された招待ではメールを送らない");
    });

    test("自分自身・システム管理者・存在しないイベント・legacyイベントへの招待は拒否", async () => {
      assert.equal(await detail(invite("u-admin", EV_A, "admin@example.invalid", "staff")), "self-assignment");
      assert.equal(await detail(invite("u-admin", EV_A, "admin2@example.invalid", "event_manager")), "target-is-system-admin");
      assert.equal(await detail(invite("u-admin", "evNeverCreated0123", "new.x@example.invalid", "staff")), "event-not-found");
      assert.equal(await detail(invite("u-admin", EV_LEGACY, "new.x@example.invalid", "staff")), "event-not-confirmed");
      assert.equal(mails.length, 0);
      assert.equal((await db.collection("eventInvitations").get()).size, 0);
    });

    test("取消: managerは自イベントのstaffの招待だけ。取消後のリンクは使えない", async () => {
      await invite("u-admin", EV_A, "new.manager@example.invalid", "event_manager");
      const managerToken = lastToken();
      await invite("u-mgr-a", EV_A, "new.staff@example.invalid", "staff");
      const staffToken = lastToken();
      const managerInvitation = invitationDocId(EV_A, "new.manager@example.invalid");
      const staffInvitation = invitationDocId(EV_A, "new.staff@example.invalid");
      assert.equal(await detail(run("revokeEventInvitation", "u-mgr-a", {eventId: EV_A, invitationId: managerInvitation})), "manager-can-revoke-staff-only");
      assert.equal(await call("revokeEventInvitation", "u-mgr-b", {eventId: EV_A, invitationId: staffInvitation}), "permission-denied");
      assert.equal(await detail(run("revokeEventInvitation", "u-mgr-b", {eventId: EV_B, invitationId: staffInvitation})), "invitation-not-found", "他イベントの招待は見つからない扱い");
      assert.equal((await run("revokeEventInvitation", "u-mgr-a", {eventId: EV_A, invitationId: staffInvitation})).changed, true);
      assert.deepEqual(await publicCall("getEventInvitation", {token: staffToken}), {status: "revoked"});
      assert.equal((await publicCall("getEventInvitation", {token: managerToken})).status, "pending", "他の招待は変わらない");
    });

    test("一覧(listEventAssignments)に招待中を返す。tokenのhash・招待者・uidは返さない。他イベントの招待は出ない", async () => {
      await invite("u-mgr-a", EV_A, "new.staff@example.invalid", "staff");
      await invite("u-mgr-b", EV_B, "other.staff@example.invalid", "staff");
      const result = await run("listEventAssignments", "u-mgr-a", {eventId: EV_A});
      assert.equal(result.invitations.length, 1);
      assert.deepEqual(Object.keys(result.invitations[0]).sort(), ["email", "expiresAt", "invitationId", "mailStatus", "role", "status"]);
      assert.equal(result.invitations[0].email, "new.staff@example.invalid");
      assert.equal(result.invitations[0].status, "pending");
      const text = JSON.stringify(result.invitations);
      for (const leaked of ["tokenHash", "invitedBy", "u-mgr-a", "other.staff@"]) assert.equal(text.includes(leaked), false, leaked);
    });
  });

  describe("招待リンクを開く・初期設定・受諾", () => {
    test("招待リンクの表示は、tokenを確認できたときだけ最小限(メールアドレスは一部だけ)。App Check必須", async () => {
      await invite("u-admin", EV_A, "new.manager@example.invalid", "event_manager");
      const token = lastToken();
      const info = await publicCall("getEventInvitation", {token});
      assert.deepEqual(Object.keys(info).sort(), ["accountExists", "email", "emailHint", "eventName", "expiresAt", "role", "status"]);
      assert.equal(info.eventName, "犬猫譲渡会・トークショー(架空)");
      assert.equal(info.role, "event_manager");
      assert.equal(info.emailHint, "ne***@example.invalid");
      assert.equal(info.accountExists, false);
      assert.equal(JSON.stringify(info).includes(EV_A), false, "eventIdを返さない");
      assert.equal(await outcome(publicCall("getEventInvitation", {token}, {appCheck: false})), "unauthenticated");
    });

    test("登録はクライアントの責務: サーバーにAuth作成・password受付・prepare exportがない", async () => {
      assert.equal(index.prepareInvitationAccount, undefined);
      await invite("u-admin", EV_A, "new.manager@example.invalid", "event_manager");
      const token = lastToken();
      const info = await publicCall("getEventInvitation", {token});
      assert.equal(info.email, "new.manager@example.invalid");
      assert.equal(info.accountExists, false);
      assert.equal(await rank("u-new", EV_A), 0);
      addUser("u-new", info.email); // 本人のAuth SDK登録が完了した状態
      assert.equal((await publicCall("getEventInvitation", {token})).accountExists, true);
      assert.equal(await detail(publicCall("getEventInvitation", {token, password: "fixture-only"})), "unexpected-key");
      assert.equal(await detail(run("acceptEventInvitation", "u-new", {token, password: "fixture-only"})), "unexpected-key");
      assert.ok(authCalls.every(([method]) => ["getUser", "getUserByEmail"].includes(method)));
    });

    test("受諾: ログインした本人のメールアドレスが一致したときだけ任命を有効にする。tokenの再利用は不可", async () => {
      await invite("u-admin", EV_A, "new.manager@example.invalid", "event_manager");
      const token = lastToken();
      addUser("u-created", "new.manager@example.invalid");
      const newUid = users.find((u) => u.email === "new.manager@example.invalid").uid;
      assert.equal(await outcome(index.acceptEventInvitation.run({data: {token}})), "unauthenticated", "未認証では任命を作れない");
      assert.equal(await detail(run("acceptEventInvitation", "u-other", {token})), "invitation-email-mismatch", "別のメールアドレスのユーザーは横取りできない");
      assert.equal(await rank(newUid, EV_A), 0);
      const accepted = await run("acceptEventInvitation", newUid, {token});
      assert.deepEqual(accepted, {eventId: EV_A, eventName: "犬猫譲渡会・トークショー(架空)", role: "event_manager"});
      assert.equal(await rank(newUid, EV_A), 2);
      assert.equal(await rank(newUid, EV_B), 0, "他イベントの権限は無い");
      const assignment = (await db.collection("eventAssignments").doc(assignmentDocId(EV_A, newUid)).get()).data();
      assert.equal(assignment.assignedBy, "u-admin");
      const invitation = await invitationDoc(EV_A, "new.manager@example.invalid");
      assert.equal(invitation.status, "accepted");
      assert.equal(invitation.acceptedBy, newUid);
      assert.equal(await detail(run("acceptEventInvitation", newUid, {token})), "invitation-accepted", "同じtokenは再利用できない");
      assert.deepEqual(await publicCall("getEventInvitation", {token}), {status: "accepted"});
      // listMyEvents・getMyAccessRoleにすぐ反映
      assert.deepEqual((await run("listMyEvents", newUid, {})).events.map((e) => [e.eventId, e.role]), [[EV_A, "event_manager"]]);
    });

    test("改ざん不可: eventId・role・uidを送っても使わない(想定外のキーとして拒否)。staffの招待でmanagerにはならない", async () => {
      await invite("u-mgr-a", EV_A, "new.staff@example.invalid", "staff");
      const token = lastToken();
      addUser("u-created", "new.staff@example.invalid");
      const newUid = users.find((u) => u.email === "new.staff@example.invalid").uid;
      for (const extra of [{eventId: EV_B}, {role: "event_manager"}, {role: "admin"}, {uid: "u-admin"}, {email: "other@example.invalid"}]) {
        assert.equal(await detail(run("acceptEventInvitation", newUid, {token, ...extra})), "unexpected-key", JSON.stringify(extra));
      }
      await run("acceptEventInvitation", newUid, {token});
      assert.equal(await rank(newUid, EV_A), 1, "staffのまま");
      assert.equal(await rank(newUid, EV_B), 0);
      assert.equal((await db.collection("accessRoles").doc(newUid).get()).exists, false, "system_adminへの昇格経路は無い");
    });

    test("期限切れ・招待者の権限が失われた招待は受諾できない", async () => {
      await invite("u-admin", EV_A, "expired@example.invalid", "staff");
      const expiredToken = lastToken();
      await db.collection("eventInvitations").doc(invitationDocId(EV_A, "expired@example.invalid")).update({expiresAt: Date.now() - 1000});
      assert.deepEqual(await publicCall("getEventInvitation", {token: expiredToken}), {status: "expired"});
      addUser("u-expired", "expired@example.invalid");
      assert.equal(await detail(run("acceptEventInvitation", "u-expired", {token: expiredToken})), "invitation-expired");
      // managerが招待した後に、そのmanagerが解除された
      await invite("u-mgr-a", EV_A, "orphan@example.invalid", "staff");
      const orphanToken = lastToken();
      await run("removeEventRole", "u-admin", {eventId: EV_A, assignmentId: assignmentDocId(EV_A, "u-mgr-a")});
      addUser("u-orphan", "orphan@example.invalid");
      assert.equal(await detail(run("acceptEventInvitation", "u-orphan", {token: orphanToken})), "invitation-inviter-inactive");
      assert.equal(await rank("u-orphan", EV_A), 0);
    });

    test("既に有効なevent_managerがstaffの招待を受けても降格しない。取消後の受諾は不可", async () => {
      // staffとして招待中の人が、受諾前にシステム管理者からイベント管理者へ任命された
      await invite("u-mgr-b", EV_B, "late.manager@example.invalid", "staff");
      const staffToken = lastToken();
      addUser("u-late", "late.manager@example.invalid");
      const uid = users.find((u) => u.email === "late.manager@example.invalid").uid;
      assert.equal((await invite("u-admin", EV_B, "late.manager@example.invalid", "event_manager")).result, "assigned", "登録済みなので即任命");
      assert.equal(await rank(uid, EV_B), 2);
      assert.deepEqual(await run("acceptEventInvitation", uid, {token: staffToken}), {eventId: EV_B, eventName: "架空イベントB", role: "event_manager"});
      assert.equal(await rank(uid, EV_B), 2, "staffの招待を受けても降格しない");
      // 他のevent_managerは、既存のevent_managerをstaffへ変更できない(Phase 2の規則は招待の経路でも同じ)
      assert.equal(await detail(invite("u-mgr-b", EV_B, "late.manager@example.invalid", "staff")), "manager-cannot-change-manager");
      // 取消後
      await invite("u-admin", EV_A, "revoked@example.invalid", "staff");
      const revokedToken = lastToken();
      addUser("u-revoked", "revoked@example.invalid");
      await run("revokeEventInvitation", "u-admin", {eventId: EV_A, invitationId: invitationDocId(EV_A, "revoked@example.invalid")});
      const revokedUid = users.find((u) => u.email === "revoked@example.invalid").uid;
      assert.equal(await detail(run("acceptEventInvitation", revokedUid, {token: revokedToken})), "invitation-revoked");
      assert.equal(await rank(revokedUid, EV_A), 0);
    });
  });

  test("受諾transactionは最新の取消・期限・招待者権限を再読込する", async () => {
    for (const change of ["revoke", "expire", "inviter", "generation"]) {
      const email = `${change}@example.invalid`;
      await invite("u-mgr-a", EV_A, email, "staff");
      const token = lastToken();
      const uid = `u-${change}`;
      addUser(uid, email);
      // token検索が終わってからtransaction開始までの変更を決定的に再現する。
      beforeGetUser = async (target) => {
        if (target !== uid) return;
        beforeGetUser = null;
        const ref = db.collection("eventInvitations").doc(invitationDocId(EV_A, email));
        if (change === "revoke") await ref.update({status: "revoked"});
        if (change === "expire") await ref.update({expiresAt: Date.now() - 1});
        if (change === "generation") await ref.update({tokenHash: hashToken(crypto.randomBytes(32).toString("base64url"))});
        if (change === "inviter") await db.collection("eventAssignments").doc(assignmentDocId(EV_A, "u-mgr-a")).update({active: false});
      };
      const result = await detail(run("acceptEventInvitation", uid, {token}));
      assert.equal(result, {revoke: "invitation-revoked", expire: "invitation-expired", inviter: "invitation-inviter-inactive", generation: "invitation-changed"}[change]);
      assert.equal(await rank(uid, EV_A), 0);
      if (change === "inviter") await db.collection("eventAssignments").doc(assignmentDocId(EV_A, "u-mgr-a")).update({active: true});
    }
  });

  test("transaction内のread待ちで期限を越えたら任命を書かない", async () => {
    await invite("u-admin", EV_A, "clock@example.invalid", "staff");
    const token = lastToken();
    const expiresAt = (await invitationDoc(EV_A, "clock@example.invalid")).expiresAt;
    let clockReads = 0;
    const api = createInvitationApi({getDb: () => db, serverTimestamp: () => env.FieldValue.serverTimestamp(),
      now: () => ++clockReads === 1 ? expiresAt - 1 : expiresAt,
      authAdmin: {findUserByEmail: async () => null, getUser: async () => ({uid: "u-clock", email: "clock@example.invalid"})},
      assignmentApi: {}, getTransport: () => { throw new Error("no mail"); }, getAppBaseUrl: () => "https://app.invalid"});
    assert.equal(await detail(api.accept({identity: {uid: "u-clock"}, data: {token}})), "invitation-expired");
    assert.equal(await rank("u-clock", EV_A), 0);
    assert.equal((await invitationDoc(EV_A, "clock@example.invalid")).status, "pending");
  });

  test("取消/受諾の同時実行はrevoked+任命なし、またはaccepted+任命の一貫した結果", async () => {
    await invite("u-mgr-a", EV_A, "race@example.invalid", "staff");
    const token = lastToken(); addUser("u-race", "race@example.invalid");
    const results = await Promise.allSettled([
      run("acceptEventInvitation", "u-race", {token}),
      run("revokeEventInvitation", "u-mgr-a", {eventId: EV_A, invitationId: invitationDocId(EV_A, "race@example.invalid")}),
    ]);
    const invitation = await invitationDoc(EV_A, "race@example.invalid");
    if (invitation.status === "revoked") {
      assert.equal(await rank("u-race", EV_A), 0);
      assert.equal(results[0].status, "rejected");
    } else {
      assert.equal(invitation.status, "accepted"); assert.equal(await rank("u-race", EV_A), 1);
      assert.equal(results[0].status, "fulfilled");
      assert.equal(results[1].value.changed, false);
    }
  });

  test("並行再招待: 旧送信成功が新世代の送信失敗を上書きしない", async () => {
    let finishOld; let oldStarted;
    const started = new Promise((resolve) => { oldStarted = resolve; });
    mailBehavior = () => new Promise((resolve) => { finishOld = resolve; oldStarted(); });
    const old = invite("u-admin", EV_A, "overlap@example.invalid", "staff");
    await started; const oldToken = lastToken();
    mailBehavior = () => ({status: 400, body: {ok: false}});
    assert.equal(await detail(invite("u-admin", EV_A, "overlap@example.invalid", "staff")), "invitation-mail-failed");
    const newToken = lastToken();
    finishOld({status: 200, body: {ok: true, messageId: "old"}}); await old;
    const invitation = await invitationDoc(EV_A, "overlap@example.invalid");
    assert.equal(invitation.tokenHash, hashToken(newToken)); assert.equal(invitation.mailStatus, "failed");
    assert.deepEqual(await publicCall("getEventInvitation", {token: oldToken}), {status: "invalid"});
    assert.equal((await publicCall("getEventInvitation", {token: newToken})).status, "pending");
  });

  test("Auth作成後の受諾一時失敗はpendingのまま、同じUIDで再開できる", async () => {
    await invite("u-admin", EV_A, "resume@example.invalid", "event_manager");
    const token = lastToken(); addUser("u-resume", "resume@example.invalid");
    beforeGetUser = async () => { beforeGetUser = null; throw new Error("temporary-auth-read-failure"); };
    await assert.rejects(run("acceptEventInvitation", "u-resume", {token}));
    assert.equal((await invitationDoc(EV_A, "resume@example.invalid")).status, "pending");
    assert.equal(await rank("u-resume", EV_A), 0);
    assert.equal((await publicCall("getEventInvitation", {token})).accountExists, true);
    assert.equal((await run("acceptEventInvitation", "u-resume", {token})).role, "event_manager");
    assert.equal(await rank("u-resume", EV_A), 2);
  });

  test("Rules: eventInvitationsはクライアントから直接読めない(ルールの静的検査)", () => {
    const rules = require("node:fs").readFileSync(path.join(__dirname, "..", "..", "firestore.rules"), "utf8");
    const block = rules.match(/match \/eventInvitations\/\{[^}]+\}\s*\{([^}]*)\}/);
    assert.ok(block);
    assert.deepEqual(block[1].match(/allow[^;]*;/g), ["allow read, write: if false;"]);
  });

  test("外部通信はEmulatorと架空のmail-apiだけ(実メール0・想定外の通信0)", async () => {
    await invite("u-admin", EV_A, "new.person@example.invalid", "staff");
    assert.deepEqual(unexpected, []);
    assert.ok(mails.every((m) => m.to.endsWith("@example.invalid")));
  });
});
