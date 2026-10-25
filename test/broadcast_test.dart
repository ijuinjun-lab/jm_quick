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
          if (req.url.path == '/getConfirmedBroadcastSettings') {
            result = {
              'recipients': [
                {
                  'participantId': 'person',
                  'name': '架空参加者',
                  'email': 'internal@example.invalid',
                },
              ],
              'history': [],
            };
          } else if (req.url.path == '/getConfirmedTestMailSettings') {
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
          home: BroadcastPage(eventId: 'synthetic', service: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '案内');
      await tester.enterText(find.byType(TextField).at(1), '本文');
      await tester.ensureVisible(find.byType(CheckboxListTile).at(0));
      await tester.tap(find.byType(CheckboxListTile).at(0));
      await tester.ensureVisible(find.byType(CheckboxListTile).at(1));
      await tester.tap(find.byType(CheckboxListTile).at(1));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('社内へテスト送信'));
      await tester.tap(find.text('社内へテスト送信'));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField<String>), findsWidgets);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('internal@example.invalid').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('テスト送信内容を確認（送信しません）'));
      await tester.tap(find.text('テスト送信内容を確認（送信しません）'));
      await tester.pumpAndSettle();
      expect(calls, [
        '/getConfirmedBroadcastSettings',
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
      'initial recipients and import totals refresh without sending at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var reads = 0;
        final service = TestMailService(
          auth: FakeAuthClient(signedIn: true),
          appCheck: FakeAppCheck(),
          client: MockClient((req) async {
            expect(req.url.path, '/getConfirmedBroadcastSettings');
            reads++;
            final recipients = List.generate(
              reads == 1 ? 8 : 7,
              (i) => {
                'participantId': 'p$i',
                'name': '架空$i',
                'email': 'p$i@example.invalid',
                'programs': [
                  {
                    'name': reads == 1 ? '犬' : '猫',
                    'timeText': '10:00–11:00',
                    'plannedCount': reads == 1 ? 2 : 3,
                  },
                ],
              },
            );
            return http.Response(
              jsonEncode({
                'result': {
                  'recipients': recipients,
                  'batchCounts': [
                    {'sequence': 1, 'count': 3},
                    {'sequence': 3, 'count': recipients.length - 3},
                  ],
                  'history': [],
                },
              }),
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
        expect(reads, 1);
        expect(find.byType(DataTable), findsOneWidget);
        for (final heading in ['氏名', 'メールアドレス', '参加プログラム', '参加時間', '参加人数']) {
          expect(find.text(heading), findsOneWidget);
        }
        expect(
          tester.getSize(find.byKey(const Key('broadcastRecipients'))).height,
          lessThanOrEqualTo(320),
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('broadcastRecipients')),
            matching: find.text('送信対象を更新'),
          ),
          findsNothing,
        );
        expect(find.text('現在の送信対象総数：8申込'), findsOneWidget);
        expect(find.text('第1回：3申込'), findsOneWidget);
        expect(find.text('第3回：5申込'), findsOneWidget);
        expect(find.text('p0@example.invalid'), findsOneWidget);
        expect(find.text('2名'), findsWidgets);
        for (final field in tester.widgetList<TextField>(
          find.byType(TextField),
        )) {
          expect(field.controller!.text, isEmpty);
        }
        await tester.dragFrom(
          tester.getTopLeft(find.byKey(const Key('broadcastRecipients'))) +
              const Offset(100, 160),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(find.text('p7@example.invalid'), findsOneWidget);
        if (width < 900) {
          await tester.drag(
            find.byKey(const Key('broadcastRecipientsHorizontal')),
            const Offset(-600, 0),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.enterText(find.byType(TextField).first, '保持する件名');
        await tester.ensureVisible(find.text('送信対象を更新'));
        await tester.tap(find.text('送信対象を更新'));
        await tester.pumpAndSettle();
        expect(reads, 2);
        expect(find.text('現在の送信対象総数：7申込'), findsOneWidget);
        expect(find.text('第3回：4申込'), findsOneWidget);
        expect(find.text('p7@example.invalid'), findsNothing);
        expect(find.text('3名'), findsWidgets);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          '保持する件名',
        );
        expect(tester.takeException(), isNull);
      },
    );
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
                'recipients': [
                  recipient,
                  {...recipient, 'participantId': 'removed'},
                ],
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
        expect(find.text('プレビュー対象者'), findsNothing);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.text('第1回'), findsNothing);
        expect(find.text('送信予定日時'), findsNothing);
        expect(find.text('① 送信内容・宛先を確認'), findsNothing);
        expect(find.text('新しい一斉メールを作成'), findsNothing);
        final proceed = find.widgetWithText(FilledButton, '一斉送信へ進む');
        expect(tester.widget<FilledButton>(proceed).onPressed, isNull);
        await tester.enterText(find.byType(TextField).at(0), '案内');
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(proceed).onPressed, isNull);
        await tester.enterText(find.byType(TextField).at(1), '本文');
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('一斉送信へ進む'));
        await tester.tap(find.text('一斉送信へ進む'));
        await tester.pumpAndSettle();
        expect(calls.any((c) => c.contains('startConfirmed')), false);
        expect(find.text('送信対象 1申込'), findsOneWidget);
        expect(
          find.text('初期表示から対象人数が変わりました。以下の最新の宛先一覧・人数をご確認ください。'),
          findsOneWidget,
        );
        expect(find.text('件名：案内\n本文：本文'), findsOneWidget);
        expect(find.text('架空参加者 / internal@example.invalid'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text,
          '案内',
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(1))
              .controller!
              .text,
          '本文',
        );
        await tester.ensureVisible(proceed);
        await tester.tap(proceed);
        await tester.pumpAndSettle();
        final start = find.widgetWithText(FilledButton, '最終確認へ');
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
