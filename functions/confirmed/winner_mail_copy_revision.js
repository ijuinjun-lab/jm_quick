// 正式文面のローカル改訂案を作る純粋関数。Firestoreへの保存や自動置換は行わない。
// 通常当選・繰り上げ当選の各テンプレートに適用し、後日の設定更新前に差分を確認する。
const {DOTTED_RULE} = require("./mail_render");
const BEFORE = "この日が素晴らしいご縁のはじまりとなるよう、スタッフ一同、心を込めて準備を進めております。";
const SEND_ONLY = "このメールは送信専用アドレスから配信されています。";
const CONTACT = "お問い合わせの際は事務局メールアドレス（sippo-support@info-event-jimukyoku.jp）までお願いいたします。";
const OLD_QR = "このQRコードは、お申し込みいただいたすべてのプログラムで共通してご利用いただけます。";
const NEW_QR = "このQRコードは、ご参加予約確定のプログラムで共通してご利用いただけます。";
function reviseWinnerMailCopy(template) {
  let intro = template.introBody;
  if (typeof intro !== "string") throw new Error("intro-body-missing");
  const count = (text) => intro.split(text).length - 1;
  if (count(OLD_QR) + count(NEW_QR) !== 1) throw new Error("qr-copy-ambiguous");
  intro = intro.replace(OLD_QR, NEW_QR);
  for (const [before, after] of [[BEFORE, SEND_ONLY], [CONTACT, NEW_QR]]) {
    if (count(before) !== 1 || count(after) !== 1) throw new Error("divider-anchor-ambiguous");
    const start = intro.indexOf(before) + before.length, end = intro.indexOf(after);
    const gap = intro.slice(start, end);
    if (end < start || (gap.trim() !== "" && gap.trim() !== DOTTED_RULE)) throw new Error("divider-content-conflict");
    intro = intro.slice(0, start) + `\n\n${DOTTED_RULE}\n\n` + intro.slice(end);
  }
  return {...template, introBody: intro};
}
module.exports = {reviseWinnerMailCopy};
