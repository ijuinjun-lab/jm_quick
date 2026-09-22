import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'reminder_page.dart';
import 'reminder_service.dart';
import 'winner_mail_page.dart';
import 'winner_mail_service.dart';
import 'winner_send_page.dart';
import 'winner_send_service.dart';

/// 管理者に見せる機能(いずれも後続Phaseで実装。この画面は入口とロール別の境界だけ)。
const List<String> adminFeatureLabels = [
  'イベント一覧',
  'イベント作成',
  'イベント設定',
  'CSV取込',
  '当選メール設定',
  '当選メール送信',
  'リマインド',
  '参加者管理',
  '受付',
  '受付訂正',
  'スタッフ管理',
];

/// 受付スタッフに見せる機能(受付系だけ)。
const List<String> staffFeatureLabels = ['当日の受付', '参加者検索'];

/// 新方式(flow=confirmed)の管理・受付の入口(/console)。従来方式の画面はこのゲートで包まない。
class ConfirmedConsolePage extends StatelessWidget {
  ConfirmedConsolePage({
    super.key,
    AuthClient? authClient,
    AccessService? accessService,
    WinnerMailService? winnerMailService,
    WinnerSendService? winnerSendService,
    ReminderService? reminderService,
    this.initialEventId,
  }) : authClient = authClient ?? FirebaseAuthClient(),
       _accessService = accessService,
       _winnerMailService = winnerMailService,
       _winnerSendService = winnerSendService,
       _reminderService = reminderService;

  final AuthClient authClient;
  final AccessService? _accessService;
  final WinnerMailService? _winnerMailService;
  final WinnerSendService? _winnerSendService;
  final ReminderService? _reminderService;

  /// 作成直後のイベントID(新方式イベントの作成後に渡される)。各画面のイベントIDの初期値になる。
  final String? initialEventId;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        _accessService ?? CallableAccessService(authClient: authClient),
    // 当選メール設定は管理者だけ(受付スタッフには表示せず、サーバー側でもadmin専用)。
    adminBuilder: (context, signOut) => _RoleHome(
      title: '管理機能',
      roleLabel: '管理者',
      features: adminFeatureLabels,
      signOut: signOut,
      notice: (initialEventId ?? '').isEmpty
          ? null
          : '作成したイベントのID: $initialEventId(各機能で自動入力されます)',
      actions: {
        // 作成済みイベントの一覧から選ぶ入口(admin専用)。eventIdを失った後もここから管理画面へ戻れる。
        'イベント一覧': () => Navigator.of(context).pushNamed('/console/events'),
        // 参加者CSVの取込(admin専用。受付スタッフには表示しない)。作成直後のイベントIDを引き継ぐ
        'CSV取込': () => Navigator.of(context).pushNamed(
          (initialEventId ?? '').isEmpty
              ? '/console/import'
              : '/console/import?eventId=${Uri.encodeQueryComponent(initialEventId!)}',
        ),
        // 新方式イベントの作成(admin専用。受付スタッフには表示しない)
        'イベント作成': () => Navigator.of(context).pushNamed('/console/events/new'),
        // QRカメラで受付(admin/staffとも利用可。受付ロジックは既存のReceptionRoutePageのまま複製しない)
        '受付': () => Navigator.of(context).pushNamed('/console/scan'),
        // 前日リマインド(admin専用。staffには表示しない)
        'リマインド': () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ReminderPage(
              initialEventId: initialEventId,
              service:
                  _reminderService ??
                  CallableReminderService(authClient: authClient),
            ),
          ),
        ),
        '当選メール送信': () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => WinnerSendPage(
              initialEventId: initialEventId,
              service:
                  _winnerSendService ??
                  CallableWinnerSendService(authClient: authClient),
              mailService:
                  _winnerMailService ??
                  CallableWinnerMailService(authClient: authClient),
            ),
          ),
        ),
        '当選メール設定': () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => WinnerMailPage(
              initialEventId: initialEventId,
              service:
                  _winnerMailService ??
                  CallableWinnerMailService(authClient: authClient),
            ),
          ),
        ),
      },
    ),
    staffBuilder: (context, signOut) => _RoleHome(
      title: '受付',
      roleLabel: '受付スタッフ',
      features: staffFeatureLabels,
      signOut: signOut,
      actions: {
        // QRカメラで受付(staff利用可)。受付ロジックは既存のReceptionRoutePageのまま複製しない
        '当日の受付': () => Navigator.of(context).pushNamed('/console/scan'),
      },
    ),
  );
}

class _RoleHome extends StatelessWidget {
  const _RoleHome({
    required this.title,
    required this.roleLabel,
    required this.features,
    required this.signOut,
    this.actions = const {},
    this.notice,
  });
  final String title;
  final String roleLabel;
  final List<String> features;
  final Future<void> Function() signOut;

  /// 機能名 → 開く処理(実装済みの機能だけ。それ以外は「準備中」)。
  final Map<String, VoidCallback> actions;
  final String? notice;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    child: Card(
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
            if (notice != null) ...[
              SelectableText(notice!),
              const SizedBox(height: 12),
            ],
            for (final feature in features)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(feature),
                subtitle: Text(
                  actions.containsKey(feature)
                      ? (feature == '当選メール送信'
                            ? '取込回ごとの送信・進行状況・失敗分の再送'
                            : feature == 'イベント一覧'
                            ? '作成済みのイベントから選んで管理する'
                            : feature == 'CSV取込'
                            ? '当選者CSVの取込(プレビュー確認後に確定・メールは送信されません)'
                            : feature == 'イベント作成'
                            ? '新方式のイベントの新規作成(メールは送信されません)'
                            : feature == 'リマインド'
                            ? '前日リマインドの設定・プレビュー・送信状況'
                            : feature == '受付' || feature == '当日の受付'
                            ? 'QRカメラで参加者を読み取り、programごとに受付する'
                            : '件名・本文の設定とプレビュー')
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
    ),
  );
}
