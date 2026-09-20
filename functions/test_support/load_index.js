// functions/index.js を、メモリ上のFirestoreと外部通信スタブだけで読み込むテスト用ローダー。
// - firebase-admin は差し替え(実Firebaseへ接続しない)
// - firebase-functions は本物を使う(onCall/onScheduleの `.run` でハンドラを直接呼べる)
// - fetch はスタブ(メールAPIへの実通信は発生しない。想定外のURLは即エラー)

const path = require("node:path");
const {FieldValue} = require("./fake_firestore");

const FUNCTIONS_DIR = path.join(__dirname, "..");
const FAKE_MAIL_ORIGIN = "https://mail-api.invalid";

function fakeModule(filename, exports) {
  require.cache[filename] = {id: filename, filename, loaded: true, exports, children: [], paths: []};
}

function loadIndex(db) {
  process.env.MAIL_API_URL = FAKE_MAIL_ORIGIN;
  process.env.MAIL_API_KEY = "test-only-key";
  process.env.APP_BASE_URL = "https://app.invalid";
  const resolve = (id) => require.resolve(id, {paths: [FUNCTIONS_DIR]});
  fakeModule(resolve("firebase-admin/app"), {initializeApp: () => {}});
  fakeModule(resolve("firebase-admin/firestore"), {getFirestore: () => db, FieldValue});
  const indexPath = path.join(FUNCTIONS_DIR, "index.js");
  delete require.cache[indexPath];
  return require(indexPath);
}

// fetchを差し替え、呼び出しを記録する。FAKE_MAIL_ORIGIN以外への通信は例外にする。
function stubFetch() {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    if (!String(url).startsWith(FAKE_MAIL_ORIGIN)) {
      throw new Error(`unexpected outbound request blocked by test: ${url}`);
    }
    const body = JSON.parse(init.body);
    calls.push({url: String(url), body});
    return {ok: true, status: 200, json: async () => ({ok: true, messageId: "test-message-id"})};
  };
  return {calls, restore: () => { globalThis.fetch = original; }};
}

module.exports = {loadIndex, stubFetch};
