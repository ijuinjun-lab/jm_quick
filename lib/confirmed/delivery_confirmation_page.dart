import 'package:flutter/material.dart';
import 'delivery_confirmation_service.dart';
import 'mail_html_preview.dart';

class DeliveryConfirmationPage extends StatefulWidget {
  const DeliveryConfirmationPage({
    super.key,
    required this.eventId,
    this.service,
  });
  final String eventId;
  final DeliveryConfirmationService? service;
  @override
  State<DeliveryConfirmationPage> createState() =>
      _DeliveryConfirmationPageState();
}

class _DeliveryConfirmationPageState extends State<DeliveryConfirmationPage> {
  static const kinds = {
    'normal': '通常当選',
    'waitlistPromotion': '繰り上げ当選',
    'broadcast': '一斉メール',
  };
  static const statuses = {
    'pending': '未送信',
    'sending': '送信中',
    'sent': '送信済み',
    'failed': '送信失敗',
    'unknown': '結果不明（再送禁止）',
  };
  late final service = widget.service ?? DeliveryConfirmationService();
  Map<String, dynamic>? settings, detail;
  List<Map<String, dynamic>> recipients = [];
  final reports = <dynamic>[];
  bool enabled = false, busy = false;
  String? error, nextAfter;
  int revision = 0;
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  bool get canManage => settings?['canManage'] == true;
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) => service.call(name, {'eventId': widget.eventId, ...data});
  @override
  void initState() {
    super.initState();
    run(load);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is DeliveryConfirmationException
              ? e.message
              : const DeliveryConfirmationException('unknown').message,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients) {
            scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() async {
    final s = await call('getDeliveryConfirmationSettings');
    if (!mounted) return;
    setState(() {
      settings = s;
      enabled = s['policy']['enabled'] == true;
      recipients = (s['policy']['recipients'] as List)
          .map(
            (r) =>
                Map<String, dynamic>.from(r as Map)
                  ..['kinds'] = List<String>.from(r['kinds'] as List),
          )
          .toList();
      reports
        ..clear()
        ..addAll(s['reports'] as List);
      nextAfter = s['nextAfter'] as String?;
      revision++;
    });
  }

  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('戻る'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('確認して実行'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> save() async {
    if (!await confirm(
      '配信確認先を保存',
      '${enabled ? '有効化します。有効化後に新規作成された正式ジョブが対象です。' : '無効にします。'}\n${recipients.map((r) => '${r['email']} / ${r['enabled'] ? '有効' : '無効'} / ${(r['kinds'] as List).map((k) => kinds[k]).join('・')}').join('\n')}\nアドレスと対象種別を確認してください。この操作だけではメールを送りません。',
    )) {
      return;
    }
    await run(() async {
      await call('updateDeliveryConfirmationPolicy', {
        'enabled': enabled,
        'recipients': recipients,
        'expectedVersion': settings!['policy']['version'],
      });
      await load();
    });
  }

  Future<void> removeRecipient(int index) async {
    if (!canManage || busy) return;
    if (!await confirm(
      '確認先を削除',
      '${recipients[index]['email']} を確認先から削除します。過去の送信履歴は保持されます。削除は「確認先設定を保存」で確定します。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      recipients.removeAt(index);
      revision++;
    });
  }

  Future<void> readReport(String id) async {
    final d = await call('getDeliveryConfirmationReport', {'reportId': id});
    if (mounted) setState(() => detail = d);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('配信確認先')),
    body: SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '正式配信完了後に、サンプルのメールと配送結果を確認先へ送ります。参加者・資格・正式配信件数は増えません。',
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(error!, key: const Key('confirmation-error')),
              OutlinedButton(
                onPressed: busy ? null : () => run(load),
                child: const Text('設定・履歴を更新'),
              ),
              if (settings != null) ...[
                if (!canManage) const Text('確認先の変更はシステム管理者のみ可能です。'),
                SwitchListTile(
                  title: const Text('配信確認を有効にする'),
                  value: enabled,
                  onChanged: canManage && !busy
                      ? (v) => setState(() => enabled = v)
                      : null,
                ),
                const Text('通常・繰り上げは取込回ごと、一斉メールは送信操作ごとに1回です。過去ジョブには自動送信しません。'),
                for (var i = 0; i < recipients.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          if (canManage)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                key: ValueKey('remove-recipient-$i'),
                                onPressed: busy
                                    ? null
                                    : () => removeRecipient(i),
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('確認先を削除'),
                              ),
                            ),
                          TextFormField(
                            key: ValueKey('email-$revision-$i'),
                            initialValue: recipients[i]['email'] as String,
                            enabled: canManage && !busy,
                            decoration: const InputDecoration(
                              labelText: '確認先メールアドレス',
                            ),
                            onChanged: (v) => recipients[i]['email'] = v,
                          ),
                          TextFormField(
                            key: ValueKey('name-$revision-$i'),
                            initialValue: recipients[i]['name'] as String,
                            enabled: canManage && !busy,
                            decoration: const InputDecoration(labelText: '表示名'),
                            onChanged: (v) => recipients[i]['name'] = v,
                          ),
                          SwitchListTile(
                            title: const Text('この確認先を有効にする'),
                            value: recipients[i]['enabled'] == true,
                            onChanged: canManage && !busy
                                ? (v) => setState(
                                    () => recipients[i]['enabled'] = v,
                                  )
                                : null,
                          ),
                          for (final k in kinds.entries)
                            CheckboxListTile(
                              title: Text(k.value),
                              value: (recipients[i]['kinds'] as List).contains(
                                k.key,
                              ),
                              onChanged: canManage && !busy
                                  ? (v) => setState(() {
                                      final list =
                                          recipients[i]['kinds'] as List;
                                      if (v == true) {
                                        list.add(k.key);
                                      } else {
                                        list.remove(k.key);
                                      }
                                    })
                                  : null,
                            ),
                        ],
                      ),
                    ),
                  ),
                if (canManage) ...[
                  OutlinedButton(
                    onPressed: busy || recipients.length >= 10
                        ? null
                        : () => setState(
                            () => recipients.add({
                              'email': '',
                              'name': '',
                              'enabled': true,
                              'kinds': kinds.keys.toList(),
                            }),
                          ),
                    child: const Text('確認先を追加（最大10件）'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : save,
                    child: const Text('確認先設定を保存'),
                  ),
                ],
                const Divider(),
                const Text('配信確認メールの履歴'),
                for (final r in reports)
                  ListTile(
                    title: Text(
                      '${kinds[r['kind']]} / ${r['completedAt'] ?? ''}',
                    ),
                    subtitle: Text(
                      r['status'] == 'unavailable'
                          ? '確認用コピーを生成できません（${r['errorCode']}）'
                          : r['subject'] as String,
                    ),
                    onTap: busy
                        ? null
                        : () => run(() => readReport(r['reportId'] as String)),
                  ),
                if (nextAfter != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final s = await call(
                              'getDeliveryConfirmationSettings',
                              {'after': nextAfter},
                            );
                            if (mounted) {
                              setState(() {
                                reports.addAll(s['reports'] as List);
                                nextAfter = s['nextAfter'] as String?;
                              });
                            }
                          }),
                    child: const Text('履歴をさらに表示'),
                  ),
              ],
              if (detail != null) ...[
                const Divider(),
                SelectableText('参照元の正式ジョブ：${detail!['sourceJobId']}'),
                SelectableText(detail!['text'] as String),
                if ((detail!['html'] as String).isNotEmpty)
                  MailHtmlPreview(
                    html: detail!['html'] as String,
                    qrPngBase64: detail!['qrPngBase64'] as String? ?? '',
                    allowWithoutQr: true,
                  ),
                for (final d in detail!['deliveries'] as List)
                  ListTile(
                    title: Text('${d['name']} / ${d['email']}'),
                    subtitle: Text(
                      '${statuses[d['status']] ?? d['status']} / 試行${d['attemptCount']}回\n送信日時：${d['sentAt'] ?? '未記録'}',
                    ),
                    trailing: d['status'] == 'failed'
                        ? TextButton(
                            onPressed: busy
                                ? null
                                : () async {
                                    if (!await confirm(
                                      '失敗した確認メールを再試行',
                                      '${d['email']} に保存済みの確認メールを送信します。正式参加者には送信しません。',
                                    )) {
                                      return;
                                    }
                                    await run(() async {
                                      await call('retryDeliveryConfirmation', {
                                        'reportId': detail!['reportId'],
                                        'recipientKey': d['recipientKey'],
                                        'expectedAttempt': d['attemptCount'],
                                      });
                                      await readReport(
                                        detail!['reportId'] as String,
                                      );
                                    });
                                  },
                            child: const Text('失敗分を再試行'),
                          )
                        : null,
                  ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          if (!await confirm(
                            '未送信の確認メールを再開',
                            '未送信、または送信開始前に中断した確認メールだけを処理します。送信済み・失敗・結果不明は再送しません。',
                          )) {
                            return;
                          }
                          await run(() async {
                            await call('resumeDeliveryConfirmation', {
                              'reportId': detail!['reportId'],
                            });
                            await readReport(detail!['reportId'] as String);
                          });
                        },
                  child: const Text('中断した未送信処理を再開'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
