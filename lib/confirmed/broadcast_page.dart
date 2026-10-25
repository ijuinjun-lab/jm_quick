import 'dart:math';
import 'package:flutter/material.dart';
import 'mail_html_preview.dart';
import 'test_mail_page.dart';

/// No Firestore client writes. All actions use authenticated, event-scoped APIs.
class BroadcastPage extends StatefulWidget {
  const BroadcastPage({super.key, required this.eventId, this.service});
  final String eventId;
  final TestMailService? service;
  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  static const deliveryLabels = {
    'pending': '未送信',
    'sending': '送信中',
    'sent': '送信済み',
    'failed': '送信失敗',
    'unknown': '結果不明（自動再送しません）',
  };
  String countsText(Map? counts) => deliveryLabels.entries
      .map((e) => '${e.value} ${counts?[e.key] ?? 0}件')
      .join(' / ');
  late final service = widget.service ?? TestMailService();
  final subject = TextEditingController(), body = TextEditingController();
  final recipientsScroll = ScrollController();
  Map<String, dynamic>? settings, preview, detail;
  String? person, error, selectedJob;
  bool busy = false,
      reviewed = false,
      details = true,
      qr = true,
      attempted = false,
      confirming = false;
  String operationId = _newId();
  static String _newId() => List.generate(
    32,
    (_) => Random.secure().nextInt(16).toRadixString(16),
  ).join();
  Map<String, dynamic> get draft => {
    'subject': subject.text,
    'body': body.text,
    'includeDetails': details,
    'includeQr': qr,
  };
  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic> data = const {},
  ]) => service.call(name, {'eventId': widget.eventId, ...data});
  @override
  void initState() {
    super.initState();
    run(load);
  }

  @override
  void dispose() {
    subject.dispose();
    body.dispose();
    recipientsScroll.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() task) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() async {
    final value = await call('getConfirmedBroadcastSettings');
    if (!mounted) return;
    setState(() {
      settings = value;
      final list = value['recipients'] as List;
      if (!list.any((r) => r['participantId'] == person)) {
        person = list.isEmpty ? null : list.first['participantId'] as String;
      }
    });
  }

  void changed() => setState(() {
    preview = null;
    reviewed = false;
  });

  Widget recipientPanel() {
    final recipients = settings?['recipients'] as List? ?? [];
    final batches = settings?['batchCounts'] as List?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('一斉メール送信対象', style: Theme.of(context).textTheme.titleLarge),
        if (settings == null)
          const Text('送信対象を取得しています。')
        else ...[
          Text('現在の送信対象総数：${recipients.length}申込'),
          const Text('取込回別件数（参加者の初回取込を基準に集計）'),
          if (batches == null)
            const Text('取込回情報を取得できません。対象総数・宛先一覧をご確認ください。')
          else
            for (final batch in batches)
              Text(
                '${batch['sequence'] == null ? '取込回不明' : '第${batch['sequence']}回'}：${batch['count']}申込',
              ),
          if (recipients.isEmpty)
            const Text('現在の送信対象者はいません。')
          else
            SizedBox(
              height: 280,
              child: Scrollbar(
                controller: recipientsScroll,
                thumbVisibility: true,
                child: ListView.builder(
                  key: const Key('broadcastRecipients'),
                  controller: recipientsScroll,
                  itemCount: recipients.length,
                  itemBuilder: (context, index) {
                    final r = recipients[index];
                    return ListTile(
                      title: Text('${r['name']}\n${r['email']}'),
                      subtitle: Text(
                        (r['programs'] as List? ?? [])
                            .map(
                              (p) =>
                                  '${p['name']} ${p['timeText'] ?? ''} ${p['plannedCount']}名',
                            )
                            .join('\n'),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
        OutlinedButton(
          onPressed: busy ? null : () => run(load),
          child: const Text('送信対象を更新'),
        ),
        const Text('資格変更・キャンセル後は「送信対象を更新」で再取得してください。正式送信前にも最新の対象を確認します。'),
        const Divider(),
      ],
    );
  }

  Future<bool> confirm(String title, String text) async {
    setState(() => confirming = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: Text(title),
              content: Text(text),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('確認して続行'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  Future<void> start() async {
    if (!await confirm(
      '正式な一斉メールを送信',
      '${preview!['targetCount']}申込へ「${subject.text}」を送信します。テスト送信ではありません。',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => attempted = true);
    await run(() async {
      final result = await call('startConfirmedBroadcastDelivery', {
        'draft': draft,
        'operationId': operationId,
        'confirmation': preview!['confirmation'],
        'recipientsConfirmed': true,
      });
      selectedJob = result['jobId'] as String;
      await load();
      await readJob(selectedJob!);
    });
  }

  Future<void> readJob(String id) async {
    // Read every result page; do not silently hide recipients after the first 100.
    String? after;
    final items = <dynamic>[];
    Map<String, dynamic>? result;
    do {
      result = await call('getConfirmedBroadcastJob', {
        'jobId': id,
        if (after != null) 'after': after,
      });
      items.addAll(result['items'] as List);
      after = result['nextAfter'] as String?;
    } while (after != null);
    if (mounted) {
      setState(() {
        selectedJob = id;
        detail = {...result!, 'items': items};
      });
    }
  }

  Future<void> recover() async {
    final result = await call('getConfirmedBroadcastRecovery', {
      'jobId': selectedJob,
    });
    for (final r in result['recipients'] as List) {
      if (!mounted) return;
      final reason = TextEditingController();
      final approved = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('未送信宛先の再確認'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${r['name']}\n${r['email']}\n${r['text']}'),
                TextField(
                  controller: reason,
                  decoration: const InputDecoration(labelText: '変更を確認した理由（必須）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () {
                if (reason.text.trim().isNotEmpty) Navigator.pop(c, true);
              },
              child: const Text('この宛先を再確認'),
            ),
          ],
        ),
      );
      final reasonText = reason.text;
      reason.dispose();
      if (approved == true) {
        await call('confirmConfirmedBroadcastRecovery', {
          'jobId': selectedJob,
          'participantId': r['participantId'],
          'fingerprint': r['fingerprint'],
          'reason': reasonText,
        });
      }
    }
    await readJob(selectedJob!);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(preview != null && !attempted ? '送信内容・宛先の確認' : '一斉メール送信'),
      leading: preview != null && !attempted
          ? BackButton(onPressed: busy ? null : changed)
          : null,
    ),
    body: SingleChildScrollView(
      key: ValueKey(preview != null && !attempted),
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('有効な参加資格を持つ全申込へ1通ずつ送信します。日時の登録は不要です。自動送信はありません。'),
              if (error != null) SelectableText(error!),
              if (busy) const LinearProgressIndicator(),
              if (preview == null || attempted) ...[
                recipientPanel(),
                Text('メール作成', style: Theme.of(context).textTheme.titleLarge),
                TextField(
                  controller: subject,
                  enabled: !busy && !attempted,
                  decoration: const InputDecoration(labelText: '件名'),
                  onChanged: (_) => changed(),
                ),
                TextField(
                  controller: body,
                  enabled: !busy && !attempted,
                  minLines: 5,
                  maxLines: 12,
                  decoration: const InputDecoration(labelText: '本文'),
                  onChanged: (_) => changed(),
                ),
                CheckboxListTile(
                  value: details,
                  title: const Text('開催情報・参加内容・問い合わせ先を表示'),
                  onChanged: busy || attempted
                      ? null
                      : (v) {
                          details = v!;
                          changed();
                        },
                ),
                CheckboxListTile(
                  value: qr,
                  title: const Text('既存QR・Web参加証リンクを表示'),
                  onChanged: busy || attempted
                      ? null
                      : (v) {
                          qr = v!;
                          changed();
                        },
                ),
                if (settings != null) ...[
                  Text('送信操作', style: Theme.of(context).textTheme.titleLarge),
                  OutlinedButton(
                    onPressed: busy || attempted || person == null
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => TestMailPage(
                                eventId: widget.eventId,
                                service: service,
                                broadcastDraft: draft,
                                initialParticipantId: person,
                              ),
                            ),
                          ),
                    child: const Text('社内へテスト送信'),
                  ),
                  FilledButton(
                    onPressed:
                        busy ||
                            attempted ||
                            person == null ||
                            subject.text.trim().isEmpty ||
                            body.text.trim().isEmpty
                        ? null
                        : () => run(() async {
                            final p = await call(
                              'previewConfirmedBroadcastMail',
                              {'draft': draft, 'participantId': person},
                            );
                            if (mounted) {
                              setState(() {
                                preview = p;
                                reviewed = false;
                              });
                            }
                          }),
                    child: const Text('一斉送信へ進む'),
                  ),
                ],
              ],
              if (preview != null) ...[
                Text('送信対象 ${preview!['targetCount']}申込'),
                if (preview!['targetCount'] !=
                    (settings?['recipients'] as List?)?.length)
                  const Text('初期表示から対象人数が変わりました。以下の最新の宛先一覧・人数をご確認ください。'),
                SelectableText('件名：${subject.text}\n本文：${body.text}'),
                for (final r in preview!['recipients'] as List)
                  ListTile(
                    title: Text('${r['name']} / ${r['email']}'),
                    subtitle: Text(
                      (r['programs'] as List)
                          .map(
                            (p) =>
                                '${p['name']} ${p['timeText'] ?? ''} ${p['plannedCount']}名',
                          )
                          .join('\n'),
                    ),
                  ),
                if (confirming)
                  const SizedBox(height: 700)
                else
                  MailHtmlPreview(
                    allowWithoutQr: true,
                    html: preview!['html'] as String,
                    qrPngBase64: preview!['qrPngBase64'] as String,
                  ),
                ExpansionTile(
                  title: const Text('テキスト版'),
                  children: [SelectableText(preview!['text'] as String)],
                ),
                CheckboxListTile(
                  value: reviewed,
                  title: const Text('宛先全員・件数・件名・本文を確認しました'),
                  onChanged: busy || attempted
                      ? null
                      : (v) => setState(() => reviewed = v!),
                ),
                FilledButton(
                  onPressed: busy || !reviewed || attempted ? null : start,
                  child: const Text('最終確認へ'),
                ),
              ],
              if (attempted) ...[
                const Text(
                  '送信開始を要求しました。通信エラー時も新しいメールを作らず、履歴を確認してください。同じ要求の再確認では重複送信しません。',
                ),
                OutlinedButton(
                  onPressed: busy ? null : start,
                  child: const Text('同じ送信要求の状態を確認・再開'),
                ),
              ],
              const Divider(),
              const Text('送信履歴・配送結果（旧リマインドを含む）'),
              TextButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        await load();
                        if (selectedJob != null) await readJob(selectedJob!);
                      }),
                child: const Text('配送結果を更新'),
              ),
              for (final j in settings?['history'] as List? ?? [])
                ListTile(
                  title: Text(
                    '${j['type'] == 'reminder' ? '旧リマインド / ' : ''}${j['subject']}',
                  ),
                  subtitle: Text(
                    '${j['createdAt']} / 作成者 ${j['createdBy']}\n送信開始 ${j['startedAt'] ?? '未開始'}\n対象 ${j['targetCount']} / 済 ${j['sentCount']} / 失敗 ${j['failedCount']} / 不明 ${j['unknownCount']}',
                  ),
                  onTap: busy
                      ? null
                      : () => run(() => readJob(j['jobId'] as String)),
                ),
              if (detail != null) ...[
                SelectableText(
                  '件名：${detail!['job']['subject'] ?? ''}\n本文：${detail!['job']['body'] ?? ''}\n${countsText(detail!['job']['counts'] as Map?)}',
                ),
                if (detail!['job']['dispatch']?['haltedReason'] != null)
                  const Text('配送を安全のため停止しました。各宛先の結果を確認してから再開してください。'),
                for (final i in detail!['items'] as List)
                  ListTile(
                    title: Text(
                      '${i['name']} / ${deliveryLabels[i['status']] ?? i['status']}',
                    ),
                    subtitle: Text(i['lastErrorCode'] as String? ?? ''),
                  ),
                if (selectedJob!.startsWith('broadcast-')) ...[
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            await call('resumeConfirmedBroadcastDelivery', {
                              'jobId': selectedJob,
                            });
                            await readJob(selectedJob!);
                          }),
                    child: const Text('このジョブの未送信分を続行'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            if (await confirm(
                              '失敗分だけ再開準備',
                              '送信済み・結果不明は再送しません。宛先・資格が変わった場合は再確認が必要です。',
                            )) {
                              await run(() async {
                                await call(
                                  'retryFailedConfirmedBroadcastMails',
                                  {'jobId': selectedJob},
                                );
                                await readJob(selectedJob!);
                              });
                            }
                          },
                    child: const Text('確実な送信失敗分を再開準備'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => run(recover),
                    child: const Text('変更により停止した宛先を再確認'),
                  ),
                ],
                const Text('結果不明の宛先は自動再送しません。配送は画面を閉じてもサーバーで継続します。'),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
