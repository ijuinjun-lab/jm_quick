// firestore.rules を、ローカルのFirestore Emulator(localhostのみ・実Firestoreへ接続しない)で検証する。
// キャッシュ済みのエミュレータJARとJavaがある場合だけ実行し、無ければスキップする(ダウンロードはしない)。
// JARの場所は環境変数 FIRESTORE_EMULATOR_JAR で上書きできる。
// 認証ヘッダなしのREST呼び出しにはRulesが適用され、"Bearer owner" はRulesをバイパスする(初期データ投入用)。
const assert = require("node:assert/strict");
const {spawn, spawnSync} = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const {after, before, describe, test} = require("node:test");

const RULES_PATH = path.join(__dirname, "..", "..", "firestore.rules");
const PROJECT = "demo-jm-quick";

function findJar() {
  if (process.env.FIRESTORE_EMULATOR_JAR) return process.env.FIRESTORE_EMULATOR_JAR;
  const dir = path.join(os.homedir(), ".cache", "firebase", "emulators");
  if (!fs.existsSync(dir)) return null;
  const jar = fs.readdirSync(dir).find((name) => /^cloud-firestore-emulator-.*\.jar$/.test(name));
  return jar ? path.join(dir, jar) : null;
}

const jar = findJar();
const javaAvailable = spawnSync("java", ["-version"]).status === 0;
const skipReason = !javaAvailable ? "javaが見つかりません" : !jar || !fs.existsSync(jar) ? "キャッシュ済みのFirestore Emulator JARがありません" : false;

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const {port} = server.address();
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

// --- Firestore REST の値エンコード ---
function encode(value) {
  if (value === null || value === undefined) return {nullValue: null};
  if (typeof value === "string") return {stringValue: value};
  if (typeof value === "boolean") return {booleanValue: value};
  if (typeof value === "number") return Number.isInteger(value) ? {integerValue: String(value)} : {doubleValue: value};
  if (value instanceof Date) return {timestampValue: value.toISOString()};
  if (Array.isArray(value)) return {arrayValue: {values: value.map(encode)}};
  return {mapValue: {fields: encodeFields(value)}};
}
const encodeFields = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, encode(v)]));

describe("Firestore Rules(ローカルEmulator)", {skip: skipReason}, () => {
  let child;
  let base;
  let origin;

  async function request(method, url, body, {owner = false} = {}) {
    const response = await fetch(url, {
      method,
      headers: {"Content-Type": "application/json", ...(owner ? {Authorization: "Bearer owner"} : {})},
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return response.status;
  }
  const docUrl = (docPath, query = "") => `${base}/${docPath}${query}`;
  const seed = async (docPath, data) => {
    const status = await request("PATCH", docUrl(docPath), {fields: encodeFields(data)}, {owner: true});
    assert.equal(status, 200, `seed ${docPath}`);
  };
  const read = (docPath) => request("GET", docUrl(docPath));
  const list = (collection) => request("GET", docUrl(collection));
  const create = (collection, id, data) =>
    request("POST", docUrl(collection, `?documentId=${id}`), {fields: encodeFields(data)});
  const update = (docPath, data) => {
    const mask = Object.keys(data).map((key) => `updateMask.fieldPaths=${key}`).join("&");
    return request("PATCH", docUrl(docPath, `?${mask}&currentDocument.exists=true`), {fields: encodeFields(data)});
  };
  const remove = (docPath) => request("DELETE", docUrl(docPath));
  const commit = (writes) => request("POST", `${origin}/v1/projects/${PROJECT}/databases/(default)/documents:commit`, {
    writes: writes.map(({path: docPath, data}) => ({
      update: {name: `projects/${PROJECT}/databases/(default)/documents/${docPath}`, fields: encodeFields(data)},
      currentDocument: {exists: false},
    })),
  });

  const event = (id, extra = {}) => ({eventId: id, eventName: id, venue: "会場", ...extra});
  const participantDoc = (id, eventId) => ({
    participantId: id, eventId, publicId: `pub_${id}_0123456789abcdef01234567`, name: "氏名",
    email: `${id}@example.com`, registeredCount: 1, registrationType: "preRegistered",
    participationConfirmed: false, reconfirmed: false, attendanceResponse: null,
  });
  const checkInDoc = (id, eventId) => ({participantId: id, eventId, checkedIn: false, attendedCount: null, checkedInAt: null});
  const EVENTS = {
    "e-legacy": event("e-legacy"),
    "e-legacy-explicit": event("e-legacy-explicit", {flow: "legacy"}),
    "e-confirmed": event("e-confirmed", {flow: "confirmed"}),
    "e-unknown": event("e-unknown", {flow: "confirmd"}),
  };

  before(async () => {
    const port = await freePort();
    const wsPort = await freePort();
    origin = `http://127.0.0.1:${port}`;
    base = `${origin}/v1/projects/${PROJECT}/databases/(default)/documents`;
    child = spawn("java", ["-jar", jar, "--host=127.0.0.1", `--port=${port}`, `--websocket_port=${wsPort}`], {stdio: ["ignore", "pipe", "pipe"]});
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("emulator did not start")), 40000);
      const onData = (chunk) => {
        if (String(chunk).includes("Dev App Server is now running")) { clearTimeout(timer); resolve(); }
      };
      child.stdout.on("data", onData);
      child.stderr.on("data", onData);
      child.on("exit", () => reject(new Error("emulator exited early")));
    });
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    const status = await request("PUT", `${origin}/emulator/v1/projects/${PROJECT}:securityRules`,
      {rules: {files: [{name: "firestore.rules", content: rules}]}});
    assert.equal(status, 200, "rulesの読込(構文エラーなら失敗)");

    for (const [id, data] of Object.entries(EVENTS)) {
      await seed(`events/${id}`, data);
      await seed(`participants/p-${id}`, participantDoc(`p-${id}`, id));
      await seed(`checkIns/p-${id}`, checkInDoc(`p-${id}`, id));
    }
    await seed("programAttendances/p-e-confirmed_cat", {eventId: "e-confirmed", participantId: "p-e-confirmed", programId: "cat", plannedCount: 2});
  });

  after(() => { child?.kill(); });

  describe("programAttendances: 認証なしクライアントから一切read/writeできない", () => {
    const id = "p-e-confirmed_cat";
    test("get(既存)", async () => assert.equal(await read(`programAttendances/${id}`), 403));
    test("get(存在しないID)", async () => assert.equal(await read("programAttendances/none_none"), 403));
    test("list", async () => assert.equal(await list("programAttendances"), 403));
    test("create", async () => assert.equal(await create("programAttendances", "x1_cat", {eventId: "e-confirmed", participantId: "x1", programId: "cat", plannedCount: 1}), 403));
    test("update", async () => assert.equal(await update(`programAttendances/${id}`, {checkedIn: true}), 403));
    test("delete", async () => assert.equal(await remove(`programAttendances/${id}`), 403));
    test("legacyイベントに紐づくデータを装っても拒否", async () =>
      assert.equal(await create("programAttendances", "y1_cat", {eventId: "e-legacy", participantId: "y1", programId: "cat", plannedCount: 1}), 403));
  });

  describe("旧クライアント直書き経路: legacyイベントは従来どおり許可される(回帰)", () => {
    for (const eventId of ["e-legacy", "e-legacy-explicit"]) {
      test(`${eventId}: 設定更新(events update)`, async () =>
        assert.equal(await update(`events/${eventId}`, {venue: "新会場", reconfirmEnabled: false}), 200));
      test(`${eventId}: 正式登録(participants update)`, async () =>
        assert.equal(await update(`participants/p-${eventId}`, {participationConfirmed: true, updatedAt: new Date()}), 200));
      test(`${eventId}: 参加予定回答/reconfirm(participants update)`, async () =>
        assert.equal(await update(`participants/p-${eventId}`, {reconfirmed: true, attendanceResponse: "attending", updatedAt: new Date()}), 200));
      test(`${eventId}: 旧受付(checkIns update)`, async () =>
        assert.equal(await update(`checkIns/p-${eventId}`, {checkedIn: true, attendedCount: 1, registeredCountSnapshot: 1, checkedInAt: new Date(), updatedAt: new Date()}), 200));
      test(`${eventId}: 参加者+受付の同時作成(旧createParticipant)`, async () => {
        const id = `n-${eventId}`;
        assert.equal(await commit([
          {path: `participants/${id}`, data: participantDoc(id, eventId)},
          {path: `checkIns/${id}`, data: checkInDoc(id, eventId)},
        ]), 200);
      });
    }
    test("legacyイベントの新規作成(flowなし)", async () =>
      assert.equal(await create("events", "e-new-legacy", event("e-new-legacy")), 200));
    test("events/participants/checkIns のreadは従来どおり(Phase 10で閉じる)", async () => {
      assert.equal(await read("events/e-legacy"), 200);
      assert.equal(await read("participants/p-e-legacy"), 200);
      assert.equal(await read("checkIns/p-e-legacy"), 200);
    });
  });

  describe("旧クライアント直書き経路: flow=confirmed / 未知flow のイベントには一切書込めない", () => {
    for (const eventId of ["e-confirmed", "e-unknown"]) {
      test(`${eventId}: 旧設定更新(events update)を拒否`, async () =>
        assert.equal(await update(`events/${eventId}`, {venue: "書換え", reconfirmEnabled: false}), 403));
      test(`${eventId}: 旧正式登録(participants update)を拒否`, async () =>
        assert.equal(await update(`participants/p-${eventId}`, {participationConfirmed: true, updatedAt: new Date()}), 403));
      test(`${eventId}: 旧reconfirm回答(participants update)を拒否`, async () =>
        assert.equal(await update(`participants/p-${eventId}`, {reconfirmed: true, attendanceResponse: "attending", updatedAt: new Date()}), 403));
      test(`${eventId}: 旧受付(checkIns update)を拒否`, async () =>
        assert.equal(await update(`checkIns/p-${eventId}`, {checkedIn: true, attendedCount: 1, registeredCountSnapshot: 1, checkedInAt: new Date(), updatedAt: new Date()}), 403));
      test(`${eventId}: 旧経路での参加者作成(participants+checkIns)を拒否`, async () => {
        const id = `n-${eventId}`;
        assert.equal(await commit([
          {path: `participants/${id}`, data: participantDoc(id, eventId)},
          {path: `checkIns/${id}`, data: checkInDoc(id, eventId)},
        ]), 403);
      });
      test(`${eventId}: participants単体のcreateも拒否`, async () =>
        assert.equal(await create("participants", `solo-${eventId}`, participantDoc(`solo-${eventId}`, eventId)), 403));
    }
    test("クライアントからflow=confirmedのイベントを新規作成できない", async () =>
      assert.equal(await create("events", "e-client-confirmed", event("e-client-confirmed", {flow: "confirmed"})), 403));
    test("既存legacyイベントをクライアントからconfirmedへ変換できない", async () =>
      assert.equal(await update("events/e-legacy", {flow: "confirmed"}), 403));
    test("confirmedイベントのflowをクライアントからlegacyへ戻せない", async () =>
      assert.equal(await update("events/e-confirmed", {flow: "legacy"}), 403));
  });

  describe("Rulesの静的検査", () => {
    const rules = fs.readFileSync(RULES_PATH, "utf8");
    test("全ドキュメントに効くワイルドカードallowがない", () => {
      assert.doesNotMatch(rules, /match\s+\/\{[^}]*=\*\*\}/);
    });
    test("programAttendancesのブロックは allow read, write: if false のみ", () => {
      const block = rules.match(/match \/programAttendances\/\{[^}]+\}\s*\{([^}]*)\}/);
      assert.ok(block, "programAttendancesのmatchが必要");
      const allows = block[1].match(/allow[^;]*;/g) || [];
      assert.deepEqual(allows, ["allow read, write: if false;"]);
    });
  });
});
