import 'package:flutter/material.dart';

import '../models/demo_models.dart';
import '../services/demo_repository.dart';
import '../widgets/common.dart';

class EventListPage extends StatefulWidget {
  const EventListPage({super.key});

  @override
  State<EventListPage> createState() => _EventListPageState();
}

class _EventListPageState extends State<EventListPage> {
  final repository = DemoRepository();

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
    final scoped = DemoRepository(selectedEventId: event.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: StreamBuilder<List<Participant>>(
        stream: scoped.watchParticipants(),
        builder: (context, participantSnapshot) => StreamBuilder<List<CheckIn>>(
          stream: scoped.watchCheckIns(),
          builder: (context, checkInSnapshot) {
            final participants = participantSnapshot.data ?? [];
            final checkIns = checkInSnapshot.data ?? [];
            final registered = participants
                .where((value) => value.participationConfirmed)
                .length;
            final appliedCount = participants.fold<int>(
              0,
              (sum, value) => sum + value.registeredCount,
            );
            final formallyRegisteredCount = participants
                .where((value) => value.participationConfirmed)
                .fold<int>(0, (sum, value) => sum + value.registeredCount);
            int responseCount(AttendanceResponse? response) => participants
                .where(
                  (value) =>
                      value.participationConfirmed &&
                      value.attendanceResponse == response,
                )
                .fold(0, (sum, value) => sum + value.registeredCount);
            final attended = checkIns
                .where((value) => value.checkedIn)
                .fold<int>(0, (sum, value) => sum + (value.attendedCount ?? 0));
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
                      '正式登録締切',
                      formatDateTime(event.registrationDeadline),
                    ),
                    Wrap(
                      spacing: 18,
                      runSpacing: 8,
                      children: [
                        Text('登録 ${participants.length}件'),
                        Text('申込人数 $appliedCount名'),
                        Text('正式登録 $registered件'),
                        Text('正式登録人数 $formallyRegisteredCount名'),
                        Text(
                          '参加予定 ${responseCount(AttendanceResponse.attending)}名',
                        ),
                        Text(
                          '不参加予定 ${responseCount(AttendanceResponse.notAttending)}名',
                        ),
                        Text('未回答 ${responseCount(null)}名'),
                        Text('受付人数 $attended名'),
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
                          TextButton.icon(
                            onPressed: () =>
                                _confirmDeleteEvent(event, participants.length),
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
    final venue = TextEditingController();
    final contact = TextEditingController();
    var date = DateTime.now().add(const Duration(days: 30));
    var start = const TimeOfDay(hour: 10, minute: 0);
    TimeOfDay? end = const TimeOfDay(hour: 16, minute: 0);
    var deadline = DateTime.now().add(const Duration(days: 14));
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
                  _tile('開催日', _date(date), () async {
                    final value = await _pickDate(date);
                    if (value != null) setState(() => date = value);
                  }),
                  _tile('開始時刻', start.format(context), () async {
                    final value = await showTimePicker(
                      context: context,
                      initialTime: start,
                    );
                    if (value != null) setState(() => start = value);
                  }),
                  _tile('終了時刻（任意）', end?.format(context) ?? '未設定', () async {
                    final value = await showTimePicker(
                      context: context,
                      initialTime: end ?? start,
                    );
                    if (value != null) setState(() => end = value);
                  }),
                  TextField(
                    controller: venue,
                    decoration: const InputDecoration(labelText: '会場'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: contact,
                    decoration: const InputDecoration(labelText: '問い合わせ先'),
                  ),
                  _tile('正式登録締切日', _date(deadline), () async {
                    final value = await _pickDate(deadline);
                    if (value != null) setState(() => deadline = value);
                  }),
                  _tile(
                    '参加予定確認メール送信時刻',
                    confirmation.format(context),
                    () async {
                      final value = await showTimePicker(
                        context: context,
                        initialTime: confirmation,
                      );
                      if (value != null) setState(() => confirmation = value);
                    },
                  ),
                  Text(
                    '参加予定確認日：${_date(date.subtract(const Duration(days: 1)))}',
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
                  startAt: _combine(date, start),
                  endAt: end == null ? null : _combine(date, end!),
                  venue: venue.text,
                  registrationDeadline: DateTime(
                    deadline.year,
                    deadline.month,
                    deadline.day,
                    23,
                    59,
                  ),
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

  DateTime _combine(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  String _date(DateTime value) =>
      '${value.year}/${value.month.toString().padLeft(2, '0')}/'
      '${value.day.toString().padLeft(2, '0')}';
}
