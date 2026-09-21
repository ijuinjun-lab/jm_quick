import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'reminder_service.dart';
import 'winner_mail_page.dart' show problemLabel;
import 'winner_mail_service.dart';
import 'winner_send_job_page.dart';
import 'winner_send_service.dart';

const _maxSubject = 150;
const _maxBody = 2000;

/// 日時入力(JST)。「2026/11/29 10:00」「2026-11-29 10:00」を、絶対時刻(UTC)にする。不正ならnull。
DateTime? parseJstDateTime(String text) {
  final match = RegExp(
    r'^\s*(\d{4})[/-](\d{1,2})[/-](\d{1,2})[ T]+(\d{1,2}):(\d{2})\s*$',
  ).firstMatch(text);
  if (match == null) return null;
  final parts = [for (var i = 1; i <= 5; i++) int.parse(match.group(i)!)];
  if (parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) {
    return null;
  }
  if (parts[3] > 23 || parts[4] > 59) return null;
  final utc = DateTime.utc(parts[0], parts[1], parts[2], parts[3], parts[4]);
  if (utc.month != parts[1] || utc.day != parts[2]) return null; // 2/30などの不正な日付
  return utc.subtract(const Duration(hours: 9));
}

/// 前日リマインド(admin専用): 設定・プレビュー・送信予定・対象人数・現在の状態。
/// 対象人数・対象外人数・状態はすべてサーバー(callable)の値。対象はイベント全体の全active participant(取込回は問わない)。
/// 自動送信は、有効にした場合だけ、送信予定日時に達したときサーバーが行う(ブラウザは不要)。設定の保存だけではメールは送られない。
class ReminderPage extends StatefulWidget {
  const ReminderPage({
    super.key,
    required this.service,
    this.initialEventId,
    this.pollInterval = const Duration(seconds: 5),
    this.now,
  });
  final ReminderService service;
  final String? initialEventId;
  final Duration pollInterval;

  /// 現在時刻(過去日時の警告用。テストで差し替える)。
  final DateTime Function()? now;

  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends State<ReminderPage> {
  late final eventId = TextEditingController(text: widget.initialEventId ?? '');
  final sendAtField = TextEditingController();
  final subject = TextEditingController();
  final intro = TextEditingController();
  final closing = TextEditingController();
  final notes = TextEditingController();
  final participantId = TextEditingController();
  ReminderSettings? settings;
  bool enabledInput = false;
  bool loading = false;
  bool busy = false;
  String? error;
  String? message;
  WinnerMailPreview? previewResult;
  String? previewError;
  Timer? pollTimer;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    if ((widget.initialEventId ?? '').isNotEmpty) _load();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    for (final c in [
      eventId,
      sendAtField,
      subject,
      intro,
      closing,
      notes,
      participantId,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _formatSendAt(DateTime? at) => at == null ? '' : jstDateTime(at);

  Future<void> _load({bool silent = false, bool keepError = false}) async {
    final id = eventId.text.trim();
    if (id.isEmpty) {
      setState(() => error = 'イベントIDを入力してください。');
      return;
    }
    if (!silent) setState(() => loading = true);
    try {
      final result = await widget.service.getSettings(id);
      if (!mounted) return;
      setState(() {
        settings = result;
        if (!silent) {
          // フォームは、サーバーの現在値で埋める(silent=pollingでは、入力中の内容を上書きしない)
          enabledInput = result.enabled;
          sendAtField.text = _formatSendAt(result.sendAt);
          subject.text = result.subject;
          intro.text = result.introBody;
          closing.text = result.closingBody;
          notes.text = result.notesBody;
          if (participantId.text.isEmpty) {
            participantId.text = result.previewParticipantId ?? '';
          }
          if (!keepError) error = null;
        }
      });
    } on WinnerSendException catch (e) {
      if (mounted && !silent) setState(() => error = e.message);
    } catch (_) {
      if (mounted && !silent) setState(() => error = '前日リマインドの情報を取得できませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
    _schedulePoll();
  }

  // サーバーが送信処理中(dispatchActive)の間だけ、状態を再取得する。終端・停止では止める(配送はサーバーが行う)。
  void _schedulePoll() {
    pollTimer?.cancel();
    pollTimer = null;
    final job = settings?.job;
    if (!mounted || job == null || job.isTerminal) return;
    if (!job.dispatchActive && job.counts.sending == 0) return;
    pollTimer = Timer(widget.pollInterval, () {
      pollTimer = null;
      if (mounted) _load(silent: true);
    });
  }

  bool get _templateDirty {
    final s = settings!;
    return subject.text != s.subject ||
        intro.text != s.introBody ||
        closing.text != s.closingBody ||
        notes.text != s.notesBody;
  }

  String? _validate() {
    final s = settings!;
    if (_templateDirty) {
      if (subject.text.trim().isEmpty) return '件名を入力してください。';
      if (subject.text.contains('\n')) return '件名は1行で入力してください。';
      if (subject.text.trim().length > _maxSubject) {
        return '件名は$_maxSubject文字以内で入力してください。';
      }
      if (intro.text.trim().isEmpty) return '冒頭本文を入力してください。';
      if (closing.text.trim().isEmpty) return '締め本文を入力してください。';
      for (final c in [intro, closing, notes]) {
        if (c.text.trim().length > _maxBody) {
          return '本文は$_maxBody文字以内で入力してください。';
        }
      }
    }
    final at = parseJstDateTime(sendAtField.text);
    if (sendAtField.text.trim().isNotEmpty && at == null) {
      return '送信予定日時は「2026/11/29 10:00」の形式(日本時間)で入力してください。';
    }
    if (enabledInput && at == null && s.sendAt == null) {
      return '自動送信を有効にするには、送信予定日時を入力してください。';
    }
    return null;
  }

  Future<void> _save() async {
    if (busy) return;
    final problem = _validate();
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    final s = settings!;
    final at = parseJstDateTime(sendAtField.text);
    final effectiveAt = at ?? s.sendAt;
    final past =
        enabledInput &&
        effectiveAt != null &&
        !effectiveAt.isAfter(_now.toUtc());
    final lines = [
      'イベント：${s.eventName}',
      '自動送信：${enabledInput ? '有効' : '無効'}',
      '送信予定：${effectiveAt == null ? '未設定' : jstDateTime(effectiveAt)}',
      if (_templateDirty) 'テンプレート：文面を更新します(v${(s.templateVersion ?? 0) + 1})',
      if (s.job != null) 'すでに作成済みのリマインドは、この変更では止まりません・作り直されません。',
      if (past) '送信予定日時が過去です。有効にすると、直ちに全員へ送信されます。',
      'この保存では、メールは送信されません(自動送信は送信予定日時にサーバーが行います)。',
    ];
    final ok = await confirmSendAction(
      context,
      title: past ? '過去の日時です。設定を保存しますか?' : '前日リマインドの設定を保存します',
      lines: lines,
      confirmLabel: '保存',
    );
    if (!ok || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await widget.service.updateSettings(
        eventId: s.eventId,
        enabled: enabledInput != s.enabled ? enabledInput : null,
        sendAt: at != null && at != s.sendAt ? at : null,
        template: _templateDirty
            ? (
                subject: subject.text,
                introBody: intro.text,
                closingBody: closing.text,
                notesBody: notes.text,
              )
            : null,
        acknowledgePast: past,
      );
      if (mounted) setState(() => message = '設定を保存しました(メールは送信していません)。');
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted) await _load(keepError: true);
  }

  Future<void> _preview() async {
    final id = participantId.text.trim();
    if (id.isEmpty) {
      setState(() => previewError = 'プレビューする参加者IDを入力してください。');
      return;
    }
    setState(() => previewError = null);
    try {
      final result = await widget.service.preview(
        eventId: settings!.eventId,
        participantId: id,
      );
      if (!mounted) return;
      setState(() {
        if (result.ready) {
          previewResult = result;
        } else {
          previewResult = null;
          previewError =
              'このメールはまだ作成できません(${result.problems.map(problemLabel).join('、')})。文面を保存してから確認してください。';
        }
      });
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => previewError = e.message);
    } on WinnerMailException catch (e) {
      if (mounted) setState(() => previewError = e.message);
    }
  }

  bool get _previewed =>
      previewResult != null &&
      previewResult!.templateVersion == settings!.templateVersion;

  Future<void> _startNow() async {
    if (busy) return;
    final s = settings!;
    final version = s.templateVersion;
    if (version == null) return;
    final ok = await confirmSendAction(
      context,
      title: '前日リマインドを今すぐ開始します',
      lines: [
        'イベント：${s.eventName}',
        '送信対象：${s.targetCount}件(イベント全体の有効な参加者)',
        'テンプレート：v$version',
        '自動送信と同じジョブへ引き渡します(別便は作られません)。',
        'この操作でメールが送信されます(送信はサーバーが行い、この画面を閉じても続きます)。',
      ],
      confirmLabel: '送信を開始',
    );
    if (!ok || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final job = await widget.service.startDelivery(
        s.eventId,
        expectedTemplateVersion: version,
        expectedTargetCount: s.targetCount,
      );
      if (mounted) {
        setState(
          () => message = job.dispatchActive
              ? 'サーバーで送信処理を開始しました。この画面を閉じても、処理は続きます。'
              : '既存のリマインドジョブの状態を表示しています。',
        );
      }
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // 応答が届かなかった場合も含め、サーバーの状態を再取得して復元する(「もう一度新規送信」とはしない)。
    if (mounted) await _load(keepError: true);
  }

  Future<void> _openJob() async {
    final s = settings!;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WinnerSendJobPage(
          service: ReminderJobAdapter(widget.service),
          eventId: s.eventId,
          eventName: s.eventName,
          jobId: ReminderJobAdapter.jobIdFor(s.eventId),
          pollInterval: widget.pollInterval,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '前日リマインド',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '前日リマインド(新方式のイベント)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: eventId,
                  decoration: const InputDecoration(labelText: 'イベントID'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: loading ? null : () => _load(),
                    child: const Text('設定を読み込む'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: const TextStyle(color: Color(0xffb42318))),
        ],
        if (message != null) ...[
          const SizedBox(height: 10),
          Text(message!, style: const TextStyle(color: Color(0xff067647))),
        ],
        if (settings != null) ...[
          const SizedBox(height: 12),
          _overview(settings!),
          const SizedBox(height: 12),
          _settingsForm(settings!),
          const SizedBox(height: 12),
          _previewCard(settings!),
          const SizedBox(height: 12),
          _jobCard(settings!),
        ],
      ],
    ),
  );

  Widget _overview(ReminderSettings s) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            s.eventName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          KeyValueRow(
            '送信予定',
            s.sendAt == null ? '未設定' : jstDateTime(s.sendAt!),
          ),
          KeyValueRow('自動送信', s.enabled ? '有効' : '無効'),
          KeyValueRow('対象', '${s.targetCount}件'),
          KeyValueRow('対象外', '${s.excludedCount}件'),
          KeyValueRow(
            'テンプレート',
            s.templateVersion == null ? '未設定' : 'v${s.templateVersion}',
          ),
          if (!s.enabled)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '自動送信は無効です。送信予定日時になっても、自動ではメールは送信されません。',
                key: ValueKey('note-disabled'),
                style: TextStyle(color: Color(0xffb54708)),
              ),
            ),
          if (s.enabled && s.job == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '送信予定日時になると、サーバーが対象を確定して自動で送信します(この画面を開いている必要はありません)。',
              ),
            ),
          if (s.eventEnded)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'イベントは終了しています。',
                style: TextStyle(color: Color(0xffb42318)),
              ),
            ),
          if (!s.ready)
            for (final problem in s.problems)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  problemLabel(problem),
                  style: const TextStyle(color: Color(0xffb54708)),
                ),
              ),
        ],
      ),
    ),
  );

  Widget _settingsForm(ReminderSettings s) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('設定', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('switch-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('自動送信を有効にする'),
            subtitle: const Text('有効にしたイベントだけ、送信予定日時にサーバーが自動送信します(既定は無効)。'),
            value: enabledInput,
            onChanged: (value) => setState(() => enabledInput = value),
          ),
          TextField(
            controller: sendAtField,
            decoration: const InputDecoration(
              labelText: '送信予定日時(日本時間)',
              helperText: '例: 2026/11/29 10:00',
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'リマインドの文面(当選メールとは別に管理されます)。参加者名・QR・program・会場などは自動で挿入されます。',
            style: TextStyle(color: Color(0xff5c6670)),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: subject,
            decoration: const InputDecoration(labelText: '件名'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: intro,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '冒頭本文',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: closing,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '締め本文',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: notes,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '注意事項(任意)',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: busy ? null : _save,
              child: const Text('設定を保存'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _previewCard(ReminderSettings s) {
    final preview = previewResult;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('プレビュー', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            TextField(
              controller: participantId,
              decoration: const InputDecoration(
                labelText: 'プレビューする参加者ID',
                helperText: '実際に届くメールと同じ内容を、サーバーが作成して表示します(送信はしません)。',
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _preview,
                child: const Text('プレビューを表示'),
              ),
            ),
            if (previewError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  previewError!,
                  style: const TextStyle(color: Color(0xffb42318)),
                ),
              ),
            if (preview != null) ...[
              const SizedBox(height: 10),
              KeyValueRow('件名', preview.subject),
              KeyValueRow('テンプレート', 'v${preview.templateVersion}'),
              Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xfff7f8fa),
                child: SelectableText(preview.text),
              ),
              const SizedBox(height: 8),
              const Text(
                '実際のメールは、本文に加えて、次の受付用QRコード(当選メールと同じQR)が画像として表示されます(HTMLメール)。',
                style: TextStyle(color: Color(0xff5c6670)),
              ),
              if (preview.qrPngBase64.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: Image.memory(
                      base64Decode(preview.qrPngBase64),
                      width: 160,
                      height: 160,
                      key: const ValueKey('reminder-preview-qr'),
                      errorBuilder: (_, _, _) => const Text('(QR画像を表示できません)'),
                    ),
                  ),
                ),
              if (preview.webPassUrl.isNotEmpty)
                KeyValueRow('Web参加証URL', preview.webPassUrl),
            ],
          ],
        ),
      ),
    );
  }

  Widget _jobCard(ReminderSettings s) {
    final job = s.job;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('送信状況', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (job == null) ...[
              const Text('リマインドはまだ作成されていません(未送信)。', key: ValueKey('no-job')),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed:
                      busy ||
                          !_previewed ||
                          s.targetCount == 0 ||
                          s.templateVersion == null
                      ? null
                      : _startNow,
                  child: const Text('今すぐリマインド送信を開始…'),
                ),
              ),
              if (!_previewed)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '開始の前に、プレビューで完成したメールを確認してください。',
                    style: TextStyle(color: Color(0xff5c6670)),
                  ),
                ),
            ] else ...[
              if (!job.trustworthy)
                const Text(
                  '状態を確認できません(件数の合計が送信対象と一致しません)。「送信状況を開く」で確認してください。',
                  key: ValueKey('reminder-untrustworthy'),
                  style: TextStyle(
                    color: Color(0xffb42318),
                    fontWeight: FontWeight.bold,
                  ),
                )
              else ...[
                KeyValueRow('ジョブの状態', job.state?.label ?? '状態を確認できません'),
                KeyValueRow('テンプレート', 'v${job.templateVersion}(作成時に固定)'),
                if (job.createdAt != null)
                  KeyValueRow('ジョブ作成', jstDateTime(job.createdAt!)),
                KeyValueRow('送信対象', '${job.targetCount}件(作成時に確定)'),
                const SizedBox(height: 6),
                DeliveryCountsView(counts: job.counts),
                if (job.counts.unknown > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '結果確認が必要な宛先が ${job.counts.unknown}件 あります(送信された可能性があります。自動では再送されません)。',
                      key: const ValueKey('reminder-unknown'),
                      style: const TextStyle(
                        color: Color(0xffb54708),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (job.state == JobState.ready && job.dispatchActive)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'サーバーで送信処理中です。この画面を閉じても、処理は最後まで続きます。',
                      key: ValueKey('reminder-server-running'),
                    ),
                  ),
                if (job.dispatchHaltedReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'サーバーが安全のため自動処理を停止しました(${haltReasonLabel(job.dispatchHaltedReason!)})。送信状況画面から再開できます。',
                      style: const TextStyle(color: Color(0xffb54708)),
                    ),
                  ),
              ],
              if (s.changedSinceJob)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'リマインドジョブの作成後に参加者が追加または状態変更されています(現在の有効な参加者 ${s.currentTargetCount ?? '-'}件 / ジョブの対象 ${job.targetCount}件)。'
                    '既存のジョブへは自動で追加されません。',
                    key: const ValueKey('reminder-changed'),
                    style: const TextStyle(color: Color(0xffb54708)),
                  ),
                ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: _openJob,
                  child: const Text('送信状況を開く'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
