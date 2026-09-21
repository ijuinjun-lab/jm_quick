import 'package:flutter/material.dart';

import '../models/demo_models.dart';
import '../services/demo_repository.dart';
import '../services/legacy_api.dart';
import '../widgets/common.dart';

class EventListPage extends StatefulWidget {
  const EventListPage({super.key, this.api, this.repository});

  /// 管理者としてログイン済みのAPI窓口(入口の LegacyAdminGate が渡す)。
  final LegacyApiClient? api;

  /// テスト用。
  final DemoRepository? repository;

  @override
  State<EventListPage> createState() => _EventListPageState();
}

class _EventListPageState extends State<EventListPage> {
  late final repository = widget.repository ?? DemoRepository(api: widget.api);

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'イベント一覧',
    child: StreamBuilder<List<DemoEvent>>(
      stream: repository.watchEvents(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return ErrorPanel(snapshot.error!);
        final events = snapshot.data;
        if (events == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _createEvent,
                icon: const Icon(Icons.add),
                label: const Text('新しいイベントを作成'),
              ),
            ),
            const SizedBox(height: 16),
            if (events.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('イベントがありません。'),
                ),
              ),
            ...events.map(_eventCard),
          ],
        );
      },
    ),
  );

  Widget _eventCard(DemoEvent event) {
    // 集計はサーバー(イベント一覧API)が計算した値。従来方式のイベントにだけ付く(新方式のイベントには付かない)。
    final summary = event.summary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Builder(
        builder: (context) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    event.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  InfoRow('開催日時', formatDateTime(event.startAt)),
                  InfoRow('会場', event.venue),
                  InfoRow(
                    '正式登録締切日時',
                    formatDateTimeMinute(event.registrationDeadline),
                  ),
                  InfoRow(
                    '参加予定確認メール送信日時',
                    formatDateTimeMinute(event.confirmationSendAt),
                  ),
                  if (summary == null)
                    // 新方式(confirmed)・未知のflowのイベント。従来の集計・削除は使わず、新しい管理画面へ案内する
                    const NonLegacyFlowNotice(
                      message: '新方式のイベントです。新しい管理画面(/console)を使用してください。',
                    )
                  else
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        Text('登録 ${summary.participantCount}件'),
                        Text('申込人数 ${summary.appliedCount}名'),
                        Text('正式登録 ${summary.registeredCount}件'),
                        Text('正式登録人数 ${summary.formallyRegisteredCount}名'),
                        Text('参加予定 ${summary.attendingCount}名'),
                        Text('不参加予定 ${summary.notAttendingCount}名'),
                        Text('未回答 ${summary.unansweredCount}名'),
                        Text('受付人数 ${summary.attendedCount}名'),
                        Chip(
                          label: Text(
                            event.statusAt(DateTime.now())?.label ?? '設定未完了',
                          ),
                        ),
                      ],
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        if (summary != null)
                          TextButton.icon(
                            onPressed: () => _confirmDeleteEvent(
                              event,
                              summary.participantCount,
                            ),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('イベントを削除'),
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.error,
                            ),
                          ),
                        FilledButton.tonal(
                          onPressed: () => Navigator.pushNamed(
                            context,
                            '/admin/events/${event.id}',
                          ),
                          child: const Text('イベント管理を開く'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteEvent(
    DemoEvent event,
    int participantCount,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('イベント削除の確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoRow('イベント名', event.name),
            InfoRow('開催日時', formatDateTime(event.startAt)),
            InfoRow('登録者数', '$participantCount件'),
            const SizedBox(height: 12),
            const Text(
              'このイベントと関連する参加者・受付情報を削除します。この操作は元に戻せません。',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('イベントを削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await repository.deleteEvent(event);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${event.name}を削除しました。')));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('イベントを削除できませんでした：$error')));
      }
    }
  }

  Future<void> _createEvent() async {
    final name = TextEditingController();
    final senderName = TextEditingController();
    final venue = TextEditingController();
    final contact = TextEditingController();
    var date = DateTime.now().add(const Duration(days: 30));
    var start = const TimeOfDay(hour: 10, minute: 0);
    TimeOfDay? end = const TimeOfDay(hour: 16, minute: 0);
    final initialDeadline = DateTime.now().add(const Duration(days: 14));
    var deadline = DateTime(
      initialDeadline.year,
      initialDeadline.month,
      initialDeadline.day,
      23,
      59,
    );
    var confirmation = const TimeOfDay(hour: 10, minute: 0);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('新しいイベントを作成'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'イベント名'),
                  ),
                  TextField(
                    controller: senderName,
                    decoration: const InputDecoration(
                      labelText: '送信者名',
                      helperText: '未設定の場合はイベント名を使用します',
                    ),
                  ),
                  _tile('開催日', _date(date), () async {
                    final value = await _pickDate(date);
                    if (value != null) setState(() => date = value);
                  }),
                  _tile('開始時刻', formatTime24(start), () async {
                    final value = await _pickTime(start);
                    if (value != null) setState(() => start = value);
                  }),
                  _tile(
                    '終了時刻（任意）',
                    end == null ? '未設定' : formatTime24(end!),
                    () async {
                      final value = await _pickTime(end ?? start);
                      if (value != null) setState(() => end = value);
                    },
                  ),
                  TextField(
                    controller: venue,
                    decoration: const InputDecoration(labelText: '会場'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: contact,
                    decoration: const InputDecoration(labelText: '問い合わせ先'),
                  ),
                  _tile('正式登録締切日時', formatDateTimeMinute(deadline), () async {
                    final value = await _pickDateTime(deadline);
                    if (value != null) setState(() => deadline = value);
                  }),
                  _tile('参加予定確認メール送信時刻', formatTime24(confirmation), () async {
                    final value = await _pickTime(confirmation);
                    if (value != null) setState(() => confirmation = value);
                  }),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '参加予定確認メール送信日時：'
                      '${formatDateTimeMinute(previousDayAt(date, confirmation))}',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () async {
                if (name.text.trim().isEmpty || venue.text.trim().isEmpty) {
                  return;
                }
                final id = await repository.createEvent(
                  eventName: name.text,
                  senderName: senderName.text,
                  startAt: _combine(date, start),
                  endAt: end == null ? null : _combine(date, end!),
                  venue: venue.text,
                  registrationDeadline: deadline,
                  confirmationSendTime: confirmation,
                  contact: contact.text,
                );
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                  Navigator.pushNamed(context, '/admin/events/$id');
                }
              },
              child: const Text('作成'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    senderName.dispose();
    venue.dispose();
    contact.dispose();
  }

  Widget _tile(String label, String value, VoidCallback onTap) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(value),
    onTap: onTap,
  );

  Future<DateTime?> _pickDate(DateTime initial) => showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime.now().subtract(const Duration(days: 365)),
    lastDate: DateTime.now().add(const Duration(days: 3650)),
  );

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(
    context: context,
    initialTime: initial,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await _pickDate(initial);
    if (date == null || !mounted) return null;
    final time = await _pickTime(TimeOfDay.fromDateTime(initial));
    return time == null ? null : _combine(date, time);
  }

  DateTime _combine(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  String _date(DateTime value) =>
      '${value.year}/${value.month.toString().padLeft(2, '0')}/'
      '${value.day.toString().padLeft(2, '0')}';
}
