import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'app_check_fake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_page.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_service.dart';

class FakeConfirmationService extends DeliveryConfirmationService {
  FakeConfirmationService({
    required this.admin,
    this.initialRecipients = const [],
    this.saveError,
  });
  final List<Map<String, dynamic>> initialRecipients;
  final String? saveError;
  final bool admin;
  final calls = <String>[];
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    calls.add(name);
    expect(data['eventId'], 'event1');
    if (name == 'getDeliveryConfirmationSettings') {
      return {
        'canManage': admin,
        'policy': {
          'enabled': false,
          'version': 0,
          'recipients': saved?['recipients'] ?? initialRecipients,
        },
        'reports': [
          {
            'reportId': 'report1',
            'kind': 'normal',
            'completedAt': '2026-11-01',
            'status': 'ready',
            'subject': '配信確認',
          },
        ],
        'nextAfter': null,
      };
    }
    if (name == 'updateDeliveryConfirmationPolicy') {
      if (saveError != null) throw DeliveryConfirmationException(saveError!);
      saved = data;
      return {'saved': true};
    }
    if (name == 'getDeliveryConfirmationReport') {
      return {
        'reportId': 'report1',
        'sourceJobId': 'winner-source',
        'html': '',
        'text': '個別参加者の情報は確認用サンプルです',
        'deliveries': [
          for (final status in ['sent', 'failed', 'unknown'])
            {
              'name': status,
              'email': '$status@example.invalid',
              'recipientKey': status,
              'status': status,
              'attemptCount': 1,
              'sentAt': null,
            },
        ],
      };
    }
    if (name == 'retryDeliveryConfirmation') {
      expect(data['recipientKey'], 'failed');
      expect(data['expectedAttempt'], 1);
      return {'status': 'sent'};
    }
    throw StateError('Unexpected call: $name');
  }
}

void main() {
  test(
    'HTTP failures map only approved codes, never server messages or details',
    () async {
      for (final item in [
        ['FAILED_PRECONDITION', 'duplicate-address', '重複'],
        ['FAILED_PRECONDITION', 'invalid-address', '形式'],
        ['FAILED_PRECONDITION', 'mail-kind-required', '1つ以上'],
        ['PERMISSION_DENIED', 'private-secret', '権限'],
        ['INTERNAL', 'duplicate-address', '時間をおいて'],
      ]) {
        final service = DeliveryConfirmationService(
          auth: FakeAuthClient(signedIn: true),
          appCheck: FakeAppCheck(),
          client: MockClient(
            (req) async => http.Response(
              jsonEncode({
                'error': {
                  'status': item[0],
                  'message': 'private-secret',
                  'details': {'code': item[1], 'email': 'private-secret'},
                },
              }),
              400,
            ),
          ),
        );
        try {
          await service.call('updateDeliveryConfirmationPolicy', {
            'eventId': 'event1',
          });
          fail('must fail');
        } on DeliveryConfirmationException catch (e) {
          expect(e.message, contains(item[2]));
          expect(e.message, isNot(contains('private-secret')));
        }
      }
    },
  );
  for (final width in [1280.0, 390.0]) {
    testWidgets(
      'delete confirmation, cancellation, save and retained fields at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = FakeConfirmationService(
          admin: true,
          initialRecipients: [
            for (final name in ['first', 'second'])
              {
                'email': '$name@example.invalid',
                'name': name,
                'enabled': true,
                'kinds': ['normal'],
              },
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: DeliveryConfirmationPage(eventId: 'event1', service: service),
          ),
        );
        await tester.pumpAndSettle();
        final remove = find.byKey(const ValueKey('remove-recipient-0'));
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        await tester.tap(find.text('戻る'));
        await tester.pumpAndSettle();
        expect(find.byType(TextFormField), findsNWidgets(4));
        await tester.tap(remove);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認して実行'));
        await tester.pumpAndSettle();
        expect(find.byType(TextFormField), findsNWidgets(2));
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .initialValue,
          'second@example.invalid',
        );
        expect(service.saved, isNull);
        await tester.ensureVisible(find.text('確認先設定を保存'));
        await tester.tap(find.text('確認先設定を保存'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認して実行'));
        await tester.pumpAndSettle();
        expect((service.saved!['recipients'] as List).length, 1);
        expect(find.text('配信確認'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final item in [
    ['duplicate-address', '重複'],
    ['invalid-address', '形式'],
    ['mail-kind-required', '1つ以上'],
    ['permission-denied', '権限'],
    ['private-secret', '時間をおいて'],
  ]) {
    testWidgets('save error ${item[0]} is safe Japanese UI text', (
      tester,
    ) async {
      final service = FakeConfirmationService(admin: true, saveError: item[0]);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryConfirmationPage(eventId: 'event1', service: service),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認先設定を保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確認して実行'));
      await tester.pumpAndSettle();
      expect(find.textContaining(item[1]), findsWidgets);
      expect(find.textContaining('private-secret'), findsNothing);
    });
  }

  testWidgets(
    'admin can configure only after explicit destination confirmation',
    (tester) async {
      final service = FakeConfirmationService(admin: true);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryConfirmationPage(eventId: 'event1', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('配信確認先'), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        false,
      );
      await tester.tap(find.text('確認先を追加（最大10件）'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'office@example.invalid',
      );
      await tester.enterText(find.byType(TextFormField).last, '事務局');
      await tester.ensureVisible(find.text('確認先設定を保存'));
      await tester.tap(find.text('確認先設定を保存'));
      await tester.pumpAndSettle();
      expect(service.saved, isNull);
      expect(find.textContaining('office@example.invalid'), findsWidgets);
      await tester.tap(find.text('確認して実行'));
      await tester.pumpAndSettle();
      expect(
        service.saved!['recipients'][0]['email'],
        'office@example.invalid',
      );
      expect(
        service.calls.where((c) => c.contains('retry') || c.contains('resume')),
        isEmpty,
      );
    },
  );
  testWidgets(
    'manager cannot configure, can retry failed only; sent and unknown lack retry actions',
    (tester) async {
      final service = FakeConfirmationService(admin: false);
      await tester.pumpWidget(
        MaterialApp(
          home: DeliveryConfirmationPage(eventId: 'event1', service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('確認先設定を保存'), findsNothing);
      expect(find.text('確認先を削除'), findsNothing);
      expect(
        tester
            .widget<SwitchListTile>(find.byType(SwitchListTile).first)
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('配信確認'));
      await tester.pumpAndSettle();
      expect(find.text('失敗分を再試行'), findsOneWidget);
      await tester.ensureVisible(find.text('失敗分を再試行'));
      await tester.tap(find.text('失敗分を再試行'));
      await tester.pumpAndSettle();
      expect(service.calls.contains('retryDeliveryConfirmation'), false);
      await tester.tap(find.text('確認して実行'));
      await tester.pumpAndSettle();
      expect(
        service.calls.where((c) => c == 'retryDeliveryConfirmation').length,
        1,
      );
    },
  );
}
