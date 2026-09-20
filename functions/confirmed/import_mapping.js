// 新方式(flow=confirmed)の当選者CSV取込: 列マッピングの純粋モデルと検証。
// Firestore・ネットワーク・Firebaseに依存しない(functions/test/confirmed_no_dedupe_sources.test.js が検査する)。
//
// 方針: 取込は「CSVの全レコードを欠落なく処理する」ことが最優先。人物の同一性
// (同じメール・同じ氏名・同じ参照コード)は判定に使わず、mappingにも同一性の設定を持たない。
// 未マップの列は読み込まず保存もしない(データ最小化)。
//
// mapping(v1):
//   {
//     version: 1,                      // mappingVersion(1以上の整数)
//     participant: {
//       nameColumn, emailColumn,       // 必須
//       externalIdColumn?,             // 参照情報(sourceReference)。同一性判定には使わない
//       kanaColumn?, registeredAtColumn?
//     },
//     rowChecks?: [{column, allowedValues[]}],   // 行の意味を確認する列(例: 区分)。外れた行はreview
//     programs: [{
//       programId,                     // event.programs のprogramIdに対応
//       countColumn,                   // 必須。人数はplannedCountの唯一の入力元
//       participationColumn?,          // 省略すると人数だけで参加を判定
//       attendingValues?, notAttendingValues?,
//       emptyMeans?: 'review'|'notAttending',    // 参加列が空のときの扱い(既定review)
//       slotColumn?, slotFormat?: 'timeRange'|'label'   // 既定label
//     }]
//   }
// participationColumn と slotColumn は同じ列でもよい(時間欄に「参加を希望しない」と入るCSV向け)。

const {isValidProgramId} = require("../programs");

const SLOT_FORMATS = ["timeRange", "label"];
const EMPTY_MEANS = ["review", "notAttending"];
const MAX_COLUMN_NAME_LENGTH = 200;
const MAX_VALUE_LENGTH = 200;
const MAX_VALUES = 50;
const MAX_PROGRAMS = 50;
const TOP_KEYS = ["version", "participant", "rowChecks", "programs"];
const PARTICIPANT_KEYS = ["externalIdColumn", "nameColumn", "kanaColumn", "emailColumn", "registeredAtColumn"];
const PROGRAM_KEYS = ["programId", "participationColumn", "attendingValues", "notAttendingValues",
  "emptyMeans", "slotColumn", "slotFormat", "countColumn"];
const ROW_CHECK_KEYS = ["column", "allowedValues"];
const WAITLIST_FRAGMENT = "キャンセル待";

class ImportMappingError extends Error {
  constructor(errors) {
    super(`invalid import mapping: ${errors.map((e) => `${e.path}:${e.code}`).join(", ")}`);
    this.name = "ImportMappingError";
    this.code = "invalid-import-mapping";
    this.errors = errors;
  }
}

const isPlainObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const isColumnName = (value) => typeof value === "string" && value.trim() !== "" &&
  value.trim().length <= MAX_COLUMN_NAME_LENGTH;

function checkKeys(object, allowed, path, errors) {
  for (const key of Object.keys(object)) {
    if (allowed.includes(key)) continue;
    // 同一性(identity)の設定は廃止した。設定しても効かないため、黙って無視せず明示的に拒否する。
    errors.push({code: key === "identity" ? "identity-not-supported" : "unknown-key",
      path: path ? `${path}.${key}` : key});
  }
}

function checkOptionalColumn(value, path, errors) {
  if (value === undefined || value === null) return;
  if (!isColumnName(value)) errors.push({code: "invalid-column", path});
}

function checkValues(values, path, errors) {
  if (values === undefined) return;
  if (!Array.isArray(values) || values.length === 0 || values.length > MAX_VALUES ||
      values.some((v) => typeof v !== "string" || v.trim() === "" || v.trim().length > MAX_VALUE_LENGTH)) {
    errors.push({code: "invalid-values", path});
  }
}

// {valid, errors, warnings}。errorsが空ならvalid。
// eventProgramIds(任意): イベントに定義されたprogramIdの配列。指定時はmapping内のprogramIdが存在するか検査する。
function validateImportMapping(mapping, {eventProgramIds} = {}) {
  const errors = [];
  const warnings = [];
  if (!isPlainObject(mapping)) {
    return {valid: false, errors: [{code: "mapping-not-object", path: ""}], warnings};
  }
  checkKeys(mapping, TOP_KEYS, "", errors);
  if (!Number.isInteger(mapping.version) || mapping.version < 1) errors.push({code: "invalid-version", path: "version"});

  const participant = mapping.participant;
  if (!isPlainObject(participant)) {
    errors.push({code: "participant-required", path: "participant"});
  } else {
    checkKeys(participant, PARTICIPANT_KEYS, "participant", errors);
    for (const key of ["nameColumn", "emailColumn"]) {
      if (participant[key] === undefined || participant[key] === null) {
        errors.push({code: "required-column", path: `participant.${key}`});
      } else if (!isColumnName(participant[key])) {
        errors.push({code: "invalid-column", path: `participant.${key}`});
      }
    }
    for (const key of ["externalIdColumn", "kanaColumn", "registeredAtColumn"]) {
      checkOptionalColumn(participant[key], `participant.${key}`, errors);
    }
    // 参加者の項目は別々の列でなければならない(同じ列を氏名とメールに使う等は設定ミス)。
    const seen = new Map();
    for (const key of PARTICIPANT_KEYS) {
      const value = isColumnName(participant[key]) ? participant[key].trim() : null;
      if (value === null) continue;
      if (seen.has(value)) errors.push({code: "duplicate-participant-column", path: `participant.${key}`});
      else seen.set(value, key);
    }
  }

  if (mapping.rowChecks !== undefined) {
    if (!Array.isArray(mapping.rowChecks)) {
      errors.push({code: "invalid-row-checks", path: "rowChecks"});
    } else {
      mapping.rowChecks.forEach((check, index) => {
        const path = `rowChecks[${index}]`;
        if (!isPlainObject(check)) { errors.push({code: "invalid-row-checks", path}); return; }
        checkKeys(check, ROW_CHECK_KEYS, path, errors);
        if (!isColumnName(check.column)) errors.push({code: "invalid-column", path: `${path}.column`});
        if (check.allowedValues === undefined) errors.push({code: "invalid-values", path: `${path}.allowedValues`});
        else checkValues(check.allowedValues, `${path}.allowedValues`, errors);
      });
    }
  }

  const programs = mapping.programs;
  if (!Array.isArray(programs) || programs.length === 0 || programs.length > MAX_PROGRAMS) {
    errors.push({code: "programs-required", path: "programs"});
  } else {
    const ids = new Set();
    const eventIds = Array.isArray(eventProgramIds) ? new Set(eventProgramIds) : null;
    programs.forEach((program, index) => {
      const path = `programs[${index}]`;
      if (!isPlainObject(program)) { errors.push({code: "invalid-program", path}); return; }
      checkKeys(program, PROGRAM_KEYS, path, errors);
      if (!isValidProgramId(program.programId)) {
        errors.push({code: "invalid-program-id", path: `${path}.programId`});
      } else if (ids.has(program.programId)) {
        errors.push({code: "duplicate-program-id", path: `${path}.programId`});
      } else {
        ids.add(program.programId);
        if (eventIds && !eventIds.has(program.programId)) {
          errors.push({code: "program-not-in-event", path: `${path}.programId`});
        }
      }
      if (program.countColumn === undefined || program.countColumn === null) {
        errors.push({code: "required-column", path: `${path}.countColumn`});
      } else if (!isColumnName(program.countColumn)) {
        errors.push({code: "invalid-column", path: `${path}.countColumn`});
      }
      checkOptionalColumn(program.participationColumn, `${path}.participationColumn`, errors);
      checkOptionalColumn(program.slotColumn, `${path}.slotColumn`, errors);
      checkValues(program.attendingValues, `${path}.attendingValues`, errors);
      checkValues(program.notAttendingValues, `${path}.notAttendingValues`, errors);
      const hasValues = program.attendingValues !== undefined || program.notAttendingValues !== undefined;
      if (hasValues && !isColumnName(program.participationColumn)) {
        errors.push({code: "values-without-participation-column", path});
      }
      if (Array.isArray(program.attendingValues) && Array.isArray(program.notAttendingValues) &&
          program.attendingValues.some((v) => program.notAttendingValues.map((x) => String(x).trim()).includes(String(v).trim()))) {
        errors.push({code: "values-overlap", path});
      }
      if (program.emptyMeans !== undefined && !EMPTY_MEANS.includes(program.emptyMeans)) {
        errors.push({code: "invalid-empty-means", path: `${path}.emptyMeans`});
      }
      if (program.slotFormat !== undefined && !SLOT_FORMATS.includes(program.slotFormat)) {
        errors.push({code: "invalid-slot-format", path: `${path}.slotFormat`});
      }
      if (program.slotFormat !== undefined && !isColumnName(program.slotColumn)) {
        errors.push({code: "slot-format-without-slot-column", path: `${path}.slotFormat`});
      }
    });
  }

  if (errors.length === 0) {
    // キャンセル待ちの列は当選リストのprogramに使ってはならない(意味が異なる)。警告にとどめて表示させる。
    for (const column of mappedColumns(mapping)) {
      if (column.includes(WAITLIST_FRAGMENT)) warnings.push({code: "waitlist-column", column});
    }
  }
  return {valid: errors.length === 0, errors, warnings};
}

// 検証して正規化した新しいオブジェクトを返す(入力は変更しない)。不正ならImportMappingErrorを投げる。
function normalizeImportMapping(mapping, options) {
  const result = validateImportMapping(mapping, options);
  if (!result.valid) throw new ImportMappingError(result.errors);
  const text = (value) => (value === undefined || value === null ? null : value.trim());
  const list = (values) => (values === undefined ? null : values.map((v) => v.trim()));
  const p = mapping.participant;
  return {
    version: mapping.version,
    participant: {
      externalIdColumn: text(p.externalIdColumn),
      nameColumn: text(p.nameColumn),
      kanaColumn: text(p.kanaColumn),
      emailColumn: text(p.emailColumn),
      registeredAtColumn: text(p.registeredAtColumn),
    },
    rowChecks: (mapping.rowChecks || []).map((c) => ({column: c.column.trim(), allowedValues: list(c.allowedValues)})),
    programs: mapping.programs.map((g) => ({
      programId: g.programId,
      participationColumn: text(g.participationColumn),
      attendingValues: list(g.attendingValues),
      notAttendingValues: list(g.notAttendingValues),
      emptyMeans: g.emptyMeans || "review",
      slotColumn: text(g.slotColumn),
      slotFormat: g.slotFormat || "label",
      countColumn: text(g.countColumn),
    })),
  };
}

// mappingが読むCSV列の名前(重複なし)。ここに無い列は読み込まず、保存もしない。
function mappedColumns(mapping) {
  const columns = new Set();
  const add = (value) => { if (typeof value === "string" && value.trim() !== "") columns.add(value.trim()); };
  const p = mapping.participant || {};
  PARTICIPANT_KEYS.forEach((key) => add(p[key]));
  (mapping.rowChecks || []).forEach((check) => add(check.column));
  (mapping.programs || []).forEach((g) => {
    add(g.participationColumn);
    add(g.slotColumn);
    add(g.countColumn);
  });
  return [...columns];
}

module.exports = {ImportMappingError, validateImportMapping, normalizeImportMapping, mappedColumns};
