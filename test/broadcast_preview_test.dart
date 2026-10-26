import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/broadcast_page.dart';
import 'package:jm_quick/confirmed/test_mail_page.dart';
import 'package:jm_quick/confirmed/mail_html_preview.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'app_check_fake.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('independent preview is read-only and isolated at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final people = [
        for (final id in ['dog', 'cat', 'talk', 'mixed'])
          {
            'participantId': id,
            'name': id,
            'email': '$id@example.invalid',
            'programs': [
              for (final name in (id == 'mixed' ? ['犬', '猫', 'トーク'] : [id]))
                {'name': name, 'timeText': '10:00', 'plannedCount': 1},
            ],
          },
      ];
      final calls = <String>[];
      final selected = <String>[];
      var latestCount = 3;
      final service = TestMailService(
        auth: FakeAuthClient(signedIn: true),
        appCheck: FakeAppCheck(),
        client: MockClient((req) async {
          final data = jsonDecode(req.body)['data'] as Map;
          calls.add(req.url.path);
          expect(req.headers['X-Firebase-AppCheck'], 'test-app-check-token');
          Map<String, dynamic> result;
          if (req.url.path == '/getConfirmedBroadcastSettings') {
            result = {
              'recipients': people,
              'batchCounts': [
                {'sequence': 1, 'count': 4},
              ],
              'history': [],
            };
          } else if (req.url.path == '/previewConfirmedBroadcastMail') {
            final id = data['participantId'] as String;
            selected.add(id);
            expect(data['draft']['subject'], '案内');
            expect(data['draft']['body'], '本文');
            // Latest response differs from the initial list, including a cancelled cat program.
            final programs = [
              for (final name in (id == 'mixed' ? ['犬', 'トーク'] : [id]))
                {
                  'name': name,
                  'timeText': '14:00',
                  'plannedCount': latestCount,
                },
            ];
            result = {
              'to': '$id@example.invalid',
              'subject': '案内',
              'html':
                  '<html><head></head><body style="margin:0">$id 最新 $latestCount名</body></html>',
              'text': '最新',
              'qrPngBase64': '',
              'targetCount': 4,
              'confirmation': 'fresh',
              'recipients': [
                for (final p in people)
                  {...p, if (p['participantId'] == id) 'programs': programs},
              ],
            };
          } else {
            throw StateError(
              'Write/send API forbidden in preview: ${req.url.path}',
            );
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
      final button = find.widgetWithText(OutlinedButton, 'メール内容をプレビュー');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextField).at(0), '案内');
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextField).at(1), '本文');
      await tester.pumpAndSettle();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('宛先：dog@example.invalid'), findsOneWidget);
      for (final id in ['cat', 'talk', 'mixed']) {
        await tester.ensureVisible(
          find.byType(DropdownButtonFormField<String>),
        );
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('$id / $id@example.invalid').last);
        await tester.pumpAndSettle();
        expect(find.text('宛先：$id@example.invalid'), findsOneWidget);
        final html = tester.widget<MailHtmlPreview>(
          find.byType(MailHtmlPreview),
        );
        expect(html.html, contains('$id 最新 3名'));
        expect(find.text('最終確認へ'), findsNothing);
      }
      expect(find.text('犬 14:00 3名'), findsOneWidget);
      expect(find.text('トーク 14:00 3名'), findsOneWidget);
      expect(find.text('猫 14:00 3名'), findsNothing);
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        '案内',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '本文',
      );
      expect(find.text('現在の送信対象総数：4申込'), findsOneWidget);
      latestCount = 2;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MailHtmlPreview>(find.byType(MailHtmlPreview)).html,
        contains('最新 2名'),
      );
      await tester.tap(find.text('閉じる'));
      await tester.pumpAndSettle();
      final proceed = find.text('一斉送信へ進む');
      await tester.ensureVisible(proceed);
      await tester.tap(proceed);
      await tester.pumpAndSettle();
      expect(
        selected.last,
        'dog',
        reason: 'Preview selection must not modify formal/default recipient',
      );
      expect(find.text('送信対象 4申込'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '最終確認へ'))
            .onPressed,
        isNull,
      );
      expect(calls.toSet(), {
        '/getConfirmedBroadcastSettings',
        '/previewConfirmedBroadcastMail',
      });
      expect(tester.takeException(), isNull);
    });
  }
}
