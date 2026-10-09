import 'dart:typed_data';

void downloadBytes(
  Uint8List bytes,
  String fileName, {
  String mimeType = 'text/csv;charset=utf-8',
}) {
  throw UnsupportedError('この環境ではファイルを書き出せません。');
}
