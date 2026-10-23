import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/qualification_change_dialog.dart';
import 'package:jm_quick/confirmed/qualification_change_service.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/reception_status_page.dart';
import 'package:jm_quick/confirmed/reception_status_summary.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';

class Changes implements QualificationChangeService, AttendanceReportService {
  final requests = <Map<String, dynamic>>[];
  bool failOnce = true;
  bool onlyOne = false;
  int reads = 0;
  @override
  Future<Map<String, dynamic>> getQualifications(
    String eventId,
    String participantId,
  ) async => {
    'name': '架空田中',
    'email': 'tanaka@example.invalid',
    'fingerprint': 'a' * 64,
    'busy': false,
    'activeQualificationCount': onlyOne ? 1 : 2,
    'mapping': {'catProgramId': 'cat', 'dogProgramId': 'dog'},
    'programs': [
      {'programId': 'cat', 'name': '猫'},
      {'programId': 'dog', 'name': '犬'},
      {'programId': 'talk', 'name': 'トーク'},
    ],
    'qualifications': [
      {
        'programId': 'cat',
        'entitlementStatus': 'active',
        'plannedCount': 2,
        'slotLabel': '10:10-10:50',
        'checkedIn': false,
      },
      if (!onlyOne)
        {
          'programId': 'talk',
          'entitlementStatus': 'active',
          'plannedCount': 2,
          'slotLabel': '13:00-14:00',
          'checkedIn': true,
        },
    ],
  };
  @override
  Future<void> changeQualification(Map<String, dynamic> request) async {
    requests.add(Map.of(request));
    if (failOnce) {
      failOnce = false;
      throw Exception('response lost');
    }
  }

  @override
  Future<AttendanceReport> getReport(String eventId) async {
    reads++;
    return report;
  }
}

final report = AttendanceReport.fromJson({
  'eventId': 'event1',
  'eventName': '架空イベント',
  'programs': [
    {'programId': 'cat', 'name': '猫'},
    {'programId': 'dog', 'name': '犬'},
    {'programId': 'talk', 'name': 'トーク'},
  ],
  'participants': [
    {
      'participantId': 'batchA-000002',
      'name': '架空田中',
      'email': 'tanaka@example.invalid',
      'status': 'active',
      'batchCommitted': true,
      'programs': [
        {
          'programId': 'cat',
          'plannedCount': 2,
          'checkedIn': false,
          'entitlementStatus': 'revoked',
        },
        {
          'programId': 'dog',
          'plannedCount': 2,
          'timeText': '14:10-14:50',
          'checkedIn': false,
        },
        {'programId': 'talk', 'plannedCount': 2, 'checkedIn': false},
      ],
    },
  ],
});
void main() {
  for (final onlyOne in [true, false]) {
    testWidgets('last qualification warning: $onlyOne', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = Changes()..onlyOne = onlyOne;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => QualificationChangeDialog(
                    service: service,
                    eventId: 'event1',
                    participantId: 'batchA-000002',
                  ),
                ),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('猫').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '変更理由（必須）'),
        '本人希望',
      );
      await tester.tap(find.text('確認へ'));
      await tester.pumpAndSettle();
      const warning =
          'この資格を取り消すと、有効な参加資格がなくなり、Web参加証は利用できなくなります。QRコード自体は変更されませんが、受付には使用できません。';
      expect(find.text(warning), onlyOne ? findsOneWidget : findsNothing);
      await tester.tap(find.text('戻る'));
      await tester.pumpAndSettle();
      expect(service.requests, isEmpty);
      if (onlyOne) {
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '変更先時間（HH:mm-HH:mm）'),
          '14:10-14:50',
        );
        await tester.tap(find.text('確認へ'));
        await tester.pumpAndSettle();
        expect(
          find.text(warning),
          findsNothing,
          reason: 'A swap retains an active qualification',
        );
      }
    });
  }
  testWidgets(
    'list selects participant; confirmed swap retries the exact operation without edits',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => QualificationChangeDialog(
                    service: changes,
                    eventId: 'event1',
                    participantId: 'batchA-000002',
                  ),
                ),
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      expect(find.text('架空田中 / tanaka@example.invalid'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('猫').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '変更先時間（HH:mm-HH:mm）'),
        '14:10-14:50',
      );
      await tester.enterText(find.widgetWithText(TextField, '変更先の予定人数'), '2');
      await tester.enterText(
        find.widgetWithText(TextField, '変更理由（必須）'),
        '本人希望',
      );
      await tester.tap(find.text('確認へ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(changes.requests.length, 1);
      await tester.tap(find.text('同じ操作を再試行'));
      await tester.pumpAndSettle();
      expect(changes.requests.length, 2);
      expect(changes.requests[1], changes.requests[0]);
      expect(changes.requests[0]['targetProgramId'], 'dog');
      expect(changes.requests[0].containsKey('publicId'), false);
    },
  );
  testWidgets('name in reception list opens qualification selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = Changes();
    await tester.pumpWidget(
      MaterialApp(
        home: ReceptionStatusPage(
          eventId: 'event1',
          eventName: '架空イベント',
          service: service,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '架空田中').first);
    await tester.pumpAndSettle();
    expect(find.text('参加資格の変更・取消'), findsOneWidget);
  });
  test(
    'cancelled cat is excluded from planned totals and retained in CSV and Excel',
    () {
      final now = DateTime.utc(2026, 10, 1);
      final status = buildReceptionStatus(report, judgedAt: now);
      expect(
        status.rows.where((r) => !r.revoked).map((r) => r.programId).toSet(),
        {'dog', 'talk'},
      );
      expect(
        status.rows.firstWhere((r) => r.programId == 'cat').plannedCount,
        0,
      );
      final csv = buildReceptionStatusCsv(
        eventId: 'event1',
        rows: status.rows,
        exportedAt: now,
        conditions: ReceptionStatusCsvConditions(
          eventName: '架空イベント',
          dataUpdatedAt: now,
        ),
      );
      expect(utf8.decode(csv.bytes), contains('取消'));
      final xlsx = buildAttendanceReportXlsx(report, exportedAt: now);
      final cells = readXlsxSheets(
        xlsx.bytes,
      ).expand((s) => s.rows).expand((r) => r).toList();
      expect(cells, contains('資格取消'));
      expect(cells, contains('犬：参加予定'));
      expect(cells, contains('14:10-14:50'));
    },
  );
}

final changes = Changes();
