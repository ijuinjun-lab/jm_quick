import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'winner_mail_service.dart';
import 'winner_send_job_page.dart';
import 'winner_send_service.dart';

/// 取込回(batch)が送信できない理由の表示。
String blockedReasonLabel(String code) => switch (code) {
  'batch-not-committed' => '取込が完了(committed)していないため、送信できません。',
  'participants-mismatch' => '参加者数が取込結果と一致しないため、送信できません。',
  'no-targets' => '送信対象の参加者がいません。',
  'mail-not-ready' => '当選メールの設定が完了していません(「当選メール設定」を確認してください)。',
  'job-exists' => '',
  _ => '送信できません($code)。',
};

String batchStatusLabel(String status) => switch (status) {
  'committed' => '取込完了',
  'committing' => '取込中(未完了)',
  'failed' => '取込失敗',
  _ => status,
};

/// 当選メール送信管理(admin専用): 取込回の選択 → 対象人数・テンプレートversionの確認 → プレビュー →
/// 最終確認 → ジョブ作成・処理 → 進行状況 → 失敗分だけ再送。
/// 対象人数・状態はすべてサーバー(callable)の値を表示する(クライアントは対象者を計算しない)。
class WinnerSendPage extends StatefulWidget {
  const WinnerSendPage({
    super.key,
    required this.service,
    required this.mailService,
    this.initialEventId,
    this.pollInterval = const Duration(seconds: 5),
  });
  final WinnerSendService service;

  /// プレビューは Phase 6 の previewConfirmedWinnerMail(実送信と同じレンダラー)を再利用する。
  final WinnerMailService mailService;
  final String? initialEventId;
  final Duration pollInterval;

  @override
  State<WinnerSendPage> createState() => _WinnerSendPageState();
}

class _WinnerSendPageState extends State<WinnerSendPage> {
  late final eventId = TextEditingController(text: widget.initialEventId ?? '');
  final participantIds = <String, TextEditingController>{};
  SendBatchList? batchList;
  bool loading = false;
  String? error;

  /// 送信作成中のbatchId(連打防止。サーバー側の冪等性が正本)。
  String? starting;
  final previews = <String, WinnerMailPreview>{};
  final previewErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    if ((widget.initialEventId ?? '').isNotEmpty) _load();
  }

  @override
  void dispose() {
    eventId.dispose();
    for (final c in participantIds.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool keepError = false}) async {
    final id = eventId.text.trim();
    if (id.isEmpty) {
      setState(() => error = 'イベントIDを入力してください。');
      return;
    }
    setState(() {
      loading = true;
      if (!keepError) error = null;
    });
    try {
      final result = await widget.service.listBatches(id);
      if (!mounted) return;
      setState(() {
        batchList = result;
        // テンプレートが変わっていたら、以前のプレビューは無効(確認し直す)
        previews.removeWhere(
          (_, p) => p.templateVersion != result.templateVersion,
        );
      });
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '取込回の一覧を取得できませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  TextEditingController _controllerFor(SendBatch batch) =>
      participantIds.putIfAbsent(
        batch.batchId,
        () => TextEditingController(text: batch.previewParticipantId ?? ''),
      );

  Future<void> _preview(SendBatch batch) async {
    final id = _controllerFor(batch).text.trim();
    if (id.isEmpty) {
      setState(() => previewErrors[batch.batchId] = 'プレビューする参加者IDを入力してください。');
      return;
    }
    setState(() => previewErrors.remove(batch.batchId));
    try {
      final result = await widget.mailService.preview(
        eventId: batchList!.eventId,
        participantId: id,
      );
      if (mounted) {
        setState(() {
          if (result.ready) {
            previews[batch.batchId] = result;
          } else {
            previews.remove(batch.batchId);
            previewErrors[batch.batchId] =
                'このメールはまだ作成できません(${result.problems.join('、')})。「当選メール設定」を確認してください。';
          }
        });
      }
    } on WinnerMailException catch (e) {
      if (mounted) setState(() => previewErrors[batch.batchId] = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => previewErrors[batch.batchId] = 'プレビューを取得できませんでした。');
      }
    }
  }

  // プレビューでテンプレートversionを確認済みの場合だけ、送信を開始できる。
  bool _previewed(SendBatch batch) {
    final p = previews[batch.batchId];
    return p != null &&
        p.ready &&
        p.templateVersion == batchList!.templateVersion;
  }

  Future<void> _start(SendBatch batch) async {
    if (starting != null) return; // 連打防止(サーバーの冪等性が正本)
    final list = batchList!;
    final version = list.templateVersion;
    if (version == null || batch.targetCount == null) return;
    final ok = await confirmSendAction(
      context,
      title: '当選メールを送信します',
      lines: [
        'イベント：${list.eventName}',
        '対象：${batch.label}',
        '送信対象：${batch.targetCount}件',
        'テンプレート：v$version',
        'この操作でメールが送信されます。',
      ],
      confirmLabel: '送信を開始',
    );
    if (!ok || !mounted) return;
    setState(() {
      starting = batch.batchId;
      error = null;
    });
    SendJob? job;
    try {
      job = await widget.service.createJob(
        eventId: list.eventId,
        batchId: batch.batchId,
        expectedTemplateVersion: version,
      );
    } on WinnerSendException catch (e) {
      if (mounted) {
        setState(() => error = e.message);
        // 応答が届かなかった場合も含め、サーバーの状態(既存のジョブ)を再取得して復元する。「もう一度新規送信」とはしない。
        await _load(keepError: true);
      }
    } finally {
      if (mounted) setState(() => starting = null);
    }
    if (job == null || !mounted) return;
    // 確認した内容と、サーバーが作成した(または既存の)ジョブが違う場合は、処理を始めない。
    if (job.targetCount != batch.targetCount ||
        job.templateVersion != version) {
      setState(
        () => error =
            '確認した内容(対象${batch.targetCount}件・テンプレートv$version)と、サーバーのジョブ(対象${job!.targetCount}件・v${job.templateVersion})が異なります。'
            'メールは送信していません。状態を確認してください。',
      );
      await _load(keepError: true);
      return;
    }
    await _openJob(job.jobId, autoStart: true);
  }

  Future<void> _openJob(String jobId, {bool autoStart = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WinnerSendJobPage(
          service: widget.service,
          eventId: batchList!.eventId,
          eventName: batchList!.eventName,
          jobId: jobId,
          autoStart: autoStart,
          pollInterval: widget.pollInterval,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '当選メール送信',
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
                  '取込回ごとの当選メール送信',
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
                    onPressed: loading ? null : _load,
                    child: const Text('取込回を読み込む'),
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
        if (batchList != null) ...[
          const SizedBox(height: 12),
          _templateCard(batchList!),
          for (final batch in batchList!.batches) ...[
            const SizedBox(height: 12),
            _batchCard(batchList!, batch),
          ],
          if (batchList!.batches.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('このイベントには取込回がありません。'),
            ),
        ],
      ],
    ),
  );

  Widget _templateCard(SendBatchList list) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            list.eventName,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            list.templateVersion == null
                ? '当選メールのテンプレート：未設定'
                : '現在の当選メールのテンプレート：v${list.templateVersion}'
                      '(送信ジョブ作成時にこのバージョンで固定されます)',
          ),
          if (!list.templateReady)
            for (final problem in list.templateProblems)
              Text(
                '設定が完了していません($problem)',
                style: const TextStyle(color: Color(0xffb54708)),
              ),
        ],
      ),
    ),
  );

  Widget _batchCard(SendBatchList list, SendBatch batch) {
    final job = batch.job;
    final busyHere = starting == batch.batchId;
    final reasons = [
      for (final r in batch.blockedReasons)
        if (blockedReasonLabel(r).isNotEmpty) blockedReasonLabel(r),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              batch.label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            KeyValueRow('取込の状態', batchStatusLabel(batch.status)),
            if (batch.importedCount != null)
              KeyValueRow('取込件数', '${batch.importedCount}件'),
            if (batch.targetCount != null)
              KeyValueRow('メール対象', '${batch.targetCount}件'),
            if ((batch.excludedInactiveCount ?? 0) > 0)
              KeyValueRow('対象外(有効でない参加者)', '${batch.excludedInactiveCount}件'),
            if (job != null) ...[
              const Divider(height: 24),
              _jobSummary(job),
            ] else if (batch.targetCount != null && batch.canCreateJob)
              const KeyValueRow('送信', '未送信(まだジョブは作成されていません)'),
            for (final reason in reasons)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  reason,
                  style: const TextStyle(color: Color(0xffb54708)),
                ),
              ),
            if (job != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: () => _openJob(job.jobId),
                  child: const Text('送信状況を開く'),
                ),
              ),
            ] else if (batch.canCreateJob) ...[
              const Divider(height: 24),
              _previewSection(batch),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: busyHere || starting != null || !_previewed(batch)
                      ? null
                      : () => _start(batch),
                  child: Text(busyHere ? 'ジョブを作成中…' : 'この取込回へ送信…'),
                ),
              ),
              if (!_previewed(batch))
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '送信の前に、プレビューで完成したメールを確認してください。',
                    style: TextStyle(color: Color(0xff5c6670)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _jobSummary(SendJob job) {
    if (!job.trustworthy) {
      return const Text(
        '状態を確認できません(件数の合計が送信対象と一致しません)。「送信状況を開く」で確認してください。',
        style: TextStyle(color: Color(0xffb42318), fontWeight: FontWeight.bold),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KeyValueRow('送信ジョブ', job.state?.label ?? '状態を確認できません'),
        KeyValueRow('テンプレート', 'v${job.templateVersion}'),
        if (job.createdAt != null)
          KeyValueRow('ジョブ作成', jstDateTime(job.createdAt!)),
        KeyValueRow('送信対象', '${job.targetCount}件'),
        const SizedBox(height: 6),
        DeliveryCountsView(counts: job.counts),
        if (job.counts.unknown > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '結果確認が必要な宛先が ${job.counts.unknown}件 あります(送信された可能性があります)。',
              style: const TextStyle(
                color: Color(0xffb54708),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }

  Widget _previewSection(SendBatch batch) {
    final preview = previews[batch.batchId];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('送信前プレビュー', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(
          controller: _controllerFor(batch),
          decoration: const InputDecoration(
            labelText: 'プレビューする参加者ID',
            helperText: '実際に届くメールと同じ内容を、サーバーが作成して表示します(送信はしません)。',
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => _preview(batch),
            child: const Text('プレビューを表示'),
          ),
        ),
        if (previewErrors[batch.batchId] != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              previewErrors[batch.batchId]!,
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
            '実際のメールは、本文(上のテキストと同じ内容)に加えて、次の受付用QRコードが画像として表示されます(HTMLメール)。',
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
                  key: const ValueKey('preview-qr'),
                  errorBuilder: (_, _, _) => const Text('(QR画像を表示できません)'),
                ),
              ),
            ),
          if (preview.webPassUrl.isNotEmpty)
            KeyValueRow('Web参加証URL', preview.webPassUrl),
        ],
      ],
    );
  }
}
