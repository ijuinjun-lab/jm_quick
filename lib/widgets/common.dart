import 'package:flutter/material.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), backgroundColor: Colors.white),
    body: Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: child,
        ),
      ),
    ),
  );
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(color: Color(0xff5c6670))),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

/// 従来方式専用の画面・操作を、新方式(flow=confirmed)などlegacyでないイベントで開いたときの案内。
class NonLegacyFlowNotice extends StatelessWidget {
  const NonLegacyFlowNotice({
    super.key,
    this.message =
        'このイベントは新方式のイベントです。この画面の従来機能（正式登録・参加予定確認・受付・当日参加登録など）は使用できません。'
        '新方式の専用機能が提供されるまでお待ちください。',
  });
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

/// Phase 11D: イベント固有の画面(当選メール設定・当選メール送信・前日リマインド等)が、
/// イベント管理画面(`/console?eventId=…`)から渡されるeventIdを持たずに開かれた場合の案内。
/// eventIdを推測したり、最初のイベントを自動選択したりしない(利用者にIDを入力させる欄も出さない)。
Widget missingEventCard(BuildContext context) => Card(
  child: Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'イベント管理画面から開いてください。',
          key: Key('missing-event-notice'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('back-to-event-console'),
          onPressed: () =>
              Navigator.of(context).pushNamedAndRemoveUntil('/console', (_) => false),
          child: const Text('イベント管理画面へ戻る'),
        ),
      ],
    ),
  ),
);

class ErrorPanel extends StatelessWidget {
  const ErrorPanel(this.error, {super.key});
  final Object error;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'データを取得できませんでした。\n$error',
        style: const TextStyle(color: Colors.red),
      ),
    ),
  );
}

String formatDateTime(DateTime? date) {
  if (date == null) return '未設定';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

String formatDateTimeMinute(DateTime? date) {
  if (date == null) return '未設定';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}/${two(date.month)}/${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}

String formatTime24(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

DateTime previousDayAt(DateTime eventDate, TimeOfDay time) {
  final previousDay = DateTime(
    eventDate.year,
    eventDate.month,
    eventDate.day,
  ).subtract(const Duration(days: 1));
  return DateTime(
    previousDay.year,
    previousDay.month,
    previousDay.day,
    time.hour,
    time.minute,
  );
}
