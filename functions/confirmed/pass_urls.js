// 受付用QRのペイロードと、Web参加証(QRが表示されない場合のバックアップ)のURL。
// QRの文字列は、この単一の純粋関数だけが生成する(メール用QR・Web参加証用QR・将来の再送・リマインドはすべて同じ文字列)。
//
// ■ 既存JM Quickとの互換:
//   - 受付QR: 従来のマイページ(participant_page.dart)が作るQRと同じ形式
//       {base}/reception?eventId={eventId}&participantId={participantId}&publicId={publicId}
//   - Web参加証: 従来のメール本文が使う /p/{participantId}?publicId={publicId}
// ■ 再送してもQRは変わらない: 入力はparticipantの不変のID(participantId・publicId)とeventId・アプリのURLだけで、
//   時刻・乱数・送信回数を一切含まない。
// ■ QRには氏名・メールアドレスなどの個人情報を入れない(推測困難なpublicIdと、内部のIDだけ)。

const {isValidParticipantId} = require("../programs");

const EVENT_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const PUBLIC_ID_PATTERN = /^pub_[A-Za-z0-9_-]{20,128}$/;
const BASE_URL_PATTERN = /^https:\/\/[A-Za-z0-9.-]+(:\d{1,5})?(\/[A-Za-z0-9._~/-]*)?$/;
// メールHTMLでQR画像を参照するContent-ID(固定値。ユーザー入力を含めない)。
const QR_CONTENT_ID = "jm-quick-reception-qr";

function normalizeBaseUrl(appBaseUrl) {
  if (typeof appBaseUrl !== "string" || !BASE_URL_PATTERN.test(appBaseUrl.trim())) throw new Error("invalid appBaseUrl");
  return appBaseUrl.trim().replace(/\/+$/, "");
}

function checkIds({eventId, participantId, publicId}) {
  if (typeof eventId !== "string" || !EVENT_ID_PATTERN.test(eventId)) throw new Error("invalid eventId");
  if (!isValidParticipantId(participantId)) throw new Error("invalid participantId");
  if (typeof publicId !== "string" || !PUBLIC_ID_PATTERN.test(publicId)) throw new Error("invalid publicId");
}

// 受付用QRのペイロード(QR画像に入れる文字列)。
function receptionQrPayload({appBaseUrl, eventId, participantId, publicId}) {
  checkIds({eventId, participantId, publicId});
  return `${normalizeBaseUrl(appBaseUrl)}/reception?eventId=${encodeURIComponent(eventId)}` +
    `&participantId=${participantId}&publicId=${encodeURIComponent(publicId)}`;
}

// QRが表示されない場合のWeb参加証URL。
function webPassUrl({appBaseUrl, eventId, participantId, publicId}) {
  checkIds({eventId, participantId, publicId});
  return `${normalizeBaseUrl(appBaseUrl)}/p/${encodeURIComponent(participantId)}?publicId=${encodeURIComponent(publicId)}`;
}

module.exports = {QR_CONTENT_ID, receptionQrPayload, webPassUrl};
