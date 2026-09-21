import 'package:flutter/material.dart';

import '../services/demo_repository.dart';
import '../widgets/common.dart';

class WalkInPage extends StatefulWidget {
  const WalkInPage({super.key, required this.eventId, this.repository});
  final String eventId;

  /// テスト用。既定は公開の当日参加登録API(サーバーが入力・イベントの状態を検証し、メールを送る)を使う。
  final DemoRepository? repository;
  @override
  State<WalkInPage> createState() => _WalkInPageState();
}

class _WalkInPageState extends State<WalkInPage> {
  late final repository =
      widget.repository ?? DemoRepository(selectedEventId: widget.eventId);
  final name = TextEditingController();
  final email = TextEditingController();
  final count = TextEditingController(text: '1');
  bool saving = false;
  ({String participantId, String publicId})? created;
  String? mailError;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    count.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final registeredCount = int.tryParse(count.text.trim());
    if (name.text.trim().isEmpty ||
        !email.text.contains('@') ||
        registeredCount == null ||
        registeredCount < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('氏名、メールアドレス、参加人数を正しく入力してください。')),
      );
      return;
    }
    setState(() {
      saving = true;
      mailError = null;
    });
    try {
      final result = await repository.registerWalkIn(
        name: name.text,
        email: email.text,
        registeredCount: registeredCount,
      );
      created = (
        participantId: result.participantId,
        publicId: result.publicId,
      );
      mailError = result.mailError;
    } on MailSendException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '当日参加登録',
    child: created == null
        ? Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '当日参加登録',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '氏名'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'メールアドレス'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: count,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '参加人数',
                      suffixText: '名',
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: saving ? null : submit,
                    child: Text(saving ? '登録中…' : '登録する'),
                  ),
                ],
              ),
            ),
          )
        : Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.check_circle, size: 56, color: Colors.green),
                  const SizedBox(height: 12),
                  const Text(
                    '登録完了',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    mailError == null
                        ? '確認メールを送信しました'
                        : '登録は完了しましたが、メール送信に失敗しました\n$mailError',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () => Navigator.pushNamed(
                      context,
                      '/p/${created!.participantId}?publicId=${Uri.encodeQueryComponent(created!.publicId)}',
                    ),
                    child: const Text('マイページを開く'),
                  ),
                ],
              ),
            ),
          ),
  );
}
