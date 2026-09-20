// テスト専用の完全な架空データ。実在の氏名・メールアドレス・自由記述は一切含まない。
// 列名は構造の確認用(取り込まない列も含める)。メールは予約ドメイン example.invalid のみ。

const HEADERS = ["区分", "rd", "氏名", "かな", "メールアドレス", "都道府県", "午前参加時間", "午前参加人数",
  "午後参加時間", "午後参加人数", "トークショー", "トークショー人数", "キャンセル待希望人数", "思いやご意見",
  "登録日時"];

const NOT_ATTENDING = "参加を希望しない";
const ATTENDING = "参加を希望する";
const UNMAPPED_MARKER = "この値は取り込まれない列の架空テキスト";

function pad(i, width = 3) { return String(i).padStart(width, "0"); }

// 既定は「午前(alpha)とトーク(gamma)に参加、午後(beta)は不参加」の正常な行。
function defaults(i) {
  return {
    "区分": "新規申込",
    "rd": `R${pad(i, 4)}`,
    "氏名": `架空テスト${pad(i)}`,
    "かな": "かくうてすと",
    "メールアドレス": `synthetic${i}@example.invalid`,
    "都道府県": "架空県",
    "午前参加時間": "10:00-11:00",
    "午前参加人数": "2",
    "午後参加時間": NOT_ATTENDING,
    "午後参加人数": "",
    "トークショー": ATTENDING,
    "トークショー人数": "1",
    "キャンセル待希望人数": "9名",
    "思いやご意見": UNMAPPED_MARKER,
    "登録日時": "2026年01月02日 03時04分05秒",
  };
}

function makeRecord(i, overrides = {}) {
  const values = {...defaults(i), ...overrides};
  return HEADERS.map((header) => values[header]);
}

// programIdは任意の名前(実際のprogram名をコードに固定しないことの確認)。
function syntheticMapping(overrides = {}) {
  return {
    version: 3,
    participant: {
      externalIdColumn: "rd", nameColumn: "氏名", kanaColumn: "かな",
      emailColumn: "メールアドレス", registeredAtColumn: "登録日時",
    },
    rowChecks: [{column: "区分", allowedValues: ["新規申込"]}],
    programs: [
      {programId: "alpha", participationColumn: "午前参加時間", notAttendingValues: [NOT_ATTENDING],
        slotColumn: "午前参加時間", slotFormat: "timeRange", countColumn: "午前参加人数"},
      {programId: "beta", participationColumn: "午後参加時間", notAttendingValues: [NOT_ATTENDING],
        slotColumn: "午後参加時間", slotFormat: "timeRange", countColumn: "午後参加人数"},
      {programId: "gamma", participationColumn: "トークショー", attendingValues: [ATTENDING],
        notAttendingValues: [NOT_ATTENDING], countColumn: "トークショー人数"},
    ],
    ...overrides,
  };
}

// n行の表。overridesFor(i) が返す値で行ごとに上書きできる(iは1始まり)。
function makeTable(n, overridesFor = () => ({})) {
  return {headers: [...HEADERS], records: Array.from({length: n}, (_, k) => makeRecord(k + 1, overridesFor(k + 1)))};
}

const EVENT_DATE = "2026-11-30";
const FILE_HASH = "a".repeat(64);

function batchInput(overrides = {}) {
  return {
    eventId: "event1", batchId: "batchA", sequence: 1, label: "第1回", sourceFileName: "synthetic.csv",
    fileHash: FILE_HASH, mapping: syntheticMapping(), eventDate: EVENT_DATE, ...overrides,
  };
}

// 再現性のある疑似乱数(テストの安定のため)。
function seededRandom(seed) {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x100000000;
  };
}

module.exports = {HEADERS, NOT_ATTENDING, ATTENDING, UNMAPPED_MARKER, EVENT_DATE, FILE_HASH, makeRecord, makeTable,
  syntheticMapping, batchInput, seededRandom};
