import 'package:flutter/material.dart';

// イベントの開催日時・会場の表示(イベント管理の概要・参加者ファイルの取込・参加証で共通)。
// 表示用の整形だけで、保存値は変えない。

const List<String> _weekdays = ['月', '火', '水', '木', '金', '土', '日'];

/// 開催日時(日本時間)。「2026年11月29日（日）10:30～16:10」。
/// 終了が無い・開始以前なら開始だけ。終了が別の日なら終了にも日付を付ける。
String eventDateTimeText(DateTime? startAt, DateTime? endAt) {
  if (startAt == null) return '未設定';
  String two(int v) => v.toString().padLeft(2, '0');
  DateTime jst(DateTime at) => at.toUtc().add(const Duration(hours: 9));
  String day(DateTime at) {
    final t = jst(at);
    return '${t.year}年${t.month}月${t.day}日（${_weekdays[t.weekday - 1]}）';
  }

  String time(DateTime at) {
    final t = jst(at);
    return '${two(t.hour)}:${two(t.minute)}';
  }

  final start = '${day(startAt)}${time(startAt)}';
  if (endAt == null || !endAt.isAfter(startAt)) return start;
  final end = day(endAt) == day(startAt)
      ? time(endAt)
      : '${day(endAt)}${time(endAt)}';
  return '$start～$end';
}

/// 会場の表示行。保存値の「／」区切りを表示時だけ改行する(保存値は変えない)。
List<String> venueDisplayLines(String venue) => [
  for (final part in venue.split('／'))
    if (part.trim().isNotEmpty) part.trim(),
];

/// 会場の表示文字列(未設定は「未設定」、「／」区切りは改行)。
String venueDisplayText(String venue) =>
    venue.trim().isEmpty ? '未設定' : venueDisplayLines(venue).join('\n');

/// 項目名の行の下に値を置く(会場名が長くても項目名と重ならない。値は折り返す)。
class StackedInfoRow extends StatelessWidget {
  const StackedInfoRow({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label：', style: const TextStyle(color: Color(0xff5c6670))),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}
