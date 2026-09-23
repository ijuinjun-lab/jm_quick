import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'auth_client.dart';

/// 新方式の管理者・スタッフ用ログイン(メールアドレスとパスワードのみ)。
/// ログインできても、権限はサーバーが別に確認する(AuthGate)。
class ConfirmedLoginPage extends StatefulWidget {
  const ConfirmedLoginPage({super.key, required this.authClient, this.banner});
  final AuthClient authClient;

  /// ログインフォームの上に表示する、任意の案内(既定はnull=何も出さない。全画面共通のこのログイン画面自体は
  /// 変えず、呼び出し元(例: 受付QRの入口)だけが必要な案内を追加で渡せる)。
  final Widget? banner;

  @override
  State<ConfirmedLoginPage> createState() => _ConfirmedLoginPageState();
}

class _ConfirmedLoginPageState extends State<ConfirmedLoginPage> {
  final email = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = 'メールアドレスとパスワードを入力してください。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.authClient.signIn(email.text, password.text);
      // 成功すると、ログイン状態の変化をAuthGateが受け取り、権限確認へ進む。
      if (mounted) password.clear();
    } on AuthFailure catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } catch (_) {
      if (mounted) setState(() => error = 'ログインできませんでした。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'ログイン',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.banner != null) ...[widget.banner!, const SizedBox(height: 16)],
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '管理者・受付スタッフ用ログイン',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'メールアドレス'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => submit(),
                    decoration: const InputDecoration(labelText: 'パスワード'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Color(0xffb42318))),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy ? 'ログイン中…' : 'ログイン'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
