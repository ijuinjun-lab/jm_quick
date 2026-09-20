const assert = require("node:assert/strict");
const {test} = require("node:test");
const {LIMITS, validateTemplateInput, validateVenueInfo, templateProblems} = require("../winner_mail_template");

const ok = {subject: "【ご参加確定】架空イベント", introBody: "冒頭文", closingBody: "締め文"};
const codes = (result) => result.errors.map((e) => `${e.path}:${e.code}`);

test("正しいテンプレートを受け付け、前後の空白を除き改行を正規化する(HTMLはそのまま保存する=プレーンテキスト)", () => {
  const result = validateTemplateInput({subject: "  件名  ", introBody: "1行目\r\n2行目\r\n\r\n段落2 ", closingBody: "締め", notesBody: "  注意  "});
  assert.equal(result.ok, true);
  assert.deepEqual(result.value, {subject: "件名", introBody: "1行目\n2行目\n\n段落2", closingBody: "締め", notesBody: "注意"});
  const html = validateTemplateInput({...ok, introBody: "<script>alert(1)</script><b>太字</b>"});
  assert.equal(html.ok, true);
  assert.equal(html.value.introBody, "<script>alert(1)</script><b>太字</b>", "HTMLとして解釈せず、テキストのまま保存する");
});

test("件名: 空・空白のみ・長すぎる・複数行を拒否する", () => {
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: ""})), ["subject:required"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: "   \n  "})), ["subject:required"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: undefined})), ["subject:required"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: "あ".repeat(LIMITS.subject + 1)})), ["subject:too-long"]);
  assert.equal(validateTemplateInput({...ok, subject: "あ".repeat(LIMITS.subject)}).ok, true);
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: "件名\nBcc: x"})), ["subject:multiline-not-allowed"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, subject: 123})), ["subject:invalid-type"]);
});

test("本文の必須・上限・制御文字", () => {
  assert.deepEqual(codes(validateTemplateInput({...ok, introBody: " "})), ["introBody:required"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, closingBody: undefined})), ["closingBody:required"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, introBody: "あ".repeat(LIMITS.introBody + 1)})), ["introBody:too-long"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, closingBody: "あ".repeat(LIMITS.closingBody + 1)})), ["closingBody:too-long"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, notesBody: "あ".repeat(LIMITS.notesBody + 1)})), ["notesBody:too-long"]);
  assert.deepEqual(codes(validateTemplateInput({...ok, introBody: "a\u0000b"})), ["introBody:invalid-character"]);
  assert.equal(validateTemplateInput({...ok, introBody: "タブ\tと改行\nはOK"}).ok, true);
  assert.equal(validateTemplateInput({...ok, notesBody: "   "}).value.notesBody, null, "注意事項は任意(空白のみ=なし)");
});

test("未知のキー(参加者情報・QR・HTML等を管理者が自由入力する余地)を拒否する", () => {
  for (const key of ["qr", "html", "recipientName", "programs", "eventName", "webPassUrl"]) {
    assert.deepEqual(codes(validateTemplateInput({...ok, [key]: "x"})), [`template.${key}:unknown-key`], key);
  }
  for (const bad of [null, undefined, "x", [], 1]) assert.deepEqual(codes(validateTemplateInput(bad)), ["template:invalid-type"]);
});

test("会場の住所・アクセス(任意): 上限・未知キー・空はなし扱い", () => {
  assert.deepEqual(validateVenueInfo({address: " 住所 ", access: "アクセス"}).value, {address: "住所", access: "アクセス"});
  assert.deepEqual(validateVenueInfo({address: "", access: "  "}).value, {address: null, access: null});
  assert.deepEqual(codes(validateVenueInfo({address: "あ".repeat(LIMITS.address + 1)})), ["address:too-long"]);
  assert.deepEqual(codes(validateVenueInfo({access: "あ".repeat(LIMITS.access + 1)})), ["access:too-long"]);
  assert.deepEqual(codes(validateVenueInfo({venue: "x"})), ["venueInfo.venue:unknown-key"]);
  assert.deepEqual(codes(validateVenueInfo("x")), ["venueInfo:invalid-type"]);
});

test("templateProblems: 未設定・不完全なテンプレートは送信・プレビューに使えない(既定本文は使わない)", () => {
  assert.deepEqual(templateProblems(undefined), ["template-not-configured"]);
  assert.deepEqual(templateProblems(null), ["template-not-configured"]);
  assert.deepEqual(templateProblems("x"), ["template-not-configured"]);
  assert.deepEqual(templateProblems({version: 1, subject: " ", introBody: "a", closingBody: "b"}), ["template-subject-invalid"]);
  assert.deepEqual(templateProblems({version: 1, subject: "s", introBody: "", closingBody: "b"}), ["template-intro-invalid"]);
  assert.deepEqual(templateProblems({version: 1, subject: "s", introBody: "a", closingBody: undefined}), ["template-closing-invalid"]);
  assert.deepEqual(templateProblems({subject: "s", introBody: "a", closingBody: "b"}), ["template-version-invalid"]);
  assert.deepEqual(templateProblems({version: 1, subject: "s", introBody: "a", closingBody: "b"}), []);
  assert.deepEqual(templateProblems({version: 1, subject: "s", introBody: "a", closingBody: "b", notesBody: null}), []);
});
