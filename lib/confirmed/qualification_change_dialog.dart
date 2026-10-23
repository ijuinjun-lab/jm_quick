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

  Future<void> submit() async {
    if (busy || source == null) return;
    if (pendingRequest == null) {
      if (reason.text.trim().isEmpty ||
          (swap &&
              (target == null ||
                  int.tryParse(count.text) == null ||
                  !RegExp(r'^\d\d:\d\d-\d\d:\d\d$').hasMatch(slot.text)))) {
        setState(() => error = '理由、変更先の時間（例 14:10-14:50）・人数を確認してください。');
        return;
      }
      setState(() {
        busy = true;
        confirming = true;
      });
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('参加資格の変更を確定しますか？'),
          content: Text(
            '${data!['name']}\n${name(source)}を取消${swap ? ' → ${name(target)} ${slot.text} ${count.text}名を追加' : ''}\n他の資格とQRは維持します。通知メールは送信しません。\n理由：${reason.text.trim()}',
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
        'reason': reason.text.trim(),
        if (swap) ...{
          'targetProgramId': target,
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
      if (mounted) Navigator.pop(context, true);
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
                      '${name(q['programId'] as String?)} ${q['slotLabel']} ${q['plannedCount']}名${q['checkedIn'] == true ? '（受付済み・変更不可）' : ''}',
                    ),
                  if (data!['busy'] == true)
                    const Text('取込・配送処理が未完了のため変更できません。'),
                  DropdownButtonFormField<String>(
                    initialValue: source,
                    decoration: const InputDecoration(labelText: '変更・取消する資格'),
                    items: [
                      for (final q in active)
                        DropdownMenuItem(
                          value: q['programId'] as String,
                          enabled: q['checkedIn'] != true,
                          child: Text(name(q['programId'] as String)),
                        ),
                    ],
                    onChanged: frozen
                        ? null
                        : (v) => setState(() {
                            source = v;
                            swap = false;
                          }),
                  ),
                  CheckboxListTile(
                    title: Text(
                      target == null ? '単独取消' : '${name(target)}へ変更する',
                    ),
                    value: swap,
                    onChanged: frozen || target == null
                        ? null
                        : (v) => setState(() => swap = v!),
                  ),
                  if (swap) ...[
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
                if (busy && !confirming) const LinearProgressIndicator(),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context, false),
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
