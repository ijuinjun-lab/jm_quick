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
//       hebelResidenceColumn?          // HEBEL属性(受付の確認用。hebel_residence.js)。省略時は属性なし(後方互換)
//     },
//     rowChecks?: [{column, allowedValues[]}],   // 行の意味を確認する列(例: 区分)。外れた行はreview
//     autoExcludeRows?: [{column, values[]}],    // この列の値が一致する行は、今回の取込から自動で除外する(例: 区分=キャンセル)。
//                                                // 一致は空白・全角半角を無視して比べる。原本の行は消さず、除外として監査に残す
//     waitlist?: {                               // キャンセル待ち繰り上げ当選の取込だけ(waitlist_promotion.js)
//       optionsColumn, countColumn,              // キャンセル待ち希望枠(選択肢のカンマ区切り)・キャンセル待ち希望人数(「N名」)
//       options: [{label, programId, kind?}]     // 選択肢の見出し(例「午後の部（犬）」)→ program。kindはファイル名との照合用(例「犬」)
//     },
//     programs: [{
//       programId,                     // event.programs のprogramIdに対応
//       countColumn,                   // 必須。人数はplannedCountの唯一の入力元
//       participationColumn?,          // 省略すると人数だけで参加を判定
//       attendingValues?, notAttendingValues?,
//       emptyMeans?: 'review'|'notAttending',    // 参加列が空のときの扱い(既定review)
//       slotColumn?, slotFormat?: 'timeRange'|'label',   // 既定label
//       ignoreCountWhenNotAttending?: boolean    // 既定false(既存の安全チェックのまま)。
//     }]
//   }
// participationColumn と slotColumn は同じ列でもよい(時間欄に「参加を希望しない」と入るCSV向け)。
//
// ■ ignoreCountWhenNotAttending(既定false・後方互換): falseまたは省略時は既存どおり、不参加(not-attending)
//   と判定したprogramの人数列に値(0以外の数値・不正値)が残っていれば not-attending-count-present として
//   reviewに残す(矛盾を自動判断しない、という既存の安全チェック。このprofile以外・既定値では変更していない)。
//   trueを明示したprofile(例: 参加意思の列と人数の列が別の設問として独立しているCSV形式)だけ、不参加と
//   判定したprogramの人数列は完全に無視する(矛盾があってもreview化しない。参加意思(participationColumn)を
//   唯一の正本として扱う)。不参加のprogramでattendance・plannedCount・slotLabelを作らないのは、
//   ignoreCountWhenNotAttendingの値に関わらずこれまでと同じ(not-attending状態からattendanceを作る分岐が
//   元々存在しないため)。

const {isValidProgramId} = require("../programs");

const SLOT_FORMATS = ["timeRange", "label"];
const EMPTY_MEANS = ["review", "notAttending"];
const MAX_COLUMN_NAME_LENGTH = 200;
const MAX_VALUE_LENGTH = 200;
const MAX_VALUES = 50;
const MAX_PROGRAMS = 50;
const TOP_KEYS = ["version", "participant", "rowChecks", "autoExcludeRows", "waitlist", "programs"];
const PARTICIPANT_KEYS = ["externalIdColumn", "nameColumn", "kanaColumn", "emailColumn", "registeredAtColumn",
  "hebelResidenceColumn"];
const PROGRAM_KEYS = ["programId", "participationColumn", "attendingValues", "notAttendingValues",
  "emptyMeans", "slotColumn", "slotFormat", "countColumn", "ignoreCountWhenNotAttending"];
const ROW_CHECK_KEYS = ["column", "allowedValues"];
const AUTO_EXCLUDE_KEYS = ["column", "values"];
const WAITLIST_KEYS = ["optionsColumn", "countColumn", "options"];
const WAITLIST_OPTION_KEYS = ["label", "programId", "kind"];
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
    for (const key of ["externalIdColumn", "kanaColumn", "registeredAtColumn", "hebelResidenceColumn"]) {
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

  if (mapping.autoExcludeRows !== undefined) {
    if (!Array.isArray(mapping.autoExcludeRows) || mapping.autoExcludeRows.length === 0 || mapping.autoExcludeRows.length > MAX_VALUES) {
      errors.push({code: "invalid-auto-exclude-rows", path: "autoExcludeRows"});
    } else {
      mapping.autoExcludeRows.forEach((rule, index) => {
        const path = `autoExcludeRows[${index}]`;
        if (!isPlainObject(rule)) { errors.push({code: "invalid-auto-exclude-rows", path}); return; }
        checkKeys(rule, AUTO_EXCLUDE_KEYS, path, errors);
        if (!isColumnName(rule.column)) errors.push({code: "invalid-column", path: `${path}.column`});
        if (rule.values === undefined) errors.push({code: "invalid-values", path: `${path}.values`});
        else checkValues(rule.values, `${path}.values`, errors);
      });
    }
  }

  const waitlist = mapping.waitlist;
  if (waitlist !== undefined) {
    if (!isPlainObject(waitlist)) {
      errors.push({code: "invalid-waitlist", path: "waitlist"});
    } else {
      checkKeys(waitlist, WAITLIST_KEYS, "waitlist", errors);
      for (const key of ["optionsColumn", "countColumn"]) {
        if (!isColumnName(waitlist[key])) errors.push({code: "invalid-column", path: `waitlist.${key}`});
      }
      const mappedProgramIds = new Set(Array.isArray(mapping.programs) ? mapping.programs.map((p) => p && p.programId) : []);
      if (!Array.isArray(waitlist.options) || waitlist.options.length === 0 || waitlist.options.length > MAX_PROGRAMS) {
        errors.push({code: "invalid-waitlist-options", path: "waitlist.options"});
      } else {
        const labels = new Set();
        waitlist.options.forEach((option, index) => {
          const path = `waitlist.options[${index}]`;
          if (!isPlainObject(option)) { errors.push({code: "invalid-waitlist-options", path}); return; }
          checkKeys(option, WAITLIST_OPTION_KEYS, path, errors);
          if (typeof option.label !== "string" || option.label.trim() === "" || option.label.trim().length > MAX_VALUE_LENGTH) {
            errors.push({code: "invalid-waitlist-label", path: `${path}.label`});
          } else if (labels.has(option.label.trim())) {
            errors.push({code: "duplicate-waitlist-label", path: `${path}.label`});
          } else {
            labels.add(option.label.trim());
          }
          // 繰り上げ先は、このmappingのprogram(=イベントのprogram)のどれか
          if (!isValidProgramId(option.programId) || !mappedProgramIds.has(option.programId)) {
            errors.push({code: "waitlist-program-not-mapped", path: `${path}.programId`});
          }
          if (option.kind !== undefined && (typeof option.kind !== "string" || option.kind.trim() === "" || option.kind.trim().length > 20)) {
            errors.push({code: "invalid-waitlist-kind", path: `${path}.kind`});
          }
        });
      }
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
      if (program.ignoreCountWhenNotAttending !== undefined &&
          typeof program.ignoreCountWhenNotAttending !== "boolean") {
        errors.push({code: "invalid-ignore-count-when-not-attending", path: `${path}.ignoreCountWhenNotAttending`});
      }
    });
  }

  if (errors.length === 0) {
    // キャンセル待ちの列は当選リストのprogramに使ってはならない(意味が異なる)。警告にとどめて表示させる。
    // 繰り上げ当選の取込(waitlist)がキャンセル待ちの列を読むのは正しい使い方なので、その列は警告しない。
    const waitlistColumns = isPlainObject(mapping.waitlist) ? [mapping.waitlist.optionsColumn, mapping.waitlist.countColumn] : [];
    for (const column of mappedColumns(mapping)) {
      if (waitlistColumns.includes(column)) continue;
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
      // 指定したときだけ持つ(指定の無いmappingの正規化結果=既存の取込回のハッシュ・指紋は従来と同じ)。
      ...(p.hebelResidenceColumn === undefined || p.hebelResidenceColumn === null ?
        {} : {hebelResidenceColumn: text(p.hebelResidenceColumn)}),
    },
    rowChecks: (mapping.rowChecks || []).map((c) => ({column: c.column.trim(), allowedValues: list(c.allowedValues)})),
    // 指定したときだけ持つ(指定の無いmappingの正規化結果=既存の取込回のハッシュ・指紋は従来と同じ)。
    ...(mapping.autoExcludeRows === undefined ? {} : {
      autoExcludeRows: mapping.autoExcludeRows.map((r) => ({column: r.column.trim(), values: list(r.values)})),
    }),
    ...(mapping.waitlist === undefined ? {} : {
      waitlist: {
        optionsColumn: mapping.waitlist.optionsColumn.trim(),
        countColumn: mapping.waitlist.countColumn.trim(),
        options: mapping.waitlist.options.map((o) => ({
          label: o.label.trim(), programId: o.programId, ...(o.kind === undefined ? {} : {kind: o.kind.trim()}),
        })),
      },
    }),
    programs: mapping.programs.map((g) => ({
      programId: g.programId,
      participationColumn: text(g.participationColumn),
      attendingValues: list(g.attendingValues),
      notAttendingValues: list(g.notAttendingValues),
      emptyMeans: g.emptyMeans || "review",
      slotColumn: text(g.slotColumn),
      slotFormat: g.slotFormat || "label",
      countColumn: text(g.countColumn),
      ignoreCountWhenNotAttending: g.ignoreCountWhenNotAttending === true,
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
  (Array.isArray(mapping.autoExcludeRows) ? mapping.autoExcludeRows : []).forEach((rule) => add(rule && rule.column));
  if (isPlainObject(mapping.waitlist)) {
    add(mapping.waitlist.optionsColumn);
    add(mapping.waitlist.countColumn);
  }
  (mapping.programs || []).forEach((g) => {
    add(g.participationColumn);
    add(g.slotColumn);
    add(g.countColumn);
  });
  return [...columns];
}

module.exports = {ImportMappingError, validateImportMapping, normalizeImportMapping, mappedColumns};
