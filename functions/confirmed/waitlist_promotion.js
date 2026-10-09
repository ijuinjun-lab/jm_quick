// キャンセル待ち繰り上げ当選(notificationType=waitlistPromotion)の取込: ファイルの内容だけから繰り上げ先を自動判定する。純粋関数のみ。
//
// ■ 管理者にprogram・時間枠・人数を入力させない。ファイルに既にある情報だけで決め、一意に決まらなければ取込を止める。
//   時間枠: シート名(例「15時30分～16時10分」)を時刻の範囲として読む。
//   program: 各行の「キャンセル待ち希望枠」(カンマ区切りの選択肢。例「午後の部（犬）15:30-16:10」)のうち、
//            mapping.waitlist.options の見出し(例「午後の部（犬）」)＋シート名の時間枠に一致する選択肢がちょうど1つ。
//            見出し → programId の対応は import profile が持つ(コードにprogramIdを固定しない)。
//   人数: 各行の「キャンセル待ち希望人数」(「N名」)。元の申込の参加人数の列は使わない。
//   トークショー等、繰り上げ先以外のprogramは作らない(元の申込の希望が残っていても今回の当選ではない)。
// ■ 判定は取込対象の行(自動除外・管理者の除外を除く)だけで行う。対象の全行が同じprogram・同じ時間枠でなければ止める。
// ■ ファイル名に種別(犬・猫など、options の kind)があれば、判定したprogramの種別と一致しなければ止める。

const {MAX_PLANNED_COUNT} = require("../programs");

const {NOTIFICATION_TYPES, NOTIFICATION_TYPE_VALUES} = require("./notification_type");

// 判定した繰り上げ先を計画へ渡すための列名(原本の列ではない。計画・許可の鍵の材料として使う)
const WAITLIST_SLOT_COLUMN = "繰り上げ時間枠（自動判定）";
const WAITLIST_COUNT_COLUMN = "繰り上げ人数（自動判定）";

const normalize = (value) => String(value === undefined || value === null ? "" : value).normalize("NFKC").trim();
const squash = (value) => normalize(value).replace(/\s+/g, "");

// 「15時30分～16時10分」「15:30〜16:10」「15:30-16:10」 → {start, end}(分)。読めなければnull。
// 時刻は 時(0-23)＋分(00-59)。「時」だけ(「15時～16時」)は分を0とする。
function parseTimeRange(text) {
  const s = squash(text).replace(/[〜~～－―‐ー−]/g, "-");
  const time = String.raw`(\d{1,2})(?:時(?:(\d{1,2})分)?|:(\d{2}))`;
  const match = new RegExp(`^${time}-${time}$`).exec(s);
  if (!match) return null;
  const toMinutes = (h, m1, m2) => {
    const hour = Number(h);
    const minute = Number(m1 ?? m2 ?? 0);
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  };
  const start = toMinutes(match[1], match[2], match[3]);
  const end = toMinutes(match[4], match[5], match[6]);
  if (start === null || end === null || end <= start) return null;
  return {start, end};
}
const sameRange = (a, b) => a.start === b.start && a.end === b.end;

// 「N名」「N」 → 整数。読めなければnull。
function parsePeopleCount(text) {
  const match = /^(\d{1,4})名?$/.exec(squash(text));
  return match ? Number(match[1]) : null;
}

// 行の「キャンセル待ち希望枠」 → 選択肢の配列(カンマ・読点区切り)
const splitOptions = (text) => normalize(text).split(/[,、，]/).map((x) => x.trim()).filter((x) => x !== "");

// 選択肢の文字列 → {label, programId, kind, slotText, range} | null(どの見出しにも当たらない)
function matchOption(text, options) {
  const s = normalize(text);
  for (const option of options) {
    const label = normalize(option.label);
    if (!s.startsWith(label)) continue;
    const slotText = s.slice(label.length).trim();
    return {label: option.label, programId: option.programId, kind: option.kind || null, slotText, range: parseTimeRange(slotText)};
  }
  return null;
}

// request: {sourceFileName, sourceSheetName, sourceSheetCandidates, headers, rows:[{sourceRowNumber, values}]}
//   sourceSheetCandidates: ファイル内の、参加者リストの形式に合うシート名すべて。シートを選ぶ=時間枠を選ぶことになるため、
//   1枚(=sourceSheetName)でなければ判定しない(画面でもAPI直呼びでも、複数シートのファイルから1枚を選んで取り込めない)。
// waitlist: 正規化済みmapping.waitlist {optionsColumn, countColumn, options:[{label, programId, kind}]}
// excluded: 取込対象外の行番号(Set)
// 戻り値: {ok:true, programId, kind, slotLabel, counts: Map(行番号→人数)} | {ok:false, reasons:[{code, sourceRowNumber?}]}
function determineWaitlistPromotion({request, waitlist, excluded}) {
  const reasons = [];
  const fail = (code, extra = {}) => reasons.push({code, ...extra});
  if (typeof request.sourceSheetName !== "string" || request.sourceSheetName.trim() === "") {
    fail("sheet-name-missing");
    return {ok: false, reasons};
  }
  const sheets = request.sourceSheetCandidates;
  if (!Array.isArray(sheets) || sheets.length === 0) {
    fail("sheet-list-missing");
    return {ok: false, reasons};
  }
  if (!sheets.includes(request.sourceSheetName)) {
    fail("sheet-not-in-list");
    return {ok: false, reasons};
  }
  if (sheets.length > 1) {
    fail("multiple-sheets", {sheetCount: sheets.length});
    return {ok: false, reasons};
  }
  const range = parseTimeRange(request.sourceSheetName);
  if (!range) {
    fail("sheet-name-not-time-range");
    return {ok: false, reasons};
  }
  const optionsIndex = request.headers.indexOf(waitlist.optionsColumn);
  const countIndex = request.headers.indexOf(waitlist.countColumn);
  const valueOf = (row, index) => (index >= 0 && index < row.values.length ? row.values[index] : "");
  const targets = request.rows.filter((row) => !excluded.has(row.sourceRowNumber));
  if (targets.length === 0) {
    fail("no-target-rows");
    return {ok: false, reasons};
  }

  const counts = new Map();
  const found = []; // 行ごとに一致した選択肢
  for (const row of targets) {
    const n = row.sourceRowNumber;
    const matches = splitOptions(valueOf(row, optionsIndex))
      .map((text) => matchOption(text, waitlist.options))
      .filter((m) => m && m.range && sameRange(m.range, range));
    const programs = new Set(matches.map((m) => m.programId));
    if (matches.length === 0) fail("slot-not-in-waitlist-options", {sourceRowNumber: n});
    else if (programs.size > 1) fail("slot-matches-multiple-options", {sourceRowNumber: n});
    else found.push({n, match: matches[0]});
    const rawCount = valueOf(row, countIndex);
    if (squash(rawCount) === "") fail("count-missing", {sourceRowNumber: n});
    else {
      const count = parsePeopleCount(rawCount);
      if (count === null) fail("count-unparsable", {sourceRowNumber: n});
      else if (count < 1) fail("count-not-positive", {sourceRowNumber: n});
      else if (count > MAX_PLANNED_COUNT) fail("count-over-limit", {sourceRowNumber: n});
      else counts.set(n, count);
    }
  }
  const programIds = new Set(found.map((f) => f.match.programId));
  if (programIds.size > 1) fail("programs-not-uniform");
  if (reasons.length > 0) return {ok: false, reasons};

  const {programId, kind} = found[0].match;
  // 時間枠の表示は、ファイルの選択肢の表記(例「15:30-16:10」)をそのまま使う(同じ範囲なら全行で同じ)。
  const slotLabels = new Set(found.map((f) => f.match.slotText));
  const slotLabel = slotLabels.size === 1 ? [...slotLabels][0] : found[0].match.slotText;
  // ファイル名の種別(犬・猫など)と、判定したprogramの種別が矛盾しないこと(書かれていなければ確認しない)
  const kinds = [...new Set(waitlist.options.map((o) => o.kind).filter((k) => typeof k === "string" && k !== ""))];
  const fileName = normalize(request.sourceFileName);
  const fileKinds = kinds.filter((k) => fileName.includes(normalize(k)));
  if (fileKinds.length > 0 && (!kind || !fileKinds.includes(kind) || fileKinds.length > 1)) {
    return {ok: false, reasons: [{code: "file-name-kind-conflict"}]};
  }
  return {ok: true, programId, kind, slotLabel, counts};
}

module.exports = {
  NOTIFICATION_TYPES, NOTIFICATION_TYPE_VALUES, WAITLIST_SLOT_COLUMN, WAITLIST_COUNT_COLUMN,
  parseTimeRange, parsePeopleCount, determineWaitlistPromotion,
};
