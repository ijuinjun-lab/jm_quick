// Phase 11C: confirmed受付用のQRカメラスキャナー。実カメラは使わず、カメラ部分([surfaceBuilder])を差し替えて検証する。
//  - QR文字列の検証(qr_scanner.dart)は純粋関数として単体で検証する。
//  - scanner → 検証 → 既存のReceptionRoutePage/ConfirmedReceptionPageへ接続する部分([qr_scanner_page.dart])を、
//    受付ロジックそのもの(既存テストが保証)を再テストせずに、接続部分だけ検証する。
//  - カメラ権限エラー・カメラ利用不可の表示内容([QrCameraErrorView])は、mobile_scannerに依存せず単体で検証する。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/qr_scanner.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'confirmed_pass_reception_test.dart' show FakeReceptionService, rp;

const _host = 'app.example.invalid';
String _qr({String? eventId, String? participantId, String? publicId}) {
  final params = <String>[
    if (eventId != null) 'eventId=$eventId',
    if (participantId != null) 'participantId=$participantId',
    if (publicId != null) 'publicId=$publicId',
  ].join('&');
  return 'https://$_host/reception?$params';
}

final _validEv1 = _qr(
  eventId: 'ev1',
  participantId: 'p1',
  publicId: 'pub_abc0123456789012345678',
);
final _validEv1Second = _qr(
  eventId: 'ev1',
  participantId: 'p2',
  publicId: 'pub_def0123456789012345678',
);
final _validEv2 = _qr(
  eventId: 'ev2',
  participantId: 'p9',
  publicId: 'pub_zzz0123456789012345678',
);

void main() {
  group('parseReceptionQrPayload(QR文字列の検証。ここはセキュリティの正本ではない)', () {
    test('正常なJM Quick受付QR → eventId/participantId/publicIdを取り出せる', () {
      final result = parseReceptionQrPayload(_validEv1, expectedHost: _host);
      expect(result.isValid, isTrue);
      expect(
        result.value,
        const ScannedReceptionQr(
          eventId: 'ev1',
          participantId: 'p1',
          publicId: 'pub_abc0123456789012345678',
        ),
      );
    });

    test('JM Quick以外のURL(他サイト・別ホスト)は拒否される', () {
      expect(
        parseReceptionQrPayload(
          'https://evil.example/reception?eventId=e&participantId=p&publicId=q',
          expectedHost: _host,
        ).reason,
        QrRejectReason.notReceptionUrl,
      );
      expect(
        parseReceptionQrPayload(
          'https://example.com/',
          expectedHost: _host,
        ).reason,
        QrRejectReason.notReceptionUrl,
      );
    });

    test('URLとして解析できない文字列(一般的なテキスト・Wi-Fi QR等)は拒否される', () {
      for (final raw in [
        '',
        '   ',
        'こんにちは',
        'WIFI:T:WPA;S:mynet;P:pass;;',
        'not a url at all',
      ]) {
        expect(
          parseReceptionQrPayload(raw, expectedHost: _host).reason,
          QrRejectReason.notReceptionUrl,
          reason: raw,
        );
      }
    });

    test('パスが /reception でないURL(同じホストでも)は拒否される', () {
      expect(
        parseReceptionQrPayload(
          'https://$_host/p/participant1?publicId=pub_x',
          expectedHost: _host,
        ).reason,
        QrRejectReason.notReceptionUrl,
      );
    });

    test('eventId欠落は拒否される', () {
      expect(
        parseReceptionQrPayload(
          _qr(participantId: 'p1', publicId: 'pub_abc0123456789012345678'),
          expectedHost: _host,
        ).reason,
        QrRejectReason.eventIdMissing,
      );
    });

    test('participantId欠落は拒否される', () {
      expect(
        parseReceptionQrPayload(
          _qr(eventId: 'ev1', publicId: 'pub_abc0123456789012345678'),
          expectedHost: _host,
        ).reason,
        QrRejectReason.participantIdMissing,
      );
    });

    test('publicId欠落は拒否される', () {
      expect(
        parseReceptionQrPayload(
          _qr(eventId: 'ev1', participantId: 'p1'),
          expectedHost: _host,
        ).reason,
        QrRejectReason.publicIdMissing,
      );
    });

    test('expectedHostを省略すると、ホストは検証しない(パス・パラメータは検証する)', () {
      expect(
        parseReceptionQrPayload(
          'https://anywhere.example/reception?eventId=e&participantId=p&publicId=q',
        ).isValid,
        isTrue,
      );
    });

    test('拒否理由の案内文には、内部コード・QR全文・IDを含まない', () {
      for (final reason in QrRejectReason.values) {
        final message = qrRejectMessage(reason);
        expect(message.contains('QrRejectReason'), isFalse);
        expect(message, isNotEmpty);
      }
    });
  });

  group('QrCameraErrorView(カメラ権限拒否・利用不可の表示。mobile_scannerに依存しない)', () {
    Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('permissionDenied: 権限確認の案内と再試行ボタンが出る', (tester) async {
      var retried = 0;
      await tester.pumpWidget(
        host(
          QrCameraErrorView(
            problem: QrCameraProblem.permissionDenied,
            onRetry: () => retried++,
          ),
        ),
      );
      expect(find.textContaining('カメラを利用できません'), findsOneWidget);
      expect(find.textContaining('権限'), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-camera-retry')));
      expect(retried, 1);
    });

    testWidgets('unsupported: 利用不可の案内が出て、再試行ボタンは出ない(アプリ全体は落ちない)', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const QrCameraErrorView(problem: QrCameraProblem.unsupported)),
      );
      expect(find.byKey(const Key('scanner-camera-error')), findsOneWidget);
      expect(find.textContaining('リンク'), findsOneWidget); // 従来のURL経路への案内
      expect(find.byKey(const Key('scanner-camera-retry')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('generic: 汎用エラーの案内と再試行ボタン', (tester) async {
      await tester.pumpWidget(
        host(const QrCameraErrorView(problem: QrCameraProblem.generic)),
      );
      expect(find.byKey(const Key('scanner-camera-error')), findsOneWidget);
    });
  });

  group('ConfirmedScanReceptionFlow(scanner ↔ 受付画面の往復。カメラはfakeで差し替える)', () {
    // 実カメラ(_MobileScannerSurface)は使わず、直接onRawを呼び出せるfakeに差し替える。
    ({void Function(String) onRaw})? latest;
    Widget fakeSurface(
      BuildContext context, {
      required void Function(String) onRaw,
    }) {
      latest = (onRaw: onRaw);
      return const SizedBox(key: Key('fake-surface'));
    }

    final calls = <({String eventId, String participantId, String publicId})>[];
    Widget fakeReception({
      required String eventId,
      required String participantId,
      required String publicId,
      required VoidCallback onScanNext,
    }) {
      calls.add((
        eventId: eventId,
        participantId: participantId,
        publicId: publicId,
      ));
      return Scaffold(
        body: Center(
          child: FilledButton(
            key: const Key('fake-scan-next'),
            onPressed: onScanNext,
            child: const Text('fake reception'),
          ),
        ),
      );
    }

    setUp(() {
      latest = null;
      calls.clear();
    });

    Future<void> pumpFlow(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedScanReceptionFlow(
            expectedHost: _host,
            surfaceBuilder: fakeSurface,
            receptionBuilder: fakeReception,
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('正常なJM Quick受付QR → 既存受付画面(ここではfake)へ進む。取り出した3つのIDがそのまま渡る', (
      tester,
    ) async {
      await pumpFlow(tester);
      expect(find.byKey(const Key('fake-surface')), findsOneWidget);
      latest!.onRaw(_validEv1);
      await tester.pump();
      expect(calls, [
        (
          eventId: 'ev1',
          participantId: 'p1',
          publicId: 'pub_abc0123456789012345678',
        ),
      ]);
      expect(find.byKey(const Key('fake-scan-next')), findsOneWidget);
    });

    testWidgets('JM Quick以外のURL → 拒否され、受付画面へは進まない', (tester) async {
      await pumpFlow(tester);
      latest!.onRaw('https://evil.example/');
      await tester.pump();
      expect(calls, isEmpty);
      expect(find.byKey(const Key('fake-scan-next')), findsNothing);
      expect(find.textContaining('JM Quickの受付用ではありません'), findsOneWidget);
    });

    testWidgets('URLでないQR → 拒否される', (tester) async {
      await pumpFlow(tester);
      latest!.onRaw('ただの文字列');
      await tester.pump();
      expect(calls, isEmpty);
      expect(find.textContaining('JM Quickの受付用ではありません'), findsOneWidget);
    });

    testWidgets('eventId・participantId・publicIdのいずれか欠落 → 拒否される', (
      tester,
    ) async {
      await pumpFlow(tester);
      for (final raw in [
        _qr(participantId: 'p1', publicId: 'pub_x0123456789012345678'),
        _qr(eventId: 'ev1', publicId: 'pub_x0123456789012345678'),
        _qr(eventId: 'ev1', participantId: 'p1'),
      ]) {
        latest!.onRaw(raw);
        await tester.pump();
        expect(calls, isEmpty, reason: raw);
      }
      expect(find.textContaining('不足しています'), findsOneWidget);
    });

    testWidgets('同じQRを連続で検出しても、受付画面への遷移は1回だけ', (tester) async {
      await pumpFlow(tester);
      latest!.onRaw(_validEv1);
      latest!.onRaw(_validEv1); // 遷移が確定する前に、もう一度同じ検出が来ても無視される
      latest!.onRaw(_validEv1);
      await tester.pump();
      expect(calls.length, 1);
    });

    testWidgets('別のイベントのQR → 拒否され、現在の受付イベントは変わらない(誤って別イベントへ進まない)', (
      tester,
    ) async {
      await pumpFlow(tester);
      latest!.onRaw(_validEv1); // ev1で固定される
      await tester.pump();
      await tester.tap(find.byKey(const Key('fake-scan-next'))); // 次のQRへ戻る
      await tester.pump();
      expect(find.byKey(const Key('fake-surface')), findsOneWidget);
      latest!.onRaw(_validEv2); // 別イベント
      await tester.pump();
      expect(calls.length, 1, reason: '別イベントのQRでは受付画面へ進まない');
      expect(find.textContaining('別のイベントの参加証です'), findsOneWidget);
    });

    testWidgets('受付完了後、「次のQRを読み取る」からscannerへ戻り、同じイベントの次の参加者を続けて受付できる', (
      tester,
    ) async {
      await pumpFlow(tester);
      latest!.onRaw(_validEv1);
      await tester.pump();
      expect(calls.length, 1);
      await tester.tap(find.byKey(const Key('fake-scan-next')));
      await tester.pump();
      expect(find.byKey(const Key('fake-scan-next')), findsNothing);
      expect(
        find.byKey(const Key('fake-surface')),
        findsOneWidget,
      ); // scannerへ戻った
      latest!.onRaw(_validEv1Second); // 同じイベントの別の参加者
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last.participantId, 'p2');
    });

    testWidgets('scannerを閉じる(×) → 元の画面へ戻れる', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            onGenerateRoute: (settings) => MaterialPageRoute(
              builder: (_) => Scaffold(
                body: Center(
                  child: Builder(
                    builder: (context) => FilledButton(
                      key: const Key('open-scanner'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => ConfirmedScanReceptionFlow(
                            expectedHost: _host,
                            surfaceBuilder: fakeSurface,
                            receptionBuilder: fakeReception,
                          ),
                        ),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-scanner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fake-surface')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scanner-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-scanner')), findsOneWidget);
      expect(find.byKey(const Key('fake-surface')), findsNothing);
    });

    testWidgets('未検出のときは既定のヒント文言だけを表示する(拒否メッセージは出さない)', (tester) async {
      await pumpFlow(tester);
      expect(find.byKey(const Key('scanner-hint')), findsOneWidget);
      expect(find.byKey(const Key('scanner-message')), findsNothing);
    });
  });

  group(
    'ConfirmedScanReceptionFlowの既定接続: 実際のReceptionRoutePage/ConfirmedReceptionPageへつながる',
    () {
      // 受付ロジック自体は既存テスト(confirmed_pass_reception_test.dart等)が保証する。
      // ここでは「scannerが取り出した3つのIDが、既存のReceptionRoutePageへ正しく渡り、
      // programが3件・order順で表示され、onScanNextがConfirmedReceptionPageまで届く」接続だけを検証する。

      testWidgets(
        'scan後、3programがevent.programs.order順で表示され、「次のQRを読み取る」も表示される',
        (tester) async {
          void Function(String)? capturedRaw;
          final receptionService = FakeReceptionService(
            programs: [
              rp('program-a', '架空プログラムA', 2, time: '10:00-11:00'),
              rp('program-b', '架空プログラムB', 1, time: '13:00-14:00'),
              rp('custom-zeta-9', '架空プログラムZ', 3),
            ],
          );
          await tester.pumpWidget(
            MaterialApp(
              home: ConfirmedScanReceptionFlow(
                expectedHost: _host,
                surfaceBuilder: (context, {required onRaw}) {
                  capturedRaw = onRaw;
                  return const SizedBox(key: Key('real-wiring-surface'));
                },
                receptionBuilder:
                    ({
                      required eventId,
                      required participantId,
                      required publicId,
                      required onScanNext,
                    }) => ReceptionRoutePage(
                      eventId: eventId,
                      participantId: participantId,
                      publicId: publicId,
                      onScanNext: onScanNext,
                      authClient: FakeAuthClient(signedIn: true),
                      accessService: FakeAccessService([
                        const AccessCheck.granted(AccessRole.admin),
                      ]),
                      receptionService: receptionService,
                      isLegacyEvent: (_) async =>
                          false, // confirmed方式として解決する(実サーバーへ問い合わせない)
                      legacyBuilder: (_) => const Text('legacy'),
                    ),
              ),
            ),
          );
          await tester.pump();
          capturedRaw!(_validEv1);
          await tester.pumpAndSettle(); // AuthGate・受付画面の非同期読み込みを進める
          expect(find.text('架空プログラムA'), findsOneWidget);
          expect(find.text('架空プログラムB'), findsOneWidget);
          expect(find.text('架空プログラムZ'), findsOneWidget);
          final order = tester
              .widgetList<Text>(find.textContaining('架空プログラム'))
              .map((t) => t.data)
              .whereType<String>()
              .toList();
          expect(order, ['架空プログラムA', '架空プログラムB', '架空プログラムZ']);
          expect(
            find.byKey(const Key('scan-next')),
            findsOneWidget,
          ); // ConfirmedReceptionPageまでonScanNextが届いている
          expect(receptionService.viewCalls, 1);
        },
      );
    },
  );

  group('ConfirmedScanReceptionRoute(未認証・受付権限なしは使用不可)', () {
    Widget route(FakeAuthClient auth, FakeAccessService access) => MaterialApp(
      home: ConfirmedScanReceptionRoute(
        authClient: auth,
        accessService: access,
      ),
    );

    testWidgets('未認証ではscannerに到達できない(ログイン画面だけ)', (tester) async {
      await tester.pumpWidget(
        route(FakeAuthClient(signedIn: false), FakeAccessService([])),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byKey(const Key('fake-surface')), findsNothing);
      expect(find.text('メールアドレス'), findsOneWidget); // ログイン画面
    });

    testWidgets('受付権限がない(accessRolesなし等)ではscannerに到達できない', (tester) async {
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.denied()]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('権限がありません'), findsOneWidget);
    });

    testWidgets('staffはscannerを利用できる', (tester) async {
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.granted(AccessRole.staff)]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(ConfirmedQrScannerView), findsOneWidget);
    });

    testWidgets('adminもscannerを利用できる', (tester) async {
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.granted(AccessRole.admin)]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.byType(ConfirmedQrScannerView), findsOneWidget);
    });
  });

  group('390px幅', () {
    testWidgets('scanner画面・エラー表示で重大なoverflowが出ない', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedQrScannerView(
            onRaw: (_) {},
            message: '別のイベントの参加証です。現在受付中のイベントとは異なるため、この画面では受付できません。',
            surfaceBuilder: (context, {required onRaw}) =>
                const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QrCameraErrorView(
              problem: QrCameraProblem.permissionDenied,
              onRetry: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('境界の静的検査', () {
    test(
      'scannerのコードはFirestoreを直接使わず、新しいparticipant・publicId・programAttendanceを作らない',
      () {
        // ファイル内容を静的に確認する(importで読み込むのではなく、テキストとして走査する)。
        for (final path in [
          'lib/confirmed/qr_scanner.dart',
          'lib/confirmed/qr_scanner_page.dart',
        ]) {
          final source = File(path).readAsStringSync();
          for (final forbidden in [
            'cloud_firestore',
            'FirebaseFirestore',
            '.collection(',
            'generatePublicId',
            'checkInConfirmedProgram(',
            'createConfirmedEvent',
            'sendJobs',
            'mailDeliveries',
          ]) {
            expect(
              source.contains(forbidden),
              isFalse,
              reason: '$path: $forbidden',
            );
          }
        }
      },
    );

    test('QR全文・参加者ID・publicIdをログ(print/debugPrint)へ出していない', () {
      for (final path in [
        'lib/confirmed/qr_scanner.dart',
        'lib/confirmed/qr_scanner_page.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source.contains('debugPrint('), isFalse, reason: path);
        expect(
          RegExp(r'(?<!//.*)\bprint\(').hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    });

    test('参加者向けの参加証(pass_page.dart)にはカメラ機能を追加していない', () {
      final source = File('lib/confirmed/pass_page.dart').readAsStringSync();
      for (final forbidden in [
        'mobile_scanner',
        'MobileScanner',
        'ConfirmedQrScannerView',
      ]) {
        expect(source.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('QRの仕様(receptionQrPayloadの形式)を変更していない: pass_urls.js・受付APIは無変更', () {
      final source = File(
        'functions/confirmed/pass_urls.js',
      ).readAsStringSync();
      expect(
        source,
        contains('/reception?eventId=\${encodeURIComponent(eventId)}'),
      );
      expect(source, contains('&participantId=\${participantId}&publicId='));
      expect(
        source,
        contains(
          'function receptionQrPayload({appBaseUrl, eventId, participantId, publicId})',
        ),
      );
    });
  });
}

// dart:io を末尾でimportしても静的検査には問題ない(テストのみで使用)。
