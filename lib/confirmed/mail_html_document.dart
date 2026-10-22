import 'dart:convert';

/// The server's complete email document, with its MIME attachment resolved for
/// the browser. No email text, styles, layout, dates or URLs are reconstructed.
/// The original document remains untouched in WinnerMailPreview.html.
String mailPreviewDocument(
  String html,
  String qrPngBase64, {
  bool allowWithoutQr = false,
}) {
  if (allowWithoutQr &&
      qrPngBase64.isEmpty &&
      !html.contains("cid:") &&
      html.contains("<head>") &&
      html.contains("<body ")) {
    return html
        .replaceFirst("<head>", "<head>$mailPreviewSecurityHead")
        .replaceFirst("<body ", "<body inert ");
  }
  if (html.isEmpty) throw const FormatException('HTMLメールを取得できませんでした。');
  if (qrPngBase64.isEmpty) throw const FormatException('QR画像を取得できませんでした。');
  final bytes = base64Decode(qrPngBase64);
  const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 8 ||
      List.generate(8, (i) => bytes[i] == pngSignature[i]).contains(false)) {
    throw const FormatException('QR画像を表示できませんでした。');
  }
  const cid = 'cid:jm-quick-reception-qr';
  if (!html.contains(cid) ||
      !html.contains('<head>') ||
      !html.contains('<body ')) {
    throw const FormatException('HTMLメールの形式を確認できませんでした。');
  }
  return html
      .replaceAll(cid, 'data:image/png;base64,${base64Encode(bytes)}')
      .replaceFirst('<head>', '<head>$mailPreviewSecurityHead')
      // Inert prevents mouse AND keyboard link navigation, without changing
      // link appearance or the email's own inline CSS. Scrolling is retained.
      .replaceFirst('<body ', '<body inert ');
}

const mailPreviewSecurityHead =
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; '
    'script-src \'none\'; style-src \'unsafe-inline\'; img-src data:; '
    'connect-src \'none\'; frame-src \'none\'; object-src \'none\'; '
    'base-uri \'none\'; form-action \'none\'">'
    '<meta name="referrer" content="no-referrer">';
