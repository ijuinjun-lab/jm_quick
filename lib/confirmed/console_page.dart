import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_role.dart';
import 'access_service.dart';
import 'assignment_pages.dart';
import 'assignment_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'import_models.dart';
import 'import_service.dart';
import 'reception_staff_qr_page.dart';
import 'reminder_page.dart';
import 'reminder_service.dart';
import 'winner_mail_page.dart';
import 'winner_mail_service.dart';
import 'winner_send_page.dart';
import 'winner_send_service.dart';

/// 管理トップ(イベント未選択, `/console`)に表示する機能。原則これだけ(Phase 11D)。
/// CSV取込・メール・リマインド・受付等はすべて特定イベントに属する機能のため、ここには出さない
/// (イベントを選んだ後の `/console?eventId=…` にだけ表示する)。
/// Phase 3: 「スタッフ管理(準備中)」を「イベント管理者設定」(システム管理者専用)に変更。受付スタッフはイベントの中で管理する。
const List<String> consoleTopFeatureLabels = ['イベント一覧', 'イベント作成', 'イベント管理者設定'];

/// イベント選択後(`/console?eventId=…`)に表示する、そのイベントに属する機能。
const List<String> eventConsoleFeatureLabels = [
  'イベント設定',
  'CSV取込',
  '当選メール設定',
  '当選メール送信',
  'リマインド',
  '参加者管理',
  'スタッフ管理',
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
    AssignmentService? assignmentService,
    this.initialEventId,
  }) : authClient = authClient ?? FirebaseAuthClient(),
       _accessService = accessService,
       _eventSummaryService = eventSummaryService,
       _winnerMailService = winnerMailService,
       _winnerSendService = winnerSendService,
       _reminderService = reminderService,
       _assignmentService = assignmentService;

  final AuthClient authClient;
  final AccessService? _accessService;

  // イベント名・開催日時・会場の表示に使う(getConfirmedEventSummary)。CSV取込画面が既に持つ、
  // 同じ読み取り専用の問い合わせ(ImportService.getEvent)をそのまま再利用するだけで、
  // CSV取込専用のロジック(previewConfirmedImport等)には一切触れない。
  final ImportService? _eventSummaryService;
  final WinnerMailService? _winnerMailService;
  final WinnerSendService? _winnerSendService;
  final ReminderService? _reminderService;

  // Phase 3: 担当イベント(listMyEvents)・スタッフ管理(任命API)。
  final AssignmentService? _assignmentService;

  /// URLの`?eventId=…`(イベント一覧からの選択・イベント作成直後に渡される)。利用者が入力する欄は無い。
  final String? initialEventId;

  String get _eventId => (initialEventId ?? '').trim();

  AssignmentService get _assignments =>
      _assignmentService ?? CallableAssignmentService(authClient: authClient);

  /// イベント管理画面(システム管理者・イベント管理者で共通。表示するroleの名前だけが違う)。
  Widget _eventConsole(
    String eventId,
    Future<void> Function() signOut,
    String viewerLabel,
  ) => _EventConsole(
    eventId: eventId,
    signOut: signOut,
    viewerLabel: viewerLabel,
    service:
        _eventSummaryService ?? CallableImportService(authClient: authClient),
    winnerMailService:
        _winnerMailService ?? CallableWinnerMailService(authClient: authClient),
    winnerSendService:
        _winnerSendService ?? CallableWinnerSendService(authClient: authClient),
    reminderService:
        _reminderService ?? CallableReminderService(authClient: authClient),
    assignmentService: _assignments,
  );

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        _accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => _eventId.isEmpty
        ? _ConsoleTop(signOut: signOut)
        : _eventConsole(_eventId, signOut, systemAdminLabel),
    // Phase 3: イベント管理者・スタッフ(担当イベントだけ)。担当はサーバー(listMyEvents)が返したものだけを表示する。
    eventScopedBuilder: (context, signOut, assignments) => _ScopedHome(
      eventId: _eventId,
      signOut: signOut,
      service: _assignments,
      managerConsole: (eventId) =>
          _eventConsole(eventId, signOut, EventRole.eventManager.label),
    ),
    // 従来の全体staff(legacy互換)。導線は変えない(QRカメラで読み取った受付QRのイベントへ固定する)。
    staffBuilder: (context, signOut) => _StaffHome(signOut: signOut),
  );
}

/// 管理トップの機能の区分け(見出し → 機能)。並びを連結するとconsoleTopFeatureLabelsと同じ順になる。
const List<(String, List<String>)> _consoleTopSections = [
  ('イベント', ['イベント一覧', 'イベント作成']),
  ('権限', ['イベント管理者設定']),
];

const Map<String, IconData> _consoleTopIcons = {
  'イベント一覧': Icons.event_note_outlined,
  'イベント作成': Icons.add_circle_outline,
  'イベント管理者設定': Icons.manage_accounts_outlined,
};

const Color _mutedText = Color(0xff5c6670);

/// 管理トップ(`/console`。eventId未指定)。ログイン状態・操作の流れ(補助説明)・区分けした機能メニュー。
class _ConsoleTop extends StatelessWidget {
  const _ConsoleTop({required this.signOut});
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) {
    final actions = <String, VoidCallback>{
      // 作成済みイベントの一覧から選ぶ入口(admin専用)。選ぶと /console?eventId=… へ進む。
      'イベント一覧': () => Navigator.of(context).pushNamed('/console/events'),
      // 新方式イベントの作成(admin専用)。作成後も /console?eventId=… へ進む。
      'イベント作成': () => Navigator.of(context).pushNamed('/console/events/new'),
      // イベントごとのイベント管理者の追加・解除(システム管理者専用)。
      'イベント管理者設定': () => Navigator.of(context).pushNamed('/console/managers'),
    };
    const descriptions = {
      'イベント一覧': '作成済みのイベントを管理',
      'イベント作成': '新しいイベントを作成',
      'イベント管理者設定': 'イベントごとの管理者を設定',
    };
    return PageFrame(
      title: '管理トップ',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccountBar(signOut: signOut, roleLabel: systemAdminLabel),
          const SizedBox(height: 4),
          const _ConsoleTopFlow(),
          for (final (heading, features) in _consoleTopSections) ...[
            const SizedBox(height: 20),
            _SectionHeading(heading),
            for (final feature in features) ...[
              const SizedBox(height: 8),
              _MenuCard(
                label: feature,
                icon: _consoleTopIcons[feature] ?? Icons.apps_outlined,
                description: descriptions[feature] ?? '',
                onTap: actions[feature],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// ログイン中のロールとログアウト(1行にまとめ、主機能より目立たせない)。
class _AccountBar extends StatelessWidget {
  const _AccountBar({required this.signOut, required this.roleLabel});
  final Future<void> Function() signOut;

  /// 画面に表示するroleの名前(システム管理者・イベント管理者・スタッフ)。
  final String roleLabel;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Icon(Icons.account_circle_outlined, size: 18, color: _mutedText),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          'ログイン中：$roleLabel',
          style: const TextStyle(color: _mutedText, fontSize: 13),
        ),
      ),
      TextButton.icon(
        onPressed: signOut,
        icon: const Icon(Icons.logout, size: 16),
        label: const Text('ログアウト'),
        style: TextButton.styleFrom(
          foregroundColor: _mutedText,
          textStyle: const TextStyle(fontSize: 13),
          visualDensity: VisualDensity.compact,
        ),
      ),
    ],
  );
}

/// 管理の流れ(作成 → 選択 → イベントごとの機能)。操作は持たない小さな補助説明。
/// 幅が狭いときは矢印を出さず、手順の区切りでだけ折り返す(行末に矢印が残らない)。
class _ConsoleTopFlow extends StatelessWidget {
  const _ConsoleTopFlow();

  static const _steps = ['① イベントを作成', '② イベント一覧から選択', '③ CSV取込・メール・受付'];
  static const _style = TextStyle(color: _mutedText, fontSize: 12);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final arrows = constraints.maxWidth >= 520;
      return Wrap(
        spacing: arrows ? 6 : 14,
        runSpacing: 2,
        children: [
          for (var i = 0; i < _steps.length; i++) ...[
            if (arrows && i > 0) const Text('→', style: _style),
            Text(_steps[i], style: _style),
          ],
        ],
      );
    },
  );
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: _mutedText,
      fontSize: 13,
      fontWeight: FontWeight.bold,
    ),
  );
}

/// 管理トップの機能1件。onTapが無い機能は「準備中」badge付きの押せない表示にする。
class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.label,
    required this.icon,
    required this.description,
    this.onTap,
  });
  final String label;
  final IconData icon;
  final String description;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final accent = Theme.of(context).colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      color: enabled ? Colors.white : const Color(0xfff3f4f6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: enabled ? const Color(0xffe8eef5) : const Color(0xffe5e7eb),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 22,
            color: enabled ? accent : const Color(0xff9aa3ad),
          ),
        ),
        title: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: enabled ? null : _mutedText,
          ),
        ),
        subtitle: Text(description),
        trailing: enabled
            ? const Icon(Icons.chevron_right)
            : const _PendingBadge(),
        onTap: onTap,
      ),
    );
  }
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('pending-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: const Color(0xffe5e7eb),
      borderRadius: BorderRadius.circular(999),
    ),
    child: const Text('準備中', style: TextStyle(color: _mutedText, fontSize: 12)),
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
    required this.assignmentService,
    required this.viewerLabel,
  });
  final String eventId;
  final Future<void> Function() signOut;
  final ImportService service;
  final WinnerMailService winnerMailService;
  final WinnerSendService winnerSendService;
  final ReminderService reminderService;
  final AssignmentService assignmentService;

  /// ログイン中のroleの名前(システム管理者・イベント管理者)。
  final String viewerLabel;

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
              roleLabel: widget.viewerLabel,
              features: eventConsoleFeatureLabels,
              signOut: widget.signOut,
              actions: {
                // Phase 3: このイベントの受付スタッフの追加・解除(システム管理者・このイベントのイベント管理者)。
                'スタッフ管理': () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EventAssignmentPage(
                      eventId: id,
                      eventName: event!.eventName,
                      targetRole: EventRole.staff,
                      service: widget.assignmentService,
                    ),
                  ),
                ),
                // CSVファイル選択画面へ直行する(このイベント固定。再びイベントを選ばせない)。
                'CSV取込': () => Navigator.of(context).pushNamed(
                  '/console/import?eventId=${Uri.encodeQueryComponent(id)}',
                ),
                // Phase 11L: PC(このイベント管理画面)自身のカメラは起動しない。「受付スタッフ用QR」
                // (このイベントに固定されたスマホ受付スキャナ`/console/scan?eventId=…`を開くだけのURL。
                // participantId/publicIdは含まない)を表示する画面へ遷移する(カメラはスマホ側だけで使う)。
                '受付': () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ConfirmedReceptionStaffQrPage(
                      eventId: id,
                      eventName: event!.eventName,
                    ),
                  ),
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
                'スタッフ管理': 'このイベントの受付スタッフを追加・解除する',
                '受付': '受付スタッフ用QRを表示する(受付スタッフがスマホで読み取って受付する)',
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

/// Phase 3: イベント管理者・スタッフのホーム(`/console`・`/console?eventId=…`)。
/// 表示するのはサーバー(listMyEvents)が返した担当イベントだけ(他イベント・legacyイベントは返らない)。
///   - eventId指定: 担当イベントならその画面、担当外なら権限なし(サーバーも拒否する)
///   - 担当イベントが1件: そのイベントの画面へ直接入る
///   - 複数: 「担当イベント」の一覧 → 選ぶと `/console?eventId=…`
/// イベント画面は、イベント管理者なら既存のイベント管理画面(_EventConsole)、スタッフなら受付の入口(_StaffEventHome)。
class _ScopedHome extends StatefulWidget {
  const _ScopedHome({
    required this.eventId,
    required this.signOut,
    required this.service,
    required this.managerConsole,
  });

  /// URLの`?eventId=…`(未指定は空文字)。
  final String eventId;
  final Future<void> Function() signOut;
  final AssignmentService service;
  final Widget Function(String eventId) managerConsole;

  @override
  State<_ScopedHome> createState() => _ScopedHomeState();
}

class _ScopedHomeState extends State<_ScopedHome> {
  late Future<List<MyEvent>> events = widget.service.listMyEvents();

  Widget _eventView(MyEvent event, {required bool hasOthers}) => event.canManage
      ? widget.managerConsole(event.eventId)
      : _StaffEventHome(
          event: event,
          signOut: widget.signOut,
          hasOthers: hasOthers,
        );

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MyEvent>>(
    future: events,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const PageFrame(
          title: '担当イベント',
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
      }
      if (snapshot.hasError) {
        return _ScopedMessage(
          message: snapshot.error is AssignmentException
              ? '${snapshot.error}'
              : '担当イベントを取得できませんでした。',
          signOut: widget.signOut,
          onRetry: () => setState(() => events = widget.service.listMyEvents()),
        );
      }
      final list = (snapshot.data ?? const <MyEvent>[])
          .where((e) => !e.isSystemAdmin)
          .toList();
      if (widget.eventId.isNotEmpty) {
        final match = list.where((e) => e.eventId == widget.eventId);
        if (match.isEmpty) {
          return _ScopedMessage(
            message: 'このイベントを利用する権限がありません。',
            signOut: widget.signOut,
            backToHome: true,
          );
        }
        return _eventView(match.first, hasOthers: list.length > 1);
      }
      if (list.isEmpty) {
        return _ScopedMessage(
          message: '担当しているイベントはありません。',
          signOut: widget.signOut,
        );
      }
      if (list.length == 1) return _eventView(list.first, hasOthers: false);
      final roleLabel = list.any((e) => e.canManage)
          ? EventRole.eventManager.label
          : EventRole.staff.label;
      return PageFrame(
        title: '担当イベント',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AccountBar(signOut: widget.signOut, roleLabel: roleLabel),
            const SizedBox(height: 4),
            const Text(
              '担当しているイベントを選んでください。',
              style: TextStyle(color: _mutedText, fontSize: 12),
            ),
            const SizedBox(height: 20),
            const _SectionHeading('担当イベント'),
            const SizedBox(height: 8),
            MyEventList(
              events: list,
              onTap: (event) => Navigator.of(context).pushNamed(
                '/console?eventId=${Uri.encodeQueryComponent(event.eventId)}',
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 担当イベントが無い・担当外・取得失敗のときの案内。
class _ScopedMessage extends StatelessWidget {
  const _ScopedMessage({
    required this.message,
    required this.signOut,
    this.onRetry,
    this.backToHome = false,
  });
  final String message;
  final Future<void> Function() signOut;
  final VoidCallback? onRetry;
  final bool backToHome;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '担当イベント',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, key: const Key('scoped-message')),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (onRetry != null)
                  FilledButton(onPressed: onRetry, child: const Text('再試行')),
                if (backToHome)
                  OutlinedButton(
                    onPressed: () => Navigator.of(
                      context,
                    ).pushNamedAndRemoveUntil('/console', (_) => false),
                    child: const Text('担当イベントへ戻る'),
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

/// Phase 3: スタッフの担当イベントの画面。受付の入口だけ(CSV・メール・リマインド・スタッフ管理は出さない)。
/// PCのカメラは起動しない(既存の二段階受付: このPCに「受付スタッフ用QR」を表示し、スマートフォンで読み取る)。
/// イベント名・開催日時・会場は listMyEvents の値を使う(スタッフはイベント概要APIを呼ばない)。
class _StaffEventHome extends StatelessWidget {
  const _StaffEventHome({
    required this.event,
    required this.signOut,
    required this.hasOthers,
  });
  final MyEvent event;
  final Future<void> Function() signOut;

  /// 他にも担当イベントがある(一覧へ戻る導線を出す)。
  final bool hasOthers;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '受付',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AccountBar(signOut: signOut, roleLabel: EventRole.staff.label),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  event.eventName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                _WrappingInfoRow('開催日時', formatDateTimeMinute(event.startAt)),
                _WrappingInfoRow(
                  '会場',
                  event.venue.isEmpty ? '未設定' : event.venue,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        const _SectionHeading('受付'),
        const SizedBox(height: 8),
        _MenuCard(
          label: '受付',
          icon: Icons.qr_code_2,
          description: '受付スタッフ用QRを表示する',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ConfirmedReceptionStaffQrPage(
                eventId: event.eventId,
                eventName: event.eventName,
              ),
            ),
          ),
        ),
        if (hasOthers) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).pushNamedAndRemoveUntil('/console', (_) => false),
              child: const Text('担当イベント一覧へ'),
            ),
          ),
        ],
      ],
    ),
  );
}

/// 項目名と値(値が長くても折り返す。スマートフォン幅で会場名等がはみ出さない)。
class _WrappingInfoRow extends StatelessWidget {
  const _WrappingInfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
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
