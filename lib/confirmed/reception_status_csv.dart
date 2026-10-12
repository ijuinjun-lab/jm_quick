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
/// ■ 列は固定の8列: 氏名 / HEBEL属性 / 参加プログラム / 参加時間 / 予定人数 / 実来場人数 / 受付状態 / 受付時刻。
///   メールアドレス・かな・HEBEL属性の原文など、これ以外の個人情報は含めない。HEBEL属性は画面と同じ3分類。
/// ■ 予定人数・実来場人数は数値のセル(単位なし)。未受付の実来場人数・受付時刻、時間の無い申込の参加時間は空欄。
///   受付時刻は日本時間の YYYY/MM/DD HH:mm。
/// ■ UTF-8(BOM付き)・CRLF・カンマ区切り。カンマ・ダブルクォーテーション・改行を含む値はRFC 4180どおりに囲む
///   (ListToCsvConverter)。数式として評価される先頭文字(= + - @ 等)を持つ文字列は、既存の参加者CSVと同じく無害化する。
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

/// [rows] は表示中の一覧(この順で出力する)。0行のときは出力しない(画面のボタンも無効)。
ReceptionStatusCsv buildReceptionStatusCsv({
  required String eventId,
  required List<ReceptionStatusRow> rows,
  required DateTime exportedAt,
}) {
  if (rows.isEmpty) throw StateError('出力する行がありません。');
  final table = [
    receptionStatusCsvHeaders,
    for (final r in rows) _row(r),
  ];
  final csv = const ListToCsvConverter(eol: '\r\n').convert([
    for (final line in table)
      [for (final cell in line) neutralizeSpreadsheetFormula(cell)],
  ]);
  return ReceptionStatusCsv(
    fileName: receptionStatusCsvFileName(eventId, exportedAt),
    bytes: Uint8List.fromList(utf8.encode('﻿$csv\r\n')),
    rowCount: rows.length,
  );
}
