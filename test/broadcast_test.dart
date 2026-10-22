import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/broadcast_page.dart';
import 'package:jm_quick/confirmed/test_mail_page.dart';
import 'package:jm_quick/confirmed/mail_html_document.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'app_check_fake.dart';

void main() {
  testWidgets(
    'broadcast draft and participant reach isolated test preview without a formal job',
    (tester) async {
      const draft = {
        'subject': '案内',
        'body': '本文',
        'includeDetails': false,
        'includeQr': false,
      };
      final calls = <String>[];
      final service = TestMailService(
        auth: FakeAuthClient(signedIn: true),
        appCheck: FakeAppCheck(),
        client: MockClient((req) async {
          calls.add(req.url.path);
          final data = jsonDecode(req.body)['data'] as Map;
          Map<String, dynamic> result;
          if (req.url.path == '/getConfirmedTestMailSettings') {
            result = {
              'addresses': ['internal@example.invalid'],
              'participants': [
                {'participantId': 'person', 'name': '架空参加者'},
              ],
              'programs': [],
              'batches': [],
              'history': [],
              'canManagePolicy': false,
            };
          } else {
            expect(req.url.path, '/previewConfirmedTestMail');
            expect(data['kind'], 'broadcast');
            expect(data['draft'], draft);
            expect(data['participantId'], 'person');
            expect(data.containsKey('batchId'), false);
            result = {
              'subject': '【テスト送信】案内',
              'text': '本文',
              'html':
                  '<html><head></head><body style="margin:0">本文</body></html>',
              'qrPngBase64': '',
              'to': 'internal@example.invalid',
              'fingerprint': 'preview',
            };
          }
          return http.Response(
            jsonEncode({'result': result}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TestMailPage(
            eventId: 'synthetic',
            service: service,
            broadcastDraft: draft,
            initialParticipantId: 'person',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('internal@example.invalid').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('テスト送信内容を確認（送信しません）'));
      await tester.tap(find.text('テスト送信内容を確認（送信しません）'));
      await tester.pumpAndSettle();
      expect(calls, [
        '/getConfirmedTestMailSettings',
        '/previewConfirmedTestMail',
      ]);
      expect(find.text('QR画像を取得できませんでした。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'notice-only HTML preserves CSS and text with the same sandbox policy',
    () {
      const html =
          '<html><head></head><body style="margin:0"><p>案内のみ</p></body></html>';
      final shown = mailPreviewDocument(html, '', allowWithoutQr: true);
      expect(shown, contains(mailPreviewSecurityHead));
      expect(shown, contains('<body inert style="margin:0"><p>案内のみ</p>'));
      expect(() => mailPreviewDocument(html, ''), throwsFormatException);
      expect(
        () => mailPreviewDocument(
          html.replaceFirst('案内のみ', 'cid:jm-quick-reception-qr'),
          '',
          allowWithoutQr: true,
        ),
        throwsFormatException,
      );
    },
  );
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'broadcast requires preview, all recipients and final approval at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        final ids = <String>[];
        const recipient = {
          'participantId': 'person',
          'name': '架空参加者',
          'email': 'internal@example.invalid',
          'programs': <dynamic>[],
        };
        final service = TestMailService(
          auth: FakeAuthClient(signedIn: true),
          appCheck: FakeAppCheck(),
          client: MockClient((req) async {
            calls.add(req.url.path);
            expect(req.headers['X-Firebase-AppCheck'], 'test-app-check-token');
            final data = jsonDecode(req.body)['data'] as Map;
            if (req.url.path == '/startConfirmedBroadcastDelivery') {
              expect(data['recipientsConfirmed'], true);
              expect(data['confirmation'], 'reviewed');
              ids.add(data['operationId'] as String);
            }
            final result = switch (req.url.path) {
              '/getConfirmedBroadcastSettings' => {
                'recipients': [recipient],
                'history': [],
              },
              '/previewConfirmedBroadcastMail' => {
                'recipients': [recipient],
                'targetCount': 1,
                'confirmation': 'reviewed',
                'html':
                    '<html><head></head><body style="margin:0">案内</body></html>',
                'text': '案内',
                'qrPngBase64': '',
              },
              '/startConfirmedBroadcastDelivery' => {'jobId': 'broadcast-test'},
              '/getConfirmedBroadcastJob' => {
                'job': {
                  'subject': '案内',
                  'counts': {'sent': 0},
                },
                'items': [],
                'nextAfter': null,
              },
              _ => throw StateError('unexpected API'),
            };
            return http.Response(
              jsonEncode({'result': result}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: BroadcastPage(eventId: 'synthetic', service: service),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('第1回'), findsNothing);
        expect(find.text('送信予定日時'), findsNothing);
        await tester.enterText(find.byType(TextField).at(0), '案内');
        await tester.enterText(find.byType(TextField).at(1), '本文');
        await tester.ensureVisible(find.text('宛先一覧・HTMLプレビューを確認'));
        await tester.tap(find.text('宛先一覧・HTMLプレビューを確認'));
        await tester.pumpAndSettle();
        expect(calls.any((c) => c.contains('startConfirmed')), false);
        final start = find.widgetWithText(FilledButton, '正式送信開始');
        expect(tester.widget<FilledButton>(start).onPressed, isNull);
        await tester.ensureVisible(find.text('宛先全員・件数・件名・本文を確認しました'));
        await tester.tap(find.text('宛先全員・件数・件名・本文を確認しました'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(start);
        await tester.tap(start);
        await tester.pumpAndSettle();
        expect(calls.any((c) => c.contains('startConfirmed')), false);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(start);
        await tester.pumpAndSettle();
        await tester.tap(start);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認して続行'));
        await tester.pumpAndSettle();
        expect(ids.length, 1);
        expect(tester.widget<FilledButton>(start).onPressed, isNull);
        await tester.ensureVisible(find.text('同じ送信要求の状態を確認・再開'));
        await tester.tap(find.text('同じ送信要求の状態を確認・再開'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認して続行'));
        await tester.pumpAndSettle();
        expect(ids.length, 2);
        expect(ids.toSet().length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
