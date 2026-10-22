import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/app_check.dart';
import 'auth_client.dart';
import 'mail_html_preview.dart';

class TestMailService {
  TestMailService({
    AuthClient? auth,
    AppCheckTokenProvider? appCheck,
    http.Client? client,
  }) : auth = auth ?? FirebaseAuthClient(),
       appCheck = appCheck ?? FirebaseAppCheckTokenProvider(),
       client = client ?? http.Client();
  final AuthClient auth;
  final AppCheckTokenProvider appCheck;
  final http.Client client;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final token = await auth.idToken();
    final check = await appCheck.token();
    if (token == null || check == null) throw Exception('ログイン・アプリ認証を確認してください。');
    final response = await client.post(
      Uri.parse('https://asia-northeast1-jm-quick.cloudfunctions.net/$name'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
        appCheckHeaderName: check,
      },
      body: jsonEncode({'data': data}),
    );
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
    if (response.statusCode != 200) {
      throw Exception((decoded['error'] as Map?)?['message'] ?? '処理に失敗しました。');
    }
    return Map<String, dynamic>.from(
      (decoded['result'] ?? decoded['data']) as Map,
    );
  }
}

class TestMailPage extends StatefulWidget {
  const TestMailPage({super.key, required this.eventId, this.service});
  final String eventId;
  final TestMailService? service;
  @override
  State<TestMailPage> createState() => _TestMailPageState();
}

class _TestMailPageState extends State<TestMailPage> {
  late final service = widget.service ?? TestMailService();
  Map<String, dynamic>? settings, preview;
  String kind = 'normal';
  String? person, to, message, batchId;
  bool busy = false, draft = false;
  final synthetic = <String>{};
  final policyInput = TextEditingController();
  final subject = TextEditingController(text: 'テスト送信・正式文面ではありません リマインド');
  final intro = TextEditingController(text: 'テスト送信・正式文面ではありません。ご参加内容をご確認ください。');
  final closing = TextEditingController(text: '社内確認用の仮文面です。');
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    policyInput.dispose();
    subject.dispose();
    intro.dispose();
    closing.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => message = '$e\n送信操作後の通信失敗は再送せず、履歴を確認してください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => run(() async {
    final value = await service.call('getConfirmedTestMailSettings', {
      'eventId': widget.eventId,
    });
    if (mounted) {
      setState(() {
        settings = value;
        preview = null;
        if (!(value['addresses'] as List).contains(to)) to = null;
        if (!(value['participants'] as List).any(
          (p) => p['participantId'] == person,
        )) {
          person = null;
        }
        if (!(value['batches'] as List).any((b) => b['batchId'] == batchId)) {
          batchId = null;
        }
      });
    }
  });
  Map<String, dynamic> input() => {
    'eventId': widget.eventId,
    'kind': kind,
    'to': to,
    if (person != null)
      'participantId': person
    else
      'syntheticProgramIds': synthetic.toList()..sort(),
    if (batchId != null && person != null && !kind.startsWith('reminder'))
      'batchId': batchId,
    if (draft && kind.startsWith('reminder'))
      'draft': {
        'subject': subject.text,
        'introBody': intro.text,
        'closingBody': closing.text,
      },
  };
  Future<void> managePolicy() async {
    final controller = policyInput;
    controller.text = (settings!['addresses'] as List).join('\n');
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('社内テスト送信先を承認（最大10件）'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(labelText: '承認する社内アドレスを1行1件'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('このイベントの送信先として承認'),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    await run(() async {
      await service.call('updateConfirmedTestMailPolicy', {
        'eventId': widget.eventId,
        'addresses': value
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
      });
      if (mounted) {
        setState(() {
          preview = null;
          to = null;
        });
      }
    });
    if (mounted) await load();
  }

  Future<void> showPreview() => run(() async {
    final value = await service.call('previewConfirmedTestMail', input());
    if (mounted) setState(() => preview = value);
  });
  Future<void> send() async {
    final p = preview;
    if (p == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('テストメールを1通送信します'),
        content: Text(
          '宛先：${p['to']}\n件名：${p['subject']}\n正式送信ではありません。表示した本文で送信します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('確認してテスト送信'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await run(() async {
      final result = await service.call('sendConfirmedTestMail', {
        ...input(),
        'fingerprint': p['fingerprint'],
      });
      if (mounted) {
        setState(() {
          message = 'テスト配送結果：${result['status']}';
          preview = null;
        });
      }
    });
  }

  void changed(VoidCallback fn) => setState(() {
    fn();
    preview = null;
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('テストメール（正式送信とは別）')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '正式な参加者・設定・配送履歴は変更しません。実参加者のQRは有効です。テスト受信者は受付に使用しないでください。\n同じ内容・同じ宛先は再送しません。結果不明は自動再送しません。1時間10通まで。',
          ),
          if (message != null) SelectableText(message!),
          if (settings != null) ...[
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: const InputDecoration(labelText: 'メール種類'),
              items: const [
                DropdownMenuItem(value: 'normal', child: Text('通常当選')),
                DropdownMenuItem(
                  value: 'waitlistPromotion',
                  child: Text('繰り上げ当選'),
                ),
                DropdownMenuItem(value: 'reminder1', child: Text('第1回リマインド')),
                DropdownMenuItem(value: 'reminder2', child: Text('第2回リマインド')),
              ],
              onChanged: busy
                  ? null
                  : (v) => changed(() {
                      kind = v!;
                      draft = false;
                      batchId = null;
                    }),
            ),
            DropdownButtonFormField<String>(
              initialValue: person ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'プレビュー対象'),
              items: [
                const DropdownMenuItem(value: '', child: Text('架空申込（QRは受付不可）')),
                for (final p in settings!['participants'] as List)
                  DropdownMenuItem(
                    value: p['participantId'] as String,
                    child: Text(p['name'] as String),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (v) => changed(() => person = v == '' ? null : v),
            ),
            if (person != null && !kind.startsWith('reminder'))
              DropdownButtonFormField<String>(
                initialValue: batchId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '通知する取込回（資格追加時は該当回を選択）',
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('初回の取込')),
                  for (final b in (settings!['batches'] as List).where(
                    (b) => b['notificationType'] == kind,
                  ))
                    DropdownMenuItem(
                      value: b['batchId'] as String,
                      child: Text(
                        '第${b['sequence']}回 / ${b['notificationType']}',
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (v) => changed(() => batchId = v == '' ? null : v),
              ),
            if (person == null) ...[
              const Text('架空の申込日時・時間・人数を使用します。正式参加資格ではありません。'),
              for (final p in settings!['programs'] as List)
                CheckboxListTile(
                  title: Text(p['name'] as String),
                  value: synthetic.contains(p['programId']),
                  onChanged: busy
                      ? null
                      : (v) => changed(() {
                          v!
                              ? synthetic.add(p['programId'] as String)
                              : synthetic.remove(p['programId']);
                        }),
                ),
            ],
            DropdownButtonFormField<String>(
              initialValue: to,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '承認済みテスト送信先'),
              items: [
                for (final a in settings!['addresses'] as List)
                  DropdownMenuItem(value: a as String, child: Text(a)),
              ],
              onChanged: busy ? null : (v) => changed(() => to = v),
            ),
            if (settings!['canManagePolicy'] == true)
              OutlinedButton(
                onPressed: busy ? null : managePolicy,
                child: const Text('承認済み社内宛先を管理'),
              ),
            if ((settings!['addresses'] as List).isEmpty)
              const Text('送信先が未承認です。システム管理者による許可リストの登録が必要です。'),
            if (kind.startsWith('reminder')) ...[
              CheckboxListTile(
                title: const Text('正式文面未設定の場合、保存しない仮文面を使う'),
                value: draft,
                onChanged: busy ? null : (v) => changed(() => draft = v!),
              ),
              if (draft) ...[
                TextField(
                  controller: subject,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'テスト仮件名'),
                  onChanged: (_) => changed(() {}),
                ),
                TextField(
                  controller: intro,
                  enabled: !busy,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'テスト仮本文'),
                  onChanged: (_) => changed(() {}),
                ),
                TextField(
                  controller: closing,
                  enabled: !busy,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'テスト仮締め文'),
                  onChanged: (_) => changed(() {}),
                ),
              ],
            ],
            OutlinedButton(
              onPressed:
                  busy || to == null || (person == null && synthetic.isEmpty)
                  ? null
                  : showPreview,
              child: const Text('テスト送信内容を確認（送信しません）'),
            ),
            if (preview != null) ...[
              SelectableText('宛先：${preview!['to']}\n件名：${preview!['subject']}'),
              MailHtmlPreview(
                html: preview!['html'] as String,
                qrPngBase64: preview!['qrPngBase64'] as String,
              ),
              ExpansionTile(
                title: const Text('テキスト版'),
                children: [SelectableText(preview!['text'] as String)],
              ),
              FilledButton(
                onPressed: busy ? null : send,
                child: const Text('テスト送信の最終確認へ'),
              ),
            ],
            OutlinedButton(
              onPressed: busy ? null : load,
              child: const Text('テスト配送履歴を更新'),
            ),
            for (final h in settings!['history'] as List)
              Text('${h['kind']} / ${h['to']} / ${h['status']}'),
          ],
          if (busy) const LinearProgressIndicator(),
        ],
      ),
    ),
  );
}

class TestMailButton extends StatelessWidget {
  const TestMailButton({super.key, required this.eventId});
  final String? eventId;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: eventId == null
        ? null
        : () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => TestMailPage(eventId: eventId!),
            ),
          ),
    child: const Text('テストメール送信'),
  );
}
