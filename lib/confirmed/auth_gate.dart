import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_role.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'login_page.dart';

typedef RoleBuilder =
    Widget Function(BuildContext context, Future<void> Function() signOut);

/// 新方式の管理画面の入口。
///   未ログイン                         → ログイン画面
///   ログイン済み・権限なし(未登録/無効/未知のrole) → 権限なし
///   admin                              → adminBuilder(管理機能)
///   staff                              → staffBuilder(受付系だけ)
/// 権限はクライアントで判断せず、必ずサーバー(getMyAccessRole)の確認結果に従う。
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.authClient,
    required this.accessService,
    required this.adminBuilder,
    required this.staffBuilder,
  });

  final AuthClient authClient;
  final AccessService accessService;
  final RoleBuilder adminBuilder;
  final RoleBuilder staffBuilder;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

enum _Phase { starting, signedOut, checking, decided }

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<bool>? _subscription;
  _Phase _phase = _Phase.starting;
  AccessCheck? _check;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.authClient.signedInChanges().listen(
      _onSignedIn,
      onError: (_) => _onSignedIn(false),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onSignedIn(bool signedIn) {
    _generation++;
    if (!signedIn) {
      if (mounted) {
        setState(() {
          _phase = _Phase.signedOut;
          _check = null;
        });
      }
      return;
    }
    _verify();
  }

  Future<void> _verify() async {
    final generation = ++_generation;
    if (mounted) setState(() => _phase = _Phase.checking);
    final check = await widget.accessService.fetchMyAccess();
    // 確認中にログアウト・再ログインされていたら、古い結果は捨てる。
    if (!mounted || generation != _generation) return;
    if (check.outcome == AccessOutcome.unauthenticated) {
      await widget.authClient.signOut();
      return; // ログイン状態の変化が signedOut へ遷移させる。
    }
    setState(() {
      _phase = _Phase.decided;
      _check = check;
    });
  }

  Future<void> _signOut() => widget.authClient.signOut();

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.starting:
        return const _Waiting('読み込み中…');
      case _Phase.signedOut:
        return ConfirmedLoginPage(authClient: widget.authClient);
      case _Phase.checking:
        return const _Waiting('権限を確認中…');
      case _Phase.decided:
        final check = _check!;
        switch (check.outcome) {
          case AccessOutcome.granted:
            return check.role!.isAdmin
                ? widget.adminBuilder(context, _signOut)
                : widget.staffBuilder(context, _signOut);
          case AccessOutcome.denied:
            return _Message(
              title: '権限がありません',
              body: 'このアカウントには、この画面を利用する権限がありません。管理者へお問い合わせください。',
              actions: [
                FilledButton(onPressed: _signOut, child: const Text('ログアウト')),
              ],
            );
          case AccessOutcome.error:
          case AccessOutcome.unauthenticated:
            return _Message(
              title: '権限を確認できませんでした',
              body: '通信に失敗した可能性があります。もう一度お試しください。',
              actions: [
                FilledButton(onPressed: _verify, child: const Text('再試行')),
                OutlinedButton(onPressed: _signOut, child: const Text('ログアウト')),
              ],
            );
        }
    }
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'JM Quick',
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    required this.actions,
  });
  final String title;
  final String body;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'JM Quick',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(body, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: actions,
            ),
          ],
        ),
      ),
    ),
  );
}
