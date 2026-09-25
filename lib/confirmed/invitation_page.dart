// Phase 4: 招待リンク(`/invite?token=…`)。招待された本人が、初期設定(パスワードの設定)・ログイン・招待の受諾を行う。
//
// 招待正本のメールで本人登録 → 自動受諾。Authだけ作成された場合もログイン/受諾の再試行で復旧する。
// パスワードはFirebase Auth SDKだけへ渡す。FunctionsはtokenとAuth ID tokenだけを受け取る。

import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'auth_client.dart';
import 'invitation_service.dart';
import 'robots_meta.dart';

const Color _mutedText = Color(0xff5c6670);

class InvitationAcceptPage extends StatefulWidget {
  InvitationAcceptPage({
    super.key,
    required this.token,
    AuthClient? authClient,
    InvitationService? service,
  }) : authClient = authClient ?? FirebaseAuthClient(),
       _service = service;

  final String? token;
  final AuthClient authClient;
  final InvitationService? _service;

  @override
  State<InvitationAcceptPage> createState() => _InvitationAcceptPageState();
}

class _InvitationAcceptPageState extends State<InvitationAcceptPage> {
  late final InvitationService service =
      widget._service ??
      CallableInvitationService(authClient: widget.authClient);
  late Future<InvitationInfo> info = _fetch();
  StreamSubscription<bool>? _signedIn;
  bool signedIn = false;
  bool busy = false;
  String? error;
  InvitationAcceptResult? done;
  bool accountRegistered = false;
  bool showLogin = false;
  final _confirmation = TextEditingController();
  final _password = TextEditingController();

  String get _token => (widget.token ?? '').trim();

  Future<InvitationInfo> _fetch() async {
    if (_token.isEmpty) {
      return const InvitationInfo(status: InvitationStatus.invalid);
    }
    return service.getInvitation(_token);
  }

  @override
  void initState() {
    super.initState();
    setNoIndex(true);
    _signedIn = widget.authClient.signedInChanges().listen(
      (value) {
        if (mounted) setState(() => signedIn = value);
      },
      onError: (_) {
        if (mounted) setState(() => signedIn = false);
      },
    );
  }

  @override
  void dispose() {
    setNoIndex(false);
    _signedIn?.cancel();
    _confirmation.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on InvitationException catch (e) {
      if (mounted) setState(() => error = e.message);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _register() => _run(() async {
    if (_password.text.isEmpty) {
      throw const InvitationException('パスワードを入力してください。');
    }
    if (_password.text != _confirmation.text) {
      throw const InvitationException('パスワードが一致しません。');
    }
    // 登録直前にも招待正本を確認する。編集されたTextFieldの値は使用しない。
    final invitation = await service.getInvitation(_token);
    if (invitation.status != InvitationStatus.pending ||
        invitation.email.isEmpty) {
      if (mounted) setState(() => info = Future.value(invitation));
      return;
    }
    if (widget.authClient.currentEmail != null || accountRegistered) {
      await _acceptCurrent(invitation);
      return;
    }
    if (invitation.accountExists) {
      if (mounted) setState(() => showLogin = true);
      throw const InvitationException('登録済みです。設定したパスワードでログインして招待を受けてください。');
    }
    try {
      await widget.authClient.register(invitation.email, _password.text);
    } on AuthFailure catch (e) {
      if (e.code == 'email-already-in-use' && mounted) {
        setState(() => showLogin = true);
      }
      rethrow;
    } finally {
      _password.clear();
      _confirmation.clear();
    }
    // acceptに失敗してもこの状態を維持し、Auth登録を繰り返さない。
    if (mounted) {
      setState(() {
        accountRegistered = true;
        signedIn = true;
      });
    }
    await _acceptCurrent(invitation);
  });

  Future<void> _signIn() => _run(() async {
    final invitation = await info;
    if (invitation.email.isEmpty || _password.text.isEmpty) {
      throw const InvitationException('パスワードを入力してください。');
    }
    try {
      await widget.authClient.signIn(invitation.email, _password.text);
    } finally {
      _password.clear();
    }
  });

  Future<void> _acceptCurrent(InvitationInfo invitation) async {
    if (widget.authClient.currentEmail?.trim().toLowerCase() !=
        invitation.email.toLowerCase()) {
      throw const InvitationException('招待されたメールアドレスでログインしてください。');
    }
    final result = await service.accept(_token);
    if (mounted) setState(() => done = result);
  }

  Future<void> _accept() => _run(() async => _acceptCurrent(await info));

  @override
  Widget build(BuildContext context) {
    final result = done;
    if (result != null) return _DonePage(result: result);
    return PageFrame(
      title: 'JM Quickへのご招待',
      child: FutureBuilder<InvitationInfo>(
        future: info,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return _MessageCard(
              message: snapshot.error is InvitationException
                  ? '${snapshot.error}'
                  : '招待を確認できませんでした。',
              action: OutlinedButton(
                onPressed: () => setState(() => info = _fetch()),
                child: const Text('再試行'),
              ),
            );
          }
          final invitation = snapshot.data!;
          switch (invitation.status) {
            case InvitationStatus.pending:
              return _pending(invitation);
            case InvitationStatus.accepted:
              return _MessageCard(
                messageKey: const Key('invitation-accepted'),
                message: 'この招待は受諾済みです。JM Quickへログインしてください。',
                action: FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pushNamedAndRemoveUntil('/console', (_) => false),
                  child: const Text('JM Quickを開く'),
                ),
              );
            case InvitationStatus.expired:
              return const _MessageCard(
                messageKey: Key('invitation-expired'),
                message: 'この招待の有効期限が切れています。\n招待した方に、もう一度招待を依頼してください。',
              );
            case InvitationStatus.revoked:
              return const _MessageCard(
                messageKey: Key('invitation-revoked'),
                message: 'この招待は取り消されています。',
              );
            case InvitationStatus.invalid:
              return const _MessageCard(
                messageKey: Key('invitation-invalid'),
                message:
                    'この招待リンクは利用できません。\nメールに記載されたリンクをもう一度開くか、招待した方に確認してください。',
              );
          }
        },
      ),
    );
  }

  Widget _pending(InvitationInfo invitation) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'JM Quickへ招待されています',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _Line('イベント', invitation.eventName),
              _Line('役割', invitation.role?.label ?? ''),
              _Line('招待先', invitation.emailHint),
              _Line('有効期限', formatDateTimeMinute(invitation.expiresAt)),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (signedIn ||
          accountRegistered ||
          invitation.accountExists ||
          showLogin)
        _loginOrAccept(invitation)
      else
        _setupCard(invitation),
      if (error != null) ...[
        const SizedBox(height: 12),
        Container(
          key: const Key('invitation-error'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xffffe8e8),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(error!),
        ),
      ],
      const SizedBox(height: 16),
      const Text(
        'このご招待に心当たりがない場合は、何も操作する必要はありません。',
        style: TextStyle(color: _mutedText, fontSize: 12),
      ),
    ],
  );

  Widget _emailField(InvitationInfo invitation, String key) => TextFormField(
    key: Key(key),
    initialValue: invitation.email,
    readOnly: true,
    decoration: const InputDecoration(labelText: 'メールアドレス（招待先）'),
  );

  Widget _setupCard(InvitationInfo invitation) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('パスワード設定', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _emailField(invitation, 'invitation-register-email'),
          TextField(
            key: const Key('invitation-register-password'),
            controller: _password,
            obscureText: true,
            enabled: !busy,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(labelText: 'パスワード'),
          ),
          TextField(
            key: const Key('invitation-confirm-password'),
            controller: _confirmation,
            obscureText: true,
            enabled: !busy,
            decoration: const InputDecoration(labelText: 'パスワード確認'),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('invitation-register'),
            onPressed: busy ? null : _register,
            child: const Text('登録して招待を受ける'),
          ),
          TextButton(
            onPressed: busy ? null : () => setState(() => showLogin = true),
            child: const Text('登録済みの方はログインして再開'),
          ),
        ],
      ),
    ),
  );

  Widget _loginOrAccept(InvitationInfo invitation) {
    if (signedIn) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'ログインしました。招待を受けると、このイベントを利用できるようになります。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 14),
              FilledButton(
                key: const Key('invitation-accept'),
                onPressed: busy ? null : _accept,
                child: const Text('招待を受ける'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          await widget.authClient.signOut();
                          if (mounted) {
                            setState(() {
                              accountRegistered = false;
                              showLogin = true;
                            });
                          }
                        }),
                  child: const Text('別のアカウントでログインする'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('ログイン', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                '招待されたメールアドレスと、初期設定で決めたパスワードでログインしてください。',
                style: TextStyle(color: _mutedText, fontSize: 13),
              ),
              const SizedBox(height: 12),
              _emailField(invitation, 'invitation-login-email'),
              const SizedBox(height: 10),
              TextField(
                key: const Key('invitation-login-password'),
                controller: _password,
                enabled: !busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: 'パスワード'),
                onSubmitted: (_) => _signIn(),
              ),
              const SizedBox(height: 14),
              FilledButton(
                key: const Key('invitation-login'),
                onPressed: busy ? null : _signIn,
                child: const Text('ログイン'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: const TextStyle(color: _mutedText)),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.message, this.action, this.messageKey});
  final String message;
  final Widget? action;
  final Key? messageKey;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(message, key: messageKey, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 16),
            Center(child: action!),
          ],
        ],
      ),
    ),
  );
}

class _DonePage extends StatelessWidget {
  const _DonePage({required this.result});
  final InvitationAcceptResult result;
  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'JM Quickへのご招待',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.check_circle_outline,
              size: 40,
              color: Color(0xff2e7d32),
            ),
            const SizedBox(height: 12),
            const Text(
              '設定が完了しました',
              key: Key('invitation-done'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${result.eventName}の${result.role.label}として登録されました。\n'
              '「JM Quickを開く」から担当イベントへ進めます。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            Center(
              child: FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/console', (_) => false),
                child: const Text('JM Quickを開く'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
