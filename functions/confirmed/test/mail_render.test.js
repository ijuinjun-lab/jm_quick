// 当選メールのview model・レンダラーのテスト。データはすべて架空。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const {renderWinnerMail, escapeHtml, QR_CONTENT_ID} = require("../mail_render");
const {buildMailSnapshot, buildMailViewModel, formatEventDateTime, missingOptionalFields, programTimeText} = require("../mail_view_model");
const {APP_BASE_URL, makeEvent, participant, attendance, attendances, fakeQrPng} = require("../test_support/mail_fixtures");

const snapshotOf = (overrides) => {
  const built = buildMailSnapshot("event1", makeEvent(overrides));
  assert.equal(built.ok, true, JSON.stringify(built.problems));
  return built.snapshot;
};
const render = (options = {}) => renderWinnerMail({
  snapshot: options.snapshot || snapshotOf(), participant: options.participant || participant(),
  attendances: options.attendances || attendances(), appBaseUrl: APP_BASE_URL, generateQrPng: fakeQrPng,
});
const okRender = async (options) => { const r = await render(options); assert.equal(r.ok, true, JSON.stringify(r.problems)); return r; };
const htmlToText = (html) => html.replace(/<title>[\s\S]*?<\/title>/, "").replace(/<br\s*\/?>/g, "\n").replace(/<\/(p|h2|h3|div)>/g, "\n").replace(/<[^>]+>/g, "")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");

test("宛名・イベント名・開催情報・管理者の文章が、text と html の両方に入る", async () => {
  const r = await okRender();
  for (const body of [r.text, htmlToText(r.html)]) {
    for (const expected of ["架空 太郎 様", "このたびは当選おめでとうございます。", "当日お会いできるのを楽しみにしています。", "駐車場はありません。",
      "開催日時：2026年11月30日(月) 10:00〜16:00", "会場：架空会場ホール", "住所：〒000-0000 架空県架空市1-2-3", "アクセス：架空駅から徒歩5分", "架空事務局 support@example.invalid"]) {
      assert.ok(body.includes(expected), `${expected}`);
    }
  }
  assert.equal(r.subject, "【ご参加確定】架空イベント");
});

test("参加するprogramだけが、event.programsのorder順で表示される(取得順に依存しない)", async () => {
  const shuffled = [attendance("talk", 2), attendance("beta", 3), attendance("alpha", 1)];
  const r = await okRender({attendances: shuffled});
  for (const body of [r.text, htmlToText(r.html)]) {
    const positions = ["プログラムA", "プログラムB", "トークセッション"].map((name) => body.indexOf(`■ ${name}`));
    assert.ok(positions.every((p) => p >= 0));
    assert.deepEqual([...positions].sort((a, b) => a - b), positions, "alpha(0) → beta(1) → talk(2)");
  }
  const reversed = await okRender({attendances: [...shuffled].reverse()});
  assert.equal(reversed.text, r.text, "attendancesの並びを変えても同じ結果");
  assert.equal(reversed.html, r.html);
});

test("参加していないprogramは表示しない(attendanceが無いprogramは出ない)", async () => {
  const r = await okRender({attendances: [attendance("alpha", 2)]});
  assert.ok(r.text.includes("■ プログラムA"));
  for (const absent of ["プログラムB", "トークセッション"]) {
    assert.ok(!r.text.includes(absent), absent);
    assert.ok(!r.html.includes(absent), absent);
  }
});

test("参加人数はplannedCountを表示する(1名・2名・3名)", async () => {
  const r = await okRender();
  assert.ok(r.text.includes("参加人数：1名") && r.text.includes("参加人数：3名") && r.text.includes("参加人数：2名"));
  assert.deepEqual(r.viewModel.programs.map((p) => [p.programId, p.plannedCount]), [["alpha", 1], ["beta", 3], ["talk", 2]]);
});

test("参加時間: slotLabel → 参加者別のstartAt/endAt → programの共通時間 → 表示しない", async () => {
  const snapshot = snapshotOf({programs: [
    {programId: "alpha", name: "プログラムA", order: 0}, {programId: "beta", name: "プログラムB", order: 1},
    {programId: "talk", name: "トークセッション", order: 2, startAt: new Date("2026-11-30T04:00:00Z"), endAt: new Date("2026-11-30T05:00:00Z")},
    {programId: "solo", name: "時間なし", order: 3}]});
  const r = await okRender({snapshot, attendances: [
    attendance("alpha", 1, {slotLabel: "  10:00〜10:40 "}),
    attendance("beta", 3, {startAt: new Date("2026-11-30T02:00:00Z"), endAt: new Date("2026-11-30T02:40:00Z")}),
    attendance("talk", 2), attendance("solo", 1)]});
  const block = (name) => r.text.split("■ ").find((b) => b.startsWith(name));
  assert.ok(block("プログラムA").includes("参加時間：10:00〜10:40"), "slotLabel(原文)");
  assert.ok(block("プログラムB").includes("参加時間：11:00〜11:40"), "attendanceのstartAt/endAt(日本時間)");
  assert.ok(block("トークセッション").includes("参加時間：13:00〜14:00"), "programの共通時間");
  assert.ok(!block("時間なし").includes("参加時間"), "時間が全く無ければ時間欄自体を出さない");
  assert.ok(block("時間なし").includes("参加人数：1名"));
  // slotLabelを優先(他の時間があっても)
  assert.equal(programTimeText({slotLabel: "午前の部", startAt: new Date("2026-11-30T02:00:00Z"), endAt: new Date("2026-11-30T03:00:00Z")}, {}), "午前の部");
  assert.equal(programTimeText({slotLabel: " "}, {}), null);
  assert.equal(programTimeText({startAt: new Date("2026-11-30T02:00:00Z"), endAt: new Date("2026-11-30T01:00:00Z")}, {}), null, "終了が開始以前なら表示しない");
});

test("任意項目(住所・アクセス・注意事項・問い合わせ先)が未設定なら、そのセクション自体を出さず、「未設定」「null」も出さない", async () => {
  const snapshot = snapshotOf({venueInfo: undefined, contact: "", winnerMailTemplate: {...makeEvent().winnerMailTemplate, notesBody: undefined}});
  const r = await okRender({snapshot});
  for (const body of [r.text, r.html]) {
    for (const forbidden of ["住所", "アクセス", "注意事項", "お問い合わせ先", "未設定", "null", "undefined", "NaN"]) assert.ok(!body.includes(forbidden), forbidden);
  }
  assert.ok(r.text.includes("会場：架空会場ホール"), "必須項目は出る");
  assert.deepEqual(missingOptionalFields(snapshot), ["contact", "address", "access", "notesBody"]);
  assert.deepEqual(missingOptionalFields(snapshotOf()), []);
});

test("終了時刻が無い・別日でも、開催日時が安全に表示される", () => {
  const d = (s) => new Date(s);
  assert.equal(formatEventDateTime(d("2026-11-30T01:00:00Z"), d("2026-11-30T07:00:00Z")), "2026年11月30日(月) 10:00〜16:00");
  assert.equal(formatEventDateTime(d("2026-11-30T01:00:00Z"), null), "2026年11月30日(月) 10:00");
  assert.equal(formatEventDateTime(d("2026-11-30T01:00:00Z"), d("2026-11-30T01:00:00Z")), "2026年11月30日(月) 10:00");
  assert.equal(formatEventDateTime(d("2026-11-30T01:00:00Z"), d("2026-11-29T01:00:00Z")), "2026年11月30日(月) 10:00");
  assert.equal(formatEventDateTime(d("2026-11-30T14:00:00Z"), d("2026-12-01T02:00:00Z")), "2026年11月30日(月) 23:00〜2026年12月1日(火) 11:00");
  assert.equal(formatEventDateTime(d("2026-11-30T15:30:00Z"), null), "2026年12月1日(火) 00:30", "日本時間で日付が変わる");
});

test("text/plain と HTML は同じview modelから作られ、参加内容が食い違わない", async () => {
  const r = await okRender();
  const text = r.text;
  const html = htmlToText(r.html);
  const facts = (body) => ({
    programs: [...body.matchAll(/■ (.+)/g)].map((m) => m[1].trim()),
    times: [...body.matchAll(/参加時間：(.+)/g)].map((m) => m[1].trim()),
    counts: [...body.matchAll(/参加人数：(\d+)名/g)].map((m) => m[1]),
    date: (body.match(/開催日時：(.+)/) || [])[1],
    venue: (body.match(/会場：(.+)/) || [])[1],
  });
  assert.deepEqual(facts(html), facts(text));
  assert.deepEqual(facts(text).programs, ["プログラムA", "プログラムB", "トークセッション"]);
  assert.ok(r.html.includes("<html") && r.html.includes("<img"));
  assert.ok(!text.includes("<") || !/<\/?(p|div|img|h2)/.test(text), "テキストにHTMLタグは含まれない");
});

test("HTMLにはQR画像(cid)と「表示されない場合」のリンクがあり、テキストにも代替URLが必ず入る", async () => {
  const r = await okRender();
  assert.equal(QR_CONTENT_ID, "jm-quick-reception-qr");
  assert.ok(r.html.includes('<img src="cid:jm-quick-reception-qr"'));
  assert.equal((r.html.match(/<img/g) || []).length, 1);
  assert.ok(r.html.includes(`<a href="${r.webPassUrl}">こちら</a>`));
  assert.ok(r.text.includes("受付用QRコードが表示できない場合はこちら"));
  assert.ok(r.text.includes(r.webPassUrl));
  assert.equal(r.webPassUrl, "https://app.invalid/p/batchA-000002?publicId=pub_0123456789abcdef0123456789abcdef");
  assert.equal(r.attachments.length, 1);
  const [attachment] = r.attachments;
  assert.deepEqual([attachment.contentType, attachment.contentId, attachment.disposition, attachment.filename],
    ["image/png", "jm-quick-reception-qr", "inline", "reception-qr.png"]);
  assert.equal(Buffer.from(attachment.contentBase64, "base64").toString("latin1").includes(`FAKE:${r.qrPayload}`), true, "QR画像はqrPayloadから生成される");
});

test("QRペイロードに個人情報が入らず、再レンダリングしても結果(QR・URL・件名・本文)が完全に不変", async () => {
  const first = await okRender();
  for (let i = 0; i < 5; i += 1) assert.deepEqual(await okRender(), first);
  assert.ok(!first.qrPayload.includes("架空") && !first.qrPayload.includes("example.invalid") && !first.qrPayload.includes("%"));
  const other = await okRender({participant: participant({name: "別の名前", email: "other@example.invalid"})});
  assert.equal(other.qrPayload, first.qrPayload, "氏名・メールが違ってもQRは(同じID・publicIdなら)同一");
});

test("外部入力・管理者入力はHTMLでescapeされる(スクリプト・タグ・属性の注入が効かない)", async () => {
  const evil = '<script>alert("x")</script><img src=x onerror=alert(1)>&"\'';
  const snapshot = snapshotOf({
    eventName: `会<b>${evil}`, venue: `会場${evil}`, contact: `連絡${evil}`, venueInfo: {address: `住所${evil}`, access: `アクセス${evil}`},
    programs: [{programId: "alpha", name: `A${evil}`, order: 0}],
    winnerMailTemplate: {subject: `件名${evil}`, introBody: `冒頭<h1>${evil}</h1>\n\n段落2 <a href="javascript:alert(1)">x</a>`, closingBody: `締め${evil}`, notesBody: `注意${evil}`, version: 1},
  });
  const r = await okRender({snapshot, participant: participant({name: `名前${evil}`}), attendances: [attendance("alpha", 1, {slotLabel: `枠${evil}`})]});
  for (const raw of ["<script", "<b>", "<h1>", 'onerror=alert(1)>', '<a href="javascript']) assert.ok(!r.html.includes(raw), `生の${raw}が出力されている`);
  assert.equal((r.html.match(/<img/g) || []).length, 1, "注入された<img>は増えない(QR画像の1つだけ)");
  assert.ok(r.html.includes("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"));
  assert.ok(r.html.includes("&amp;&quot;&#39;"));
  assert.ok(htmlToText(r.html).includes(evil), "escapeを戻すと元の文字列(表示上は文字そのまま)");
  assert.ok(r.text.includes(evil), "テキスト版はエスケープしない(そのまま)");
  assert.equal(escapeHtml("<>&\"'"), "&lt;&gt;&amp;&quot;&#39;");
});

test("管理者入力の改行は段落・<br>になる(HTMLとして解釈されない)", async () => {
  const snapshot = snapshotOf({winnerMailTemplate: {...makeEvent().winnerMailTemplate, introBody: "1行目\n2行目\n\n次の段落"}});
  const r = await okRender({snapshot});
  assert.ok(r.html.includes("1行目<br>2行目</p>"));
  assert.ok(r.html.includes("次の段落</p>"));
});

test("件名は1行に正規化される(ヘッダー注入の防御)", async () => {
  const snapshot = snapshotOf();
  snapshot.template.subject = "件名\r\nBcc: x\ny";
  assert.equal((await okRender({snapshot})).subject, "件名 Bcc: x y");
});

test("必須情報が欠けていればメールを生成せず、理由(problems)を返す", async () => {
  const problems = async (options) => (await render(options)).problems;
  assert.deepEqual(await problems({participant: participant({name: " "})}), ["participant-name-missing"]);
  assert.deepEqual(await problems({attendances: []}), ["no-attendance"]);
  assert.deepEqual(await problems({attendances: [attendance("nope", 1)]}), ["attendance-program-unknown", "no-attendance"]);
  assert.deepEqual(await problems({attendances: [attendance("alpha", 0)]}), ["attendance-planned-count-invalid", "no-attendance"]);
  assert.deepEqual(await problems({attendances: [attendance("alpha", 1, {participantId: "other-000002"})]}), ["attendance-owner-mismatch", "no-attendance"]);
  assert.deepEqual(await problems({attendances: [attendance("alpha", 1, {eventId: "event2"})]}), ["attendance-owner-mismatch", "no-attendance"]);
  assert.deepEqual(await problems({participant: participant({publicId: "bad"})}), ["qr-inputs-invalid"]);
  const bad = await renderWinnerMail({snapshot: snapshotOf(), participant: participant(), attendances: attendances(), appBaseUrl: "http://insecure.invalid", generateQrPng: fakeQrPng});
  assert.deepEqual(bad.problems, ["qr-inputs-invalid"]);
});

test("snapshot: テンプレート未設定・不完全、イベント情報(名前・開催日時・会場)の不足は作れない。個人情報を含まない", () => {
  const problemsFor = (overrides) => buildMailSnapshot("event1", makeEvent(overrides)).problems;
  assert.deepEqual(problemsFor({winnerMailTemplate: undefined}), ["template-not-configured"]);
  assert.deepEqual(problemsFor({winnerMailTemplate: {version: 1, subject: "", introBody: "a", closingBody: "b"}}), ["template-subject-invalid"]);
  assert.deepEqual(problemsFor({eventName: " "}), ["event-name-missing"]);
  assert.deepEqual(problemsFor({startAt: null}), ["event-start-missing"]);
  assert.deepEqual(problemsFor({venue: undefined}), ["event-venue-missing"]);
  assert.deepEqual(problemsFor({eventName: "", startAt: undefined, venue: ""}), ["event-name-missing", "event-start-missing", "event-venue-missing"]);
  const snapshot = snapshotOf();
  assert.equal(snapshot.event.startAt, "2026-11-30T01:00:00.000Z");
  assert.deepEqual(snapshot.programs.map((p) => p.programId), ["talk", "alpha", "beta"], "snapshotはevent.programsを保持し、順序付けは表示時に行う");
  const serialized = JSON.stringify(snapshot);
  assert.ok(!/example\.invalid|架空 太郎|publicId|pub_/.test(serialized.replace("support@example.invalid", "")), "参加者の個人情報を含まない");
  assert.deepEqual(Object.keys(snapshot).sort(), ["event", "programs", "template"]);
});

test("senderName: 既存のevent.senderNameを再利用し、無ければイベント名(新しい重複フィールドを作らない)", () => {
  assert.equal(snapshotOf().event.senderName, "架空事務局");
  assert.equal(snapshotOf({senderName: ""}).event.senderName, "架空イベント");
  assert.ok(!("senderName" in snapshotOf().template));
});

test("リマインド等でも、同じview model(participant・attendances・event・QR・Web参加証URL)を文章と独立に再利用できる", () => {
  const built = buildMailViewModel({snapshot: snapshotOf(), participant: participant(), attendances: attendances(), appBaseUrl: APP_BASE_URL});
  assert.equal(built.ok, true);
  assert.deepEqual(Object.keys(built.viewModel).sort(), ["access", "address", "contact", "dateTimeText", "eventName", "notes", "programs", "qrPayload",
    "recipientName", "venue", "webPassUrl"]);
  assert.ok(!("subject" in built.viewModel) && !("introBody" in built.viewModel), "view modelに文章(winner専用)は含まれない");
});
