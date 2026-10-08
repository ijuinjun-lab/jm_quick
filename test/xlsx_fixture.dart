// テスト用の、匿名の小さなExcel(.xlsx)をメモリ上で組み立てる(実ファイル・実データは使わない)。
// Excelが保存する形に近いXML(共有文字列・ふりがな(rPh)・インライン文字列・数値・日付の書式・数式のキャッシュ・
// 結合セル・非表示シート)を、必要な分だけ生成する。
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// セルの値。String(共有文字列)/ num(数値)/ [XCell]の各種。nullは空のセル(保存しない)。
sealed class XCell {
  const XCell();
}

/// ふりがな(rPh)付きの共有文字列(ふりがなは読み取り結果に含まれないこと)。
class XPhonetic extends XCell {
  const XPhonetic(this.text, this.phonetic);
  final String text;
  final String phonetic;
}

/// インライン文字列(t="inlineStr")。
class XInline extends XCell {
  const XInline(this.text);
  final String text;
}

/// 日付の書式(組み込みの書式22: yyyy/m/d h:mm)のシリアル値。
class XDate extends XCell {
  const XDate(this.serial);
  final num serial;
}

/// 数式(計算結果のキャッシュ付き)。
class XFormula extends XCell {
  const XFormula(this.formula, this.cached);
  final String formula;
  final num cached;
}

class XSheet {
  const XSheet(
    this.name,
    this.rows, {
    this.hidden = false,
    this.merges = const [],
  });
  final String name;

  /// rows[i] はシートの(i+1)行目。
  final List<List<Object?>> rows;
  final bool hidden;
  final List<String> merges;
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _col(int index) {
  var n = index + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

const _ns = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _rns =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _pns = 'http://schemas.openxmlformats.org/package/2006/relationships';

Uint8List buildXlsx(List<XSheet> sheets) {
  final shared = <String>[];
  final sharedXml = <String>[];
  int sharedIndex(String text, [String? phonetic]) {
    shared.add(text);
    sharedXml.add(
      phonetic == null
          ? '<si><t xml:space="preserve">${_esc(text)}</t></si>'
          : '<si><t>${_esc(text)}</t><rPh sb="0" eb="${text.length}"><t>${_esc(phonetic)}</t></rPh><phoneticPr fontId="1"/></si>',
    );
    return shared.length - 1;
  }

  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  final sheetXml = <String>[];
  for (final sheet in sheets) {
    final rows = StringBuffer();
    for (var r = 0; r < sheet.rows.length; r++) {
      final cells = StringBuffer();
      for (var c = 0; c < sheet.rows[r].length; c++) {
        final v = sheet.rows[r][c];
        final ref = '${_col(c)}${r + 1}';
        switch (v) {
          case null:
            continue;
          case String s:
            cells.write('<c r="$ref" t="s"><v>${sharedIndex(s)}</v></c>');
          case num n:
            cells.write('<c r="$ref"><v>$n</v></c>');
          case XPhonetic p:
            cells.write(
              '<c r="$ref" t="s"><v>${sharedIndex(p.text, p.phonetic)}</v></c>',
            );
          case XInline i:
            cells.write(
              '<c r="$ref" t="inlineStr"><is><t>${_esc(i.text)}</t></is></c>',
            );
          case XDate d:
            cells.write('<c r="$ref" s="1"><v>${d.serial}</v></c>');
          case XFormula f:
            cells.write(
              '<c r="$ref"><f>${_esc(f.formula)}</f><v>${f.cached}</v></c>',
            );
        }
      }
      if (cells.isNotEmpty) rows.write('<row r="${r + 1}">$cells</row>');
    }
    final merges = sheet.merges.isEmpty
        ? ''
        : '<mergeCells count="${sheet.merges.length}">${sheet.merges.map((m) => '<mergeCell ref="$m"/>').join()}</mergeCells>';
    sheetXml.add(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="$_ns" xmlns:r="$_rns"><sheetData>$rows</sheetData>$merges</worksheet>',
    );
  }

  add(
    '[Content_Types].xml',
    '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/></Types>',
  );
  add(
    '_rels/.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="$_pns">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>',
  );
  add(
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="$_ns" xmlns:r="$_rns"><sheets>'
        '${[for (var i = 0; i < sheets.length; i++) '<sheet name="${_esc(sheets[i].name)}" sheetId="${i + 1}"${sheets[i].hidden ? ' state="hidden"' : ''} r:id="rId${i + 1}"/>'].join()}'
        '</sheets></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="$_pns">'
        '${[for (var i = 0; i < sheets.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}'
        '<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
        '<Relationship Id="rIdT" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '</Relationships>',
  );
  for (var i = 0; i < sheets.length; i++) {
    add('xl/worksheets/sheet${i + 1}.xml', sheetXml[i]);
  }
  add(
    'xl/sharedStrings.xml',
    '<?xml version="1.0" encoding="UTF-8"?><sst xmlns="$_ns" count="${shared.length}" uniqueCount="${shared.length}">${sharedXml.join()}</sst>',
  );
  // スタイル0: 標準 / スタイル1: 組み込みの日付書式22
  add(
    'xl/styles.xml',
    '<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="$_ns"><cellXfs count="2">'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="22" fontId="0" fillId="0" borderId="0" applyNumberFormat="1"/>'
        '</cellXfs></styleSheet>',
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// 正式フォーマット(sipposample形式)の主要列をもつ、匿名の参加者リストの列名。
/// HEBEL属性の列名は、実際のExcelと同じく「&#160;」の表記を含む。
const fixtureHeaders = [
  '区分', 'id', '氏名', 'かな', 'メールアドレス', 'HEBEL&#160;HAUSにお住まいですか',
  '午前参加時間', '午前参加人数', '午後参加時間', '午後参加人数', 'トークショー', 'トークショー人数', '登録日時',
];

/// HEBEL属性の選択肢(申込フォームの原文)。
const hebelHausOption = 'ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）';
const hebelMaisonOption = 'ヘーベルメゾンにお住まい';
const hebelNoneOption = 'いいえ';

/// 匿名の参加者1行(犬・猫・トークの参加と人数・時間枠、HEBEL属性)。
List<Object?> fixtureRow(
  int i, {
  required Object? hebel,
  String am = '10:30-11:10',
  Object? amCount = 2,
  String pm = '参加を希望しない',
  Object? pmCount,
  String talk = '参加を希望する',
  Object? talkCount = 1,
}) => [
  const XPhonetic('新規申込', 'シンキモウシコミ'),
  i,
  '架空 参加者$i',
  'かくう さんかしゃ',
  'fixture$i@example.invalid',
  hebel,
  am,
  amCount,
  pm,
  pmCount,
  talk,
  talkCount,
  '2026-09-0${i % 9 + 1} 10:00:00',
];
