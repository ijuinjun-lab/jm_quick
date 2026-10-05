// USER-REPORTED AGGREGATES ONLY — NOT sampleLIST.csv or an anonymized copy of it.
// 原本未取得。期待集計を再現する完全な架空データ。行順・氏名・人数・枠の組合せ・残存人数の行は架空。
const {mapping: baseMapping} = require("./participation_fixture");
const EXPECTED_TYPES = {dog: 6, cat: 7, dog_cat: 1, talk: 48, dog_talk: 36, cat_talk: 8, dog_cat_talk: 14};
const EXPECTED_SLOTS = {
  "program-1": {"10:30–11:10": 5, "11:10–11:50": 9, "11:50–12:30": 16},
  "program-2": {"14:10–14:50": 46, "14:50–15:30": 9, "15:30–16:10": 2},
};
const HEADERS = ["氏名", "かな", "メールアドレス", "登録日時", "午前参加時間", "午前参加人数", "午後参加時間", "午後参加人数", "トークショー", "トークショー人数"];
const mapping = {...baseMapping, participant: {...baseMapping.participant, registeredAtColumn: "登録日時"}};
function makeSyntheticSample() {
  const slots = Object.fromEntries(Object.entries(EXPECTED_SLOTS).map(([id, counts]) =>
    [id, Object.entries(counts).flatMap(([label, n]) => Array(n).fill(label))]));
  const positions = {"program-1": 0, "program-2": 0};
  const residualLeft = {cat: 1, dog: 2};
  const rows = [];
  const residuals = [];
  for (const [expectedType, count] of Object.entries(EXPECTED_TYPES)) {
    for (let i = 0; i < count; i++) {
      const ordinal = rows.length + 1;
      const cells = {"氏名": `匿名検証${String(ordinal).padStart(3, "0")}`, "かな": "とくめいけんしょう",
        "メールアドレス": `synthetic${ordinal}@example.invalid`, "登録日時": "2026年01月02日 03時04分05秒"};
      const expectedAttendances = [];
      const groups = [["cat", "program-1", "午前参加時間", "午前参加人数"],
        ["dog", "program-2", "午後参加時間", "午後参加人数"], ["talk", "program-3", "トークショー", "トークショー人数"]];
      for (const [index, [role, programId, participationColumn, countColumn]] of groups.entries()) {
        const participating = expectedType.split("_").includes(role);
        const slotLabel = participating && role !== "talk" ? slots[programId][positions[programId]++] : null;
        cells[participationColumn] = participating ? slotLabel || "参加を希望する" : "参加を希望しない";
        cells[countColumn] = participating ? String(1 + (ordinal + index) % 4) : "";
        if (participating) expectedAttendances.push({programId, slotLabel, plannedCount: Number(cells[countColumn])});
        else if (residualLeft[role] > 0) {
          cells[countColumn] = "2";
          residualLeft[role]--;
          residuals.push({sourceRowNumber: ordinal + 1, programId, participationColumn, countColumn});
        }
      }
      rows.push({sourceRowNumber: ordinal + 1, cells, expectedType, expectedAttendances});
    }
  }
  return {rows, residuals, table: {headers: HEADERS, records: rows.map((r) => HEADERS.map((h) => r.cells[h]))}};
}
module.exports = {EXPECTED_TYPES, EXPECTED_SLOTS, mapping, makeSyntheticSample};
