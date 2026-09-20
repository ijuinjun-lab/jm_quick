import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'confirmed/console_page.dart';
import 'firebase_options.dart';
import 'pages/demo_admin_page.dart';
import 'pages/event_list_page.dart';
import 'pages/participant_page.dart';
import 'pages/reception_page.dart';
import 'pages/walk_in_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
        final Widget page = switch (uri.path) {
          '/admin' || '/demo-admin' => const EventListPage(),
          // 新方式(flow=confirmed)の管理・受付。ログイン+サーバー側の権限確認を通った場合だけ機能が表示される。
          '/console' => ConfirmedConsolePage(),
          '/reception' => ReceptionPage(
            eventId: uri.queryParameters['eventId'],
            participantId: uri.queryParameters['participantId'],
            publicId: uri.queryParameters['publicId'],
          ),
          _
              when uri.pathSegments.length == 3 &&
                  uri.pathSegments[0] == 'admin' &&
                  uri.pathSegments[1] == 'events' =>
            DemoAdminPage(eventId: uri.pathSegments[2]),
          _
              when uri.pathSegments.length == 3 &&
                  uri.pathSegments[0] == 'e' &&
                  uri.pathSegments[2] == 'walk-in' =>
            WalkInPage(eventId: uri.pathSegments[1]),
          _
              when uri.pathSegments.length == 2 &&
                  uri.pathSegments.first == 'p' =>
            ParticipantPage(
              participantId: uri.pathSegments[1],
              publicId: uri.queryParameters['publicId'],
            ),
          _ => const _HomePage(),
        };
        return MaterialPageRoute(builder: (_) => page, settings: settings);
      },
    );
  }
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
