// 当選メールのテンプレート(管理者が編集できる文章)の検証。純粋関数のみ。
//
// ■ 管理者が編集するのは「文章」だけ(すべてプレーンテキスト。HTMLとしては保存・解釈しない):
//     subject / introBody / closingBody / notesBody(任意) と、会場の住所・アクセス(任意)
// ■ JM Quickが正確なデータから生成する部分(管理者が自由入力できない):
//     宛名・受付QR・Web参加証URL・program名・参加時間・参加人数・開催日時・会場・問い合わせ先
// ■ 件名にテンプレート言語(差込)は使わない。単純な1行の文字列。

const LIMITS = Object.freeze({subject: 150, introBody: 2000, closingBody: 2000, notesBody: 2000, address: 300, access: 1000});
// 制御文字(改行・タブを除く)は拒否する。
const CONTROL_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/;

const normalizeNewlines = (value) => value.replace(/\r\n?/g, "\n");

function textField(value, {name, max, required, singleLine}, errors) {
  if (value === undefined || value === null) {
    if (required) errors.push({code: "required", path: name});
    return null;
  }
  if (typeof value !== "string") { errors.push({code: "invalid-type", path: name}); return null; }
  const text = normalizeNewlines(value).trim();
  if (text === "") {
    if (required) errors.push({code: "required", path: name});
    return null;
  }
  if (text.length > max) errors.push({code: "too-long", path: name});
  if (CONTROL_CHARS.test(text)) errors.push({code: "invalid-character", path: name});
  if (singleLine && /\n/.test(text)) errors.push({code: "multiline-not-allowed", path: name});
  return text;
}

function checkKeys(input, allowed, path, errors) {
  for (const key of Object.keys(input)) if (!allowed.includes(key)) errors.push({code: "unknown-key", path: `${path}.${key}`});
}

// 管理者が送るテンプレート入力を検証・正規化する。{ok, value:{subject,introBody,closingBody,notesBody}, errors}
function validateTemplateInput(input) {
  const errors = [];
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return {ok: false, errors: [{code: "invalid-type", path: "template"}]};
  }
  checkKeys(input, ["subject", "introBody", "closingBody", "notesBody"], "template", errors);
  const value = {
    subject: textField(input.subject, {name: "subject", max: LIMITS.subject, required: true, singleLine: true}, errors),
    introBody: textField(input.introBody, {name: "introBody", max: LIMITS.introBody, required: true}, errors),
    closingBody: textField(input.closingBody, {name: "closingBody", max: LIMITS.closingBody, required: true}, errors),
    notesBody: textField(input.notesBody, {name: "notesBody", max: LIMITS.notesBody, required: false}, errors),
  };
  return {ok: errors.length === 0, value, errors};
}

// 会場の住所・アクセス(任意)。{ok, value:{address, access}, errors}
function validateVenueInfo(input) {
  const errors = [];
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    return {ok: false, errors: [{code: "invalid-type", path: "venueInfo"}]};
  }
  checkKeys(input, ["address", "access"], "venueInfo", errors);
  const value = {
    address: textField(input.address, {name: "address", max: LIMITS.address, required: false}, errors),
    access: textField(input.access, {name: "access", max: LIMITS.access, required: false}, errors),
  };
  return {ok: errors.length === 0, value, errors};
}

// 保存済みテンプレートが、送信・プレビューに使える状態か。使えなければ理由コードを返す。
// 未設定・不完全なテンプレートで、勝手な既定本文を使って送信することはない。
function templateProblems(template) {
  if (template === null || template === undefined || typeof template !== "object") return ["template-not-configured"];
  const problems = [];
  const blank = (v) => typeof v !== "string" || v.trim() === "";
  if (blank(template.subject) || template.subject.length > LIMITS.subject) problems.push("template-subject-invalid");
  if (blank(template.introBody)) problems.push("template-intro-invalid");
  if (blank(template.closingBody)) problems.push("template-closing-invalid");
  if (!Number.isInteger(template.version) || template.version < 1) problems.push("template-version-invalid");
  return problems;
}

module.exports = {LIMITS, validateTemplateInput, validateVenueInfo, templateProblems};
