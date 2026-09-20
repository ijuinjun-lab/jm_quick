// ローカルのFirestore Emulator(localhostのみ・実Firestoreへ接続しない)でRulesを検証するための共通ハーネス。
// キャッシュ済みのエミュレータJARとJavaがある場合だけ使える(ダウンロードはしない)。
// 認証ヘッダなしのREST呼び出しにはRulesが適用され、"Bearer owner" はRulesをバイパスする(初期データ投入用)。
// "Bearer <署名なしJWT>" は、エミュレータではrequest.authを持つログイン済みクライアントとして扱われる。
const {spawn, spawnSync} = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const PROJECT = "demo-jm-quick";
const RULES_PATH = path.join(__dirname, "..", "..", "firestore.rules");

function findJar() {
  if (process.env.FIRESTORE_EMULATOR_JAR) return process.env.FIRESTORE_EMULATOR_JAR;
  const dir = path.join(os.homedir(), ".cache", "firebase", "emulators");
  if (!fs.existsSync(dir)) return null;
  const jar = fs.readdirSync(dir).find((name) => /^cloud-firestore-emulator-.*\.jar$/.test(name));
  return jar ? path.join(dir, jar) : null;
}

function skipReason() {
  const jar = findJar();
  if (spawnSync("java", ["-version"]).status !== 0) return "javaが見つかりません";
  if (!jar || !fs.existsSync(jar)) return "キャッシュ済みのFirestore Emulator JARがありません";
  return false;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => { const {port} = server.address(); server.close(() => resolve(port)); });
    server.on("error", reject);
  });
}

function encode(value) {
  if (value === null || value === undefined) return {nullValue: null};
  if (typeof value === "string") return {stringValue: value};
  if (typeof value === "boolean") return {booleanValue: value};
  if (typeof value === "number") return Number.isInteger(value) ? {integerValue: String(value)} : {doubleValue: value};
  if (value instanceof Date) return {timestampValue: value.toISOString()};
  if (Array.isArray(value)) return {arrayValue: {values: value.map(encode)}};
  return {mapValue: {fields: Object.fromEntries(Object.entries(value).map(([k, v]) => [k, encode(v)]))}};
}
const encodeFields = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, encode(v)]));

// ログイン済みクライアントを表す署名なしJWT(エミュレータ専用)。claimsはRulesのrequest.auth.tokenに入る。
function unsignedToken(uid, claims = {}) {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  return `${b64({alg: "none", typ: "JWT"})}.${b64({sub: uid, user_id: uid, iat: 1, firebase: {sign_in_provider: "password"}, ...claims})}.`;
}

async function startEmulator() {
  const jar = findJar();
  const port = await freePort();
  const wsPort = await freePort();
  const origin = `http://127.0.0.1:${port}`;
  const child = spawn("java", ["-jar", jar, "--host=127.0.0.1", `--port=${port}`, `--websocket_port=${wsPort}`], {stdio: ["ignore", "pipe", "pipe"]});
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("emulator did not start")), 40000);
    const onData = (chunk) => { if (String(chunk).includes("Dev App Server is now running")) { clearTimeout(timer); resolve(); } };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", () => reject(new Error("emulator exited early")));
  });
  const base = `${origin}/v1/projects/${PROJECT}/databases/(default)/documents`;

  // token: undefined=未認証 / "owner"=Rulesバイパス / それ以外=Bearerとして送るJWT文字列
  async function request(method, url, body, token) {
    const response = await fetch(url, {
      method,
      headers: {"Content-Type": "application/json", ...(token ? {Authorization: `Bearer ${token}`} : {})},
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return response.status;
  }
  const docUrl = (docPath, query = "") => `${base}/${docPath}${query}`;
  return {
    origin, base,
    stop: () => child.kill(),
    async loadRules(content) {
      const status = await request("PUT", `${origin}/emulator/v1/projects/${PROJECT}:securityRules`, {rules: {files: [{name: "firestore.rules", content}]}});
      if (status !== 200) throw new Error(`rules load failed: ${status}`);
    },
    seed: (docPath, data) => request("PATCH", docUrl(docPath), {fields: encodeFields(data)}, "owner"),
    get: (docPath, token) => request("GET", docUrl(docPath), undefined, token),
    list: (collection, token) => request("GET", docUrl(collection), undefined, token),
    create: (collection, id, data, token) => request("POST", docUrl(collection, `?documentId=${id}`), {fields: encodeFields(data)}, token),
    update: (docPath, data, token) => {
      const mask = Object.keys(data).map((key) => `updateMask.fieldPaths=${key}`).join("&");
      return request("PATCH", docUrl(docPath, `?${mask}&currentDocument.exists=true`), {fields: encodeFields(data)}, token);
    },
    set: (docPath, data, token) => request("PATCH", docUrl(docPath), {fields: encodeFields(data)}, token),
    remove: (docPath, token) => request("DELETE", docUrl(docPath), undefined, token),
  };
}

module.exports = {PROJECT, RULES_PATH, skipReason, startEmulator, unsignedToken};
