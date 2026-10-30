import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_page.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_service.dart';

class FakeConfirmationService extends DeliveryConfirmationService {
  FakeConfirmationService({required this.admin});
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
        'policy': {'enabled': false, 'version': 0, 'recipients': []},
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
