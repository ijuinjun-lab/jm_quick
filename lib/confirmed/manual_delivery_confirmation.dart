import 'package:flutter/material.dart';
import 'delivery_confirmation_service.dart';
import 'mail_html_preview.dart';

/// Separate office notification; never invokes participant delivery endpoints.
class ManualDeliveryConfirmationButton extends StatelessWidget {
  const ManualDeliveryConfirmationButton({
    super.key,
    required this.eventId,
    required this.jobId,
    this.service,
  });
  final String eventId;
  final String jobId;
  final DeliveryConfirmationService? service;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: () => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ManualNotificationDialog(
        eventId: eventId,
        jobId: jobId,
        service: service ?? DeliveryConfirmationService(),
      ),
    ),
    child: const Text('事務局へ送信結果を通知'),
  );
}

class _ManualNotificationDialog extends StatefulWidget {
  const _ManualNotificationDialog({
    required this.eventId,
    required this.jobId,
    required this.service,
  });
  final String eventId;
  final String jobId;
  final DeliveryConfirmationService service;
  @override
  State<_ManualNotificationDialog> createState() =>
      _ManualNotificationDialogState();
}

class _ManualNotificationDialogState extends State<_ManualNotificationDialog> {
  Map<String, dynamic>? preview;
  bool busy = false;
  String? error;
  static const statuses = {
    'pending': '未送信',
    'sending': '処理中',
    'sent': '通知済み',
    'failed': '送信失敗（未送信）',
    'unknown': '結果不明（再送禁止）',
  };
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() => run('previewManualDeliveryConfirmation');
  Future<void> run(
    String endpoint, [
    Map<String, dynamic> extra = const {},
  ]) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.service.call(endpoint, {
        'eventId': widget.eventId,
        'jobId': widget.jobId,
        ...extra,
      });
      if (mounted) setState(() => preview = result);
    } catch (e) {
      if (mounted) {
        setState(() {
          // A lost response is not evidence of failure. Require a fresh read.
          preview = null;
          error = e is DeliveryConfirmationException
              ? e.message
              : '結果を確認できません。「状態を更新」で確認してください。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> send([Map? recipient]) => run('sendManualDeliveryConfirmation', {
    'fingerprint': preview!['fingerprint'],
    if (recipient != null) ...{
      'recipientKey': recipient['recipientKey'],
      'expectedAttempt': recipient['attemptCount'],
    },
  });
  @override
  Widget build(BuildContext context) {
    final p = preview;
    final counts = p?['counts'] as Map?;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('事務局へ送信結果を通知'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (busy) const LinearProgressIndicator(),
                if (error != null) Text(error!),
                if (p != null) ...[
                  const Text('通知先・内容を確認してください。参加者向けメールは再送しません。'),
                  if (p['errorCode'] != null)
                    Text(
                      DeliveryConfirmationException(
                        p['errorCode'] as String,
                      ).message,
                    ),
                  if (counts != null)
                    Text(
                      '対象 ${counts['targetCount']}件 / 成功 ${counts['sentCount']}件 / 失敗 ${counts['failedCount']}件 / 結果不明 ${counts['unknownCount']}件',
                    ),
                  for (final d in (p['deliveries'] as List).whereType<Map>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${d['email']}'),
                      subtitle: Text(
                        '${statuses[d['status']] ?? d['status']} / 試行${d['attemptCount']}回${d['sentAt'] == null ? '' : ' / ${d['sentAt']}'}',
                      ),
                      trailing:
                          d['status'] == 'failed' &&
                              d['allowed'] == true &&
                              p['errorCode'] == null
                          ? TextButton(
                              onPressed: busy ? null : () => send(d),
                              child: const Text('この宛先へ再送する'),
                            )
                          : null,
                    ),
                  Text('件名：${p['subject']}'),
                  const SizedBox(height: 12),
                  Text(p['text'] as String? ?? ''),
                  if ((p['html'] as String? ?? '').isNotEmpty)
                    MailHtmlPreview(
                      html: p['html'] as String,
                      qrPngBase64: p['qrPngBase64'] as String? ?? '',
                      allowWithoutQr: true,
                    ),
                  const Text('通知済み・結果不明は再送しません。失敗した宛先だけ個別に再送できます。'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
          TextButton(onPressed: busy ? null : load, child: const Text('状態を更新')),
          FilledButton(
            onPressed: !busy && p?['canSend'] == true ? () => send() : null,
            child: const Text('送信する'),
          ),
        ],
      ),
    );
  }
}
