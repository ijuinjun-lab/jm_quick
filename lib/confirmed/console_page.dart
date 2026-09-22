import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'import_models.dart';
import 'import_service.dart';
import 'reminder_page.dart';
import 'reminder_service.dart';
import 'winner_mail_page.dart';
import 'winner_mail_service.dart';
import 'winner_send_page.dart';
import 'winner_send_service.dart';

/// 管理トップ(イベント未選択, `/console`)に表示する機能。原則これだけ(Phase 11D)。
/// CSV取込・メール・リマインド・受付等はすべて特定イベントに属する機能のため、ここには出さない
/// (イベントを選んだ後の `/console?eventId=…` にだけ表示する)。
const List<String> consoleTopFeatureLabels = ['イベント一覧', 'イベント作成', 'スタッフ管理'];

/// イベント選択後(`/console?eventId=…`)に表示する、そのイベントに属する機能。
const List<String> eventConsoleFeatureLabels = [
  'イベント設定',
  'CSV取込',
  '当選メール設定',
  '当選メール送信',
  'リマインド',
  '参加者管理',
  '受付',
  '受付訂正',
];

/// 受付スタッフに見せる機能(受付系だけ)。
const List<String> staffFeatureLabels = ['当日の受付', '参加者検索'];

/// 新方式(flow=confirmed)の管理・受付の入口(`/console`)。従来方式の画面はこのゲートで包まない。
///
/// ■ Phase 11Dから、eventIdの有無で表示する画面を分ける:
///   - eventId未指定(管理トップ): 「イベント一覧」「イベント作成」「スタッフ管理」だけ。イベント固有の機能は出さない。
///   - eventId指定(`?eventId=…`。イベント一覧からの選択・イベント作成直後に渡される): そのイベントの管理画面。
///     イベント名・開催日時・会場を表示したうえで、そのイベントに属する機能(CSV取込・メール・リマインド・受付等)
///     を一覧する。各機能へはeventIdを内部的に(URLのクエリ・コンストラクタ引数として)引き継ぐだけで、
///     利用者がIDを入力・コピーする操作は作らない。
/// ■ staffは、権限を広げないため現状の導線(「当日の受付」→QRカメラで読み取った最初のQRのイベントへ自動で
///   固定する)のまま維持する。「イベント一覧」(`listLegacyEvents`)はサーバー側がadmin専用のcallableのため、
///   staffには開放していない(開放にはサーバー側の権限変更が要るため、今回は行わない)。
class ConfirmedConsolePage extends StatelessWidget {
  ConfirmedConsolePage({
    super.key,
    AuthClient? authClient,
    AccessService? accessService,
    ImportService? eventSummaryService,
    WinnerMailService? winnerMailService,
    WinnerSendService? winnerSendService,
    ReminderService? reminderService,
    this.initialEventId,
  }) : authClient = authClient ?? FirebaseAuthClient(),
       _accessService = accessService,
       _eventSummaryService = eventSummaryService,
       _winnerMailService = winnerMailService,
       _winnerSendService = winnerSendService,
       _reminderService = reminderService;

  final AuthClient authClient;
  final AccessService? _accessService;

  // イベント名・開催日時・会場の表示に使う(getConfirmedEventSummary)。CSV取込画面が既に持つ、
  // 同じ読み取り専用の問い合わせ(ImportService.getEvent)をそのまま再利用するだけで、
  // CSV取込専用のロジック(previewConfirmedImport等)には一切触れない。
  final ImportService? _eventSummaryService;
  final WinnerMailService? _winnerMailService;
  final WinnerSendService? _winnerSendService;
  final ReminderService? _reminderService;

  /// URLの`?eventId=…`(イベント一覧からの選択・イベント作成直後に渡される)。利用者が入力する欄は無い。
  final String? initialEventId;

  String get _eventId => (initialEventId ?? '').trim();

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        _accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => _eventId.isEmpty
        ? _ConsoleTop(signOut: signOut)
        : _EventConsole(
            eventId: _eventId,
            signOut: signOut,
            service:
                _eventSummaryService ??
                CallableImportService(authClient: authClient),
            winnerMailService:
                _winnerMailService ??
                CallableWinnerMailService(authClient: authClient),
            winnerSendService:
                _winnerSendService ??
                CallableWinnerSendService(authClient: authClient),
            reminderService:
                _reminderService ??
                CallableReminderService(authClient: authClient),
          ),
    // staffの導線は変えない(権限を広げない。詳細はクラス doc参照)。
    staffBuilder: (context, signOut) => _StaffHome(signOut: signOut),
  );
}

/// 管理トップ(`/console`。eventId未指定)。
class _ConsoleTop extends StatelessWidget {
  const _ConsoleTop({required this.signOut});
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '管理機能',
    child: _FeatureCard(
      roleLabel: '管理者',
      features: consoleTopFeatureLabels,
      signOut: signOut,
      actions: {
        // 作成済みイベントの一覧から選ぶ入口(admin専用)。選ぶと /console?eventId=… へ進む。
        'イベント一覧': () => Navigator.of(context).pushNamed('/console/events'),
        // 新方式イベントの作成(admin専用)。作成後も /console?eventId=… へ進む。
        'イベント作成': () => Navigator.of(context).pushNamed('/console/events/new'),
      },
      descriptions: const {
        'イベント一覧': '作成済みのイベントから選んで管理する',
        'イベント作成': '新方式のイベントの新規作成(メールは送信されません)',
      },
    ),
  );
}

/// イベント選択後の管理画面(`/console?eventId=…`)。イベント名・開催日時・会場を表示したうえで、
/// そのイベントに属する機能を一覧する。
class _EventConsole extends StatefulWidget {
  const _EventConsole({
    required this.eventId,
    required this.signOut,
    required this.service,
    required this.winnerMailService,
    required this.winnerSendService,
    required this.reminderService,
  });
  final String eventId;
  final Future<void> Function() signOut;
  final ImportService service;
  final WinnerMailService winnerMailService;
  final WinnerSendService winnerSendService;
  final ReminderService reminderService;

  @override
  State<_EventConsole> createState() => _EventConsoleState();
}

class _EventConsoleState extends State<_EventConsole> {
  ImportEventSummary? event;
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
      final loaded = await widget.service.getEvent(widget.eventId);
      if (!mounted) return;
      setState(() => event = loaded);
    } on ImportException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'イベントを読み込めませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.eventId;
    return PageFrame(
      title: 'イベント管理',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EventHeaderCard(
            loading: loading,
            error: error,
            event: event,
            onRetry: _load,
          ),
          if (event != null)
            _FeatureCard(
              roleLabel: '管理者',
              features: eventConsoleFeatureLabels,
              signOut: widget.signOut,
              actions: {
                // CSVファイル選択画面へ直行する(このイベント固定。再びイベントを選ばせない)。
                'CSV取込': () => Navigator.of(context).pushNamed(
                  '/console/import?eventId=${Uri.encodeQueryComponent(id)}',
                ),
                // QRカメラで受付(このイベントへscannerを固定する。program別受付ロジックは変更しない)。
                '受付': () => Navigator.of(context).pushNamed(
                  '/console/scan?eventId=${Uri.encodeQueryComponent(id)}',
                ),
                'リマインド': () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReminderPage(
                      initialEventId: id,
                      service: widget.reminderService,
                    ),
                  ),
                ),
                '当選メール送信': () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WinnerSendPage(
                      initialEventId: id,
                      service: widget.winnerSendService,
                      mailService: widget.winnerMailService,
                    ),
                  ),
                ),
                '当選メール設定': () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WinnerMailPage(
                      initialEventId: id,
                      service: widget.winnerMailService,
                    ),
                  ),
                ),
              },
              descriptions: const {
                'CSV取込': '当選者CSVの取込(プレビュー確認後に確定・メールは送信されません)',
                '当選メール送信': '取込回ごとの送信・進行状況・失敗分の再送',
                '当選メール設定': '件名・本文の設定とプレビュー',
                'リマインド': '前日リマインドの設定・プレビュー・送信状況',
                '受付': 'QRカメラで参加者を読み取り、programごとに受付する',
              },
            ),
        ],
      ),
    );
  }
}

/// イベント名・開催日時・会場(最低限の表示)。
class _EventHeaderCard extends StatelessWidget {
  const _EventHeaderCard({
    required this.loading,
    required this.error,
    required this.event,
    required this.onRetry,
  });
  final bool loading;
  final String? error;
  final ImportEventSummary? event;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (error != null)
            Container(
              key: const Key('event-console-error'),
              padding: const EdgeInsets.all(12),
              color: const Color(0xffffe8e8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(error!),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: onRetry,
                      child: const Text('再試行'),
                    ),
                  ),
                ],
              ),
            ),
          if (event != null) ...[
            Text(
              event!.eventName,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            InfoRow('開催日時', formatDateTimeMinute(event!.startAt)),
            InfoRow('会場', event!.venue.isEmpty ? '未設定' : event!.venue),
          ],
        ],
      ),
    ),
  );
}

/// 受付スタッフのトップ(`/console`)。既存の導線(当日の受付)をそのまま維持する。
class _StaffHome extends StatelessWidget {
  const _StaffHome({required this.signOut});
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '受付',
    child: _FeatureCard(
      roleLabel: '受付スタッフ',
      features: staffFeatureLabels,
      signOut: signOut,
      actions: {
        // QRカメラで受付(staff利用可)。受付ロジックは既存のReceptionRoutePageのまま複製しない
        '当日の受付': () => Navigator.of(context).pushNamed('/console/scan'),
      },
      descriptions: const {'当日の受付': 'QRカメラで参加者を読み取り、programごとに受付する'},
    ),
  );
}

/// 機能の一覧(ログイン中のロール表示・機能リスト・ログアウト)。管理トップ・イベント管理・受付スタッフで共通。
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.roleLabel,
    required this.features,
    required this.signOut,
    this.actions = const {},
    this.descriptions = const {},
  });
  final String roleLabel;
  final List<String> features;
  final Future<void> Function() signOut;

  /// 機能名 → 開く処理(実装済みの機能だけ。それ以外は「準備中」)。
  final Map<String, VoidCallback> actions;

  /// 機能名 → 説明文(actionsにある機能だけ使う)。
  final Map<String, String> descriptions;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'ログイン中：$roleLabel',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          for (final feature in features)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(feature),
              subtitle: Text(
                actions.containsKey(feature)
                    ? (descriptions[feature] ?? '')
                    : '準備中',
              ),
              trailing: actions.containsKey(feature)
                  ? const Icon(Icons.chevron_right)
                  : null,
              onTap: actions[feature],
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: signOut,
              child: const Text('ログアウト'),
            ),
          ),
        ],
      ),
    ),
  );
}
