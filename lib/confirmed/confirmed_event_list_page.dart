import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'event_list_service.dart';

/// 作成済みのconfirmedイベントを選ぶ入口(`/console/events`)。管理者(admin)としてログインした場合だけ表示される。
/// 受付スタッフ・権限なし・未ログインでは表示されない(サーバー側の`listLegacyEvents`もadmin専用)。
///
/// ここでeventIdを入力・選択させる以外の目的では使わない: 対象イベントを選ぶと、そのまま既存の
/// `/console?eventId=…`(confirmedの管理画面)へ遷移する。eventIdは内部で引き継ぐだけで、
/// 利用者がIDを手入力する場面は無い。
class ConfirmedEventListRoute extends StatelessWidget {
  ConfirmedEventListRoute({
    super.key,
    AuthClient? authClient,
    this.accessService,
    this.service,
  }) : authClient = authClient ?? FirebaseAuthClient();

  final AuthClient authClient;
  final AccessService? accessService;
  final EventListService? service;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => ConfirmedEventListPage(
      service: service ?? CallableEventListService(authClient: authClient),
    ),
    staffBuilder: (context, signOut) => PageFrame(
      title: 'イベント一覧',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'イベント一覧は管理者のみ利用できます',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Center(
                child: FilledButton(
                  onPressed: signOut,
                  child: const Text('ログアウト'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// confirmedイベントの一覧画面。選ぶと`/console?eventId=…`へ進む。
class ConfirmedEventListPage extends StatefulWidget {
  const ConfirmedEventListPage({super.key, required this.service});
  final EventListService service;

  @override
  State<ConfirmedEventListPage> createState() => _ConfirmedEventListPageState();
}

class _ConfirmedEventListPageState extends State<ConfirmedEventListPage> {
  List<ConfirmedEventListItem>? events;
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final loaded = await widget.service.listConfirmedEvents();
      if (!mounted) return;
      setState(() => events = loaded);
    } on EventListException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'イベント一覧を取得できませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _select(ConfirmedEventListItem item) {
    Navigator.of(
      context,
    ).pushNamed('/console?eventId=${Uri.encodeQueryComponent(item.eventId)}');
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'イベント一覧',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('作成済みのイベントから、管理するイベントを選んでください。'),
            const SizedBox(height: 12),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (error != null)
              Container(
                key: const Key('event-list-error'),
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                color: const Color(0xffffe8e8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(error!),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: _load,
                        child: const Text('再試行'),
                      ),
                    ),
                  ],
                ),
              ),
            if (!loading && error == null && (events ?? const []).isEmpty)
              const Padding(
                key: Key('event-list-empty'),
                padding: EdgeInsets.all(12),
                child: Text('まだイベントがありません。「イベント作成」から作成してください。'),
              ),
            if (events != null)
              for (final item in events!)
                Card(
                  key: ValueKey('event-item-${item.eventId}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(item.eventName),
                    subtitle: Text(
                      '${formatDateTimeMinute(item.startAt)} / '
                      '${item.venue.isEmpty ? '会場未設定' : item.venue}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _select(item),
                  ),
                ),
          ],
        ),
      ),
    ),
  );
}
