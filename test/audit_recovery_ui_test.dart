import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/import_service.dart';
import 'package:jm_quick/confirmed/reminder_page.dart';
import 'package:jm_quick/confirmed/reminder_service.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';
import 'import_page_test.dart' show FakeImportService;
import 'reminder_test.dart' show FakeReminderService;

class RecoveryImport extends FakeImportService implements ImportRecoveryService {
  String? reason;
  @override
  Future<List<Map<String, dynamic>>> getRecovery(String eventId) async => [{
    'batchId': 'partial', 'sequence': 1, 'sourceFileName': '架空.csv', 'status': 'failed',
    'persistedCount': 1, 'pendingCount': 2, 'fingerprint': 'f' * 64,
    'rows': [{'sourceRowNumber': 2, 'result': 'created'}],
  }];
  @override
  Future<void> abandonImport(String eventId, Map<String, dynamic> batch, String reason) async {
    this.reason = reason;
    expect(batch['batchId'], 'partial');
    expect(batch['fingerprint'], 'f' * 64);
  }
}
class RecoveryReminder extends FakeReminderService implements ReminderRecoveryService {
  String? reason;
  @override
  Future<List<Map<String, dynamic>>> recoveryPreview(String eventId) async => [{
    'participantId': 'p1', 'name': '架空対象', 'email': 'p1@example.invalid', 'text': '犬3人＋トーク2人・既存QR', 'fingerprint': 'a' * 64,
  }];
  @override
  Future<void> confirmRecovery(String eventId, Map<String, dynamic> recipient, String reason) async {
    this.reason = reason;
    expect(recipient['participantId'], 'p1'); expect(recipient['fingerprint'], 'a' * 64);
  }
}
void main() {
  testWidgets('未完了取込の保存済み・未保存行を表示し、理由を入力して放棄する', (tester) async {
    final service = RecoveryImport();
    await tester.pumpWidget(MaterialApp(home: ConfirmedImportPage(eventId: 'event1', service: service, picker: () async => null)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-recovery'))); await tester.pumpAndSettle();
    expect(find.text('保存済み 1行 / 未保存 2行'), findsOneWidget);
    await tester.tap(find.byType(ExpansionTile)); await tester.pumpAndSettle();
    expect(find.text('2行目: created（保存済み）'), findsOneWidget);
    await tester.tap(find.text('再開できない取込回を放棄')); await tester.pumpAndSettle();
    await tester.tap(find.text('放棄を確定')); await tester.pumpAndSettle();
    expect(service.reason, isNull);
    await tester.enterText(find.byType(TextField), '原本の修復が必要');
    await tester.tap(find.text('放棄を確定')); await tester.pumpAndSettle();
    expect(service.reason, '原本の修復が必要'); expect(service.commits, isEmpty);
  });
  testWidgets('リマインド復旧は宛先と本文を確認し、理由を保存しても送信しない', (tester) async {
    final service = RecoveryReminder()..seedJob({'p1': DeliveryState.failed, 'p2': DeliveryState.sent, 'p3': DeliveryState.unknown});
    await tester.pumpWidget(MaterialApp(home: ReminderPage(service: service, initialEventId: 'event1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('reminder-recovery')));
    await tester.tap(find.byKey(const Key('reminder-recovery'))); await tester.pumpAndSettle();
    await tester.tap(find.text('架空対象 / p1@example.invalid')); await tester.pumpAndSettle();
    expect(find.text('犬3人＋トーク2人・既存QR'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), '変更内容を原本で確認');
    await tester.tap(find.text('この宛先の再開を承認')); await tester.pumpAndSettle();
    expect(service.reason, '変更内容を原本で確認'); expect(service.startCalls, 0); expect(service.retryCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
