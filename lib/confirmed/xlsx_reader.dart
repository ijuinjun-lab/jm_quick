import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Excel(.xlsx)の表データだけを読む、最小の読み取り器(書式・画像・グラフは読まない。書き込みはしない)。
///
/// ■ 値はすべて「セルに表示される文字列」に近い形の文字列にする(CSVで保存した場合と同じ考え方):
///   - 文字列(共有文字列・インライン文字列): 本文の文字列だけ。ふりがな(rPh)は含めない。
///   - 数値: 整数ならそのまま(「2.0」ではなく「2」)。日付の書式のセルは「yyyy-MM-dd HH:mm:ss」等の文字列にする。
///   - 数式: 保存されている計算結果(キャッシュ)の値。計算結果が無ければ空。
///   - 真偽値: TRUE / FALSE。エラー値: #N/A 等の表示文字列。
/// ■ 結合セルは、Excelと同じく左上のセルだけが値を持つ(他は空として読む)。件数は[XlsxSheet.mergedRangeCount]で分かる。
/// ■ 行は、シートの1行目からデータのある最後の行までを、間の空の行も含めて返す(行番号がExcelの行番号と一致する)。
class XlsxParseException implements Exception {
  const XlsxParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

class XlsxSheet {
  const XlsxSheet({
    required this.name,
    required this.hidden,
    required this.rows,
    this.mergedRangeCount = 0,
    this.formulaCellCount = 0,
  });

  final String name;

  /// 非表示(hidden / veryHidden)のシート。
  final bool hidden;

  /// rows[i] = シートの(i+1)行目のセルの値(A列から、値のある最後の列まで)。値の無い行は空のリスト。
  final List<List<String>> rows;
  final int mergedRangeCount;
  final int formulaCellCount;

  bool get isEmpty => rows.every((r) => r.every((c) => c.trim().isEmpty));
}

/// 安全のための上限(UIの取込上限より十分大きい値。壊れたファイル・圧縮爆弾で固まらないため)。
const int _maxPartBytes = 64 * 1024 * 1024;
const int _maxRows = 100000;
const int _maxColumns = 16384;

const _relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

List<XlsxSheet> readXlsxSheets(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const XlsxParseException(
      'Excelファイル(.xlsx)として読み取れませんでした。ファイルが壊れていないか、パスワードが設定されていないかを確認してください。',
    );
  }
  final files = <String, ArchiveFile>{
    for (final f in archive.files)
      if (f.isFile) f.name.replaceAll('\\', '/'): f,
  };

  XmlDocument? part(String path) {
    final file = files[path];
    if (file == null) return null;
    if (file.size > _maxPartBytes) {
      throw const XlsxParseException('Excelファイルが大きすぎるため読み込めません。');
    }
    try {
      final content = file.readBytes();
      if (content == null) return null;
      return XmlDocument.parse(_decodeUtf8(content));
    } catch (_) {
      throw const XlsxParseException('Excelファイルの内容を読み取れませんでした(形式が壊れています)。');
    }
  }

  final workbookPath = _officeDocumentPath(part('_rels/.rels'));
  final workbook = part(workbookPath);
  if (workbook == null) {
    throw const XlsxParseException(
      'Excelファイル(.xlsx)として読み取れませんでした(ブックの情報がありません)。古い形式(.xls)の場合は、.xlsxで保存し直してください。',
    );
  }
  final baseDir = workbookPath.contains('/')
      ? workbookPath.substring(0, workbookPath.lastIndexOf('/') + 1)
      : '';
  final rels = _relationships(part(_relsPathOf(workbookPath)), baseDir);

  final sharedStringsPath =
      rels.entries
          .where((e) => e.value.type.endsWith('/sharedStrings'))
          .map((e) => e.value.target)
          .firstOrNull ??
      '${baseDir}sharedStrings.xml';
  final sharedStrings = [
    for (final si in _children(part(sharedStringsPath)?.rootElement, 'si'))
      _richText(si),
  ];

  final stylesPath =
      rels.entries
          .where((e) => e.value.type.endsWith('/styles'))
          .map((e) => e.value.target)
          .firstOrNull ??
      '${baseDir}styles.xml';
  final dateStyles = _dateStyleIndexes(part(stylesPath));

  final workbookPr = _children(workbook.rootElement, 'workbookPr').firstOrNull;
  final date1904 = const {
    'true',
    '1',
  }.contains(workbookPr?.getAttribute('date1904'));

  final sheetsElement = _children(workbook.rootElement, 'sheets').firstOrNull;
  final result = <XlsxSheet>[];
  for (final sheet in _children(sheetsElement, 'sheet')) {
    final name = sheet.getAttribute('name') ?? '';
    final state = sheet.getAttribute('state') ?? 'visible';
    final relId = sheet.getAttribute('id', namespace: _relNs);
    final target = relId == null ? null : rels[relId]?.target;
    final doc = target == null ? null : part(target);
    if (doc == null) {
      throw XlsxParseException('シート「$name」を読み取れませんでした。');
    }
    result.add(
      _readSheet(
        doc,
        name: name,
        hidden: state != 'visible',
        sharedStrings: sharedStrings,
        dateStyles: dateStyles,
        date1904: date1904,
      ),
    );
  }
  if (result.isEmpty) {
    throw const XlsxParseException('Excelファイルにシートがありません。');
  }
  return result;
}

String _decodeUtf8(List<int> bytes) {
  var data = bytes;
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = data.sublist(3);
  }
  return utf8.decode(data);
}

Iterable<XmlElement> _children(XmlElement? parent, String localName) =>
    parent == null
    ? const []
    : parent.childElements.where((e) => e.name.local == localName);

String _relsPathOf(String path) {
  final slash = path.lastIndexOf('/');
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
  final file = slash >= 0 ? path.substring(slash + 1) : path;
  return '${dir}_rels/$file.rels';
}

String _officeDocumentPath(XmlDocument? rootRels) {
  for (final rel in _children(rootRels?.rootElement, 'Relationship')) {
    if ((rel.getAttribute('Type') ?? '').endsWith('/officeDocument')) {
      final target = rel.getAttribute('Target') ?? '';
      if (target.isNotEmpty) return _resolve('', target);
    }
  }
  return 'xl/workbook.xml';
}

Map<String, ({String type, String target})> _relationships(
  XmlDocument? doc,
  String baseDir,
) => {
  for (final rel in _children(doc?.rootElement, 'Relationship'))
    if (rel.getAttribute('Id') != null && rel.getAttribute('Target') != null)
      rel.getAttribute('Id')!: (
        type: rel.getAttribute('Type') ?? '',
        target: _resolve(baseDir, rel.getAttribute('Target')!),
      ),
};

/// 関係(rels)のTargetを、zip内のパスにする(「/xl/…」の絶対指定・「../」を解決する)。
String _resolve(String baseDir, String target) {
  final raw = target.startsWith('/') ? target.substring(1) : '$baseDir$target';
  final parts = <String>[];
  for (final segment in raw.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(segment);
    }
  }
  return parts.join('/');
}

/// 共有文字列・インライン文字列の本文。ふりがな(rPh)・ふりがなの設定(phoneticPr)は含めない。
String _richText(XmlElement element) {
  final buffer = StringBuffer();
  for (final child in element.childElements) {
    switch (child.name.local) {
      case 't':
        buffer.write(child.innerText);
      case 'r':
        for (final t in _children(child, 't')) {
          buffer.write(t.innerText);
        }
    }
  }
  return _unescapeOoxml(buffer.toString());
}

/// OOXMLの文字のエスケープ「_x000D_」等を元の文字へ戻す(「_x005F_」は「_」そのもの)。
String _unescapeOoxml(String text) {
  if (!text.contains('_x')) return text;
  return text.replaceAllMapped(
    RegExp(r'_x([0-9A-Fa-f]{4})_'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
}

/// 日付・時刻の書式が指定されたセルのスタイル番号(cellXfsの位置)。
Set<int> _dateStyleIndexes(XmlDocument? styles) {
  final root = styles?.rootElement;
  final custom = <int, String>{
    for (final f in _children(_children(root, 'numFmts').firstOrNull, 'numFmt'))
      if (int.tryParse(f.getAttribute('numFmtId') ?? '') != null)
        int.parse(f.getAttribute('numFmtId')!):
            f.getAttribute('formatCode') ?? '',
  };
  final result = <int>{};
  final xfs = _children(_children(root, 'cellXfs').firstOrNull, 'xf').toList();
  for (var i = 0; i < xfs.length; i++) {
    final id = int.tryParse(xfs[i].getAttribute('numFmtId') ?? '') ?? 0;
    final code = custom[id];
    if (code != null ? _isDateFormatCode(code) : _isBuiltInDateFormat(id)) {
      result.add(i);
    }
  }
  return result;
}

/// 組み込みの日付・時刻の書式(日本語環境の和暦・年月日の書式27〜36・50〜58を含む)。
bool _isBuiltInDateFormat(int id) =>
    (id >= 14 && id <= 22) ||
    (id >= 27 && id <= 36) ||
    (id >= 45 && id <= 47) ||
    (id >= 50 && id <= 58);

bool _isDateFormatCode(String code) {
  // 文字列リテラル・エスケープ・色や条件([Red]等)を除いてから、日付・時刻の記号があるか見る。
  final stripped = code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAll(RegExp(r'\[(?![hms]+\])[^\]]*\]', caseSensitive: false), '');
  if (stripped.toLowerCase() == 'general') return false;
  return RegExp(r'[ymdhsg]', caseSensitive: false).hasMatch(stripped);
}

XlsxSheet _readSheet(
  XmlDocument doc, {
  required String name,
  required bool hidden,
  required List<String> sharedStrings,
  required Set<int> dateStyles,
  required bool date1904,
}) {
  final root = doc.rootElement;
  final sheetData = _children(root, 'sheetData').firstOrNull;
  final cellsByRow = <int, Map<int, String>>{};
  var formulas = 0;
  var nextRow = 1;
  for (final row in _children(sheetData, 'row')) {
    final rowNumber = int.tryParse(row.getAttribute('r') ?? '') ?? nextRow;
    nextRow = rowNumber + 1;
    if (rowNumber < 1 || rowNumber > _maxRows) {
      throw const XlsxParseException('シートの行数が多すぎるため読み込めません。');
    }
    var nextColumn = 1;
    for (final cell in _children(row, 'c')) {
      final column = _columnOf(cell.getAttribute('r')) ?? nextColumn;
      nextColumn = column + 1;
      if (column > _maxColumns) {
        throw const XlsxParseException('シートの列数が多すぎるため読み込めません。');
      }
      if (_children(cell, 'f').isNotEmpty) formulas += 1;
      final value = _cellValue(
        cell,
        sharedStrings: sharedStrings,
        dateStyles: dateStyles,
        date1904: date1904,
      );
      if (value.isEmpty) continue;
      (cellsByRow[rowNumber] ??= {})[column] = value;
    }
  }
  final lastRow = cellsByRow.keys.fold<int>(0, (a, b) => a > b ? a : b);
  final rows = <List<String>>[
    for (var r = 1; r <= lastRow; r++)
      if (cellsByRow[r] case final cells?)
        [
          for (var c = 1; c <= cells.keys.reduce((a, b) => a > b ? a : b); c++)
            cells[c] ?? '',
        ]
      else
        const <String>[],
  ];
  final merged = _children(
    _children(root, 'mergeCells').firstOrNull,
    'mergeCell',
  ).length;
  return XlsxSheet(
    name: name,
    hidden: hidden,
    rows: rows,
    mergedRangeCount: merged,
    formulaCellCount: formulas,
  );
}

/// 「AB12」→ 28(A=1)。
int? _columnOf(String? reference) {
  final match = RegExp(r'^([A-Za-z]{1,3})\d*$').firstMatch(reference ?? '');
  if (match == null) return null;
  var n = 0;
  for (final unit in match.group(1)!.toUpperCase().codeUnits) {
    n = n * 26 + (unit - 64);
  }
  return n;
}

String _cellValue(
  XmlElement cell, {
  required List<String> sharedStrings,
  required Set<int> dateStyles,
  required bool date1904,
}) {
  final type = cell.getAttribute('t') ?? 'n';
  final v = _children(cell, 'v').firstOrNull?.innerText;
  switch (type) {
    case 's':
      final index = int.tryParse(v ?? '');
      if (index == null || index < 0 || index >= sharedStrings.length) {
        throw const XlsxParseException('Excelファイルの文字列の情報が壊れています。');
      }
      return sharedStrings[index];
    case 'inlineStr':
      final inline = _children(cell, 'is').firstOrNull;
      return inline == null ? '' : _richText(inline);
    case 'str' || 'e':
      return _unescapeOoxml(v ?? '');
    case 'b':
      return v == null ? '' : (v.trim() == '1' ? 'TRUE' : 'FALSE');
  }
  if (v == null || v.trim().isEmpty) return '';
  final number = num.tryParse(v.trim());
  if (number == null) return v.trim();
  final style = int.tryParse(cell.getAttribute('s') ?? '') ?? 0;
  if (dateStyles.contains(style)) {
    return _formatSerialDate(number.toDouble(), date1904: date1904) ?? v.trim();
  }
  return _formatNumber(number, v.trim());
}

String _formatNumber(num number, String original) {
  if (number is int) return number.toString();
  final d = number.toDouble();
  if (d.isFinite && d == d.truncateToDouble() && d.abs() < 1e15) {
    return d.toInt().toString();
  }
  return original;
}

/// Excelのシリアル値 → 「yyyy-MM-dd」(時刻なし)/「yyyy-MM-dd HH:mm:ss」/「HH:mm:ss」(1日未満)。
String? _formatSerialDate(double serial, {required bool date1904}) {
  if (!serial.isFinite || serial < 0 || serial > 2958466) return null;
  final totalSeconds = (serial * 86400).round();
  final days = totalSeconds ~/ 86400;
  final seconds = totalSeconds % 86400;
  String two(int n) => n.toString().padLeft(2, '0');
  final time =
      '${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  if (days == 0 && !date1904) return time;
  // 1900年方式は、Excelが1900年2月29日(存在しない日)を数えているため、1900年3月1日以降は1899-12-30起点になる。
  final DateTime date;
  if (date1904) {
    date = DateTime.utc(1904, 1, 1).add(Duration(days: days));
  } else if (days < 60) {
    date = DateTime.utc(1899, 12, 31).add(Duration(days: days - 1));
  } else {
    date = DateTime.utc(1899, 12, 30).add(Duration(days: days));
  }
  final day =
      '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}';
  return seconds == 0 ? day : '$day $time';
}
