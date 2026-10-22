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

/// 前日リマインド(イベント管理者以上): 文面・送信前の宛先一覧・プレビュー・手動送信・現在の状態。
/// 対象人数・対象外人数・宛先・状態はすべてサーバー(callable)の値。対象は当選メールが送信済みの有効な参加者(取込回は問わない)。
/// 手動送信専用: 自動送信の有効化・送信予定日時の入力は無い(サーバーも自動送信の有効化を拒否し、自動ではジョブを作らない)。
/// 文面の保存だけではメールは送られない。送信は宛先一覧を確認してから「今すぐリマインド送信を開始…」で行う。
///
/// ■ Phase 11D: [initialEventId](イベント管理画面から内部的に渡される)を正本として使う。利用者が
///   イベントIDを見る・入力する・書き換える欄は無い。[initialEventId]が無い状態(直接この画面に来た場合)は、
///   イベントを推測したり最初のイベントを自動選択したりせず、「イベント管理画面から開いてください」という
///   案内だけを表示する。
class ReminderPage extends StatefulWidget {
  const ReminderPage({
    super.key,
    required this.service,
    this.initialEventId,
    this.pollInterval = const Duration(seconds: 5),
    this.now,
  });
  final ReminderService service;

  /// イベント管理画面(`/console?eventId=…`)から渡される、対象イベントのID(正本)。
  final String? initialEventId;
  final Duration pollInterval;

  /// 現在時刻(過去日時の警告用。テストで差し替える)。
  final DateTime Function()? now;

  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends State<ReminderPage> {
  final subject = TextEditingController();
  final intro = TextEditingController();
  final closing = TextEditingController();
  final notes = TextEditingController();
  final participantId = TextEditingController();
  ReminderSettings? settings;
  bool loading = false;
  bool busy = false;
  String? error;
  String? message;
  WinnerMailPreview? previewResult;
  String? previewError;
  Timer? pollTimer;

  String get _eventId => (widget.initialEventId ?? '').trim();
  bool get _hasEventId => _eventId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasEventId) _load();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    for (final c in [
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

  Future<void> _load({bool silent = false, bool keepError = false}) async {
    if (!_hasEventId) return; // 呼び出し元(initState・再読み込みボタン)がガードしている
    if (!silent) setState(() => loading = true);
    try {
      final result = await widget.service.getSettings(_eventId);
      if (!mounted) return;
      setState(() {
        settings = result;
        if (!silent) {
          // フォームは、サーバーの現在値で埋める(silent=pollingでは、入力中の内容を上書きしない)
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
    if (!_templateDirty) return '文面に変更がありません。';
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
    final lines = [
      'イベント：${s.eventName}',
      'テンプレート：文面を更新します(v${(s.templateVersion ?? 0) + 1})',
      if (s.job != null) 'すでに作成済みのリマインドは、この変更では止まりません・作り直されません。',
      'この保存では、メールは送信されません(送信は宛先一覧を確認してから手動で行います)。',
    ];
    final ok = await confirmSendAction(
      context,
      title: '前日リマインドの文面を保存します',
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
      // 文面だけを保存する(自動送信の有効・無効、送信予定日時は送らない=手動送信専用)
      await widget.service.updateSettings(
        eventId: s.eventId,
        template: _templateDirty
            ? (
                subject: subject.text,
                introBody: intro.text,
                closingBody: closing.text,
                notesBody: notes.text,
              )
            : null,
      );
      if (mounted) setState(() => message = '文面を保存しました(メールは送信していません)。');
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
    if (version == null || s.blocked || s.targetsFingerprint == null) return;
    final ok = await confirmSendAction(
      context,
      title: '前日リマインドを今すぐ開始します',
      lines: [
        'イベント：${s.eventName}',
        '送信対象：${s.targetCount}件(当選メール送信済みの参加者。通常当選${s.normalCount}件・繰り上げ当選${s.waitlistCount}件)',
        '送信対象外：${s.recipients.where((r) => !r.target).length}件(当選メール未送信・送信失敗など。送信されません)',
        '宛先は、この画面の宛先一覧のとおりです(確認後に変わっていれば、サーバーが開始を止めます)。',
        'テンプレート：v$version',
        '送信はサーバーが行います(このイベントのリマインドは1つだけで、二重には作られません)。',
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
        expectedTargetsFingerprint: s.targetsFingerprint,
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
    child: !_hasEventId
        ? missingEventCard(context)
        : Column(
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    key: const Key('reminder-reload'),
                    onPressed: loading ? null : () => _load(),
                    child: const Text('最新の状態に更新'),
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
          _recipientsCard(settings!),
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
          KeyValueRow('対象', '${s.targetCount}件'),
          KeyValueRow('対象外', '${s.excludedCount}件'),
          KeyValueRow(
            'テンプレート',
            s.templateVersion == null ? '未設定' : 'v${s.templateVersion}',
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '前日リマインドは手動送信です。送信前の宛先一覧を確認してから「今すぐリマインド送信を開始…」で送信します(自動送信はありません)。',
              key: ValueKey('note-manual-only'),
              style: TextStyle(color: Color(0xff5c6670)),
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
          const Text('文面', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
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
              child: const Text('文面を保存'),
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

  /// 送信前の宛先一覧(送信対象・対象外)。参加者を選ぶ・除外する操作は無い(対象はサーバーが判定する)。
  Widget _recipientsCard(ReminderSettings s) {
    final targets = s.recipients.where((r) => r.target).toList();
    final excluded = s.recipients.where((r) => !r.target).toList();
    Widget row(ReminderRecipient r) => Container(
      key: ValueKey('reminder-recipient-${r.participantId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xffe5e7eb)))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${r.name}　${r.email}', style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            '${r.additionUnresolved ? '追加当選通知の確認待ち / ' : ''}${r.notificationTypeLabel}　当選メール：${r.winnerStatusLabel}',
            style: TextStyle(
              color: r.winnerStatus == 'unknown' ? const Color(0xffb42318) : const Color(0xff5c6670),
              fontSize: 13,
            ),
          ),
          for (final p in r.programs)
            Text(
              '${p.name}${p.timeText == null ? '' : '　${p.timeText}'}${p.plannedCount == null ? '' : '　${p.plannedCount}名'}',
              style: const TextStyle(fontSize: 13),
            ),
          if (r.duplicateLabel.isNotEmpty)
            Text(
              '${r.duplicateLabel}(同じアドレス${r.duplicateGroupSize}件)',
              style: TextStyle(
                fontSize: 13,
                color: r.duplicate == 'suspected-duplicate' || r.duplicate == 'undetermined'
                    ? const Color(0xffb54708)
                    : const Color(0xff5c6670),
              ),
            ),
        ],
      ),
    );
    return Card(
      key: const ValueKey('reminder-recipients'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('送信前の宛先一覧', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              '送信予定：${targets.length}件(通常当選${s.normalCount}件・繰り上げ当選${s.waitlistCount}件)　送信対象外：${excluded.length}件',
              key: const ValueKey('reminder-recipients-summary'),
            ),
            const Text(
              '送信対象は、当選メールが送信済みの参加者です。同じメールアドレスでも参加者ごとに1通ずつ送ります(統合しません)。',
              style: TextStyle(color: Color(0xff5c6670), fontSize: 12),
            ),
            if (s.unknownWinnerMail > 0)
              Container(
                key: const ValueKey('reminder-unknown-warning'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                color: const Color(0xffffe8e8),
                child: Text(
                  '当選メールの結果不明、または追加当選通知が未確定の申込が${s.unknownWinnerMail}件あります。この状態では前日リマインドを作成しません'
                  '(手動・自動とも)。当選メールの送信状況を確認してください。',
                ),
              ),
            if (s.suspectedDuplicates > 0)
              Container(
                key: const ValueKey('reminder-duplicate-warning'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                color: const Color(0xffffe8e8),
                child: Text(
                  '重複登録の疑い(同じメールアドレス・氏名・プログラム・時間帯)が${s.suspectedDuplicates}件あります。'
                  '誤送信を防ぐため、この状態では前日リマインドを作成しません(参加者の統合・削除はしません)。',
                ),
              ),
            const SizedBox(height: 10),
            Text('送信予定(${targets.length}件)', style: const TextStyle(fontWeight: FontWeight.w600)),
            if (targets.isEmpty) const Text('送信予定の参加者はいません。', style: TextStyle(color: Color(0xff5c6670))),
            for (final r in targets) row(r),
            if (excluded.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('送信対象外(${excluded.length}件。送信されません)', style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final r in excluded) row(r),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _recoverRecipients() async {
    final service = widget.service as ReminderRecoveryService;
    try {
      final rows = await service.recoveryPreview(_eventId);
      if (!mounted) return;
      final selected = await showDialog<Map<String, dynamic>>(context: context, builder: (context) => AlertDialog(
        title: const Text('安全停止した宛先の再確認'),
        content: SizedBox(width: 600, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('確実に未送信で、当選通知がすべて送信済みの宛先だけを表示します。送信済み・結果不明は再送しません。文面設定はジョブ作成時のまま、参加資格は再確認した現在の内容になります。'),
          if (rows.isEmpty) const Text('再確認できる宛先はありません。追加当選通知の配送状態や有効な参加資格を確認してください。'),
          for (final r in rows) TextButton(onPressed: () => Navigator.pop(context, r), child: Text('${r['name']} / ${r['email']}')),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる'))],
      ));
      if (selected == null || !mounted) return;
      var reason = '';
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('宛先・参加資格・本文を確認'),
        content: SizedBox(width: 600, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${selected['name']} / ${selected['email']}'), SelectableText(selected['text'] as String),
          TextField(maxLength: 200, onChanged: (v) => reason = v, decoration: const InputDecoration(labelText: '確認根拠（必須）')),
        ]))), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('戻る')),
          TextButton(onPressed: () { if (reason.trim().isNotEmpty) Navigator.pop(context, true); }, child: const Text('この宛先の再開を承認'))],
      ));
      if (accepted != true || !mounted) return;
      await service.confirmRecovery(_eventId, selected, reason.trim());
      if (!mounted) return;
      setState(() => message = 'この宛先を未送信に戻しました。送信状況画面で配送を再開できます。');
      await _load();
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
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
            if (job != null && job.counts.failed > 0 && widget.service is ReminderRecoveryService)
              OutlinedButton(key: const Key('reminder-recovery'), onPressed: loading ? null : _recoverRecipients, child: const Text('安全停止した宛先を確認して復旧')),
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
                          s.templateVersion == null ||
                          s.blocked ||
                          s.targetsFingerprint == null
                      ? null
                      : _startNow,
                  child: const Text('今すぐリマインド送信を開始…'),
                ),
              ),
              if (s.blocked)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '当選メールの結果不明・重複登録の疑いがあるため、開始できません。宛先一覧を確認してください。',
                    key: ValueKey('reminder-start-blocked'),
                    style: TextStyle(color: Color(0xffb42318)),
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
