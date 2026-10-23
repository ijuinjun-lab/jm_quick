import 'dart:math';
import 'package:flutter/material.dart';
import 'winner_send_service.dart';
import 'qualification_change_service.dart';

class QualificationChangeDialog extends StatefulWidget {
  const QualificationChangeDialog({
    super.key,
    required this.service,
    required this.eventId,
    required this.participantId,
  });
  final QualificationChangeService service;
  final String eventId;
  final String participantId;
  @override
  State<QualificationChangeDialog> createState() =>
      _QualificationChangeDialogState();
}

class _QualificationChangeDialogState extends State<QualificationChangeDialog> {
  Map<String, dynamic>? data;
  Map<String, dynamic>? pendingRequest;
  String? source;
  String action = 'cancel';
  bool changed = false;
  bool swap = false, busy = false, confirming = false;
  String? error;
  final reason = TextEditingController();
  final slot = TextEditingController();
  final count = TextEditingController(text: '1');
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    reason.dispose();
    slot.dispose();
    count.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.service.getQualifications(
        widget.eventId,
        widget.participantId,
      );
      if (mounted) {
        setState(() {
          data = result;
          source = null;
          swap = false;
          pendingRequest = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '参加資格を取得できませんでした。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Map> get active => (data?['qualifications'] as List? ?? [])
      .whereType<Map>()
      .where((q) => q['entitlementStatus'] != 'revoked')
      .toList();
  String name(String? id) =>
      (data?['programs'] as List? ?? [])
              .whereType<Map>()
              .where((p) => p['programId'] == id)
              .firstOrNull?['name']
          as String? ??
      id ??
      '';
  String? get target {
    final m = data?['mapping'] as Map? ?? {};
    if (source == m['catProgramId']) return m['dogProgramId'] as String?;
    if (source == m['dogProgramId']) return m['catProgramId'] as String?;
    return null;
  }

  bool get details => swap || action == 'add' || action == 'edit';
  List<String> get slots =>
      ((data?['slots'] as Map?)?[swap ? target : source] as List? ?? [])
          .cast<String>();
  void selectSource(String? v) {
    source = v;
    final q = active.where((q) => q['programId'] == v).firstOrNull;
    slot.text =
        (q?['timeText'] ?? q?['slotLabel']) as String? ??
        (slots.firstOrNull ?? '');
    count.text = '${q?['plannedCount'] ?? 1}';
  }

  String deliveryLabel(dynamic status) =>
      const {
        'sent': '送信済み',
        'failed': '送信失敗（未送信）',
        'unknown': '結果不明（再送禁止）',
        'sending': '処理中・結果未確定',
        'pending': '配送待ち',
      }[status] ??
      '$status';
  String describe(List rows) => rows
      .whereType<Map>()
      .map(
        (q) =>
            '${name(q['programId'])} ${q['timeText'] ?? q['slotLabel'] ?? ''} ${q['plannedCount']}名${q['entitlementStatus'] == 'revoked' ? '（取消）' : ''}',
      )
      .join('\n');
  Future<void> notify(Map h) async {
    final service = widget.service as QualificationNoticeService;
    setState(() => busy = true);
    try {
      final request = {
        'eventId': widget.eventId,
        'participantId': widget.participantId,
        'operationId': h['operationId'],
      };
      final preview = await service.previewNotice(request);
      if (!mounted) return;
      setState(() => confirming = true);
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(
            preview['canRetry'] == true ? '失敗した変更通知の再送を確認' : '本人への変更通知を確認',
          ),
          content: SingleChildScrollView(
            child: SelectableText(
              '宛先：${preview['to']}\n${preview['subject']}\n\n${preview['text']}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('戻る'),
            ),
            FilledButton(
              onPressed:
                  preview['status'] != null && preview['canRetry'] != true
                  ? null
                  : () => Navigator.pop(c, true),
              child: Text(
                preview['canRetry'] == true ? '未送信を確認して手動再送' : 'この本人に送信',
              ),
            ),
          ],
        ),
      );
      if (mounted) setState(() => confirming = false);
      if (ok == true) {
        final result = await service.sendNotice({
          ...request,
          'fingerprint': preview['fingerprint'],
          'expectedAttempt': preview['expectedAttempt'] ?? 0,
          if (preview['canRetry'] == true) 'retry': true,
        });
        await load();
        if (mounted) {
          setState(
            () => error =
                '変更通知：${deliveryLabel(result['status'])}。${result['status'] == 'failed' ? '履歴から内容を再確認し、手動再送できます。' : '送信済み・結果不明は再送できません。'}',
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = '通知の内容または結果を確認できません。再取得して配送状態を確認してください。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> review(Map delivery) async {
    var reviewReason = "";
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('結果不明の配送を確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '配送処理の終了記録または実行期限を確認しました。送信中のまま停止した通知は結果不明として保持し、再送せず参加内容の変更を許可します。確認内容・理由を入力してください。',
            ),
            TextField(
              onChanged: (value) => reviewReason = value.trim(),
              maxLength: 200,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () {
              if (reviewReason.isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('確認を記録'),
          ),
        ],
      ),
    );
    final reason = reviewReason;
    if (ok != true || !mounted) return;
    setState(() => busy = true);
    try {
      await (widget.service as QualificationNoticeService).reviewDelivery({
        'eventId': widget.eventId,
        'participantId': widget.participantId,
        'kind': delivery['kind'],
        if (delivery['fingerprint'] != null)
          'fingerprint': delivery['fingerprint'],
        'deliveryId': delivery['id'],
        'reason': reason,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(() => error = '処理中または状態が変わったため確認を保存できません。再取得してください。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy || source == null) return;
    if (pendingRequest == null) {
      if (reason.text.trim().isEmpty ||
          (details &&
              ((swap && target == null) ||
                  int.tryParse(count.text) == null ||
                  (int.tryParse(count.text) ?? 0) < 1 ||
                  (int.tryParse(count.text) ?? 1000) > 999 ||
                  (slot.text.isEmpty && action != 'edit')))) {
        setState(() => error = '理由、変更先の時間（例 14:10-14:50）・人数を確認してください。');
        return;
      }
      setState(() {
        busy = true;
        confirming = true;
      });
      final removesLastQualification =
          !details && (data!['activeQualificationCount'] ?? active.length) == 1;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('参加資格の変更を確定しますか？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${data!['name']}\n変更前：${describe(active)}\n変更：${name(source)} ${action == 'add'
                      ? '追加'
                      : action == 'edit'
                      ? '時間・人数変更'
                      : '取消'}${details ? ' → ${name(swap ? target : source)} ${slot.text} ${count.text}名' : ''}\n他の資格とQRは維持します。通知メールは送信しません。\n理由：${reason.text.trim()}',
                ),
                if (removesLastQualification) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'この資格を取り消すと、有効な参加資格がなくなり、Web参加証は利用できなくなります。QRコード自体は変更されませんが、受付には使用できません。',
                    key: Key('last-qualification-warning'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('戻る'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('確定'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() => confirming = false);
      if (confirmed != true) {
        setState(() => busy = false);
        return;
      }
      final random = Random.secure();
      pendingRequest = {
        'eventId': widget.eventId,
        'participantId': widget.participantId,
        'operationId': List.generate(
          24,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'fingerprint': data!['fingerprint'],
        'programId': source,
        if (action != 'cancel') 'action': action,
        'reason': reason.text.trim(),
        if (details) ...{
          if (swap) 'targetProgramId': target,
          'slotLabel': slot.text,
          'plannedCount': int.parse(count.text),
        },
      };
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.service.changeQualification(pendingRequest!);
      changed = true;
      await load();
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = '${e.message} 再試行は同じ操作として照合されます。');
    } catch (_) {
      if (mounted) setState(() => error = '結果を確認できません。同じ操作を再試行してください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frozen = busy || pendingRequest != null;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('参加資格の変更・取消'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (data != null) ...[
                  Text('${data!['name']} / ${data!['email']}'),
                  Text('申込ID：${data!['sourceReference'] ?? 'なし'}'),
                  const Text('現在の有効資格'),
                  for (final q in active)
                    Text(
                      '${name(q['programId'] as String?)} ${q['timeText'] ?? q['slotLabel']} ${q['plannedCount']}名${q['checkedIn'] == true ? '（受付済み・変更不可）' : ''}',
                    ),
                  if (data!['busy'] == true)
                    Text(
                      data!['busyReason'] as String? ??
                          '取込・配送処理が未完了のため変更できません。',
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: action,
                    decoration: const InputDecoration(labelText: '操作'),
                    items: const [
                      DropdownMenuItem(
                        value: 'cancel',
                        child: Text('資格取消・猫⇄犬変更'),
                      ),
                      DropdownMenuItem(value: 'add', child: Text('資格追加')),
                      DropdownMenuItem(value: 'edit', child: Text('時間・人数の変更')),
                    ],
                    onChanged: frozen
                        ? null
                        : (v) => setState(() {
                            action = v!;
                            swap = false;
                            selectSource(null);
                          }),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('source-$action-${data!['fingerprint']}'),
                    initialValue: source,
                    decoration: const InputDecoration(labelText: '変更・取消する資格'),
                    items: [
                      for (final q
                          in (action == 'add'
                              ? (data!['programs'] as List)
                                    .whereType<Map>()
                                    .where(
                                      (p) => !active.any(
                                        (a) => a['programId'] == p['programId'],
                                      ),
                                    )
                              : active))
                        DropdownMenuItem(
                          value: q['programId'] as String,
                          enabled: q['checkedIn'] != true,
                          child: Text(name(q['programId'] as String)),
                        ),
                    ],
                    onChanged: frozen
                        ? null
                        : (v) => setState(() {
                            swap = false;
                            selectSource(v);
                          }),
                  ),
                  if (action == 'cancel')
                    CheckboxListTile(
                      title: Text(
                        target == null ? '単独取消' : '${name(target)}へ変更する',
                      ),
                      value: swap,
                      onChanged: frozen || target == null
                          ? null
                          : (v) => setState(() {
                              swap = v!;
                              if (swap) {
                                slot.text = slots.firstOrNull ?? '';
                              } else {
                                selectSource(source);
                              }
                            }),
                    ),
                  if (details) ...[
                    if (slots.isNotEmpty)
                      DropdownButtonFormField<String>(
                        key: ValueKey('slot-$source-$swap-$action'),
                        initialValue: slots.contains(slot.text)
                            ? slot.text
                            : null,
                        decoration: const InputDecoration(labelText: '参加時間'),
                        items: [
                          for (final value in slots)
                            DropdownMenuItem(value: value, child: Text(value)),
                        ],
                        onChanged: frozen
                            ? null
                            : (v) => setState(() => slot.text = v!),
                      )
                    else
                      TextField(
                        controller: slot,
                        enabled: !frozen,
                        decoration: const InputDecoration(
                          labelText: '変更先時間（HH:mm-HH:mm）',
                        ),
                      ),
                    TextField(
                      controller: count,
                      enabled: !frozen,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '変更先の予定人数'),
                    ),
                  ],
                  TextField(
                    controller: reason,
                    enabled: !frozen,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: '変更理由（必須）'),
                  ),
                ],
                for (final h
                    in (data?['history'] as List? ?? []).whereType<Map>())
                  ExpansionTile(
                    title: Text('変更履歴 ${h['changedAt']}'),
                    subtitle: Text('${h['reason']} / ${h['changedBy']}'),
                    children: [
                      Text(
                        '変更前\n${describe(h['before'] as List)}\n変更後\n${describe(h['after'] as List)}',
                      ),
                      if (widget.service is QualificationNoticeService)
                        TextButton(
                          onPressed: busy ? null : () => notify(h),
                          child: const Text('変更通知を確認・手動送信'),
                        ),
                    ],
                  ),
                for (final delivery
                    in (data?['deliveries'] as List? ?? []).whereType<Map>())
                  ListTile(
                    title: Text('配送：${deliveryLabel(delivery['status'])}'),
                    subtitle: Text(
                      '${delivery['to'] ?? ''} ${delivery['startedAt'] ?? ''}（試行${delivery['attemptCount'] ?? 1}回）\n${delivery['kind']} / ${delivery['id']}${delivery['reviewed'] == true ? '（確認済み・再送禁止）' : ''}',
                    ),
                    trailing:
                        delivery['recoverable'] == true &&
                            delivery['reviewed'] != true &&
                            widget.service is QualificationNoticeService
                        ? TextButton(
                            onPressed: busy ? null : () => review(delivery),
                            child: const Text('状態確認・復旧'),
                          )
                        : null,
                  ),
                if (busy && !confirming) const LinearProgressIndicator(),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, changed),
            child: const Text('閉じる'),
          ),
          TextButton(onPressed: busy ? null : load, child: const Text('再取得')),
          FilledButton(
            onPressed: busy || source == null || data?['busy'] == true
                ? null
                : submit,
            child: Text(pendingRequest == null ? '確認へ' : '同じ操作を再試行'),
          ),
        ],
      ),
    );
  }
}
