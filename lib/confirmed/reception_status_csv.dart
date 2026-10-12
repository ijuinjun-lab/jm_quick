import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../services/participant_csv_export_service.dart'
    show neutralizeSpreadsheetFormula, safeExportFileName;
import 'reception_status_summary.dart';

/// 主催者用「受付状況一覧」の、表示中の一覧(検索・絞り込み・並び順を反映した全行)のCSV。純粋関数。
///
/// ■ 入力は画面が保持している行(filterReceptionRows の結果)だけ。通信・Firestoreの読取はしない。
///   描画範囲(スクロール位置・仮想リスト)には依存しない。
/// ■ 構成: 先頭に抽出条件の情報欄(「項目名,値」の2列×10行)→ 空行1行 → 参加者一覧の見出し → 参加者データ。
///   情報欄には、出力ボタンを押した時点の画面の条件(氏名検索・program・受付状態・HEBEL属性・並び順)と、
///   データ最終更新日時(画面が最後に取得した日時)・CSV出力日時(区別する)・抽出件数(=書き出したデータ行数)を記録する。
///   条件の無い項目は「指定なし」/「すべて」と明記する。
/// ■ 参加者一覧の列は固定の8列: 氏名 / HEBEL属性 / 参加プログラム / 参加時間 / 予定人数 / 実来場人数 / 受付状態 / 受付時刻。
///   メールアドレス・かな・HEBEL属性の原文など、これ以外の個人情報は含めない。HEBEL属性は画面と同じ3分類。
/// ■ 予定人数・実来場人数は数値のセル(単位なし)。未受付の実来場人数・受付時刻、時間の無い申込の参加時間は空欄。
///   受付時刻は日本時間の YYYY/MM/DD HH:mm。
/// ■ UTF-8(BOM付き)・CRLF・カンマ区切り。カンマ・ダブルクォーテーション・改行を含む値はRFC 4180どおりに囲む
///   (ListToCsvConverter)。数式として評価される先頭文字(= + - @ 等)を持つ文字列は、既存の参加者CSVと同じく無害化する
///   (情報欄の氏名検索の文字列・イベント名も同じ)。

/// CSVに記録する抽出条件(出力ボタンを押した時点の画面の状態)。
class ReceptionStatusCsvConditions {
  const ReceptionStatusCsvConditions({
    required this.eventName,
    required this.dataUpdatedAt,
    this.query = '',
    this.programName,
    this.state = ReceptionStateFilter.all,
    this.hebel,
    this.sort = ReceptionSort.standard,
  });

  final String eventName;

  /// データ最終更新日時(画面が最後に取得に成功した日時)。CSV出力日時とは別。
  final DateTime? dataUpdatedAt;

  /// 氏名検索の入力(空なら指定なし)。
  final String query;

  /// 絞り込み中のprogramの表示名(nullならすべて)。
  final String? programName;
  final ReceptionStateFilter state;

  /// 絞り込み中のHEBEL属性(nullならすべて)。
  final ReceptionHebelGroup? hebel;
  final ReceptionSort sort;
}

class ReceptionStatusCsv {
  const ReceptionStatusCsv({
    required this.fileName,
    required this.bytes,
    required this.rowCount,
  });

  final String fileName;
  final Uint8List bytes;

  /// 出力したデータ行の数(見出しを除く)。
  final int rowCount;
}

const List<String> receptionStatusCsvHeaders = [
  '氏名',
  'HEBEL属性',
  '参加プログラム',
  '参加時間',
  '予定人数',
  '実来場人数',
  '受付状態',
  '受付時刻',
];

const Duration _jst = Duration(hours: 9);

String _two(int v) => v.toString().padLeft(2, '0');

/// 日本時間の YYYY/MM/DD HH:mm:ss(情報欄の日時。日本時間であることを添える)。
String formatCsvJstSeconds(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${t.year}/${_two(t.month)}/${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}（日本時間）';
}

/// 日本時間の YYYY/MM/DD HH:mm(CSVの受付時刻)。
String formatCsvJst(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${t.year}/${_two(t.month)}/${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// JM_Quick_Reception_Status_{eventId}_{日本時間のYYYYMMDD_HHmmss}.csv
String receptionStatusCsvFileName(String eventId, DateTime exportedAt) {
  final t = exportedAt.toUtc().add(_jst);
  final stamp =
      '${t.year}${_two(t.month)}${_two(t.day)}_${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
  return 'JM_Quick_Reception_Status_${safeExportFileName(eventId)}_$stamp.csv';
}

List<Object> _row(ReceptionStatusRow r) => [
  r.name,
  r.hebel.label,
  r.programName,
  r.timeText ?? '',
  r.plannedCount ?? '',
  r.checkedIn ? (r.attendedCount ?? '') : '',
  r.checkedIn ? '受付済み' : '未受付',
  r.checkedIn && r.checkedInAt != null ? formatCsvJst(r.checkedInAt!) : '',
];

/// 情報欄の項目名(この順で10行)。
const List<String> receptionStatusCsvInfoLabels = [
  'イベント名',
  'イベントID',
  'データ最終更新日時',
  'CSV出力日時',
  '氏名検索条件',
  '参加プログラム',
  '受付状態',
  'HEBEL属性',
  '並び順',
  '抽出件数',
];

List<List<Object>> _infoRows({
  required String eventId,
  required ReceptionStatusCsvConditions c,
  required DateTime exportedAt,
  required int rowCount,
}) {
  final query = c.query.trim();
  final values = <Object>[
    c.eventName,
    eventId,
    c.dataUpdatedAt == null ? '取得なし' : formatCsvJstSeconds(c.dataUpdatedAt!),
    formatCsvJstSeconds(exportedAt),
    query.isEmpty ? '指定なし' : query,
    c.programName ?? 'すべて',
    c.state.label,
    c.hebel?.label ?? 'すべて',
    c.sort.label,
    rowCount,
  ];
  return [
    for (final (i, label) in receptionStatusCsvInfoLabels.indexed) [label, values[i]],
  ];
}

String _toCsv(List<List<Object>> lines) =>
    const ListToCsvConverter(eol: '\r\n').convert([
      for (final line in lines)
        [for (final cell in line) neutralizeSpreadsheetFormula(cell)],
    ]);

/// [rows] は表示中の一覧(この順で出力する)。0行のときは出力しない(画面のボタンも無効)。
/// 抽出件数は [rows] の行数(=書き出すデータ行数)から決める。
ReceptionStatusCsv buildReceptionStatusCsv({
  required String eventId,
  required List<ReceptionStatusRow> rows,
  required DateTime exportedAt,
  required ReceptionStatusCsvConditions conditions,
}) {
  if (rows.isEmpty) throw StateError('出力する行がありません。');
  final info = _toCsv(
    _infoRows(eventId: eventId, c: conditions, exportedAt: exportedAt, rowCount: rows.length),
  );
  final table = _toCsv([
    receptionStatusCsvHeaders,
    for (final r in rows) _row(r),
  ]);
  // 情報欄 → 空行1行 → 参加者一覧(見出し・データ)。最後の行もCRLFで終える。
  return ReceptionStatusCsv(
    fileName: receptionStatusCsvFileName(eventId, exportedAt),
    bytes: Uint8List.fromList(utf8.encode('\ufeff$info\r\n\r\n$table\r\n')),
    rowCount: rows.length,
  );
}
