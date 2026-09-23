// Phase 11L: 「受付」の入口(PC・イベント管理画面から開く)。PCのカメラは絶対に起動しない
// (getUserMediaを一切呼ばない)ことを、静的検査(このファイルがカメラ関連ファイルをimportしていないこと)と
// widgetツリー(カメラ系widgetが一切無いこと)の両方で確認する。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_staff_qr_page.dart';
import 'package:jm_quick/confirmed/web_qr_camera.dart';
import 'package:qr_flutter/qr_flutter.dart';

Widget _page({
  String eventId = 'evfixture0123456789',
  String eventName = '犬猫譲渡会・トークショー(架空)',
  Uri? baseUri,
}) => MaterialApp(
  home: ConfirmedReceptionStaffQrPage(
    eventId: eventId,
    eventName: eventName,
    baseUri: baseUri,
  ),
);

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

    testWidgets(
      'QRの中身は、このイベントに固定された既存のスマホ受付スキャナのURL。participantId/publicIdは含まない',
      (tester) async {
        await tester.pumpWidget(
          _page(
            eventId: 'event1',
            baseUri: Uri.parse('https://jm-quick.web.app/console'),
          ),
        );
        await tester.pumpAndSettle();
        final key =
            (tester.widget<QrImageView>(find.byType(QrImageView)).key
                    as ValueKey<String>)
                .value;
        expect(
          key,
          contains('https://jm-quick.web.app/console/scan?eventId=event1'),
        );
        expect(key.contains('participantId='), isFalse);
        expect(key.contains('publicId='), isFalse);
      },
    );

    testWidgets('イベントが変われば、QRのURLのeventIdも変わる', (tester) async {
      await tester.pumpWidget(
        _page(
          eventId: 'event-a',
          baseUri: Uri.parse('https://jm-quick.web.app/console'),
        ),
      );
      await tester.pumpAndSettle();
      final keyA =
          (tester.widget<QrImageView>(find.byType(QrImageView)).key
                  as ValueKey<String>)
              .value;
      expect(keyA, contains('eventId=event-a'));

      await tester.pumpWidget(
        _page(
          eventId: 'event-b',
          baseUri: Uri.parse('https://jm-quick.web.app/console'),
        ),
      );
      await tester.pumpAndSettle();
      final keyB =
          (tester.widget<QrImageView>(find.byType(QrImageView)).key
                  as ValueKey<String>)
              .value;
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
        final text = File(
          'lib/confirmed/reception_staff_qr_page.dart',
        ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
        for (final forbidden in [
          'web_qr_camera',
          'qr_scanner_page.dart',
          'getUserMedia',
          'MediaDevices',
        ]) {
          expect(text.contains(forbidden), isFalse, reason: forbidden);
        }
        // 使っているのは既存のqr_flutter(表示専用のQR画像生成)だけ。
        expect(text.contains("import 'package:qr_flutter/qr_flutter.dart';"), isTrue);
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
