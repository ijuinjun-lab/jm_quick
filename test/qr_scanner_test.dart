// Phase 11C/11C-2: confirmed受付用のQRカメラスキャナー。実カメラは使わず、カメラ部分を差し替えて検証する。
//  - QR文字列の検証(qr_scanner.dart)は純粋関数として単体で検証する。
//  - scanner → 検証 → 既存のReceptionRoutePage/ConfirmedReceptionPageへ接続する部分([qr_scanner_page.dart])を、
//    受付ロジックそのもの(既存テストが保証)を再テストせずに、接続部分だけ検証する。
//  - カメラ権限エラー・カメラ利用不可の表示内容([QrCameraErrorView])は、カメラ実装に依存せず単体で検証する。
//  - カメラアダプタの状態遷移(open/close・検出の伝播・エラー分類)は、[WebQrCameraView]に[WebCameraGateway]の
//    fake実装を注入して検証する(実カメラ〈getUserMedia・<video>・BarcodeDetector〉は実ブラウザが無いと動かせないため、
//    playsInline/muted/autoplay・背面カメラ要求・連続decode抑止は静的検査〈ソーステキストの確認〉で担保する)。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/qr_scanner.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';
import 'package:jm_quick/confirmed/web_qr_camera.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'confirmed_pass_reception_test.dart' show FakeReceptionService, rp;

/// [WebCameraGateway]のfake実装。実カメラ(getUserMedia・<video>・BarcodeDetector)には一切接続しない。
class FakeCameraGateway implements WebCameraGateway {
  FakeCameraGateway({this.openError});

  /// open()が投げる例外(nullなら成功する)。
  final Object? openError;
  int openCalls = 0;
  int closeCalls = 0;
  void Function(String rawValue)? onDetect;

  @override
  Future<void> open({required void Function(String rawValue) onDetect}) async {
    openCalls++;
    final error = openError;
    if (error != null) throw error;
    this.onDetect = onDetect;
  }

  @override
  Future<void> close() async => closeCalls++;

  @override
  Widget buildPreview() => const SizedBox(key: Key('fake-camera-preview'));
}

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

/// コメント行(`//`で始まる行)を除いたソース(経緯説明などのコメント中の言葉を誤検出しないための静的検査補助)。
String _codeOnly(String path) => File(
  path,
).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

/// scanner関連の全ソース(静的検査の対象)。
const _scannerSourceFiles = [
  'lib/confirmed/qr_scanner.dart',
  'lib/confirmed/qr_scanner_page.dart',
  'lib/confirmed/web_qr_camera.dart',
  'lib/confirmed/web_qr_camera_gateway.dart',
  'lib/confirmed/web_qr_camera_stub.dart',
  'lib/confirmed/web_qr_camera_web.dart',
];

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

  group('WebQrCameraView(カメラアダプタの状態遷移。fakeのWebCameraGatewayへ差し替える)', () {
    Widget host(Widget child) => MaterialApp(home: child);

    testWidgets('stream開始: gateway.open()が呼ばれ、成功するとpreviewが表示される', (
      tester,
    ) async {
      final gateway = FakeCameraGateway();
      await tester.pumpWidget(
        host(
          WebQrCameraView(
            onDetected: (_) {},
            onProblem: (_) {},
            gatewayFactory: () => gateway,
          ),
        ),
      );
      await tester.pump();
      expect(gateway.openCalls, 1);
      expect(find.byKey(const Key('fake-camera-preview')), findsOneWidget);
    });

    testWidgets('正常QR decode: gatewayが検出した文字列が、そのままonDetectedへ渡る', (
      tester,
    ) async {
      final gateway = FakeCameraGateway();
      final detected = <String>[];
      await tester.pumpWidget(
        host(
          WebQrCameraView(
            onDetected: detected.add,
            onProblem: (_) {},
            gatewayFactory: () => gateway,
          ),
        ),
      );
      await tester.pump();
      gateway.onDetect!(
        'https://example.invalid/reception?eventId=e&participantId=p&publicId=q',
      );
      expect(detected, [
        'https://example.invalid/reception?eventId=e&participantId=p&publicId=q',
      ]);
    });

    testWidgets(
      'dispose時停止: ウィジェットが破棄されるとgateway.close()が呼ばれる(MediaStreamTrackの解放)',
      (tester) async {
        final gateway = FakeCameraGateway();
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              onDetected: (_) {},
              onProblem: (_) {},
              gatewayFactory: () => gateway,
            ),
          ),
        );
        await tester.pump();
        expect(gateway.closeCalls, 0);
        await tester.pumpWidget(
          host(const SizedBox()),
        ); // 差し替えてWebQrCameraViewを破棄する
        expect(gateway.closeCalls, 1);
      },
    );

    testWidgets(
      '次のQRで再開: keyを変えて作り直すと、新しいgatewayでopenがもう一度呼ばれる(古いgatewayはclose済み)',
      (tester) async {
        final first = FakeCameraGateway();
        final second = FakeCameraGateway();
        var callCount = 0;
        WebCameraGateway factory() => callCount++ == 0 ? first : second;
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              key: const ValueKey(0),
              onDetected: (_) {},
              onProblem: (_) {},
              gatewayFactory: factory,
            ),
          ),
        );
        await tester.pump();
        expect(first.openCalls, 1);
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              key: const ValueKey(1),
              onDetected: (_) {},
              onProblem: (_) {},
              gatewayFactory: factory,
            ),
          ),
        );
        await tester.pump();
        expect(first.closeCalls, 1, reason: '古いgatewayは作り直しの前に必ず閉じる');
        expect(second.openCalls, 1);
      },
    );

    testWidgets(
      '権限拒否: gateway.open()がWebCameraException(permissionDenied)を投げると、onProblemへ伝わる',
      (tester) async {
        final gateway = FakeCameraGateway(
          openError: const WebCameraException(QrCameraProblem.permissionDenied),
        );
        QrCameraProblem? reported;
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              onDetected: (_) {},
              onProblem: (p) => reported = p,
              gatewayFactory: () => gateway,
            ),
          ),
        );
        await tester.pump();
        expect(reported, QrCameraProblem.permissionDenied);
        expect(find.byKey(const Key('fake-camera-preview')), findsNothing);
      },
    );

    testWidgets(
      'getUserMedia失敗: WebCameraException以外の例外もgenericとして伝わる(アプリは落ちない)',
      (tester) async {
        final gateway = FakeCameraGateway(
          openError: Exception('getUserMedia rejected'),
        );
        QrCameraProblem? reported;
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              onDetected: (_) {},
              onProblem: (p) => reported = p,
              gatewayFactory: () => gateway,
            ),
          ),
        );
        await tester.pump();
        expect(reported, QrCameraProblem.generic);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'disposeされた後にgatewayが遅れてdetectを呼んでも、onDetected/onProblemへ伝えない(setState after dispose防止)',
      (tester) async {
        final gateway = FakeCameraGateway();
        var detectedCalls = 0;
        await tester.pumpWidget(
          host(
            WebQrCameraView(
              onDetected: (_) => detectedCalls++,
              onProblem: (_) {},
              gatewayFactory: () => gateway,
            ),
          ),
        );
        await tester.pump();
        final detect = gateway.onDetect!;
        await tester.pumpWidget(host(const SizedBox()));
        detect(
          'https://example.invalid/reception?eventId=e&participantId=p&publicId=q',
        );
        expect(detectedCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('ConfirmedScanReceptionFlow(scanner ↔ 受付画面の往復。カメラはfakeで差し替える)', () {
    // 実カメラ(_WebCameraSurface)は使わず、直接onRawを呼び出せるfakeに差し替える。
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

    testWidgets('カメラ非対応環境(このテスト実行環境=VM)でも、既定のカメラ面はクラッシュせず「利用できません」表示に落ち着く', (
      tester,
    ) async {
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.granted(AccessRole.admin)]),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump(); // gateway.open()の失敗(VM=unsupported)が伝わるのを待つ
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('scanner-camera-error')), findsOneWidget);
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
        for (final path in _scannerSourceFiles) {
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
      for (final path in _scannerSourceFiles) {
        final source = File(path).readAsStringSync();
        expect(source.contains('debugPrint('), isFalse, reason: path);
        expect(
          RegExp(r'(?<!//.*)\bprint\(').hasMatch(source),
          isFalse,
          reason: path,
        );
      }
    });

    test(
      'mobile_scannerは依存にも本体コード(コメントの経緯説明を除く)にも残っていない(iPhone Safariの黒画面issueを踏む実装を使わない)',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec.contains('mobile_scanner'), isFalse);
        for (final path in _scannerSourceFiles) {
          final source = _codeOnly(path);
          expect(source.contains('mobile_scanner'), isFalse, reason: path);
          expect(source.contains('MobileScanner'), isFalse, reason: path);
        }
      },
    );

    test(
      'Web実カメラアダプタは、<video>へ playsInline / muted / autoplay を明示している(iPhone Safariの黒画面対策)',
      () {
        final source = File(
          'lib/confirmed/web_qr_camera_web.dart',
        ).readAsStringSync();
        for (final required in [
          '..playsInline = true',
          '..muted = true',
          '..autoplay = true',
        ]) {
          expect(source.contains(required), isTrue, reason: required);
        }
      },
    );

    test('Web実カメラアダプタは、背面カメラ(environment)を要求し、特定端末名をハードコードしていない', () {
      final source = _codeOnly('lib/confirmed/web_qr_camera_web.dart');
      expect(source.contains("'facingMode'"), isTrue);
      expect(source.contains("'environment'"), isTrue);
      for (final forbidden in [
        'iPhone',
        'iPad',
        'Pixel',
        'Galaxy',
        'userAgent',
      ]) {
        expect(source.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('Web実カメラアダプタは、終了時に必ずMediaStreamTrackをstopする(カメラが使用中のまま残らない)', () {
      final source = File(
        'lib/confirmed/web_qr_camera_web.dart',
      ).readAsStringSync();
      expect(source.contains('track.stop()'), isTrue);
      // close()の中でstopしていること(catchで握りつぶして呼ばれない実装になっていないか、近傍のテキストで確認)。
      final closeBody = source.substring(
        source.indexOf('Future<void> close()'),
      );
      expect(closeBody.contains('track.stop()'), isTrue);
    });

    test('Web実カメラアダプタは、前回のdecodeが終わるまで次のdetectを開始しない(連続decode抑止)', () {
      final source = File(
        'lib/confirmed/web_qr_camera_web.dart',
      ).readAsStringSync();
      expect(source.contains('if (_detecting'), isTrue);
    });

    test('QR decodeは標準BarcodeDetectorを優先し、無ければjsQR(自前配信・QR専用の小さいfallback)を使う。'
        '外部CDN・zxing相当の巨大な実装は追加していない', () {
      final source = _codeOnly('lib/confirmed/web_qr_camera_web.dart');
      expect(source.contains("@JS('BarcodeDetector')"), isTrue);
      expect(source.contains("@JS('jsQR')"), isTrue);
      for (final forbidden in [
        'zxing',
        'cdn.jsdelivr.net',
        'unpkg.com',
        'wasm',
      ]) {
        expect(
          source.toLowerCase().contains(forbidden.toLowerCase()),
          isFalse,
          reason: forbidden,
        );
      }
    });

    test('jsQRはFirebase Hostingと同一origin(web/vendor)から配信し、外部CDNへは依存しない', () {
      final source = _codeOnly('lib/confirmed/web_qr_camera_web.dart');
      expect(source.contains('web.window.location.origin'), isTrue);
      expect(source.contains('/vendor/jsqr.min.js'), isTrue);
      final asset = File('web/vendor/jsqr.min.js');
      expect(
        asset.existsSync(),
        isTrue,
        reason: 'jsQRのdecoder assetがbuild成果物に含まれる必要がある',
      );
      expect(asset.readAsStringSync().contains('jsQR'), isTrue);
    });

    test('BarcodeDetectorが使えるときは、jsQRのスクリプトをロードしない(不要な読み込みをしない)', () {
      final source = _codeOnly('lib/confirmed/web_qr_camera_web.dart');
      // _resolveFrameDecoder: BarcodeDetectorが使えるときはBarcodeDetectorのdecoderをそのまま返し、
      // _ensureJsQrLoaded(スクリプト注入)は呼ばれない経路になっていることをソース構造で確認する。
      final resolver = source.substring(
        source.indexOf('Future<_FrameDecoder> _resolveFrameDecoder()'),
      );
      final ifBlockEnd = resolver.indexOf('}\n  try {');
      final earlyReturnBlock = resolver.substring(0, ifBlockEnd);
      expect(earlyReturnBlock.contains('_ensureJsQrLoaded'), isFalse);
    });

    test('BarcodeDetectorが使えないときは、jsQRを読み込んでfallback decoderを使う', () {
      final resolver = _codeOnly('lib/confirmed/web_qr_camera_web.dart')
          .substring(
            _codeOnly(
              'lib/confirmed/web_qr_camera_web.dart',
            ).indexOf('Future<_FrameDecoder> _resolveFrameDecoder()'),
          );
      final fallbackBlock = resolver.substring(resolver.indexOf('try {'));
      expect(fallbackBlock.contains('_ensureJsQrLoaded()'), isTrue);
      expect(fallbackBlock.contains('_JsQrFrameDecoder()'), isTrue);
    });

    test('decoderが1つも用意できない場合(jsQRの読み込み失敗を含む)は、明確なエラー(generic)として報告する', () {
      final resolver = _codeOnly('lib/confirmed/web_qr_camera_web.dart')
          .substring(
            _codeOnly(
              'lib/confirmed/web_qr_camera_web.dart',
            ).indexOf('Future<_FrameDecoder> _resolveFrameDecoder()'),
          );
      expect(
        resolver.contains('WebCameraException(QrCameraProblem.generic)'),
        isTrue,
      );
    });

    test(
      'getUserMedia成功＋BarcodeDetectorなし(jsQR fallback)でも、videoの生成・camera previewの開始は行われる'
      '(decoderの種類でcamera previewの有無を分けていない)',
      () {
        final body = _codeOnly('lib/confirmed/web_qr_camera_web.dart')
            .substring(
              _codeOnly(
                'lib/confirmed/web_qr_camera_web.dart',
              ).indexOf('Future<void> open({'),
            );
        final decoderLine = body.indexOf(
          '_decoder = await _resolveFrameDecoder();',
        );
        final videoLine = body.indexOf('final video = web.HTMLVideoElement()');
        // decoderを決めた直後(BarcodeDetector/jsQRのどちらであっても)、同じ手順でvideo/previewを作る。
        expect(decoderLine, greaterThan(-1));
        expect(videoLine, greaterThan(decoderLine));
        expect(body.contains('is _BarcodeDetectorFrameDecoder'), isFalse);
      },
    );

    test('fallback decoder(jsQR)は、見つからなければnullを返すだけで、無効QRの拒否・連続decode抑止を複製しない'
        '(既存のonDetect→parseReceptionQrPayloadの経路へそのまま委ねる)', () {
      final source = _codeOnly('lib/confirmed/web_qr_camera_web.dart');
      final classBody = source.substring(
        source.indexOf('class _JsQrFrameDecoder'),
      );
      expect(classBody.contains('return result?.data;'), isTrue);
      for (final forbidden in [
        'parseReceptionQrPayload',
        'qrRejectMessage',
        'ReceptionRoutePage',
      ]) {
        expect(classBody.contains(forbidden), isFalse, reason: forbidden);
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
