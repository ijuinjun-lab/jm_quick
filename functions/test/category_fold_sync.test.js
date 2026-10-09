// 区分の値(キャンセルの自動除外)の比較を、Flutter(lib/confirmed/import_profile.dart の comparableCategory)と
// サーバー(confirmed/import_request.js の comparable: NFKC＋空白の除去)で一致させるための確認。
//  - Flutterが使う表(lib/confirmed/category_fold.dart)が、Node の NFKC から作り直した表と完全に同じ
//  - Flutterと同じ手順(表で1文字ずつ置換 → かな＋濁点の合成 → 空白の除去)を、表に載る全文字について
//    「キャンセル」へ差し込み・置き換えた文字列で、サーバーの判定と比べる
//  - 共有の表記ゆれfixture(fixtures/category_variants.json。Flutterのテストも同じものを読む)をサーバーが期待どおりに判定する
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const {OUTPUT, generate, foldEntries, composeEntries} = require("../tools/gen_category_fold");
const {comparable} = require("../confirmed/import_request");

const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", "category_variants.json"), "utf8"));

// Flutter の comparableCategory と同じ手順(表は生成元と同じもの)
const fold = new Map(foldEntries());
const compose = new Map(composeEntries().map(([cp, mark, c]) => [cp * 0x10000 + mark, c]));
function clientComparable(value) {
  const out = [];
  for (const ch of value) {
    const folded = fold.get(ch.codePointAt(0));
    for (const r of folded === undefined ? [ch] : [...folded]) {
      const cp = r.codePointAt(0);
      if (out.length > 0 && (cp === 0x3099 || cp === 0x309A)) {
        const c = compose.get(out[out.length - 1] * 0x10000 + cp);
        if (c !== undefined) { out[out.length - 1] = c; continue; }
      }
      out.push(cp);
    }
  }
  return String.fromCodePoint(...out).replace(/\s+/g, "");
}

test("Flutterの表(category_fold.dart)は、NodeのNFKCから作り直した表と同じ(古い・手で編集した表を使わない)", () => {
  assert.equal(fs.readFileSync(OUTPUT, "utf8"), generate(), "node functions/tools/gen_category_fold.js で作り直してください");
});

test("共有の表記ゆれfixture: サーバーの判定(NFKC＋空白の除去)が期待どおり", () => {
  assert.ok(fixture.variants.length >= 20);
  for (const {value, cancel} of fixture.variants) {
    assert.equal(comparable(value) === comparable(fixture.target), cancel, JSON.stringify(value));
    assert.equal(clientComparable(value) === comparable(fixture.target), cancel, `client: ${JSON.stringify(value)}`);
  }
});

test("表に載る全文字・空白・結合文字を「キャンセル」へ差し込み/置き換えても、Flutterの手順とサーバーの判定が一致する", () => {
  const target = comparable(fixture.target);
  const extra = [0x3099, 0x309A, 0x0301, 0x0020, 0x3000, 0x00A0, 0x200B, 0xFEFF, 0x30FC, 0x304D];
  const chars = [...new Set([...fold.keys(), ...extra, ...[...target].map((c) => c.codePointAt(0))])].map((cp) => String.fromCodePoint(cp));
  const base = [...fixture.target];
  let checked = 0;
  let matches = 0;
  const check = (s) => {
    const server = comparable(s) === target;
    assert.equal(clientComparable(s) === target, server, JSON.stringify(s));
    checked++;
    if (server) matches++;
  };
  for (const x of chars) {
    for (let i = 0; i <= base.length; i++) check([...base.slice(0, i), x, ...base.slice(i)].join(""));
    for (let i = 0; i < base.length; i++) check([...base.slice(0, i), x, ...base.slice(i + 1)].join(""));
  }
  // 半角・全角を混ぜた組み合わせ(各文字をそのまま/表で同じ文字になる別の文字に)
  const variantsOf = (c) => [c, ...[...fold].filter(([, n]) => n === c).map(([cp]) => String.fromCodePoint(cp))];
  const expand = (i) => (i === base.length ? [""] : variantsOf(base[i]).flatMap((v) => expand(i + 1).map((rest) => v + rest)));
  const mixes = expand(0);
  for (const s of mixes) {
    check(s);
    check(` ${s}　`);
  }
  assert.ok(checked > 5000 && matches > mixes.length, `checked=${checked} matches=${matches}`);
});
