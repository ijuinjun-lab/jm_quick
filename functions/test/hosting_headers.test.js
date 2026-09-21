// Phase 10D: Hostingのヘッダ構成の構造テスト。参加証・受付・管理・当日参加登録のURLに X-Robots-Tag: noindex, nofollow を付け、
// サイト全体(トップ・静的ファイル)は検索対象から外さない。既存のCache-Control設定は維持する。
// (robots.txtはクロールの指示であってアクセス制御ではない。参加証・受付URLの秘密性は publicId・認証・App Check・rate limit で守る。
//  robots.txtでDisallowすると、クローラーがページを取得せずnoindexのヘッダを読めなくなるため、robots.txtは追加していない。)
// Hostingのglob照合は firebase-tools 同梱のsuperstatic(minimatch)で、次のパスが意図どおり一致することを確認済み:
//   /p/** → /p/abc、/reception・/reception/**、/e/**、/admin・/admin/**、/demo-admin・/console。 /・/robots.txt・/main.dart.js は一致しない。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {test} = require("node:test");

const ROOT = path.join(__dirname, "..", "..");
const config = JSON.parse(fs.readFileSync(path.join(ROOT, "firebase.json"), "utf8"));
const headers = config.hosting.headers;
const NOINDEX_SOURCES = ["/p/**", "/reception", "/reception/**", "/e/**", "/admin", "/admin/**", "/demo-admin", "/demo-admin/**", "/console", "/console/**"];

test("既存のCache-Control(全パス)が維持されている", () => {
  const all = headers.find((h) => h.source === "**");
  assert.ok(all);
  assert.deepEqual(all.headers, [{key: "Cache-Control", value: "no-cache, no-store, max-age=0, must-revalidate"}]);
});

test("参加証(/p/**)・受付(/reception)・管理・当日参加登録のURLに X-Robots-Tag: noindex, nofollow が付く", () => {
  for (const source of NOINDEX_SOURCES) {
    const entry = headers.find((h) => h.source === source);
    assert.ok(entry, `${source}のヘッダ設定`);
    assert.deepEqual(entry.headers, [{key: "X-Robots-Tag", value: "noindex, nofollow"}], source);
  }
});

test("サイト全体・静的ファイルには noindex を付けない(誤ってサイト全体を検索対象外にしない)", () => {
  const all = headers.find((h) => h.source === "**");
  assert.equal(all.headers.some((h) => /robots/i.test(h.key)), false);
  for (const entry of headers) {
    if (entry.source === "**") continue;
    assert.ok(NOINDEX_SOURCES.includes(entry.source), `想定外のヘッダ設定: ${entry.source}`);
    assert.equal(/^\/?\*\*?$/.test(entry.source), false);
  }
});

test("SPAのrewriteは従来どおり(全パスがindex.html)。robots.txtは追加していない", () => {
  assert.deepEqual(config.hosting.rewrites, [{source: "**", destination: "/index.html"}]);
  assert.equal(fs.existsSync(path.join(ROOT, "web", "robots.txt")), false);
});
