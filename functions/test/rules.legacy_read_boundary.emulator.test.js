// Phase 10B(confirmed参加者のread遮断)+ Phase 10C(従来方式のクライアント直接read/writeを閉じる)を、ローカルEmulator(localhostのみ)で固定する。
//
// Phase 10B: confirmed・未知のflow・孤児(イベントが存在しない)・eventId欠落/不正 の participants / checkIns は、get・queryとも拒否(fail-closed)。
//   Rulesはクエリ結果のフィルタではないため、confirmedのeventIdを明示したqueryも、絞り込みなしのqueryも、複数イベント混在のqueryも拒否される。
// Phase 10C: 従来方式(legacy)の participants / checkIns / mailJobs も、read・writeとも全面拒否になった(以前のlegacy公開read・legacy直書きは、
//   意図的に拒否へ変更した。同じ操作は認証つきのサーバーAPIで行う)。eventsのreadだけはPhase 10Dまで公開のまま(受付QRの方式判定用)、eventsのwriteは拒否。
//
// データはすべて完全な架空(実在人物・実メール・実CSV由来のデータではない)。メールは予約TLD .invalid。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const {after, before, describe, test} = require("node:test");
const {PROJECT, RULES_PATH, skipReason, startEmulator, unsignedToken} = require("../test_support/rules_harness");

describe("Firestore Rules(Phase 10B/10C): 参加者・受付のread/write遮断(confirmedも従来方式も)(ローカルEmulator)", {skip: skipReason()}, () => {
  let emu;
  let root;
  const NOBODY = unsignedToken("u-nobody", {});
  const STAFF = unsignedToken("u-staff", {role: "staff"});
  const ADMIN = unsignedToken("u-admin", {role: "admin", admin: true});
  const CLIENTS = [["未認証", undefined], ["認証済み(accessRolesなし)", NOBODY], ["staff相当", STAFF], ["admin相当", ADMIN]];
  const PUBLIC_ID = (c) => `pub_${c.repeat(32)}`;

  // 完全な架空の参加者(confirmedの形: かな・sourceReference・importBatchId・schemaVersion 等を含む)
  const confirmedParticipant = (id, eventId) => ({
    participantId: id, eventId, publicId: PUBLIC_ID("c"), name: "架空 花子", kana: "かくう はなこ", email: "leak-check-confirmed@example.invalid",
    sourceReference: "SRC-架空-001", importBatchId: "batchA", importRow: 2, schemaVersion: 2, status: "active", registrationType: "winner",
  });
  const legacyParticipant = (id, eventId) => ({
    participantId: id, eventId, publicId: PUBLIC_ID("l"), name: "旧 太郎", email: "legacy-participant@example.invalid", registeredCount: 1,
    registrationType: "preRegistered", participationConfirmed: false, reconfirmed: false,
  });
  const checkIn = (id, eventId) => ({participantId: id, eventId, checkedIn: false, attendedCount: null, checkedInAt: null});

  const EVENTS = {
    "e-legacy": {eventId: "e-legacy", eventName: "旧(flowなし)"},
    "e-legacy-explicit": {eventId: "e-legacy-explicit", eventName: "旧(legacy)", flow: "legacy"},
    "e-legacy-null": {eventId: "e-legacy-null", eventName: "旧(null)", flow: null},
    "e-legacy-empty": {eventId: "e-legacy-empty", eventName: "旧(空)", flow: ""},
    "e-conf": {eventId: "e-conf", eventName: "新", flow: "confirmed"},
    "e-typo": {eventId: "e-typo", eventName: "未知", flow: "confirmd"},
    "e-number": {eventId: "e-number", eventName: "未知(数値)", flow: 1},
  };

  // token: undefined=未認証 / JWT / "owner"=Rulesバイパス
  async function call(method, url, body, token) {
    const response = await fetch(url, {method, headers: {"Content-Type": "application/json", ...(token ? {Authorization: `Bearer ${token}`} : {})}, body: body === undefined ? undefined : JSON.stringify(body)});
    return {status: response.status, text: await response.text()};
  }
  const get = (path, token) => call("GET", `${emu.base}/${path}`, undefined, token);
  // Firestore SDKのクエリと同じ StructuredQuery(runQuery)。filters: [[field, op, value]]
  async function query(collection, filters, token) {
    const value = (v) => (Array.isArray(v) ? {arrayValue: {values: v.map((x) => ({stringValue: x}))}} : typeof v === "boolean" ? {booleanValue: v} : {stringValue: v});
    const parts = filters.map(([field, op, v]) => ({fieldFilter: {field: {fieldPath: field}, op, value: value(v)}}));
    const structuredQuery = {from: [{collectionId: collection}], ...(parts.length === 0 ? {} : {where: parts.length === 1 ? parts[0] : {compositeFilter: {op: "AND", filters: parts}}})};
    const result = await call("POST", `${root}:runQuery`, {structuredQuery}, token);
    let docs = [];
    try { const parsed = JSON.parse(result.text); docs = Array.isArray(parsed) ? parsed.filter((x) => x.document).map((x) => x.document.name.split("/").pop()) : []; } catch (error) { docs = []; }
    return {status: result.status, docs, text: result.text};
  }
  const denied = (result) => result.status >= 400 && result.docs.length === 0;
  const seed = (path, data) => emu.seed(path, data);

  before(async () => {
    emu = await startEmulator();
    await emu.loadRules(fs.readFileSync(RULES_PATH, "utf8"));
    root = `${emu.origin}/v1/projects/${PROJECT}/databases/(default)/documents`;
    for (const [id, data] of Object.entries(EVENTS)) await seed(`events/${id}`, data);
    // legacy(4通りの表現)・confirmed・未知flow(2種)の参加者と受付
    for (const id of ["e-legacy", "e-legacy-explicit", "e-legacy-null", "e-legacy-empty"]) {
      await seed(`participants/pl-${id}`, legacyParticipant(`pl-${id}`, id));
      await seed(`checkIns/pl-${id}`, checkIn(`pl-${id}`, id));
    }
    await seed("participants/pc-1", confirmedParticipant("pc-1", "e-conf"));
    await seed("participants/pc-2", confirmedParticipant("pc-2", "e-conf"));
    await seed("checkIns/pc-1", checkIn("pc-1", "e-conf"));
    for (const id of ["e-typo", "e-number"]) {
      await seed(`participants/pu-${id}`, confirmedParticipant(`pu-${id}`, id));
      await seed(`checkIns/pu-${id}`, checkIn(`pu-${id}`, id));
    }
    // 孤児(参照先のイベントが存在しない)・eventId欠落・eventIdが文字列でない・パスを壊すeventId
    await seed("participants/po", confirmedParticipant("po", "e-missing"));
    await seed("checkIns/po", checkIn("po", "e-missing"));
    const {eventId: _omit, ...noEvent} = confirmedParticipant("pn", "x");
    await seed("participants/pn", noEvent);
    await seed("checkIns/pn", {participantId: "pn", checkedIn: false});
    await seed("participants/pnum", {...confirmedParticipant("pnum", "x"), eventId: 12345});
    await seed("checkIns/pnum", {participantId: "pnum", eventId: 12345, checkedIn: false});
    await seed("participants/pslash", confirmedParticipant("pslash", "e-legacy/../e-conf"));
    await seed("checkIns/pslash", checkIn("pslash", "e-legacy/../e-conf"));
    // 保護済みcollection(既存どおり直接アクセス不可であることの確認用)
    await seed("programAttendances/pc-1_a", {eventId: "e-conf", participantId: "pc-1", programId: "a", plannedCount: 1, checkedIn: false});
    await seed("programAttendances/pc-1_a/history/check-in-1", {action: "check-in", changedBy: "u-staff"});
    await seed("importBatches/batchA", {eventId: "e-conf", status: "committed"});
    await seed("importBatches/batchA/rows/1", {result: "created"});
    await seed("sendJobs/winner-batchA", {eventId: "e-conf", status: "ready"});
    await seed("sendJobs/winner-batchA/items/pc-1", {status: "pending"});
    await seed("mailDeliveries/pc-1_winner", {participantId: "pc-1", status: "sent"});
    await seed("accessRoles/u-admin", {role: "admin", active: true});
  });
  after(() => emu?.stop());

  for (const [label, token] of CLIENTS) {
    describe(`${label}のクライアント`, () => {
      test("confirmed参加者: documentのget(participantIdを知っていても)を拒否し、レスポンスに個人情報が含まれない", async () => {
        for (const id of ["pc-1", "pc-2"]) {
          const result = await get(`participants/${id}`, token);
          assert.equal(result.status, 403, id);
          for (const secret of ["架空 花子", "かくう", "leak-check-confirmed@example.invalid", PUBLIC_ID("c"), "SRC-架空-001", "batchA"]) {
            assert.ok(!result.text.includes(secret), `${id}: 応答に ${secret} が含まれている`);
          }
        }
      });

      test("confirmed参加者: eventId == confirmedのquery(events一覧で得たeventIdを使う攻撃経路)を拒否する。1件も返らない", async () => {
        // 攻撃経路: eventsを一覧 → flow=confirmedのeventIdを得る → そのeventIdでparticipantsをquery
        const events = JSON.parse((await get("events", token)).text).documents || [];
        const confirmedIds = events.filter((d) => d.fields.flow && d.fields.flow.stringValue === "confirmed").map((d) => d.fields.eventId.stringValue);
        assert.deepEqual(confirmedIds, ["e-conf"], "eventsはまだ公開read(Phase 10D)。confirmedのeventIdは取得できる");
        for (const eventId of confirmedIds) {
          const result = await query("participants", [["eventId", "EQUAL", eventId]], token);
          assert.ok(denied(result), `eventId=${eventId}: 拒否されるはず (${result.status})`);
          assert.ok(!result.text.includes("leak-check-confirmed@example.invalid") && !result.text.includes(PUBLIC_ID("c")));
        }
      });

      test("confirmed参加者: 他の条件でのquery(participantId・publicId・email・status・eventId+status・絞り込みなし)もすべて拒否する", async () => {
        for (const filters of [
          [["participantId", "EQUAL", "pc-1"]], [["publicId", "EQUAL", PUBLIC_ID("c")]], [["email", "EQUAL", "leak-check-confirmed@example.invalid"]],
          [["status", "EQUAL", "active"]], [["eventId", "EQUAL", "e-conf"], ["status", "EQUAL", "active"]], [],
        ]) {
          const result = await query("participants", filters, token);
          assert.ok(denied(result), JSON.stringify(filters));
        }
      });

      test("Rulesを迂回できない: legacyとconfirmedのeventIdを混在させたquery(in)は、confirmedを返さず全体が拒否される", async () => {
        const mixed = await query("participants", [["eventId", "IN", ["e-legacy", "e-conf"]]], token);
        assert.ok(denied(mixed), `混在queryは拒否 (${mixed.status})`);
        const mixedCheckIns = await query("checkIns", [["eventId", "IN", ["e-legacy", "e-conf"]]], token);
        assert.ok(denied(mixedCheckIns));
      });

      test("unknown flow(タイプミス・数値)・orphan(イベント不存在)・eventId欠落・eventIdが数値・パスを壊すeventId の参加者は、get・queryとも拒否", async () => {
        for (const id of ["pu-e-typo", "pu-e-number", "po", "pn", "pnum", "pslash"]) {
          assert.equal((await get(`participants/${id}`, token)).status, 403, `participants/${id}`);
        }
        for (const eventId of ["e-typo", "e-number", "e-missing", "e-legacy/../e-conf"]) {
          assert.ok(denied(await query("participants", [["eventId", "EQUAL", eventId]], token)), `participants eventId=${eventId}`);
        }
      });

      test("confirmedのcheckIns: get・eventId queryを拒否。unknown flow・orphan・eventId欠落・数値・パスを壊すeventIdも拒否", async () => {
        assert.equal((await get("checkIns/pc-1", token)).status, 403);
        assert.ok(denied(await query("checkIns", [["eventId", "EQUAL", "e-conf"]], token)));
        for (const id of ["pu-e-typo", "pu-e-number", "po", "pn", "pnum", "pslash"]) assert.equal((await get(`checkIns/${id}`, token)).status, 403, `checkIns/${id}`);
        for (const eventId of ["e-typo", "e-number", "e-missing", "e-legacy/../e-conf"]) assert.ok(denied(await query("checkIns", [["eventId", "EQUAL", eventId]], token)), `checkIns eventId=${eventId}`);
        assert.ok(denied(await query("checkIns", [], token)), "絞り込みなしのlistも拒否");
      });

      // Phase 10C: 以前は「legacy(従来どおり公開read)」として get・eventId queryとも許可していた。従来方式も全面拒否へ変更した。
      test("Phase 10C: 従来方式(flowなし・null・空文字・'legacy')の参加者と受付も、get・eventId queryとも拒否(以前は許可)。個人情報を含まない", async () => {
        for (const id of ["e-legacy", "e-legacy-explicit", "e-legacy-null", "e-legacy-empty"]) {
          for (const path of [`participants/pl-${id}`, `checkIns/pl-${id}`]) {
            const result = await get(path, token);
            assert.equal(result.status, 403, path);
            for (const secret of ["旧 太郎", "legacy-participant@example.invalid", PUBLIC_ID("l")]) assert.ok(!result.text.includes(secret), `${path}: 応答に ${secret}`);
          }
          assert.ok(denied(await query("participants", [["eventId", "EQUAL", id]], token)), `participants query ${id}`);
          assert.ok(denied(await query("checkIns", [["eventId", "EQUAL", id]], token)), `checkIns query ${id}`);
        }
        assert.ok(denied(await query("participants", [], token)), "絞り込みなしのlistも拒否");
        assert.ok(denied(await query("participants", [["email", "EQUAL", "legacy-participant@example.invalid"]], token)), "emailでのquery(個人の探索)も拒否");
      });
    });
  }

  describe("読み取り境界の意味(eventsのreadだけが、Phase 10Dまで公開のまま)", () => {
    test("残しているもの: eventsのread(get・list)だけ。participants・checkIns・mailJobs(従来方式も)は、未認証で読めない", async () => {
      assert.equal((await get("events/e-conf")).status, 200, "eventsのreadは維持(/receptionのflow判定に必要。Phase 10Dで閉じる)");
      assert.equal((await get("events/e-legacy")).status, 200);
      assert.equal((await get("participants/pl-e-legacy")).status, 403, "Phase 10C: 従来方式の参加者も拒否(以前は公開read)");
      assert.equal((await get("checkIns/pl-e-legacy")).status, 403, "Phase 10C: 従来方式の受付も拒否(以前は公開read)");
      await seed("mailJobs/e-legacy_invitation", {eventId: "e-legacy", type: "invitation", status: "queued"});
      assert.equal((await get("mailJobs/e-legacy_invitation")).status, 403, "Phase 10C: mailJobsのreadも拒否(以前は限定的に許可。進捗は管理者向けAPI)");
      assert.ok(denied(await query("mailJobs", [["eventId", "EQUAL", "e-legacy"]])), "mailJobsのqueryも拒否");
      assert.equal((await get("mailJobs/e-legacy_invitation/items/x")).status, 403, "itemsは従来どおり拒否");
    });

    test("confirmedの受付の正本 programAttendances と履歴、その他の保護collectionは、従来どおり全クライアントで直接read/write拒否", async () => {
      const paths = ["programAttendances/pc-1_a", "programAttendances/pc-1_a/history/check-in-1", "importBatches/batchA", "importBatches/batchA/rows/1",
        "sendJobs/winner-batchA", "sendJobs/winner-batchA/items/pc-1", "mailDeliveries/pc-1_winner", "accessRoles/u-admin", "mailLogs/x", "walkInRegistrations/x"];
      for (const [label, token] of CLIENTS) {
        for (const path of paths) {
          assert.equal((await get(path, token)).status, 403, `${label}: GET ${path}`);
          const collection = path.split("/").filter((_, i) => i % 2 === 0).slice(-1)[0];
          void collection;
        }
        assert.equal((await emu.update("programAttendances/pc-1_a", {checkedIn: true, attendedCount: 1}, token)), 403, `${label}: UPDATE programAttendances`);
        assert.equal((await emu.update("mailDeliveries/pc-1_winner", {status: "pending"}, token)), 403, `${label}: UPDATE mailDeliveries`);
        assert.equal((await emu.update("accessRoles/u-admin", {role: "staff"}, token)), 403, `${label}: UPDATE accessRoles`);
      }
    });
  });

  describe("Phase 10C: writeはすべて拒否(従来方式・confirmed・孤児とも)", () => {
    test("Phase 10C: 従来方式の正式登録・参加予定の回答・旧受付・イベント設定更新・参加者作成・イベント作成は、すべて拒否(以前は許可)", async () => {
      for (const [label, token] of CLIENTS) {
        assert.equal(await emu.update("participants/pl-e-legacy", {participationConfirmed: true, updatedAt: new Date()}, token), 403, `${label}: 正式登録`);
        assert.equal(await emu.update("participants/pl-e-legacy", {reconfirmed: true, attendanceResponse: "attending", updatedAt: new Date()}, token), 403, `${label}: 回答`);
        assert.equal(await emu.update("checkIns/pl-e-legacy", {checkedIn: true, attendedCount: 1, registeredCountSnapshot: 1, checkedInAt: new Date(), updatedAt: new Date()}, token), 403, `${label}: 旧受付`);
        assert.equal(await emu.update("events/e-legacy", {eventName: "旧(更新)"}, token), 403, `${label}: イベント設定更新`);
        assert.equal(await emu.create("participants", "pl-new", {...legacyParticipant("pl-new", "e-legacy")}, token), 403, `${label}: 参加者作成`);
        assert.equal(await emu.create("checkIns", "pl-new", checkIn("pl-new", "e-legacy"), token), 403, `${label}: 受付作成`);
        assert.equal(await emu.create("events", "e-new-legacy", {eventId: "e-new-legacy", eventName: "新規"}, token), 403, `${label}: イベント作成`);
        assert.equal(await emu.remove("participants/pl-e-legacy", token), 403, `${label}: 参加者削除`);
        assert.equal(await emu.remove("checkIns/pl-e-legacy", token), 403, `${label}: 受付削除`);
        assert.equal(await emu.remove("events/e-legacy", token), 403, `${label}: イベント削除`);
        assert.equal(await emu.create("mailJobs", "e-legacy_invitation2", {eventId: "e-legacy", type: "invitation", status: "queued"}, token), 403, `${label}: mailJobs作成`);
        assert.equal(await emu.update("mailJobs/e-legacy_invitation", {status: "completed"}, token), 403, `${label}: mailJobs更新`);
      }
    });

    test("confirmed: 参加者・受付・イベントへのクライアント直接write(create・update・delete)は、従来どおりすべて拒否", async () => {
      for (const [label, token] of CLIENTS) {
        assert.equal(await emu.update("participants/pc-1", {participationConfirmed: true, updatedAt: new Date()}, token), 403, `${label}: participants update`);
        assert.equal(await emu.update("participants/pc-1", {name: "改ざん"}, token), 403, `${label}: participants name`);
        assert.equal(await emu.create("participants", "pc-new", {...legacyParticipant("pc-new", "e-conf")}, token), 403, `${label}: participants create`);
        assert.equal(await emu.remove("participants/pc-1", token), 403, `${label}: participants delete`);
        assert.equal(await emu.update("checkIns/pc-1", {checkedIn: true, attendedCount: 1, registeredCountSnapshot: 1, checkedInAt: new Date(), updatedAt: new Date()}, token), 403, `${label}: checkIns update`);
        assert.equal(await emu.update("events/e-conf", {eventName: "改ざん"}, token), 403, `${label}: events update`);
        assert.equal(await emu.create("events", "e-conf-new", {eventId: "e-conf-new", eventName: "n", flow: "confirmed"}, token), 403, `${label}: events create`);
      }
    });

    // Phase 10C: 以前は「既存のwriteの性質の記録」として、孤児の参加者(参照先イベントなし)へのlegacy形式のupdateが許可されていた
    // (write用helperがイベント不存在をlegacy扱いにしていたため)。全面拒否になり、孤児・未知のflow・eventId欠落・型不正のいずれもwriteできない。
    test("Phase 10C: 孤児・未知のflow・eventId欠落・eventIdが数値・パスを壊すeventId の参加者・受付へのwriteは、すべて拒否(以前は孤児へのupdateが許可されていた)", async () => {
      for (const [label, token] of CLIENTS) {
        for (const id of ["po", "pn", "pnum", "pslash", "pu-e-typo", "pu-e-number"]) {
          assert.equal(await emu.update(`participants/${id}`, {participationConfirmed: true, updatedAt: new Date()}, token), 403, `${label}: participants/${id} update`);
          assert.equal(await emu.update(`checkIns/${id}`, {checkedIn: true, attendedCount: 1, registeredCountSnapshot: 1, checkedInAt: new Date(), updatedAt: new Date()}, token), 403, `${label}: checkIns/${id} update`);
          assert.equal(await emu.remove(`participants/${id}`, token), 403, `${label}: participants/${id} delete`);
        }
      }
      assert.equal((await get("participants/po")).status, 403);
    });
  });

  test("Rulesの静的検査(Phase 10C): participants・checkIns・mailJobsは read, write とも if false のみ。eventsはreadだけ公開、writeは拒否。旧helperは残っていない", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const allowsOf = (name) => {
      const match = rules.match(new RegExp(`match /${name}/\\{[^}]+\\}\\s*\\{([\\s\\S]*?)\\n    \\}`));
      assert.ok(match, `${name}のmatchが必要`);
      // 子match(mailJobs/items)は除いて、そのcollection自身のallowを取る
      const own = match[1].split(/\n\s*match /)[0];
      return own.match(/allow[^;]*;/g);
    };
    assert.deepEqual(allowsOf("participants"), ["allow read, write: if false;"]);
    assert.deepEqual(allowsOf("checkIns"), ["allow read, write: if false;"]);
    assert.deepEqual(allowsOf("mailJobs"), ["allow read, write: if false;"]);
    assert.deepEqual(allowsOf("events"), ["allow read: if true;", "allow create, update, delete: if false;"]);
    // 条件つきallowが残っていない(=flow・イベント存在・eventIdの型に依存した許可が無い)
    for (const helper of ["eventIsReadableLegacy", "eventIsLegacy", "isLegacyEventData", "eventExists"]) assert.doesNotMatch(rules, new RegExp(helper), `${helper}は不要になった`);
    assert.doesNotMatch(rules, /allow[^;]*:\s*if\s+true[^;]*;[\s\S]*allow[^;]*:\s*if\s+true/, "公開のallowはeventsのreadだけ");
    assert.equal((rules.match(/if true;/g) || []).length, 1, "if true は events の read の1か所だけ");
  });
});
