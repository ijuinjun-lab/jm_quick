// Phase 11L: 「受付」の入口(PC・イベント管理画面から開く)。PCのカメラは絶対に起動しない
// (getUserMediaを一切呼ばない)ことを、静的検査(このファイルがカメラ関連ファイルをimportしていないこと)と
// widgetツリー(カメラ系widgetが一切無いこと)の両方で確認する。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_staff_qr_page.dart';
import 'package:jm_quick/confirmed/web_qr_camera.dart';
import 'package:jm_quick/confirmed/reception_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'reception_staff_key_fake.dart';

Widget _page({
  String eventId = 'evfixture0123456789',
  String eventName = '犬猫譲渡会・トークショー(架空)',
  Uri? baseUri,
  FakeReceptionStaffKeyIssuer? issuer,
}) => MaterialApp(
  home: ConfirmedReceptionStaffQrPage(
    eventId: eventId,
    eventName: eventName,
    baseUri: baseUri,
    issuer: issuer ?? FakeReceptionStaffKeyIssuer(),
  ),
);

String _qrData(WidgetTester tester) =>
    (tester.widget<QrImageView>(find.byType(QrImageView)).key
            as ValueKey<String>)
        .value
        .replaceFirst('reception-staff-qr:', '');

void main() {
  group('ConfirmedReceptionStaffQrPage(PCの「受付」= 受付スタッフ用QRの表示のみ)', () {
    testWidgets('イベント名・案内文・「このPCではカメラを使用しません」が表示される', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pumpAndSettle();
      expect(find.text('犬猫譲渡会・トークショー(架空)'), findsOneWidget);
      expect(find.text('受付スタッフ用QRコード'), findsOneWidget);
      expect(find.text('受付スタッフのスマートフォンで、このQRを読み取ってください。'), findsOneWidget);
      expect(find.text('このPCではカメラを使用しません。'), findsOneWidget);
    });

    testWidgets('QRの中身は、アカウント不要の受付端末の入口(このイベントの受付キーつき)。ログイン用の/console/scanではなく、'
        'participantId/publicId・Firebaseのトークン・パスワードは含まない', (tester) async {
      final issuer = FakeReceptionStaffKeyIssuer();
      await tester.pumpWidget(
        _page(
          eventId: 'event1',
          baseUri: Uri.parse('https://jm-quick.web.app/console?x=1#frag'),
          issuer: issuer,
        ),
      );
      await tester.pumpAndSettle();
      final data = _qrData(tester);
      expect(
        data,
        'https://jm-quick.web.app/reception/staff?eventId=event1&key=$fakeReceptionKey',
      );
      expect(issuer.calls, ['event1'], reason: 'サーバーで、このイベントの受付キーを取得する');
      final uri = Uri.parse(data);
      expect(uri.queryParameters.keys.toSet(), {'eventId', 'key'});
      for (final forbidden in [
        '/console/scan',
        'participantId',
        'publicId',
        'token',
        'password',
        'Bearer',
      ]) {
        expect(data.contains(forbidden), isFalse, reason: forbidden);
      }
      expect(find.textContaining('有効期限:'), findsOneWidget);
      expect(find.textContaining('ログインは不要です'), findsOneWidget);
    });

    testWidgets('受付キーを取得できなければQRを出さず、理由と再試行を表示する(再試行で表示できる)', (tester) async {
      final issuer = FakeReceptionStaffKeyIssuer(
        error: const ReceptionException('この操作を行う権限がありません。'),
      );
      await tester.pumpWidget(_page(issuer: issuer));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('この操作を行う権限がありません。'), findsOneWidget);
      issuer.error = null;
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      expect(issuer.calls.length, 2);
    });

    testWidgets('イベントが変われば、QRのURLのeventIdも変わる', (tester) async {
      await tester.pumpWidget(
        _page(
          eventId: 'event-a',
          baseUri: Uri.parse('https://jm-quick.web.app/console'),
        ),
      );
      await tester.pumpAndSettle();
      final keyA = _qrData(tester);
      expect(keyA, contains('eventId=event-a'));

      await tester.pumpWidget(
        _page(
          eventId: 'event-b',
          baseUri: Uri.parse('https://jm-quick.web.app/console'),
        ),
      );
      await tester.pumpAndSettle();
      final keyB = _qrData(tester);
      expect(keyB, contains('eventId=event-b'));
      expect(keyB.contains('eventId=event-a'), isFalse);
    });

    testWidgets(
      'PC受付画面にはカメラ関連のwidgetが一切無い(WebQrCameraView・ConfirmedQrScannerViewが無い)',
      (tester) async {
        await tester.pumpWidget(_page());
        await tester.pumpAndSettle();
        expect(find.byType(WebQrCameraView), findsNothing);
        expect(find.byType(ConfirmedQrScannerView), findsNothing);
        // カメラ利用不可・権限系の文言も出ない(そもそもカメラを試みていない証拠)。
        expect(find.byKey(const Key('scanner-camera-error')), findsNothing);
      },
    );

    testWidgets('390px幅・PC幅(1200px)のどちらでもoverflowしない', (tester) async {
      for (final size in [const Size(390, 900), const Size(1200, 900)]) {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_page());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$size');
      }
    });
  });

  group('境界の静的検査', () {
    test(
      'Phase 11L: PCの「受付」画面(reception_staff_qr_page.dart)は、カメラ関連ファイルを一切importしない'
      '(getUserMediaを呼ぶ経路自体が存在しない、ソースレベルの保証)',
      () {
        final text = File('lib/confirmed/reception_staff_qr_page.dart')
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final forbidden in [
          'web_qr_camera',
          'qr_scanner_page.dart',
          'getUserMedia',
          'MediaDevices',
        ]) {
          expect(text.contains(forbidden), isFalse, reason: forbidden);
        }
        // 使っているのは既存のqr_flutter(表示専用のQR画像生成)だけ。
        expect(
          text.contains("import 'package:qr_flutter/qr_flutter.dart';"),
          isTrue,
        );
      },
    );

    test(
      'Phase 11L: 受付スタッフ用QRのURLに、参加者ID・publicIdを埋め込む余地が無い'
      '(ConfirmedReceptionStaffQrPageのコード自体〈コメントを除く〉はeventId・eventNameしか扱わない)',
      () {
        final text = File('lib/confirmed/reception_staff_qr_page.dart')
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(text.contains('participantId'), isFalse);
        expect(text.contains('publicId'), isFalse);
      },
    );
  });
}
