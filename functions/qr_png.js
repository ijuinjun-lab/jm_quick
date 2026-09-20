// 受付QRのPNG画像を生成する(qrcodeパッケージ)。決定的: 同じ文字列からは常に同じPNGバイト列になる。
// ペイロード(文字列)の生成は functions/confirmed/pass_urls.js が唯一の正本。ここでは画像にするだけ。
const QRCode = require("qrcode");

// 誤り訂正M・余白2モジュール・1モジュール8px(約400px四方・数KB)。メール表示は240px程度に縮小される。
function generateQrPng(payload) {
  if (typeof payload !== "string" || payload === "" || payload.length > 1000) throw new Error("invalid QR payload");
  return QRCode.toBuffer(payload, {type: "png", errorCorrectionLevel: "M", margin: 2, scale: 8});
}

module.exports = {generateQrPng};
