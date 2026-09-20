import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../models/demo_models.dart';

class ParticipantCsvExport {
  const ParticipantCsvExport({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;
}

ParticipantCsvExport buildParticipantCsv({
  required DemoEvent event,
  required List<Participant> participants,
  required List<CheckIn> checkIns,
  required DateTime exportedAt,
}) {
  final eventParticipants =
      participants
          .where((participant) => participant.eventId == event.id)
          .toList()
        ..sort((left, right) => _sortKey(left).compareTo(_sortKey(right)));
  final eventCheckIns = {
    for (final checkIn in checkIns)
      if (checkIn.eventId == event.id) checkIn.participantId: checkIn,
  };
  final rows = <List<dynamic>>[
    const [
      '確認',
      '氏名',
      'メールアドレス',
      '申込人数',
      '案内メール',
      '正式登録',
      '参加予定',
      '受付状態',
      '実参加人数',
    ],
    for (final participant in eventParticipants)
      _participantRow(participant, eventCheckIns[participant.id]),
  ];
  // 数式の無害化は全セルに一括適用する。列が増えても個別の対応漏れが起きない。
  // 引用符やカンマのエスケープはListToCsvConverterが担当する。
  final csv = const ListToCsvConverter().convert(
    rows.map((row) => row.map(neutralizeSpreadsheetFormula).toList()).toList(),
  );
  final encoded = utf8.encode('\ufeff$csv');
  final date =
      '${exportedAt.year}'
      '${exportedAt.month.toString().padLeft(2, '0')}'
      '${exportedAt.day.toString().padLeft(2, '0')}';
  return ParticipantCsvExport(
    fileName: '${_safeFileName(event.name)}_参加者一覧_$date.csv',
    bytes: Uint8List.fromList(encoded),
  );
}

/// Excel等で数式として評価される先頭文字（= + - @ タブ CR）を持つ文字列の前に
/// `'` を付け、テキストとして扱わせる（CSV/数式インジェクション対策）。
/// 文字列以外（人数などの数値）はそのまま返す。
dynamic neutralizeSpreadsheetFormula(dynamic value) {
  if (value is! String || value.isEmpty) return value;
  return '=+-@\t\r'.contains(value[0]) ? "'$value" : value;
}

List<dynamic> _participantRow(Participant participant, CheckIn? checkIn) => [
  '',
  participant.name,
  participant.email,
  participant.registeredCount,
  _invitationStatus(participant),
  participant.participationConfirmed ? '登録済み' : '未登録',
  participant.attendanceResponse?.label ?? '未回答',
  checkIn?.checkedIn == true ? '受付済み' : '未受付',
  checkIn?.checkedIn == true ? checkIn?.attendedCount ?? 0 : '',
];

String _invitationStatus(Participant participant) {
  if (participant.invitationSent) return '送信済み';
  if (participant.invitationMailStatus == 'failed') return '送信失敗';
  if (participant.invitationMailStatus == 'sending') return '送信中';
  return '未送信';
}

String _sortKey(Participant participant) {
  final furigana = [
    participant.furiganaLastName?.trim() ?? '',
    participant.furiganaFirstName?.trim() ?? '',
  ].where((value) => value.isNotEmpty).join(' ');
  return furigana.isEmpty ? participant.name : furigana;
}

String _safeFileName(String value) {
  final sanitized = value.trim().replaceAll(
    RegExp(r'[\\/:*?"<>|\x00-\x1f]'),
    '_',
  );
  return sanitized.isEmpty ? 'イベント' : sanitized;
}
