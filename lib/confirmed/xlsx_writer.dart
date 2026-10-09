import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 業務データ確認用の、最小のExcel(.xlsx)書き出し(1シート・明細表)。読み取りは[xlsx_reader.dart]。
///
/// ■ 値の型(セルの値として渡す):
///   - String: 文字列のセル(インライン文字列)。数字だけの文字列・先頭が「=」の文字列も、数値・数式にしない
///   - int / double: 数値のセル
///   - [XlsxDateTime]: 日付時刻のセル(Excelのシリアル値+「yyyy/mm/dd hh:mm:ss」書式。並べ替え・フィルターができる)
///   - null: 空のセル
/// ■ 1行目は列名(太字)。先頭行を固定し、全体にオートフィルターを付ける。装飾はこれだけ。
/// ■ ブラウザ上で作る(サーバー・Storageには保存しない)。
class XlsxDateTime {
  /// [wallClock]の年月日・時分秒を、そのままExcelの日時にする(Excelにはタイムゾーンが無いため、
  /// 呼び出し側が表示したい時刻(例: 日本時間)にそろえて渡す)。
  const XlsxDateTime(this.wallClock);
  final DateTime wallClock;
}

/// 列名と列幅(Excelの文字数単位)。
typedef XlsxColumn = ({String header, double width});

const xlsxMimeType =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

Uint8List buildXlsx({
  required String sheetName,
  required List<XlsxColumn> columns,
  required List<List<Object?>> rows,
}) {
  final archive = Archive();
  void add(String name, String xml) {
    final bytes = utf8.encode(xml);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  final safeSheetName = _sheetName(sheetName);
  final lastColumn = _columnName(columns.isEmpty ? 1 : columns.length);
  final lastRow = rows.length + 1;
  add('[Content_Types].xml', _contentTypes);
  add('_rels/.rels', _rootRels);
  add('xl/workbook.xml', _workbook(safeSheetName, lastColumn, lastRow));
  add('xl/_rels/workbook.xml.rels', _workbookRels);
  add('xl/styles.xml', _styles);
  add(
    'xl/worksheets/sheet1.xml',
    _sheet(columns, rows, lastColumn: lastColumn, lastRow: lastRow),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 列番号(1始まり) → 「A」「AB」等。
String _columnName(int number) {
  var n = number;
  final buffer = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    buffer.write(String.fromCharCode(65 + rem));
    n = (n - 1) ~/ 26;
  }
  return buffer.toString().split('').reversed.join();
}

/// シート名に使えない文字([]:*?/\)を除き、31文字以内にする。
String _sheetName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), '_').trim();
  final value = cleaned.isEmpty ? 'Sheet1' : cleaned;
  return value.length > 31 ? value.substring(0, 31) : value;
}

/// XMLの文字列として安全にする: XMLで使えない文字(制御文字・不正なサロゲート)を除き、
/// Excelがエスケープとして解釈する「_xHHHH_」をそのままの文字として残す(「_x005F_」で「_」を表す)。
String _xmlText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final allowed =
        rune == 0x9 ||
        rune == 0xA ||
        rune == 0xD ||
        (rune >= 0x20 && rune <= 0xD7FF) ||
        (rune >= 0xE000 && rune <= 0xFFFD) ||
        (rune >= 0x10000 && rune <= 0x10FFFF);
    if (allowed) buffer.writeCharCode(rune);
  }
  final escapedOoxml = buffer.toString().replaceAllMapped(
    RegExp(r'_(x[0-9A-Fa-f]{4}_)'),
    (m) => '_x005F_${m.group(1)}',
  );
  return _xmlEscape(escapedOoxml);
}

/// XMLの特殊文字(& < > ")だけをエスケープする(シート名・定義名用)。
String _xmlEscape(String value) => const HtmlEscape(
  HtmlEscapeMode.element,
).convert(value).replaceAll('"', '&quot;');

/// 日付時刻 → Excelのシリアル値(1900年方式。1900年3月1日以降)。
double _serial(DateTime wallClock) {
  final utc = DateTime.utc(
    wallClock.year,
    wallClock.month,
    wallClock.day,
    wallClock.hour,
    wallClock.minute,
    wallClock.second,
  );
  return utc.difference(DateTime.utc(1899, 12, 30)).inSeconds / 86400;
}

const _styleHeader = 1;
const _styleDateTime = 2;

String _cell(String ref, Object? value, {int? style}) {
  final s = style == null ? '' : ' s="$style"';
  return switch (value) {
    null => '',
    final String text when text.isEmpty => '',
    final String text =>
      '<c r="$ref" t="inlineStr"$s><is><t xml:space="preserve">${_xmlText(text)}</t></is></c>',
    final int n => '<c r="$ref"$s><v>$n</v></c>',
    final double d when d.isFinite => '<c r="$ref"$s><v>$d</v></c>',
    final XlsxDateTime dt =>
      '<c r="$ref" s="$_styleDateTime"><v>${_serial(dt.wallClock)}</v></c>',
    _ => throw ArgumentError(
      'unsupported xlsx cell value: ${value.runtimeType}',
    ),
  };
}

String _sheet(
  List<XlsxColumn> columns,
  List<List<Object?>> rows, {
  required String lastColumn,
  required int lastRow,
}) {
  final b = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    ..write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">',
    )
    ..write('<dimension ref="A1:$lastColumn$lastRow"/>')
    // 先頭行(列名)を固定する
    ..write(
      '<sheetViews><sheetView workbookViewId="0">'
      '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
      '<selection pane="bottomLeft" activeCell="A2" sqref="A2"/>'
      '</sheetView></sheetViews>',
    )
    ..write('<sheetFormatPr defaultRowHeight="15"/>');
  if (columns.isNotEmpty) {
    b.write('<cols>');
    for (var i = 0; i < columns.length; i++) {
      b.write(
        '<col min="${i + 1}" max="${i + 1}" width="${columns[i].width}" customWidth="1"/>',
      );
    }
    b.write('</cols>');
  }
  b.write('<sheetData><row r="1">');
  for (var i = 0; i < columns.length; i++) {
    b.write(
      _cell('${_columnName(i + 1)}1', columns[i].header, style: _styleHeader),
    );
  }
  b.write('</row>');
  for (var r = 0; r < rows.length; r++) {
    final rowNumber = r + 2;
    b.write('<row r="$rowNumber">');
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      b.write(_cell('${_columnName(c + 1)}$rowNumber', row[c]));
    }
    b.write('</row>');
  }
  b
    ..write('</sheetData>')
    // 1行目を見出しとして、全体にオートフィルター(並べ替え・絞り込み)を付ける
    ..write('<autoFilter ref="A1:$lastColumn$lastRow"/>')
    ..write('</worksheet>');
  return b.toString();
}

String _workbook(String sheetName, String lastColumn, int lastRow) {
  final quoted = "'${sheetName.replaceAll("'", "''")}'";
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="${_xmlEscape(sheetName)}" sheetId="1" r:id="rId1"/></sheets>'
      '<definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">'
      '${_xmlEscape(quoted)}!\$A\$1:\$$lastColumn\$$lastRow</definedName></definedNames>'
      '</workbook>';
}

const _contentTypes =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    '</Types>';

const _rootRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
    '</Relationships>';

const _workbookRels =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
    '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

// cellXfs: 0=標準 / 1=列名(太字) / 2=日付時刻(yyyy/mm/dd hh:mm:ss)
const _styles =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy/mm/dd hh:mm:ss"/></numFmts>'
    '<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
    '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>'
    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
    '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
    '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
    '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
    '</styleSheet>';
