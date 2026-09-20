// 新方式(flow=confirmed)のコードが守るべき不変条件を、ソースコードの走査で固定する。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {test} = require("node:test");

const FUNCTIONS_DIR = path.join(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(FUNCTIONS_DIR, file), "utf8");

function listFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, {withFileTypes: true}).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? listFiles(full) : [full];
  });
}

// 新方式のファイル: 個別に列挙したもの + functions/confirmed/ 配下すべて。
// 新方式のコードを追加したらここに追加する(confirmed/ 配下に置けば自動的に対象)。
const CONFIRMED_FLOW_FILES = [
  path.join(FUNCTIONS_DIR, "flow.js"),
  path.join(FUNCTIONS_DIR, "programs.js"),
  ...listFiles(path.join(FUNCTIONS_DIR, "confirmed")),
];

test("新方式のコードは旧参加者ドキュメントの人数フィールド(registeredCount)を参照しない", () => {
  for (const file of CONFIRMED_FLOW_FILES) {
    assert.ok(fs.existsSync(file), `${file} が存在しません`);
    assert.doesNotMatch(fs.readFileSync(file, "utf8"), /registeredCount/,
      `${path.relative(FUNCTIONS_DIR, file)} が registeredCount を参照しています。人数の正本は programAttendances.plannedCount です`);
  }
});

function handlerSource(source, exportName) {
  const start = source.indexOf(`exports.${exportName} =`);
  assert.notEqual(start, -1, `${exportName}が見つかりません`);
  const next = source.indexOf("\nexports.", start + 1);
  return source.slice(start, next === -1 ? undefined : next);
}

test("programAttendancesへ書込む実装があるなら、旧削除callable(participant/event)は新方式を拒否するか掃除すること(Phase 8までに専用削除が必須)", () => {
  const usage = /collection\(["']programAttendances["']\)/;
  // 実装ファイル: functions/直下とfunctions/confirmed/直下の.js(テストは含めない)
  const sourceDirs = [FUNCTIONS_DIR, path.join(FUNCTIONS_DIR, "confirmed")];
  const sources = sourceDirs.flatMap((dir) => fs.readdirSync(dir)
    .filter((name) => name.endsWith(".js"))
    .map((name) => fs.readFileSync(path.join(dir, name), "utf8")));
  const index = read("index.js");
  const deleteHandlers = [handlerSource(index, "deleteParticipant"), handlerSource(index, "deleteEvent")];
  const writesAttendances = sources.some((source) => usage.test(source));
  for (const handler of deleteHandlers) {
    if (writesAttendances) {
      // 孤児データを残さない: 新方式は拒否する(assertDeletable*)か、programAttendancesを掃除している。
      assert.ok(/assertDeletable/.test(handler) || usage.test(handler), "旧削除callableが新方式のデータを黙って孤児にします");
    }
    // 専用削除(admin認証つきカスケード)を作るまでは、忘れないようTODOタグが残っていること。
    assert.match(handler, /TODO\(PHASE-8-REQUIRED\)/);
  }
});
