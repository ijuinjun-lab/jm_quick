import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/manual_delivery_confirmation.dart';
import 'support/manual_delivery_confirmation_browser.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('preview, explicit send and duplicate prevention at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = ManualNotificationFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManualDeliveryConfirmationButton(
              eventId: 'event1',
              jobId: 'winner-job',
              service: service,
            ),
          ),
        ),
      );
      await tester.tap(find.text('事務局へ送信結果を通知'));
      await tester.pumpAndSettle();
      expect(service.calls, ['previewManualDeliveryConfirmation']);
      for (final email in ManualNotificationFixture.emails) {
        expect(find.text(email), findsOneWidget);
      }
      expect(find.textContaining('対象 10件 / 成功 8件'), findsOneWidget);
      expect(find.text('件名：事務局用の送信結果'), findsOneWidget);
      expect(find.textContaining('送信結果の本文'), findsOneWidget);
      await tester.tap(find.text('送信する'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送信する'))
            .onPressed,
        isNull,
      );
      await tester.pumpAndSettle();
      expect(
        service.calls
            .where((c) => c == 'sendManualDeliveryConfirmation')
            .length,
        1,
      );
      expect(service.requests.last['fingerprint'], 'preview-fingerprint');
      expect(find.textContaining('通知済み / 試行'), findsNWidgets(5));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送信する'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'only failed recipient can retry after preview; unknown and sent cannot',
    (tester) async {
      final service = ManualNotificationFixture(mode: 'mixed');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManualDeliveryConfirmationButton(
              eventId: 'event1',
              jobId: 'winner-job',
              service: service,
            ),
          ),
        ),
      );
      await tester.tap(find.text('事務局へ送信結果を通知'));
      await tester.pumpAndSettle();
      expect(find.text('この宛先へ再送する'), findsOneWidget);
      expect(find.textContaining('結果不明（再送禁止） /'), findsOneWidget);
      await tester.tap(find.text('この宛先へ再送する'));
      await tester.pumpAndSettle();
      expect(service.requests.last['recipientKey'], 'recipient-0');
      expect(service.requests.last['expectedAttempt'], 1);
      expect(find.text('この宛先へ再送する'), findsNothing);
    },
  );
  for (final mode in ['denied', 'lost']) {
    testWidgets('$mode never automatically sends or retries', (tester) async {
      final service = ManualNotificationFixture(mode: mode);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManualDeliveryConfirmationButton(
              eventId: 'event1',
              jobId: 'winner-job',
              service: service,
            ),
          ),
        ),
      );
      await tester.tap(find.text('事務局へ送信結果を通知'));
      await tester.pumpAndSettle();
      if (mode == 'lost') {
        await tester.tap(find.text('送信する'));
        await tester.pumpAndSettle();
      }
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '送信する'))
            .onPressed,
        isNull,
      );
      expect(
        service.calls
            .where((c) => c == 'sendManualDeliveryConfirmation')
            .length,
        mode == 'lost' ? 1 : 0,
      );
    });
  }
}
