import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'confirmed/assignment_pages.dart';
import 'confirmed/confirmed_event_list_page.dart';
import 'confirmed/console_page.dart';
import 'confirmed/event_create_page.dart';
import 'confirmed/import_page.dart';
import 'confirmed/invitation_page.dart';
import 'confirmed/pass_page.dart';
import 'confirmed/pass_service.dart';
import 'confirmed/qr_scanner_page.dart';
import 'confirmed/reception_route.dart';
import 'confirmed/reception_staff_device_page.dart';
import 'firebase_options.dart';
import 'pages/participant_page.dart';
import 'pages/reception_page.dart';
import 'pages/walk_in_page.dart';
import 'services/app_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // 公開API(参加証・マイページ・当日参加登録)へ付けるApp Check。サイトキーはビルド時の--dart-define(コードに埋め込まない)。
  // 未設定なら有効化せず、公開APIはクライアント側で止まる(サーバーも拒否する)。管理・受付は従来どおりログイン+権限で保護される。
  await activateAppCheck();
  runApp(const JmQuickApp());
}

class JmQuickApp extends StatelessWidget {
  const JmQuickApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'イベント参加受付',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff17324d),
          surface: const Color(0xfff7f8fa),
        ),
        scaffoldBackgroundColor: const Color(0xfff7f8fa),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Color(0xffdfe3e8)),
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      onGenerateRoute: (settings) {
        final uri = Uri.parse(settings.name ?? '/');
        final page = resolveRoute(uri);
        return MaterialPageRoute(builder: (_) => page, settings: settings);
      },
    );
  }
}

/// URL(パス・クエリ)から表示する画面を決める(`onGenerateRoute`の本体)。
/// 副作用は無い純粋な組み立てなので、Firebaseの初期化なしにルーティング表そのものを検査できる
/// (widgetを実際に構築するだけでは、まだFirebaseへは触れない。ビルド・マウントして初めて各画面が
/// AuthClient等を通じてFirebaseへ触れる)。
Widget resolveRoute(Uri uri) => switch (uri.path) {
  // 旧管理画面(/admin・/admin/…・/demo-admin)は廃止した。管理の入口は/consoleだけ。古いブックマーク・履歴から開いた場合も、
  // 旧画面は表示せず新しい管理画面へ移す(Hostingも/admin・/demo-adminを/consoleへ302で転送する)。
  _ when isLegacyAdminPath(uri) => LegacyAdminRedirect(
    target: legacyAdminRedirectTarget(uri),
  ),
  // JM Quickのトップ(https://jm-quick.web.app/ を直接開いた場合)と、新方式(confirmed)の正式入口。
  // 従来、トップ(/)はどのルートにも一致せず、未知のURLと同じ「お探しのページは見つかりませんでした」
  // (catch-allの_HomePage)になっていた。管理者・受付スタッフが迷わず管理機能へ入れるよう、
  // 下記の画面をトップと共通にする(新しい画面は増やさない・最小変更)。この画面の内部(AuthGate)が、
  // 未ログインならログイン画面、ログイン済みならサーバーが確認したロール(admin/staff)に応じた機能を
  // 自動的に出し分ける。公開参加者用のURL(/p/…・/reception?…等)はこの変更の対象外で、以下の
  // 各ルートのまま変わらない。
  '/' || '/console' => ConfirmedConsolePage(
    initialEventId: uri.queryParameters['eventId'],
  ),
  // 作成済みのconfirmedイベントを選ぶ入口(admin専用)。eventIdを失った後にここから管理画面へ戻れる。
  '/console/events' => ConfirmedEventListRoute(),
  // Phase 3: イベントごとのイベント管理者の追加・解除(システム管理者専用)。
  '/console/managers' => ConfirmedManagerSettingsRoute(),
  // Phase 4: 招待リンク(招待された本人が初期設定・ログイン・招待の受諾を行う)。tokenを確認できた場合だけ内容を表示する。
  '/invite' => InvitationAcceptPage(token: uri.queryParameters['token']),
  // 新方式のイベント作成(admin専用)
  '/console/events/new' => ConfirmedEventCreateRoute(),
  // 新方式の参加者CSV取込(admin専用)
  '/console/import' => ConfirmedImportRoute(
    eventId: uri.queryParameters['eventId'],
  ),
  // 受付用QRをスマートフォンのカメラで読み取る入口(staff/admin専用)。
  // 読み取った文字列は /reception と同じReceptionRoutePageへそのまま渡す(受付ロジックは複製しない)。
  // eventIdは任意(イベント選択後の管理画面「受付」から渡される。内部的な引き継ぎのみ)。
  '/console/scan' => ConfirmedScanReceptionRoute(
    eventId: uri.queryParameters['eventId'],
  ),
  // 受付スタッフ用QR(PCの「受付」に表示)を読み取った受付端末。ログイン不要で、URLの受付キー(サーバーが毎回検証)により
  // このイベントの受付だけを行う(管理機能・他イベントは不可)。カメラへ直接進む。
  '/reception/staff' => ReceptionStaffDeviceRoute(
    eventId: uri.queryParameters['eventId'],
    receptionKey: uri.queryParameters['key'],
  ),
  // 受付用QR。従来方式は従来の受付画面、新方式(confirmed)はprogram別受付画面。どちらもstaff/adminのログインが必要(Phase 10C)。
  // 未知のflow・存在しないイベント・読み取り失敗では、どちらの受付画面も出さない。
  '/reception' => ReceptionRoutePage(
    eventId: uri.queryParameters['eventId'],
    participantId: uri.queryParameters['participantId'],
    publicId: uri.queryParameters['publicId'],
    legacyBuilder: (_) => ReceptionPage(
      eventId: uri.queryParameters['eventId'],
      participantId: uri.queryParameters['participantId'],
      publicId: uri.queryParameters['publicId'],
    ),
  ),
  _
      when uri.pathSegments.length == 3 &&
          uri.pathSegments[0] == 'e' &&
          uri.pathSegments[2] == 'walk-in' =>
    WalkInPage(eventId: uri.pathSegments[1]),
  _ when uri.pathSegments.length == 2 && uri.pathSegments.first == 'p' =>
    // 新方式(confirmed)の参加証(読み取り専用)。確認できなければ従来のマイページ。
    PassRoutePage(
      participantId: uri.pathSegments[1],
      publicId: uri.queryParameters['publicId'],
      service: CallablePassService(),
      legacyBuilder: (_) => ParticipantPage(
        participantId: uri.pathSegments[1],
        publicId: uri.queryParameters['publicId'],
      ),
    ),
  _ => const _HomePage(),
};

/// 旧管理画面のURL(`/admin`・`/admin/…`・`/demo-admin`・`/demo-admin/…`)か。
bool isLegacyAdminPath(Uri uri) =>
    uri.pathSegments.isNotEmpty &&
    (uri.pathSegments.first == 'admin' ||
        uri.pathSegments.first == 'demo-admin');

/// 旧管理画面のURLの移動先。旧イベント管理(`/admin/events/{eventId}`)は、そのイベントの新しい管理画面
/// (`/console?eventId=…`。新方式でないイベントはサーバーが拒否し、画面に理由が出る)。それ以外は管理トップ(`/console`)。
Uri legacyAdminRedirectTarget(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length == 3 &&
      segments[0] == 'admin' &&
      segments[1] == 'events' &&
      segments[2].trim().isNotEmpty) {
    return Uri(path: '/console', queryParameters: {'eventId': segments[2]});
  }
  return Uri(path: '/console');
}

/// 旧管理画面のURLで開かれたときに、新しい管理画面([target])を表示し、ブラウザのURLも[target]へ置き換える
/// (履歴は増やさない)。旧画面・旧APIの取得は一切しない。認証・権限は/consoleの画面(AuthGate)のまま。
class LegacyAdminRedirect extends StatefulWidget {
  const LegacyAdminRedirect({super.key, required this.target});
  final Uri target;

  @override
  State<LegacyAdminRedirect> createState() => _LegacyAdminRedirectState();
}

class _LegacyAdminRedirectState extends State<LegacyAdminRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 起動時の途中のルート(画面の下に積まれたもの)はURLを変えない。表示中のルートだけが置き換える。
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      SystemNavigator.routeInformationUpdated(uri: widget.target, replace: true);
    });
  }

  @override
  Widget build(BuildContext context) => resolveRoute(widget.target);
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('イベント参加受付')),
      body: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'イベント参加受付',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                const Text('お探しのページは見つかりませんでした。', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
