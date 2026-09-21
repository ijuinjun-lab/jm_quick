// 当選メールのレンダラー。プレビューと実送信は、必ずこの renderWinnerMail を使う(プレビュー専用の別レンダラーは作らない)。
// 同じ snapshot・participant・attendances・アプリURL を与えれば、件名・text・html・QRペイロード・Web参加証URL・QR画像が
// 必ず同一になる(時刻・乱数を使わない)。
//
// ■ text/plain と HTML を必ず両方生成する。どちらも同じview modelから作るため、参加内容が食い違わない。
// ■ 外部入力・管理者入力(氏名・イベント名・program名・時間・会場・住所・アクセス・本文など)は、HTMLでは必ずescapeする。
//   管理者入力はプレーンテキストとして保存されており、ここで安全なHTMLへ変換する(HTMLとして解釈しない)。
// ■ リマインド等でも、view model(buildMailViewModel)を再利用できる。文章(winner専用)はこのファイルの外から渡す。

const {buildMailViewModel} = require("./mail_view_model");
const {QR_CONTENT_ID} = require("./pass_urls");

const QR_FILENAME = "reception-qr.png";

function escapeHtml(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// プレーンテキスト → 段落(<p>)。空行で段落、単一の改行は<br>。すべてescape済み。
function paragraphsHtml(text, style) {
  return String(text).replace(/\r\n?/g, "\n").split(/\n{2,}/)
    .map((paragraph) => `<p style="${style}">${escapeHtml(paragraph).replace(/\n/g, "<br>")}</p>`).join("\n");
}
const linesHtml = (text) => escapeHtml(text).replace(/\r\n?|\n/g, "<br>");
const singleLine = (text) => String(text).replace(/[\r\n]+/g, " ").trim();

const RULE = "────────────────────";

// テキスト版。QR画像は表示できないため、Web参加証URLを必ず載せる。
function buildText(vm, template, {showEventName = false} = {}) {
  const lines = [];
  // 前日リマインドなど: 冒頭にイベント名を明示する(当選メールの出力は変えない)
  if (showEventName) lines.push(`【${vm.eventName}】`, "");
  lines.push(`${vm.recipientName} 様`, "", template.introBody, "", RULE);
  lines.push("【受付用QRコード】");
  lines.push("当日は、受付用QRコードを受付でご提示ください。");
  lines.push("QRコードは、メールのHTML表示で画像として表示されます。");
  lines.push("", "受付用QRコードが表示できない場合はこちら", vm.webPassUrl, "", RULE);
  lines.push("【ご参加内容】");
  for (const program of vm.programs) {
    lines.push("", `■ ${program.name}`);
    if (program.timeText) lines.push(`参加時間：${program.timeText}`);
    lines.push(`参加人数：${program.plannedCount}名`);
  }
  lines.push("", RULE, "【開催情報】", `開催日時：${vm.dateTimeText}`, `会場：${vm.venue}`);
  if (vm.address) lines.push(`住所：${vm.address}`);
  if (vm.access) lines.push(`アクセス：${vm.access}`);
  lines.push("", RULE, "", template.closingBody);
  if (vm.notes) lines.push("", "【注意事項】", vm.notes);
  if (vm.contact) lines.push("", "【お問い合わせ先】", vm.contact);
  return `${lines.join("\n")}\n`;
}

const P = "margin:0 0 14px 0;";
const H2 = "margin:24px 0 8px 0;padding-top:16px;border-top:1px solid #d9dde3;font-size:16px;color:#17324d;";
const H3 = "margin:14px 0 4px 0;font-size:15px;color:#17324d;";

function buildHtml(vm, template, subject, {showEventName = false} = {}) {
  const parts = [];
  if (showEventName) parts.push(`<p style="${P}font-size:18px;font-weight:bold;color:#17324d;">${escapeHtml(vm.eventName)}</p>`);
  parts.push(`<p style="${P}font-size:16px;font-weight:bold;">${escapeHtml(vm.recipientName)} 様</p>`);
  parts.push(paragraphsHtml(template.introBody, P));
  parts.push(`<h2 style="${H2}">受付用QRコード</h2>`);
  parts.push(`<p style="${P}">当日は、下記のQRコードを受付でご提示ください。</p>`);
  parts.push(`<p style="${P}text-align:center;"><img src="cid:${QR_CONTENT_ID}" alt="受付用QRコード" width="240" height="240" style="width:240px;height:240px;border:0;"></p>`);
  parts.push(`<p style="${P}">QRコードが表示されない場合は<a href="${escapeHtml(vm.webPassUrl)}">こちら</a></p>`);
  parts.push(`<p style="${P}font-size:12px;word-break:break-all;">${escapeHtml(vm.webPassUrl)}</p>`);
  parts.push(`<h2 style="${H2}">ご参加内容</h2>`);
  for (const program of vm.programs) {
    const rows = [];
    if (program.timeText) rows.push(`参加時間：${escapeHtml(program.timeText)}`);
    rows.push(`参加人数：${program.plannedCount}名`);
    parts.push(`<h3 style="${H3}">■ ${escapeHtml(program.name)}</h3>`);
    parts.push(`<p style="${P}">${rows.join("<br>")}</p>`);
  }
  parts.push(`<h2 style="${H2}">開催情報</h2>`);
  const info = [`開催日時：${escapeHtml(vm.dateTimeText)}`, `会場：${linesHtml(vm.venue)}`];
  if (vm.address) info.push(`住所：${linesHtml(vm.address)}`);
  if (vm.access) info.push(`アクセス：${linesHtml(vm.access)}`);
  parts.push(`<p style="${P}">${info.join("<br>")}</p>`);
  parts.push(`<div style="margin-top:20px;">${paragraphsHtml(template.closingBody, P)}</div>`);
  if (vm.notes) {
    parts.push(`<h2 style="${H2}">注意事項</h2>`, paragraphsHtml(vm.notes, P));
  }
  if (vm.contact) {
    parts.push(`<h2 style="${H2}">お問い合わせ先</h2>`, paragraphsHtml(vm.contact, P));
  }
  return `<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${escapeHtml(subject)}</title></head>
<body style="margin:0;padding:0;background:#f4f5f7;">
<div style="max-width:600px;margin:0 auto;padding:24px 20px;background:#ffffff;color:#222222;font-family:'Hiragino Kaku Gothic ProN','Yu Gothic',Meiryo,sans-serif;font-size:14px;line-height:1.7;">
${parts.join("\n")}
</div>
</body></html>
`;
}

// 当選メールを生成する(プレビューと実送信の共通の入口)。
//   snapshot: buildMailSnapshot の結果 / participant: {participantId, name, publicId} / attendances: programAttendancesの内容
//   generateQrPng(payload) → Promise<Buffer>: QR画像(PNG)の生成(注入)。
// 戻り値: {ok:true, subject, text, html, qrPayload, webPassUrl, attachments, viewModel} | {ok:false, problems}
async function renderMail({snapshot, participant, attendances, appBaseUrl, generateQrPng, showEventName = false}) {
  const built = buildMailViewModel({snapshot, participant, attendances, appBaseUrl});
  if (!built.ok) return {ok: false, problems: built.problems};
  const vm = built.viewModel;
  const {template} = snapshot;
  const subject = singleLine(template.subject);
  const png = await generateQrPng(vm.qrPayload);
  return {
    ok: true,
    subject,
    text: buildText(vm, template, {showEventName}),
    html: buildHtml(vm, template, subject, {showEventName}),
    qrPayload: vm.qrPayload,
    webPassUrl: vm.webPassUrl,
    attachments: [{
      filename: QR_FILENAME, contentType: "image/png", contentBase64: Buffer.from(png).toString("base64"),
      contentId: QR_CONTENT_ID, disposition: "inline",
    }],
    viewModel: vm,
  };
}

// 当選メール。既存の出力は変わらない。
const renderWinnerMail = (args) => renderMail(args);
// 前日リマインド。同じレンダラー・同じview model(program・時間・plannedCount・QR・Web参加証URL・会場)を使い、文章(snapshot.template)と
// 冒頭のイベント名だけが異なる。QR・publicIdは当選メールと同一(再発行しない)。
const renderReminderMail = (args) => renderMail({...args, showEventName: true});

module.exports = {QR_CONTENT_ID, QR_FILENAME, escapeHtml, renderWinnerMail, renderReminderMail};
