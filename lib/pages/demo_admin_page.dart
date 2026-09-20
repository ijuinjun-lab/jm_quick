import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/demo_models.dart';
import '../services/demo_repository.dart';
import '../services/csv_import_service.dart';
import '../widgets/common.dart';
import '../services/download_service.dart';
import '../services/participant_csv_export_service.dart';

String walkInPathForEvent(String eventId) =>
    '/e/${Uri.encodeComponent(eventId)}/walk-in';

class DemoAdminPage extends StatefulWidget {
  const DemoAdminPage({super.key, required this.eventId});
  final String eventId;
  @override
  State<DemoAdminPage> createState() => _DemoAdminPageState();
}

class _DemoAdminPageState extends State<DemoAdminPage> {
  late final repository = DemoRepository(selectedEventId: widget.eventId);
  bool busy = false;

  Future<void> run(Future<void> Function() action, String success) async {
    setState(() => busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(success)));
      }
    } on MailSendException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('メール送信失敗：${e.message}'),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('処理失敗：$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'JM Quick 管理画面',
    child: StreamBuilder<DemoEvent?>(
      stream: repository.watchEvent(),
      builder: (context, eventSnapshot) {
        if (eventSnapshot.hasError) return ErrorPanel(eventSnapshot.error!);
        if (eventSnapshot.data == null) {
          return const ErrorPanel('イベントが見つかりません。');
        }
        return StreamBuilder<List<Participant>>(
          stream: repository.watchParticipants(),
          builder: (context, participantSnapshot) {
            if (participantSnapshot.hasError) {
              return ErrorPanel(participantSnapshot.error!);
            }
            return StreamBuilder<List<CheckIn>>(
              stream: repository.watchCheckIns(),
              builder: (context, checkInSnapshot) {
                if (checkInSnapshot.hasError) {
                  return ErrorPanel(checkInSnapshot.error!);
                }
                return StreamBuilder<BulkMailJob?>(
                  stream: repository.watchBulkMailJob('invitation'),
                  builder: (context, invitationJobSnapshot) =>
                      StreamBuilder<BulkMailJob?>(
                        stream: repository.watchBulkMailJob('reconfirmation'),
                        builder: (context, reconfirmationJobSnapshot) =>
                            _content(
                              eventSnapshot.data!,
                              participantSnapshot.data ?? [],
                              checkInSnapshot.data ?? [],
                              invitationJobSnapshot.data,
                              reconfirmationJobSnapshot.data,
                            ),
                      ),
                );
              },
            );
          },
        );
      },
    ),
  );

  Widget _content(
    DemoEvent event,
    List<Participant> participants,
    List<CheckIn> checkIns,
    BulkMailJob? invitationJob,
    BulkMailJob? reconfirmationJob,
  ) {
    final byParticipant = {for (final c in checkIns) c.participantId: c};
    final registeredTotal = participants.fold(
      0,
      (sum, p) => sum + p.registeredCount,
    );
    final attendedTotal = checkIns
        .where((c) => c.checkedIn)
        .fold(0, (sum, c) => sum + (c.attendedCount ?? 0));
    final walkInTotal = participants
        .where((p) => p.isWalkIn)
        .fold(0, (sum, p) => sum + p.registeredCount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _eventSettingsCard(event),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
              spacing: 28,
              runSpacing: 10,
              children: [
                _metric('登録件数', '${participants.length}件'),
                _metric('申込人数', '$registeredTotal名'),
                _metric(
                  '参加予定',
                  '${participants.where((p) => p.participationConfirmed && p.attendanceResponse == AttendanceResponse.attending).fold<int>(0, (sum, p) => sum + p.registeredCount)}名',
                ),
                _metric(
                  '不参加予定',
                  '${participants.where((p) => p.participationConfirmed && p.attendanceResponse == AttendanceResponse.notAttending).fold<int>(0, (sum, p) => sum + p.registeredCount)}名',
                ),
                _metric(
                  '未回答',
                  '${participants.where((p) => p.participationConfirmed && p.attendanceResponse == null).fold<int>(0, (sum, p) => sum + p.registeredCount)}名',
                ),
                _metric(
                  '受付済み組数',
                  '${checkIns.where((c) => c.checkedIn).length}組',
                ),
                _metric('実参加人数', '$attendedTotal名'),
                _metric('当日参加人数', '$walkInTotal名'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _invitationMailSummary(event, participants, invitationJob),
        const SizedBox(height: 16),
        _confirmationSummary(event, participants, reconfirmationJob),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton(
              onPressed: busy ? null : () => _showAddParticipant(),
              child: const Text('テスト参加者を追加'),
            ),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => _importParticipantCsv(event, participants),
              icon: const Icon(Icons.upload_file),
              label: const Text('このイベントの参加者CSVを読み込む'),
            ),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => _exportParticipantCsv(event, participants, checkIns),
              icon: const Icon(Icons.download),
              label: const Text('参加者一覧CSVを書き出す'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _showWalkInQr(event),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('当日参加用QRを表示'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          '参加者一覧',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        ...participants.map(
          (p) => _participantCard(event, p, byParticipant[p.id], participants),
        ),
      ],
    );
  }

  void _exportParticipantCsv(
    DemoEvent event,
    List<Participant> participants,
    List<CheckIn> checkIns,
  ) {
    final export = buildParticipantCsv(
      event: event,
      participants: participants,
      checkIns: checkIns,
      exportedAt: DateTime.now(),
    );
    downloadBytes(export.bytes, export.fileName);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${export.fileName}を書き出しました。')));
  }

  Future<void> _showWalkInQr(DemoEvent event) async {
    final path = walkInPathForEvent(event.id);
    final url = Uri.base.resolve(path);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(event.name),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '当日参加の方は、このQRコードをスマートフォンで読み取り、必要事項をご登録ください。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: QrImageView(data: url.toString(), size: 300),
              ),
              const SizedBox(height: 12),
              SelectableText(url.toString(), textAlign: TextAlign.center),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Widget _invitationMailSummary(
    DemoEvent event,
    List<Participant> participants,
    BulkMailJob? job,
  ) {
    final targets = participants.where((participant) => !participant.isWalkIn);
    final sent = targets
        .where((participant) => participant.invitationSent)
        .length;
    final failed = targets
        .where(
          (participant) =>
              !participant.invitationSent &&
              participant.invitationMailStatus == 'failed',
        )
        .length;
    final unsent = targets.length - sent - failed;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '案内メール一括送信',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                Text('対象者 ${targets.length}名'),
                Text('送信済み $sent名'),
                Text('未送信 $unsent名'),
                Text('失敗 $failed名'),
              ],
            ),
            if (job != null) ...[
              const SizedBox(height: 8),
              Text(
                '一括処理：${_jobStatusLabel(job.status)} '
                '${job.sentCount}/${job.totalCount}件送信・${job.failedCount}件失敗',
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: busy || unsent == 0 || job?.isRunning == true
                      ? null
                      : () => _confirmBulkInvitation(
                          event,
                          targets.length,
                          sent,
                          unsent,
                        ),
                  icon: const Icon(Icons.send),
                  label: const Text('案内メールを一括送信'),
                ),
                OutlinedButton(
                  onPressed: busy || failed == 0 || job?.isRunning == true
                      ? null
                      : () => run(
                          () => repository.startBulkInvitationMail(
                            failedOnly: true,
                          ),
                          '失敗者のみの再送処理を開始しました。',
                        ),
                  child: const Text('失敗者のみ再送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _jobStatusLabel(String status) => switch (status) {
    'preparing' => '対象者を準備中',
    'queued' => '送信待ち',
    'running' => '送信中',
    'completed' => '完了',
    _ => status,
  };

  Future<void> _confirmBulkInvitation(
    DemoEvent event,
    int targetCount,
    int sentCount,
    int sendCount,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('案内メール一括送信の確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              event.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            InfoRow('対象者', '$targetCount名'),
            InfoRow('送信済み', '$sentCount名'),
            InfoRow('今回送信', '$sendCount名'),
            const SizedBox(height: 8),
            Text('$sendCount名へ案内メールを送信します。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('一括送信'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(
        () => repository.startBulkInvitationMail(),
        '案内メール一括送信を開始しました。画面を閉じても処理は継続します。',
      );
    }
  }

  Widget _confirmationSummary(
    DemoEvent event,
    List<Participant> participants,
    BulkMailJob? job,
  ) {
    final eligible = participants
        .where((value) => value.participationConfirmed)
        .toList();
    final sent = eligible.where((value) => value.reconfirmationMailSent).length;
    int responseCount(AttendanceResponse? response) => eligible
        .where((value) => value.attendanceResponse == response)
        .fold(0, (sum, value) => sum + value.registeredCount);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '参加予定確認',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            InfoRow('送信予定日時', formatDateTime(event.confirmationSendAt)),
            Wrap(
              spacing: 20,
              children: [
                Text(
                  '対象人数 ${eligible.fold<int>(0, (sum, value) => sum + value.registeredCount)}名',
                ),
                Text('送信済み $sent名'),
                Text('参加予定 ${responseCount(AttendanceResponse.attending)}名'),
                Text(
                  '不参加予定 ${responseCount(AttendanceResponse.notAttending)}名',
                ),
                Text('未回答 ${responseCount(null)}名'),
              ],
            ),
            if (job != null) ...[
              const SizedBox(height: 8),
              Text(
                '一括再送：${_jobStatusLabel(job.status)} '
                '${job.sentCount}/${job.totalCount}件送信・${job.failedCount}件失敗',
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed:
                    busy ||
                        job?.isRunning == true ||
                        eligible.every(
                          (participant) =>
                              participant.attendanceResponse != null ||
                              !participant.reconfirmationMailSent,
                        )
                    ? null
                    : () => run(
                        repository.startBulkReconfirmationMail,
                        '未回答者への一括再送を開始しました。',
                      ),
                child: const Text('参加予定確認の未回答者へ一括再送'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importParticipantCsv(
    DemoEvent event,
    List<Participant> participants,
  ) async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
    } catch (error, stackTrace) {
      debugPrint('CSV file selection failed: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CSVファイルを開けませんでした。もう一度お試しください。')),
        );
      }
      return;
    }
    final bytes = picked?.files.single.bytes;
    if (bytes == null || !mounted) return;
    CsvImportPreview preview;
    try {
      preview = parseParticipantCsv(bytes);
    } catch (error, stackTrace) {
      debugPrint('CSV parsing failed: $error\n$stackTrace');
      preview = const CsvImportPreview(
        rows: [],
        errors: ['CSV解析中に予期しないエラーが発生しました。'],
        inputRowCount: 0,
      );
    }
    final existingEmails = participants
        .map((value) => value.email.trim().toLowerCase())
        .toSet();
    final duplicateCount = preview.rows
        .where((row) => existingEmails.contains(row.email))
        .length;
    final newRows = preview.rows
        .where((row) => !existingEmails.contains(row.email))
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${event.name}へ参加者を登録します'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoRow('イベント名', event.name),
                InfoRow('開催日時', formatDateTime(event.startAt)),
                InfoRow('CSVデータ行数', '${preview.inputRowCount}件'),
                InfoRow('取込予定', '${preview.rows.length}件'),
                InfoRow('新規登録', '${newRows.length}件'),
                InfoRow('重複候補件数', '$duplicateCount件'),
                InfoRow('エラー件数', '${preview.errorCount}件'),
                InfoRow('参加人数合計', '${preview.registeredCountTotal}名'),
                const Divider(height: 24),
                InfoRow('氏名に使用する列', preview.nameHeader ?? '未判定'),
                InfoRow('メールに使用する列', preview.emailHeader ?? '未判定'),
                InfoRow(
                  '登録人数に使用する列',
                  preview.registeredCountHeader ?? '列なし（全員1名）',
                ),
                if (preview.errors.isNotEmpty) ...[
                  const Divider(height: 24),
                  const Text(
                    '確認が必要な内容',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ...preview.errors.map(
                    (message) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('・$message'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: !preview.canImport || newRows.isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: Text('${event.name}へ取り込む'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => busy = true);
    try {
      for (final row in newRows) {
        await repository.createParticipant(
          name: row.name,
          email: row.email,
          registeredCount: row.registeredCount,
          registrationType: 'preRegistered',
          furiganaLastName: row.furiganaLastName,
          furiganaFirstName: row.furiganaFirstName,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${event.name}へ${newRows.length}件登録しました。')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _eventSettingsCard(DemoEvent event) {
    final status = event.statusAt(DateTime.now());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'イベント設定',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => _showEventSettings(event),
                  child: const Text('設定を編集'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InfoRow('イベント名', event.name),
            InfoRow('開催日時', _eventDateRange(event)),
            InfoRow('会場', event.venue),
            InfoRow(
              '正式登録締切日時',
              formatDateTimeMinute(event.registrationDeadline),
            ),
            InfoRow(
              '参加予定確認メール送信日時',
              formatDateTimeMinute(event.confirmationSendAt),
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Text('現在の状態'),
                const Spacer(),
                Chip(label: Text(status?.label ?? '設定未完了')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _eventDateRange(DemoEvent event) {
    final start = formatDateTimeMinute(event.startAt);
    if (event.endAt == null) return start;
    final end = event.endAt!;
    String two(int value) => value.toString().padLeft(2, '0');
    return '$start〜${two(end.hour)}:${two(end.minute)}';
  }

  Future<void> _showEventSettings(DemoEvent event) async {
    final name = TextEditingController(text: event.name);
    final senderName = TextEditingController(text: event.senderName);
    final venue = TextEditingController(text: event.venue);
    final contact = TextEditingController(text: event.contact);
    var eventDate =
        event.startAt ?? DateTime.now().add(const Duration(days: 1));
    var startTime = TimeOfDay.fromDateTime(event.startAt ?? eventDate);
    TimeOfDay? endTime = event.endAt == null
        ? null
        : TimeOfDay.fromDateTime(event.endAt!);
    var deadline =
        event.registrationDeadline ??
        eventDate.subtract(const Duration(days: 7));
    var confirmationTime = TimeOfDay.fromDateTime(
      event.confirmationSendAt ?? eventDate.subtract(const Duration(days: 1)),
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('イベント設定'),
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
                  _pickerTile('開催日', _dateOnly(eventDate), () async {
                    final value = await _pickDate(eventDate);
                    if (value != null) setDialogState(() => eventDate = value);
                  }),
                  _pickerTile('開始時刻', formatTime24(startTime), () async {
                    final value = await _pickTime(startTime);
                    if (value != null) setDialogState(() => startTime = value);
                  }),
                  _pickerTile(
                    '終了時刻（任意）',
                    endTime == null ? '未設定' : formatTime24(endTime!),
                    () async {
                      final value = await _pickTime(endTime ?? startTime);
                      if (value != null) setDialogState(() => endTime = value);
                    },
                    clear: endTime == null
                        ? null
                        : () => setDialogState(() => endTime = null),
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
                  _pickerTile(
                    '正式登録締切日時',
                    formatDateTimeMinute(deadline),
                    () async {
                      final value = await _pickDateTime(deadline);
                      if (value != null) setDialogState(() => deadline = value);
                    },
                  ),
                  _pickerTile(
                    '参加予定確認メール送信時刻',
                    formatTime24(confirmationTime),
                    () async {
                      final value = await _pickTime(confirmationTime);
                      if (value != null) {
                        setDialogState(() => confirmationTime = value);
                      }
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '参加予定確認メール送信日時：'
                      '${formatDateTimeMinute(previousDayAt(eventDate, confirmationTime))}',
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
                final start = _combine(eventDate, startTime);
                final end = endTime == null
                    ? null
                    : _combine(eventDate, endTime!);
                if (name.text.trim().isEmpty ||
                    venue.text.trim().isEmpty ||
                    (end != null && !end.isAfter(start))) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('入力内容を確認してください。')),
                  );
                  return;
                }
                await repository.updateEventSettings(
                  eventName: name.text,
                  senderName: senderName.text,
                  startAt: start,
                  endAt: end,
                  venue: venue.text,
                  registrationDeadline: deadline,
                  confirmationSendTime: confirmationTime,
                  contact: contact.text,
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('保存'),
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

  Widget _pickerTile(
    String label,
    String value,
    VoidCallback onTap, {
    VoidCallback? clear,
  }) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: Text(value),
    trailing: clear == null
        ? const Icon(Icons.edit_calendar)
        : IconButton(onPressed: clear, icon: const Icon(Icons.clear)),
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

  String _dateOnly(DateTime value) =>
      '${value.year}/${value.month.toString().padLeft(2, '0')}/'
      '${value.day.toString().padLeft(2, '0')}';

  Widget _metric(String label, String value) => SizedBox(
    width: 140,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Color(0xff5c6670))),
        Text(
          value,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget _participantCard(
    DemoEvent event,
    Participant p,
    CheckIn? c,
    List<Participant> participants,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${p.name}様',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(p.email),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('登録人数 ${p.registeredCount}名'),
                Text(p.isWalkIn ? '当日参加' : '事前参加'),
                Text(p.participationConfirmed ? '正式登録済み' : '正式登録前'),
                Text('参加予定確認：${p.attendanceResponse?.label ?? '未回答'}'),
                Text(
                  c?.checkedIn == true
                      ? '受付済み・実参加${c?.attendedCount ?? 0}名'
                      : '未受付',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              p.invitationSent
                  ? '案内メール：送信済${p.invitationSentAt == null ? '' : '（${_formatDateTime(p.invitationSentAt!)}）'}'
                  : '案内メール：未送信',
            ),
            if (p.invitationMessageId?.isNotEmpty == true)
              SelectableText(
                'SendGrid Message ID：${p.invitationMessageId}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: busy || p.invitationSent
                      ? null
                      : () => _confirmInvitation(event, p, participants),
                  child: const Text('案内メール送信'),
                ),
                OutlinedButton(
                  onPressed: busy || !p.participationConfirmed
                      ? null
                      : () => run(
                          () => repository.sendMail(p, 'reconfirmation'),
                          '${p.email}へ参加予定確認メールを送信しました。',
                        ),
                  child: const Text('参加予定確認メール再送（テスト）'),
                ),
                TextButton(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/p/${p.id}?publicId=${Uri.encodeQueryComponent(p.publicId)}',
                  ),
                  child: const Text('マイページ'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _confirmDeleteParticipant(event, p, c),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  child: const Text('削除'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _confirmDeleteParticipant(
    DemoEvent event,
    Participant participant,
    CheckIn? checkIn,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('参加者削除の確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoRow('氏名', participant.name),
            InfoRow('メールアドレス', participant.email),
            InfoRow('登録人数', '${participant.registeredCount}名'),
            InfoRow('イベント名', event.name),
            const Divider(height: 24),
            Text(participant.participationConfirmed ? '正式登録済み' : '正式登録前'),
            Text('参加予定：${participant.attendanceResponse?.label ?? '未回答'}'),
            Text(checkIn?.checkedIn == true ? '受付済み' : '未受付'),
            const SizedBox(height: 12),
            const Text(
              'この参加者をイベントから削除します。この操作は元に戻せません。',
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
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(
        () => repository.deleteParticipant(participant),
        '${participant.name}様を削除しました。',
      );
    }
  }

  Future<void> _confirmInvitation(
    DemoEvent event,
    Participant participant,
    List<Participant> participants,
  ) async {
    final unsent = participants.where((value) => !value.invitationSent).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('案内メール送信の確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InfoRow('イベント名', event.name),
            const InfoRow('今回の送信対象', '1名'),
            InfoRow('このイベントの未送信人数', '$unsent名'),
            Text('${participant.name}様へ送信します。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('${event.name}の案内を送信'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(
        () => repository.sendMail(participant, 'invitation'),
        '${participant.email}へ案内メールを送信しました。',
      );
    }
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  Future<void> _showAddParticipant() async {
    final name = TextEditingController();
    final email = TextEditingController();
    final count = TextEditingController(text: '1');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('テスト参加者を追加'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: '氏名'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'メールアドレス'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '登録人数'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () async {
              final n = int.tryParse(count.text);
              if (n == null || n < 1) return;
              try {
                await repository.createParticipant(
                  name: name.text,
                  email: email.text,
                  registeredCount: n,
                  registrationType: 'preRegistered',
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (e) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(SnackBar(content: Text('追加できませんでした：$e')));
                }
              }
            },
            child: const Text('追加'),
          ),
        ],
      ),
    );
    name.dispose();
    email.dispose();
    count.dispose();
  }
}
