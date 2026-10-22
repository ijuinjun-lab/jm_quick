const {test} = require("node:test");
const assert = require("node:assert/strict");
const {reviseWinnerMailCopy} = require("../winner_mail_copy_revision");
const {renderWinnerMail, renderReminderMail, DOTTED_RULE} = require("../mail_render");
const {buildMailSnapshot, formatSourceRegisteredAt} = require("../mail_view_model");
const {composeWinnerMailFor} = require("../winner_mail_message");
const {planImportRows} = require("../import_rows");
const {TYPES, EVENT_ID} = require("../participation_types");
const {mapping, cells, event, person} = require("../test_support/participation_fixture");
const {fakeQrPng, APP_BASE_URL} = require("../test_support/mail_fixtures");
const {FakeFirestore} = require("../../test_support/fake_firestore");
const OLD = "このQRコードは、お申し込みいただいたすべてのプログラムで共通してご利用いただけます。";
const NEW = "このQRコードは、ご参加予約確定のプログラムで共通してご利用いただけます。";
const date = new Date("2026-09-30T15:05:59Z");
const textDate = "お申し込み日時：2026年10月01日 00:05";
const template = (waitlist) => ({...event().winnerMailTemplate,
  introBody: `${waitlist ? "追加当選のお知らせ\n\n" : ""}${event().winnerMailTemplate.introBody}\n\n${OLD}各プログラムの受付でご提示ください。`,
});
function rows(type, p) {
  return planImportRows({rows: [{sourceRowNumber: 2, cells: cells(type)}], mapping}).results[0].attendances
    .map(a=>({...a, eventId: EVENT_ID, participantId: p.participantId}));
}
for (const waitlist of [false, true]) for (const type of TYPES) {
  test(`${waitlist ? "繰り上げ" : "通常"}・${type.label}: 本文2区切り・JST申込日時・QR維持`, async () => {
    const original = template(waitlist), revised = reviseWinnerMailCopy(original);
    assert.deepEqual(reviseWinnerMailCopy(revised), revised, "再適用しても二重化しない");
    assert.equal(revised.introBody.split(DOTTED_RULE).length - 1, 2);
    assert.deepEqual({...revised, introBody: original.introBody}, original, "本文の指定箇所以外は変えない");
    const p = {...person(), sourceRegisteredAt: {toDate: () => date}, createdAt: new Date("2030-01-01")};
    const args = {snapshot: buildMailSnapshot(EVENT_ID, event({winnerMailTemplate: original})).snapshot,
      participant: p, attendances: rows(type.value, p), appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng};
    const before = await renderWinnerMail(args);
    const after = await renderWinnerMail({...args, snapshot: buildMailSnapshot(EVENT_ID, event({winnerMailTemplate: revised})).snapshot});
    assert.equal(after.ok, true);
    assert.equal(after.text, before.text.replace(original.introBody, revised.introBody));
    assert.equal(after.html.match(/<hr style="[^"]+"/g).length, 2);
    assert.equal(new Set(after.html.match(/<hr style="[^"]+"/g)).size, 1, "点線のスタイルは同一");
    for (const body of [after.text, after.html]) {
      assert.equal(body.split(NEW).length - 1, 1);
      assert.ok(!body.includes(OLD));
      assert.equal(body.split(textDate).length - 1, 1);
      assert.ok(body.indexOf(textDate) > body.lastIndexOf("参加人数："));
    }
    assert.ok(after.text.includes(`\n\n${textDate}\n`));
    assert.equal(after.qrPayload, before.qrPayload);
    assert.equal(after.webPassUrl, before.webPassUrl);
    assert.deepEqual(after.attachments, before.attachments);
    assert.deepEqual(after.viewModel.programs, before.viewModel.programs);
    assert.equal(after.subject, before.subject);
  });
}
test("日時はタイムゾーン明示値・Timestamp・DateだけをJST表示。不明値を推測しない", () => {
  for (const value of [date, date.toISOString(), "2026-10-01T00:05:59+09:00", {toDate:()=>date}])
    assert.equal(formatSourceRegisteredAt(value), "2026年10月01日 00:05");
  for (const value of [null, undefined, "", "2026/10/01 00:05", "bad", 0, new Date("bad")])
    assert.equal(formatSourceRegisteredAt(value), null);
});
test("アンカーの欠落・重複・間に別文章がある場合は改訂案を作らない", () => {
  for (const introBody of ["異なる文面", template(false).introBody + OLD,
    template(false).introBody.replace("このメールは", "変更禁止の別文章。このメールは")])
    assert.throws(()=>reviseWinnerMailCopy({...template(false), introBody}));
});
test("実際のcompose経由で追加資格のみ通知し、元の申込日時・既存QRを維持", async () => {
  const p = {...person(), sourceRegisteredAt: date};
  const all = rows("dog_talk", p), dog = all.filter(a=>a.programId === "program-2");
  const seed = Object.fromEntries(all.map(a=>[`programAttendances/${p.participantId}_${a.programId}`, a]));
  seed[`qualificationGrants/addition-${p.participantId}`] = {eventId:EVENT_ID, initial:false, attendances:dog};
  const db = new FakeFirestore(seed);
  const snapshot = buildMailSnapshot(EVENT_ID, event({winnerMailTemplate:reviseWinnerMailCopy(template(true))})).snapshot;
  const args = {db, snapshot, participant:p, participantId:p.participantId, appBaseUrl:APP_BASE_URL, generateQrPng:fakeQrPng};
  const normal = await composeWinnerMailFor(args);
  const added = await composeWinnerMailFor({...args, snapshot:{...snapshot, grantBatchId:"addition"}});
  assert.equal(added.ok, true);
  assert.deepEqual(added.viewModel.programs.map(p=>p.role), ["dog"]);
  assert.ok(added.text.includes(textDate));
  assert.equal(added.qrPayload, normal.qrPayload);
  assert.equal(added.webPassUrl, normal.webPassUrl);
  assert.deepEqual(added.attachments, normal.attachments);
  assert.equal(db.writes.length, 0);
  const missing = await composeWinnerMailFor({...args, participant:{...p, sourceRegisteredAt:null, createdAt:date}});
  assert.ok(!missing.text.includes("お申し込み日時："));
  assert.deepEqual(missing.warnings, ["source-registered-at-missing-or-invalid"]);
});
test("リマインドの出力には申込日時や新しい点線を追加しない", async () => {
  const p = person();
  const args = {snapshot:buildMailSnapshot(EVENT_ID,event()).snapshot,participant:p,attendances:rows("dog",p),appBaseUrl:APP_BASE_URL,generateQrPng:fakeQrPng};
  const a = await renderReminderMail(args), b = await renderReminderMail({...args,participant:{...p,sourceRegisteredAt:date}});
  assert.equal(a.text,b.text);assert.equal(a.html,b.html);
});
