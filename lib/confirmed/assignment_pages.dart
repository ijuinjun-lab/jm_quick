// Phase 3: イベント単位の任命の画面。
//   - イベント管理者設定(`/console/managers`。システム管理者専用): confirmedイベントを選び、そのイベントのイベント管理者を追加・解除する
//   - スタッフ管理(イベント管理画面から開く。システム管理者・そのイベントのイベント管理者): 受付スタッフを追加・解除する
// 権限の判断はサーバー(Functions)が行う。画面にはuid・assignmentId・eventIdを表示しない(assignmentIdは解除の内部値だけ)。
// 追加はメールアドレスの入力だけ(Firebase Authに登録済みの利用者のみ。パスワード入力・アカウント作成は無い)。

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_role.dart';
import 'access_service.dart';
import 'assignment_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';

const Color _mutedText = Color(0xff5c6670);

/// `/console/managers`: イベント管理者設定(システム管理者専用)。
class ConfirmedManagerSettingsRoute extends StatelessWidget {
  ConfirmedManagerSettingsRoute({
    super.key,
    AuthClient? authClient,
    this.accessService,
    this.service,
  }) : authClient = authClient ?? FirebaseAuthClient();

  final AuthClient authClient;
  final AccessService? accessService;
  final AssignmentService? service;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => ManagerSettingsPage(
      service: service ?? CallableAssignmentService(authClient: authClient),
    ),
    // システム管理者以外(従来の全体staff)には出さない。イベント単位の権限だけのユーザーはAuthGateが権限なしを表示する。
    staffBuilder: (context, signOut) => const PageFrame(
      title: 'イベント管理者設定',
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('イベント管理者設定はシステム管理者のみ利用できます。'),
        ),
      ),
    ),
  );
}

/// イベント管理者設定: confirmedイベントの一覧 → 選んだイベントのイベント管理者。
class ManagerSettingsPage extends StatefulWidget {
  const ManagerSettingsPage({super.key, required this.service});
  final AssignmentService service;

  @override
  State<ManagerSettingsPage> createState() => _ManagerSettingsPageState();
}

class _ManagerSettingsPageState extends State<ManagerSettingsPage> {
  late Future<List<MyEvent>> events = widget.service.listMyEvents();

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'イベント管理者設定',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'イベントを選ぶと、そのイベントのイベント管理者を追加・解除できます。',
          style: TextStyle(color: _mutedText, fontSize: 13),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<MyEvent>>(
          future: events,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                message: '${snapshot.error}',
                onRetry: () =>
                    setState(() => events = widget.service.listMyEvents()),
              );
            }
            final list = snapshot.data ?? const <MyEvent>[];
            if (list.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('イベントがありません。'),
                ),
              );
            }
            return MyEventList(
              events: list,
              showRole: false,
              onTap: (event) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => EventAssignmentPage(
                    eventId: event.eventId,
                    eventName: event.eventName,
                    targetRole: EventRole.eventManager,
                    service: widget.service,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}

/// イベントの一覧(担当イベント・イベント管理者設定で共通)。eventIdは表示しない。
class MyEventList extends StatelessWidget {
  const MyEventList({
    super.key,
    required this.events,
    required this.onTap,
    this.showRole = true,
  });
  final List<MyEvent> events;
  final void Function(MyEvent event) onTap;
  final bool showRole;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final event in events)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              key: ValueKey('my-event:${event.eventId}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              title: Text(
                event.eventName.isEmpty ? '(名称未設定)' : event.eventName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              // 役割は日時・会場とは別の行に出す(スマートフォン幅で「スタ｜ッフ」のように語の途中で折り返さない)。
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      formatDateTimeMinute(event.startAt),
                      if (event.venue.isNotEmpty) event.venue,
                    ].join(' / '),
                  ),
                  if (showRole)
                    Text(
                      event.roleLabel,
                      style: const TextStyle(
                        color: Color(0xff17324d),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onTap(event),
            ),
          ),
        ),
    ],
  );
}

/// イベントの任命の追加・解除(イベント管理者設定・スタッフ管理で共通)。[targetRole]の任命だけを扱う。
class EventAssignmentPage extends StatefulWidget {
  const EventAssignmentPage({
    super.key,
    required this.eventId,
    required this.eventName,
    required this.targetRole,
    required this.service,
  });

  final String eventId;
  final String eventName;
  final EventRole targetRole;
  final AssignmentService service;

  @override
  State<EventAssignmentPage> createState() => _EventAssignmentPageState();
}

class _EventAssignmentPageState extends State<EventAssignmentPage> {
  final _email = TextEditingController();
  List<EventAssignmentEntry>? entries;

  /// Phase 4: 招待中(未登録の人への招待)。
  List<EventInvitationEntry> invitations = const [];
  String? loadError;
  String? notice;
  String? error;
  bool busy = false;

  bool get _isStaff => widget.targetRole == EventRole.staff;
  String get _title => _isStaff ? 'スタッフ管理' : 'イベント管理者設定';
  String get _addLabel => _isStaff ? 'スタッフを追加' : 'イベント管理者を追加';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => loadError = null);
    try {
      final all = await widget.service.listAssignments(widget.eventId);
      final invited = await widget.service.listInvitations(widget.eventId);
      if (!mounted) return;
      setState(() {
        entries = all.where((e) => e.role == widget.targetRole).toList();
        invitations = invited
            .where((e) => e.role == widget.targetRole)
            .toList();
      });
    } on AssignmentException catch (e) {
      if (mounted) setState(() => loadError = e.message);
    } catch (_) {
      if (mounted) setState(() => loadError = '一覧を取得できませんでした。');
    }
  }

  Future<void> _add() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => error = 'メールアドレスを入力してください。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final changed = await widget.service.assign(
        eventId: widget.eventId,
        email: email,
        role: widget.targetRole,
      );
      if (!mounted) return;
      _email.clear();
      setState(
        () => notice = changed
            ? '${widget.targetRole.label}を追加しました。'
            : 'すでに${widget.targetRole.label}として登録されています。',
      );
      await _load();
    } on AssignmentException catch (e) {
      // Phase 4: 未登録のメールアドレスなら、確認のうえ招待メールを送る(登録済みならこれまでどおり即任命)
      if (e.code == 'user-not-found' && mounted) {
        setState(() => busy = false);
        await _invite(email);
        return;
      }
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _invite(String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('招待メールを送信しますか？'),
        content: Text(
          '$email\n\nこのメールアドレスはJM Quickに未登録です。\n'
          '${widget.targetRole.label}として招待メールを送信します。',
          key: const Key('invite-confirm-message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            key: const Key('invite-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('招待メールを送信'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await widget.service.invite(
        eventId: widget.eventId,
        email: email,
        role: widget.targetRole,
      );
      if (!mounted) return;
      _email.clear();
      setState(
        () => notice = result == InviteResult.invited
            ? '招待メールを送信しました。本人が初期設定を終えると${widget.targetRole.label}になります。'
            : '${widget.targetRole.label}を追加しました。',
      );
      await _load();
    } on AssignmentException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _revoke(EventInvitationEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('招待を取り消しますか？'),
        content: Text('${entry.email}\n招待メールのリンクは使えなくなります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            key: const Key('invitation-revoke-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取り消す'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await widget.service.revokeInvitation(
        eventId: widget.eventId,
        invitationId: entry.invitationId,
      );
      if (!mounted) return;
      setState(() => notice = '招待を取り消しました。');
      await _load();
    } on AssignmentException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove(EventAssignmentEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${widget.targetRole.label}を解除しますか？'),
        content: Text('${entry.email}\nこのイベントの権限がなくなります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            key: const Key('assignment-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解除する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await widget.service.remove(
        eventId: widget.eventId,
        assignmentId: entry.assignmentId,
      );
      if (!mounted) return;
      setState(() => notice = '${widget.targetRole.label}を解除しました。');
      await _load();
    } on AssignmentException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: _title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.eventName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        _addCard(),
        if (notice != null) ...[
          const SizedBox(height: 12),
          _Banner(key: const Key('assignment-notice'), text: notice!, ok: true),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          _Banner(key: const Key('assignment-error'), text: error!, ok: false),
        ],
        const SizedBox(height: 20),
        Text(
          '現在の${widget.targetRole.label}',
          style: const TextStyle(
            color: _mutedText,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        _list(),
        if (invitations.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            '招待中',
            style: TextStyle(
              color: _mutedText,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _invitationList(),
        ],
      ],
    ),
  );

  Widget _invitationList() => Card(
    child: Column(
      children: [
        for (final entry in invitations)
          ListTile(
            key: ValueKey('invitation-entry:${entry.email}'),
            title: Text(entry.email, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                entry.role.label,
                entry.statusLabel,
                if (entry.expiresAt != null)
                  '期限 ${formatDateTimeMinute(entry.expiresAt)}',
              ].join(' / '),
            ),
            trailing: TextButton(
              key: ValueKey('invitation-revoke:${entry.email}'),
              onPressed: busy ? null : () => _revoke(entry),
              child: const Text('取消'),
            ),
          ),
      ],
    ),
  );

  Widget _addCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('assignment-email-field'),
            controller: _email,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'メールアドレス'),
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('assignment-add-button'),
            onPressed: busy ? null : _add,
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: Text(_addLabel),
          ),
          const SizedBox(height: 8),
          const Text(
            '登録済みの方はすぐに追加されます。未登録の方には、確認のうえ招待メールを送信します。',
            style: TextStyle(color: _mutedText, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _list() {
    if (loadError != null) {
      return _ErrorCard(message: loadError!, onRetry: _load);
    }
    final list = entries;
    if (list == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (list.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('${widget.targetRole.label}はまだいません。'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final entry in list)
            ListTile(
              key: ValueKey('assignment-entry:${entry.email}'),
              title: Text(entry.email, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                entry.isSelf ? '${entry.role.label}（あなた）' : entry.role.label,
              ),
              trailing: entry.isSelf
                  ? null
                  : TextButton(
                      key: ValueKey('assignment-remove:${entry.email}'),
                      onPressed: busy ? null : () => _remove(entry),
                      child: const Text('解除'),
                    ),
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text, required this.ok});
  final String text;
  final bool ok;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: ok ? const Color(0xffe8f5ec) : const Color(0xffffe8e8),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(text),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('再試行')),
        ],
      ),
    ),
  );
}

/// Phase 3: イベント単位の権限はあるが、この画面の対象イベントを担当していない(または必要なroleが無い)ときの案内。
/// サーバーも同じ操作を拒否する(画面で隠すだけの制御ではない)。
class EventScopeDenied extends StatelessWidget {
  const EventScopeDenied({
    super.key,
    required this.title,
    required this.message,
    required this.signOut,
  });
  final String title;
  final String message;
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              message,
              key: const Key('event-scope-denied'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pushNamedAndRemoveUntil('/console', (_) => false),
                  child: const Text('トップへ戻る'),
                ),
                OutlinedButton(onPressed: signOut, child: const Text('ログアウト')),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
