import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/test_mail_page.dart';
import 'package:jm_quick/confirmed/qr_scanner.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'app_check_fake.dart';

void main() {
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
