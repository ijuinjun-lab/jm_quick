import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/test_mail_page.dart';
import 'package:jm_quick/confirmed/mail_html_preview.dart';
import 'package:jm_quick/confirmed/qr_scanner.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'app_check_fake.dart';

void main() {
  for (final scenario in [
    for (final kind in ['normal', 'waitlistPromotion', 'broadcast'])
      for (final size in [
        const Size(390, 640),
        const Size(800, 600),
        const Size(1280, 900),
        const Size(900, 400),
      ])
        (kind, size),
  ]) {
    final (kind, size) = scenario;
    testWidgets('long $kind preview keeps fixed confirmation reachable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add(request.url.path);
        final data = (jsonDecode(request.body) as Map)['data'] as Map;
        final result = switch (request.url.path) {
          '/getConfirmedTestMailSettings' => {
            'addresses': ['internal@example.invalid'],
            'participants': [
              {'participantId': 'p1', 'name': '架空参加者'},
            ],
            'programs': [
              {'programId': 'dog', 'name': '犬'},
            ],
            'batches': [],
            'history': [],
            'canManagePolicy': false,
          },
          '/previewConfirmedTestMail' => {
            'subject': '長いテストメール',
            'text': '末尾確認',
            'html':
                '<html><head></head><body style="margin:0">'
                '${List.filled(100, '<p>長いメール本文</p>').join()}'
                '<p>末尾確認</p><img src="cid:jm-quick-reception-qr"></body></html>',
            'qrPngBase64':
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH2kAAAAASUVORK5CYII=',
            'to': 'internal@example.invalid',
            'fingerprint': 'fixed',
          },
          '/sendConfirmedTestMail' => {'status': 'sent'},
          _ => throw StateError('Unexpected request: ${request.url.path}'),
        };
        if (request.url.path == '/previewConfirmedTestMail' ||
            request.url.path == '/sendConfirmedTestMail') {
          expect(data['kind'], kind);
        }
        if (request.url.path == '/sendConfirmedTestMail') {
          expect(data['to'], 'internal@example.invalid');
          expect(data['fingerprint'], 'fixed');
          if (kind == 'broadcast') {
            expect(data['participantId'], 'p1');
            expect(data['draft']['body'], '本文');
          }
        }
        return http.Response(
          jsonEncode({'result': result}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TestMailPage(
            eventId: 'test-event',
            broadcastDraft: kind == 'broadcast'
                ? {
                    'subject': '件名',
                    'body': '本文',
                    'includeDetails': true,
                    'includeQr': true,
                  }
                : null,
            initialParticipantId: kind == 'broadcast' ? 'p1' : null,
            service: TestMailService(
              auth: FakeAuthClient(signedIn: true),
              appCheck: FakeAppCheck(),
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (kind == 'waitlistPromotion') {
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('繰り上げ当選').last);
        await tester.pumpAndSettle();
      }
      if (kind != 'broadcast') {
        await tester.ensureVisible(find.text('犬'));
        await tester.tap(find.text('犬'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<String>).last,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('internal@example.invalid').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('テスト送信内容を確認（送信しません）'));
      await tester.tap(find.text('テスト送信内容を確認（送信しません）'));
      await tester.pumpAndSettle();
      final preview = tester.widget<MailHtmlPreview>(
        find.byType(MailHtmlPreview),
      );
      expect(preview.height, (size.height * 0.5).clamp(120, 700));
      expect(preview.html, contains('末尾確認'));
      final scrollbar = tester
          .widgetList<Scrollbar>(find.byType(Scrollbar))
          .firstWhere((s) => s.thumbVisibility == true);
      expect(scrollbar.interactive, isTrue);
      final controller = scrollbar.controller!;
      final action = find.widgetWithText(FilledButton, 'テスト送信の最終確認へ');
      final fixedRect = tester.getRect(action);
      expect(fixedRect.top, greaterThanOrEqualTo(0));
      expect(fixedRect.bottom, lessThanOrEqualTo(size.height));
      expect(fixedRect.left, greaterThanOrEqualTo(0));
      expect(fixedRect.right, lessThanOrEqualTo(size.width));
      for (final offset in [
        0.0,
        controller.position.maxScrollExtent / 2,
        controller.position.maxScrollExtent,
      ]) {
        controller.jumpTo(offset);
        await tester.pumpAndSettle();
        expect(tester.getRect(action), fixedRect);
        expect(action.hitTestable(), findsOneWidget);
      }
      await tester.tap(find.text('テスト送信の最終確認へ'));
      await tester.pumpAndSettle();
      expect(find.text('テストメールを1通送信します'), findsOneWidget);
      expect(calls, [
        '/getConfirmedTestMailSettings',
        '/previewConfirmedTestMail',
      ]);
      expect(
        find.byType(MailHtmlPreview),
        findsNothing,
        reason: 'No native iframe may intercept the dialog buttons',
      );
      await tester.tap(find.text('戻る'));
      await tester.pumpAndSettle();
      expect(find.byType(MailHtmlPreview), findsOneWidget);
      expect(calls.where((c) => c.contains('sendConfirmed')), isEmpty);
      await tester.tap(find.text('テスト送信の最終確認へ'));
      await tester.pumpAndSettle();
      expect(find.byType(MailHtmlPreview), findsNothing);
      await tester.tap(find.text('確認してテスト送信'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls.where((c) => c == '/sendConfirmedTestMail'), hasLength(1));
      expect(find.text('テスト配送結果：sent'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  test('synthetic test QR is rejected by the actual reception parser', () {
    expect(
      parseReceptionQrPayload('JM_QUICK_TEST_ONLY_NOT_A_RECEPTION_QR').isValid,
      false,
    );
    expect(
      parseReceptionQrPayload(
        'https://example.invalid/p/synthetic-test-only?publicId=pub_synthetic_test_only_00000000',
        expectedHost: 'jm-quick.web.app',
      ).isValid,
      false,
    );
  });
  testWidgets(
    'preview is read-only; final confirmation required; HTML/text and destination shown',
    (tester) async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add(req.url.path);
        expect(req.headers['X-Firebase-AppCheck'], 'test-app-check-token');
        final input = (jsonDecode(req.body) as Map)['data'] as Map;
        expect(input['eventId'], 'test-event');
        final result = switch (req.url.path) {
          '/getConfirmedTestMailSettings' => {
            'addresses': ['internal@example.invalid'],
            'participants': [],
            'programs': [
              {'programId': 'dog', 'name': '犬'},
            ],
            'batches': [],
            'history': [],
            'canManagePolicy': false,
          },
          '/previewConfirmedTestMail' => {
            'subject': '【テスト送信】当選',
            'text': 'これはテストメールです。正式な参加案内ではありません。',
            'html': '<html><body>これはテストメールです。</body></html>',
            'qrPngBase64': '',
            'to': 'internal@example.invalid',
            'fingerprint': 'fixed',
          },
          '/sendConfirmedTestMail' => {'status': 'sent'},
          _ => throw StateError('unexpected call'),
        };
        return http.Response(
          jsonEncode({'result': result}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TestMailPage(
            eventId: 'test-event',
            service: TestMailService(
              auth: FakeAuthClient(signedIn: true),
              appCheck: FakeAppCheck(),
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('犬'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('internal@example.invalid').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('テスト送信内容を確認（送信しません）'));
      await tester.tap(find.text('テスト送信内容を確認（送信しません）'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.contains('sendConfirmed')), isEmpty);
      await tester.ensureVisible(find.text('テスト送信の最終確認へ'));
      await tester.tap(find.text('テスト送信の最終確認へ'));
      await tester.pumpAndSettle();
      expect(find.text('テストメールを1通送信します'), findsOneWidget);
      expect(calls.where((c) => c.contains('sendConfirmed')), isEmpty);
      await tester.tap(find.text('戻る'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.contains('sendConfirmed')), isEmpty);
    },
  );
}
