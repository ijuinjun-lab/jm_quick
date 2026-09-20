// QR画像(PNG)の生成テスト。PNGをデコードして、ペイロードのQRコードと一致することを確認する(通信なし)。
const assert = require("node:assert/strict");
const {test} = require("node:test");
const QRCode = require("qrcode");
const {PNG} = require("pngjs");
const {generateQrPng} = require("../qr_png");
const {receptionQrPayload} = require("../confirmed/pass_urls");

const payload = receptionQrPayload({appBaseUrl: "https://app.invalid", eventId: "event1", participantId: "batchA-000002", publicId: "pub_0123456789abcdef0123456789abcdef"});

test("PNGとして有効で、mail-apiの添付上限(100KB)に十分収まる", async () => {
  const png = await generateQrPng(payload);
  assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  assert.ok(png.length > 500 && png.length < 20 * 1024, `size=${png.length}`);
  assert.doesNotThrow(() => PNG.sync.read(png));
});

test("PNGの画素が、ペイロードのQRコード(モジュール行列)と完全に一致する", async () => {
  const image = PNG.sync.read(await generateQrPng(payload));
  const qr = QRCode.create(payload, {errorCorrectionLevel: "M"});
  const size = qr.modules.size;
  const margin = 2;
  const scale = image.width / (size + margin * 2);
  assert.equal(Number.isInteger(scale), true);
  assert.equal(image.width, image.height);
  let mismatches = 0;
  for (let row = 0; row < size; row += 1) {
    for (let col = 0; col < size; col += 1) {
      const x = Math.floor((col + margin + 0.5) * scale);
      const y = Math.floor((row + margin + 0.5) * scale);
      const i = (y * image.width + x) * 4;
      const dark = image.data[i] < 128;
      if (dark !== Boolean(qr.modules.get(row, col))) mismatches += 1;
    }
  }
  assert.equal(mismatches, 0);
  // 余白(quiet zone)は白
  assert.ok(image.data[0] > 200 && image.data[1] > 200 && image.data[2] > 200);
});

test("QRのデータ部分はペイロード文字列そのもの(個人情報の混入なし)", () => {
  const qr = QRCode.create(payload, {errorCorrectionLevel: "M"});
  // qrcodeは入力を複数のセグメント(英数字・バイト等)に分割することがある。全セグメントを連結すると元の文字列になる。
  const data = qr.segments.map((segment) => (typeof segment.data === "string" ? segment.data : Buffer.from(segment.data).toString("utf8"))).join("");
  assert.equal(data, payload);
});

test("決定的: 同じ文字列からは常に同じPNGバイト列(再送してもQR画像は変わらない)・違う文字列は違う画像", async () => {
  const first = await generateQrPng(payload);
  for (let i = 0; i < 5; i += 1) assert.ok(first.equals(await generateQrPng(payload)));
  const other = await generateQrPng(payload.replace("000002", "000003"));
  assert.ok(!first.equals(other));
});

test("不正なペイロード(空・非文字列・長すぎる)は生成しない", () => {
  for (const bad of ["", null, undefined, 1, "x".repeat(1001)]) assert.throws(() => generateQrPng(bad), /invalid QR payload/);
});
