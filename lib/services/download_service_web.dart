// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;
import 'dart:typed_data';

/// ブラウザ上でファイルを保存させる(サーバー・Storageには何も保存しない)。[mimeType]の既定はCSV(従来どおり)。
void downloadBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'text/csv;charset=utf-8',
}) {
  final blob = html.Blob([bytes], mimeType);
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = fileName
    ..click();
  html.Url.revokeObjectUrl(url);
}
