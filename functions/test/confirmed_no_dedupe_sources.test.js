// 新方式の取込ロジック(functions/confirmed/)が守るべき方針を、ソースコードの走査で固定する。
//  - 人物単位の重複排除・一意制約・行のskipを実装していない(主催者の全レコードを欠落なく処理する)
//  - 旧参加者ドキュメントの人数フィールドを参照しない(人数の正本はplannedCountのみ)
//  - 純粋関数のみ: Firebase・Firestore・ネットワークに触れない
//  - Phase 3ではcallableとして公開していない(index.jsから読み込まれていない)
// 禁止語はこのファイル自身が走査対象に入らないよう、連結して組み立てている(このファイルはconfirmed/の外にある)。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {test} = require("node:test");

const FUNCTIONS_DIR = path.join(__dirname, "..");
const CONFIRMED_DIR = path.join(FUNCTIONS_DIR, "confirmed");

function listFiles(dir) {
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? listFiles(full) : [full];
  });
}
const files = listFiles(CONFIRMED_DIR).filter((f) => /\.(js|json)$/.test(f));
const rel = (file) => path.relative(FUNCTIONS_DIR, file);

test("走査対象のファイルが存在する(走査が空振りしていない)", () => {
  const names = files.map(rel);
  for (const expected of ["confirmed/import_mapping.js", "confirmed/import_rows.js", "confirmed/import_batch_plan.js",
    "confirmed/test/no_loss.test.js"]) {
    assert.ok(names.includes(expected), `${expected} が見つかりません`);
  }
});

test("人物単位の重複排除・一意制約・行のskipの概念をコードに持ち込まない", () => {
  const forbidden = ["participant" + "Keys", "identity" + "Key", "skipped" + "Count", "walkIn" + "Registrations"];
  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    for (const token of forbidden) assert.ok(!text.includes(token), `${rel(file)} に ${token} があります`);
  }
});

test("旧参加者ドキュメントの人数フィールドを参照しない(人数の正本はplannedCountのみ)", () => {
  const token = "registered" + "Count";
  for (const file of files) {
    assert.ok(!fs.readFileSync(file, "utf8").includes(token), `${rel(file)} が ${token} を参照しています`);
  }
});

test("純粋関数のみ: Firebase・Firestore・ネットワークを使わない", () => {
  const forbidden = ["firebase-admin", "firebase-functions", "getFirestore", "fetch(", "node:http", "node:https", "node:net",
    "node:dns", "require(\"http", "require('http", "XMLHttpRequest", "child_process"];
  for (const file of files.filter((f) => !f.endsWith(".json"))) {
    const text = fs.readFileSync(file, "utf8");
    for (const token of forbidden) assert.ok(!text.includes(token), `${rel(file)} が ${token} を使っています`);
  }
});

test("取込ロジック(import_*)はまだcallableへ接続していない(index.jsがconfirmed/から読み込むのはaccess_roleだけ)", () => {
  const index = fs.readFileSync(path.join(FUNCTIONS_DIR, "index.js"), "utf8");
  const required = [...index.matchAll(/require\("\.\/confirmed\/([^"]+)"\)/g)].map((m) => m[1]);
  assert.deepEqual(required, ["access_role"]);
  assert.doesNotMatch(index, /import_(mapping|rows|batch_plan)/);
});

test("テスト・fixtureに実CSV由来のデータが入っていない(実在の氏名・メールの形跡がない)", () => {
  // メールアドレスは予約TLD(.invalid: RFC 2606。実在しない)のみ。それ以外のドメインを含むメール形式の文字列を許さない。
  const emailLike = /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/g;
  for (const file of files) {
    const matches = fs.readFileSync(file, "utf8").match(emailLike) || [];
    for (const match of matches) {
      assert.ok(/\.invalid$/i.test(match), `${rel(file)} に想定外のメール形式: ${match}`);
    }
  }
  assert.ok(!files.some((f) => /\.csv$/i.test(f)), "confirmed/ にCSVファイルがあります");
});
