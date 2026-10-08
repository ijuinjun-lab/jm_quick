// 参加者の「HEBEL属性」(申込フォームの設問「HEBEL HAUSにお住まいですか」の回答)。受付での確認専用。純粋関数のみ。
//
// ■ 単純なboolean(住んでいる/いない)にはしない。申込フォームの選択肢の意味をそのまま区別する:
//   hebelHaus   ← 「ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）」
//   hebelMaison ← 「ヘーベルメゾンにお住まい」
//   none        ← 「いいえ」
//   unset       ← 列はあるがセルが空(エラーにも警告にもしない)
//   unknown     ← 上のどれにも当たらない値。勝手に none 等へ丸めず、取込前の検証で警告(確認が必要)にする
// ■ 保存(participant.hebelResidence): {category, rawValue}。rawValueはセルの原文(前後の空白だけ除去。空ならnull)で監査用。
//   HEBEL属性の列が無いファイル・既存のparticipantはフィールド自体を持たない(属性なしはエラーにしない)。
// ■ 当選メール・リマインド・Web参加証・QRには入れない(受付画面の表示だけに使う)。

const HEBEL_RESIDENCE = Object.freeze({
  HEBEL_HAUS: "hebelHaus",
  HEBEL_MAISON: "hebelMaison",
  NONE: "none",
  UNSET: "unset",
  UNKNOWN: "unknown",
});

// 申込フォームの選択肢(原文) → 分類。表示名は原文の意味を尊重する(「いいえ」は設問への否定の回答)。
const OPTIONS = Object.freeze([
  {category: HEBEL_RESIDENCE.HEBEL_HAUS, option: "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）",
    label: "ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）"},
  {category: HEBEL_RESIDENCE.HEBEL_MAISON, option: "ヘーベルメゾンにお住まい", label: "ヘーベルメゾンにお住まい"},
  {category: HEBEL_RESIDENCE.NONE, option: "いいえ", label: "該当なし（いいえ）"},
]);

const LABELS = Object.freeze({
  ...Object.fromEntries(OPTIONS.map((o) => [o.category, o.label])),
  [HEBEL_RESIDENCE.UNSET]: "未設定（空欄）",
  [HEBEL_RESIDENCE.UNKNOWN]: "未知のHEBEL属性",
});

// 集計・表示の順序。
const CATEGORY_ORDER = Object.freeze([
  HEBEL_RESIDENCE.HEBEL_HAUS, HEBEL_RESIDENCE.HEBEL_MAISON, HEBEL_RESIDENCE.NONE, HEBEL_RESIDENCE.UNSET, HEBEL_RESIDENCE.UNKNOWN,
]);
const CATEGORIES = new Set(CATEGORY_ORDER);
const MAX_RAW_VALUE_LENGTH = 200;

// 比較用の正規化(原文は変えない): 全角・半角の揺れ(NFKC)、ノーブレークスペース(文字・「&#160;」表記)、空白の有無。
function comparable(text) {
  return text.replace(/&#160;|&nbsp;/gi, " ").normalize("NFKC").replace(/\s+/g, "");
}
const OPTION_BY_COMPARABLE = new Map(OPTIONS.map((o) => [comparable(o.option), o.category]));

// セルの値 → {category, rawValue}。
function classifyHebelResidence(value) {
  const rawValue = value === undefined || value === null ? "" : String(value).trim();
  if (rawValue === "") return {category: HEBEL_RESIDENCE.UNSET, rawValue: null};
  const category = OPTION_BY_COMPARABLE.get(comparable(rawValue));
  return {category: category || HEBEL_RESIDENCE.UNKNOWN, rawValue};
}

function hebelResidenceLabel(category) {
  return LABELS[category] || LABELS[HEBEL_RESIDENCE.UNKNOWN];
}

// 取込前の検証の集計。categories: 行ごとの分類(配列)。全分類を固定の順序で返す(0件も含む)。
function hebelResidenceSummary(categories) {
  const counts = Object.fromEntries(CATEGORY_ORDER.map((c) => [c, 0]));
  for (const category of categories) counts[CATEGORIES.has(category) ? category : HEBEL_RESIDENCE.UNKNOWN] += 1;
  return CATEGORY_ORDER.map((category) => ({category, label: LABELS[category], count: counts[category]}));
}

// 受付画面に返す形。participant正本にフィールドが無ければnull(表示しない)。
// 想定外の形・分類は丸めずに「未知」とし、原文があれば(受付スタッフが読めるように)添える。
function hebelResidenceView(field) {
  if (field === undefined || field === null) return null;
  const isObject = typeof field === "object" && !Array.isArray(field);
  const category = isObject && CATEGORIES.has(field.category) ? field.category : HEBEL_RESIDENCE.UNKNOWN;
  const view = {category, label: hebelResidenceLabel(category)};
  const raw = isObject && typeof field.rawValue === "string" ? field.rawValue.trim().slice(0, MAX_RAW_VALUE_LENGTH) : "";
  if (category === HEBEL_RESIDENCE.UNKNOWN && raw !== "") view.rawValue = raw;
  return view;
}

module.exports = {
  HEBEL_RESIDENCE, CATEGORY_ORDER, classifyHebelResidence, hebelResidenceLabel, hebelResidenceSummary, hebelResidenceView,
};
