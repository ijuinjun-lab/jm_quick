#!/usr/bin/env node
// lib/confirmed/category_fold.dart(区分の値をサーバーと同じNFKCで比べるための表)を生成する。
//
//   node functions/tools/gen_category_fold.js        # 表を書き出す(Node の String.normalize が正本)
//
// 表の内容が NFKC と一致していることは functions/test/category_fold_sync.test.js が確認する(表が古ければ失敗)。

const fs = require("fs");
const path = require("path");

const OUTPUT = path.join(__dirname, "..", "..", "lib", "confirmed", "category_fold.dart");
const WHITESPACE = /\s/;
const isKana = (c) => { const x = c.codePointAt(0); return x >= 0x3041 && x <= 0x30FF; };

// 1文字 → NFKC。対象: 全角・半角形(U+FF00〜FFEF)、NFKCでかな・空白を含む文字になる文字。
function foldEntries() {
  const entries = [];
  for (let cp = 0; cp <= 0x10FFFF; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    const s = String.fromCodePoint(cp);
    const n = s.normalize("NFKC");
    if (n === s) continue;
    const chars = [...n];
    if ((cp >= 0xFF00 && cp <= 0xFFEF) || chars.some(isKana) || chars.some((c) => WHITESPACE.test(c))) entries.push([cp, n]);
  }
  return entries;
}

// かな ＋ 結合用の濁点・半濁点 → 合成した1文字(NFC)。
function composeEntries() {
  const entries = [];
  for (let cp = 0x3041; cp <= 0x30FF; cp++) {
    for (const mark of [0x3099, 0x309A]) {
      const n = String.fromCodePoint(cp, mark).normalize("NFC");
      if ([...n].length === 1) entries.push([cp, mark, n.codePointAt(0)]);
    }
  }
  return entries;
}

const hex = (n) => "0x" + n.toString(16).toUpperCase().padStart(4, "0");
const esc = (s) => [...s].map((c) => `\\u{${c.codePointAt(0).toString(16).toUpperCase()}}`).join("");

function generate() {
  const lines = [
    "// 生成ファイル(手で編集しない。functions/tools/gen_category_fold.js で作る)。",
    "// 区分の値の比較(キャンセルの自動除外)を、サーバー(import_request.js の String.normalize(\"NFKC\") ＋ 空白の除去)と",
    "// 同じ結果にするための、NFKCの一部の表。対象: 全角・半角形(U+FF00〜FFEF)、NFKCでかな・空白を含む文字になる文字、",
    "// かな＋濁点・半濁点の合成。表が NFKC と一致することは functions/test/category_fold_sync.test.js が確認する。",
    "",
    "/// 1文字(コードポイント) → NFKC の結果。表に無い文字は変えない。",
    "const Map<int, String> categoryFoldTable = {",
    ...foldEntries().map(([cp, n]) => `  ${hex(cp)}: '${esc(n)}',`),
    "};",
    "",
    "/// かな ＋ 結合用の濁点(U+3099)・半濁点(U+309A) → 合成した1文字(NFC)。キーは (かな << 16) | 結合文字。",
    "const Map<int, int> categoryComposeTable = {",
    ...composeEntries().map(([cp, mark, c]) => `  (${hex(cp)} << 16) | ${hex(mark)}: ${hex(c)},`),
    "};",
    "",
  ];
  return lines.join("\n");
}

if (require.main === module) {
  fs.writeFileSync(OUTPUT, generate());
  process.stdout.write(`${path.relative(process.cwd(), OUTPUT)} を書き出しました。\n`);
}

module.exports = {OUTPUT, generate, foldEntries, composeEntries};
