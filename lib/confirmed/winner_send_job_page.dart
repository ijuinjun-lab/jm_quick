import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'winner_send_service.dart';

/// 送信管理の確認ダイアログ(ワンクリック即送信を避ける)。確定ならtrue。
Future<bool> confirmSendAction(
  BuildContext context, {
  required String title,
  required List<String> lines,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

/// 項目名と値の1行(長い値は折り返す。狭い画面でもはみ出さない)。
class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xff5c6670)),
        ),
        Text(value),
      ],
    ),
  );
}

Color deliveryColor(DeliveryState state) => switch (state) {
  DeliveryState.pending => const Color(0xff5c6670),
  DeliveryState.sending => const Color(0xff1d4ed8),
  DeliveryState.sent => const Color(0xff067647),
  DeliveryState.failed => const Color(0xffb42318),
  DeliveryState.unknown => const Color(0xffb54708),
};

String jstDateTime(DateTime at) {
  final jst = at.toUtc().add(const Duration(hours: 9));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${jst.year}/${two(jst.month)}/${two(jst.day)} ${two(jst.hour)}:${two(jst.minute)}';
}

/// 5つの配送状態の件数(未送信・送信中・送信済み・失敗・結果確認が必要)。failedとunknownは別の欄・別の色。
class DeliveryCountsView extends StatelessWidget {
  const DeliveryCountsView({super.key, required this.counts});
  final DeliveryCounts counts;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final state in DeliveryState.values)
        Container(
          width: 108,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: deliveryColor(state)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.label,
                style: TextStyle(
                  fontSize: 12,
                  color: deliveryColor(state),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${counts.of(state)}',
                key: ValueKey('count-${state.value}'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// 送信ジョブの詳細・進行状況(admin専用)。状態はすべてサーバーから取得し、画面の再読込でも復元できる
/// (ローカル状態を正本にしない)。Firestoreは直接読まず、callableのpollingで更新する(終端状態で停止)。
///
/// 処理(メールの送信)は、管理者が確認ダイアログで確定した操作の間だけ、この画面が処理callableを繰り返し呼ぶ。
/// ブラウザを閉じると処理は止まるが、状態はサーバーに残り、再度開いて「続ける」で再開できる(二重送信にはならない)。
class WinnerSendJobPage extends StatefulWidget {
  const WinnerSendJobPage({
    super.key,
    required this.service,
    required this.eventId,
    required this.jobId,
    this.eventName = '',
    this.autoStart = false,
    this.pollInterval = const Duration(seconds: 5),
    this.processLimit = 50,
  });
  final WinnerSendService service;
  final String eventId;
  final String jobId;
  final String eventName;

  /// 一覧画面の確認ダイアログで送信を確定して開いた場合、読み込み後に処理を始める。
  final bool autoStart;
  final Duration pollInterval;
  final int processLimit;

  @override
  State<WinnerSendJobPage> createState() => _WinnerSendJobPageState();
}

class _WinnerSendJobPageState extends State<WinnerSendJobPage> {
  SendJob? job;
  List<SendItem> items = [];
  String? nextAfter;
  DeliveryState? filter;
  bool loading = true;
  bool running = false;
  bool stopRequested = false;
  String? error;
  String? notice;
  Timer? pollTimer;
  bool autoStartPending = false;

  @override
  void initState() {
    super.initState();
    autoStartPending = widget.autoStart;
    _reload();
  }

  @override
  void dispose() {
    pollTimer?.cancel();
    super.dispose();
  }

  bool get _canContinue =>
      job != null &&
      job!.trustworthy &&
      job!.state == JobState.ready &&
      job!.counts.pending > 0 &&
      !running;
  bool get _canRetry =>
      job != null &&
      job!.trustworthy &&
      (job!.state == JobState.ready || job!.state == JobState.completed) &&
      job!.counts.failed > 0 &&
      !running;

  Future<void> _reload({bool silent = false}) async {
    if (!silent) setState(() => loading = true);
    try {
      final detail = await widget.service.getJob(
        widget.jobId,
        itemStatus: filter,
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        job = detail.job;
        items = detail.items;
        nextAfter = detail.nextAfter;
        if (!silent) error = null;
      });
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '状態を取得できませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
    _schedulePoll();
    if (autoStartPending && mounted) {
      autoStartPending = false;
      if (_canContinue) await _runProcessing();
    }
  }

  // 処理中(sending)の項目がある間だけ、間隔を空けて再取得する。終端状態(completed/failed)では止める。
  void _schedulePoll() {
    pollTimer?.cancel();
    pollTimer = null;
    final current = job;
    if (!mounted || current == null || running || current.isTerminal) return;
    if (current.counts.sending == 0 && current.state != JobState.preparing) {
      return;
    }
    pollTimer = Timer(widget.pollInterval, () {
      pollTimer = null;
      if (mounted) _reload(silent: true);
    });
  }

  Future<void> _loadMore() async {
    final after = nextAfter;
    if (after == null) return;
    try {
      final detail = await widget.service.getJob(
        widget.jobId,
        itemStatus: filter,
        after: after,
        limit: 100,
      );
      if (mounted) {
        setState(() {
          items = [...items, ...detail.items];
          nextAfter = detail.nextAfter;
        });
      }
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _runProcessing({bool retry = false}) async {
    if (running) return;
    setState(() {
      running = true;
      stopRequested = false;
      error = null;
      notice = null;
    });
    pollTimer?.cancel();
    try {
      if (retry) {
        final progress = await widget.service.retryFailed(widget.jobId);
        if (mounted) setState(() => job = job!.withProgress(progress));
      }
      while (mounted) {
        final result = await widget.service.processJob(
          widget.jobId,
          limit: widget.processLimit,
        );
        if (!mounted) return;
        setState(() => job = job!.withProgress(result.job));
        if (stopRequested) {
          notice = '処理を停止しました。未送信分は「送信を続ける」で再開できます。';
          break;
        }
        if (!result.job.trustworthy || result.job.counts.pending == 0) break;
        if (result.processed == 0) {
          notice = 'これ以上処理を進められませんでした。状態を更新して確認してください。';
          break;
        }
      }
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => error = '処理に失敗しました。画面を更新して、現在の状態を確認してください。');
      }
    } finally {
      if (mounted) setState(() => running = false);
    }
    // 応答が失われた場合も含め、最終的な状態は必ずサーバーから再取得する。
    if (mounted) await _reload(silent: true);
  }

  Future<void> _confirmContinue() async {
    final current = job!;
    final ok = await confirmSendAction(
      context,
      title: '未送信分の送信を続けます',
      lines: [
        if (widget.eventName.isNotEmpty) 'イベント：${widget.eventName}',
        '対象：${current.batchLabel.isEmpty ? current.batchId : current.batchLabel}',
        '未送信：${current.counts.pending}件',
        'テンプレート：v${current.templateVersion}',
      ],
      confirmLabel: '送信を続ける',
    );
    if (ok && mounted) await _runProcessing();
  }

  Future<void> _confirmRetry() async {
    final current = job!;
    final ok = await confirmSendAction(
      context,
      title: '失敗分だけを再送します',
      lines: [
        '再送対象：失敗 ${current.counts.failed}件',
        '送信済み・結果確認が必要な宛先は再送しません。',
        'テンプレート：v${current.templateVersion}(このジョブに固定)',
      ],
      confirmLabel: '失敗分を再送',
    );
    if (ok && mounted) await _runProcessing(retry: true);
  }

  Future<void> _finishPreparation() async {
    final current = job!;
    setState(() {
      running = true;
      error = null;
    });
    try {
      // 準備が途中で止まっていたジョブを、同じbatchで完了させる(冪等。新しいジョブも二重送信も作られない)。
      await widget.service.createJob(
        eventId: widget.eventId,
        batchId: current.batchId,
        expectedTemplateVersion: current.templateVersion,
      );
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => running = false);
    }
    if (mounted) await _reload();
  }

  Future<void> _setFilter(DeliveryState? value) async {
    setState(() => filter = value);
    await _reload(silent: true);
  }

  @override
  Widget build(BuildContext context) =>
      PageFrame(title: '送信状況', child: _body());

  Widget _body() {
    if (loading && job == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final current = job;
    if (current == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(error ?? '状態を取得できませんでした。'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _reload, child: const Text('再読み込み')),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _summaryCard(current),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: const TextStyle(color: Color(0xffb42318))),
        ],
        if (notice != null) ...[
          const SizedBox(height: 10),
          Text(notice!, style: const TextStyle(color: Color(0xffb54708))),
        ],
        const SizedBox(height: 12),
        _itemsCard(current),
      ],
    );
  }

  Widget _summaryCard(SendJob current) {
    final title = current.batchLabel.isEmpty
        ? current.batchId
        : current.batchLabel;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (widget.eventName.isNotEmpty) widget.eventName,
                title,
              ].join(' / '),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            KeyValueRow('ジョブの状態', current.state?.label ?? '状態を確認できません'),
            KeyValueRow(
              'テンプレート',
              'v${current.templateVersion}(この送信ではv${current.templateVersion}を使用。作成時に固定)',
            ),
            KeyValueRow('送信対象', '${current.targetCount}件'),
            if (current.excludedInactiveCount > 0)
              KeyValueRow('対象外(有効でない参加者)', '${current.excludedInactiveCount}件'),
            if (current.createdAt != null)
              KeyValueRow('ジョブ作成', jstDateTime(current.createdAt!)),
            if (current.completedAt != null)
              KeyValueRow('処理完了', jstDateTime(current.completedAt!)),
            const SizedBox(height: 10),
            if (!current.trustworthy)
              _banner(
                '状態を確認できません。件数の合計が送信対象と一致しないため、完了とは扱わず、操作もできません。'
                '画面を更新しても解消しない場合は、管理者へ連絡してください。',
                const Color(0xffb42318),
                key: const ValueKey('banner-untrustworthy'),
              )
            else ...[
              DeliveryCountsView(counts: current.counts),
              const SizedBox(height: 10),
              if (current.counts.unknown > 0)
                _banner(
                  '結果確認が必要な宛先が ${current.counts.unknown}件 あります。'
                  'メールは送信された可能性があります(失敗とは限りません)。自動では再送されません。'
                  '送信記録を確認してください。',
                  const Color(0xffb54708),
                  key: const ValueKey('banner-unknown'),
                ),
              if (current.state == JobState.completed)
                _banner(
                  current.counts.failed == 0 && current.counts.unknown == 0
                      ? '送信処理が完了しました(全 ${current.counts.sent}件 送信済み)。'
                      : '送信処理が完了しました(送信済み ${current.counts.sent}件・失敗 ${current.counts.failed}件・結果確認が必要 ${current.counts.unknown}件)。',
                  const Color(0xff067647),
                  key: const ValueKey('banner-completed'),
                ),
              if (current.state == JobState.preparing)
                _banner(
                  'ジョブの準備が完了していません。「準備を完了する」で、同じ取込回の続きから完了できます(メールは送信されません)。',
                  const Color(0xffb54708),
                ),
              if (current.state == JobState.failed)
                _banner(
                  'ジョブの準備に失敗しました。管理者へ連絡してください(メールは送信されていません)。',
                  const Color(0xffb42318),
                ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_canContinue)
                  FilledButton(
                    onPressed: _confirmContinue,
                    child: Text('未送信分の送信を続ける(${current.counts.pending}件)'),
                  ),
                if (_canRetry)
                  OutlinedButton(
                    onPressed: _confirmRetry,
                    child: Text('失敗分だけ再送(${current.counts.failed}件)'),
                  ),
                if (current.state == JobState.preparing && !running)
                  FilledButton(
                    onPressed: _finishPreparation,
                    child: const Text('準備を完了する'),
                  ),
                if (running && current.state != JobState.preparing)
                  OutlinedButton(
                    onPressed: stopRequested
                        ? null
                        : () => setState(() => stopRequested = true),
                    child: Text(stopRequested ? '停止しています…' : '処理を停止'),
                  ),
                TextButton(
                  onPressed: running || loading ? null : () => _reload(),
                  child: const Text('状態を更新'),
                ),
              ],
            ),
            if (running)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Text('送信処理中です。この画面を開いたままお待ちください(閉じても状態は保存され、再開できます)。'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _banner(String text, Color color, {Key? key}) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontWeight: FontWeight.bold),
    ),
  );

  Widget _itemsCard(SendJob current) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('宛先ごとの状態', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('すべて'),
                selected: filter == null,
                onSelected: (_) => _setFilter(null),
              ),
              for (final state in DeliveryState.values)
                ChoiceChip(
                  label: Text(state.label),
                  selected: filter == state,
                  onSelected: (_) => _setFilter(state),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (items.isEmpty) const Text('該当する宛先はありません。'),
          for (final item in items) _itemRow(item),
          if (nextAfter != null)
            TextButton(onPressed: _loadMore, child: const Text('さらに表示')),
        ],
      ),
    ),
  );

  Widget _itemRow(SendItem item) {
    final state = item.state;
    final color = state == null
        ? const Color(0xff5c6670)
        : deliveryColor(state);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name.isEmpty ? item.participantId : item.name),
                Text(
                  item.participantId,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff5c6670),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              state?.label ?? '状態不明',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
