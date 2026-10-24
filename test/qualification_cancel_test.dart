import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/qualification_change_dialog.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/reception_status_summary.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';
import 'qualification_management_ui_test.dart' show ManagementFake;

class CancelFake extends ManagementFake {
  CancelFake() {
    rows.clear();
    for (final (i, id) in ['cat', 'dog', 'talk'].indexed) {
      rows.add({
        'programId': id,
        'slotLabel': ['11:50-12:30', '15:30-16:10', '13:00-14:00'][i],
        'plannedCount': i + 1,
        'checkedIn': false,
        'entitlementStatus': 'active',
      });
    }
  }
  @override
  Future<Map<String, dynamic>> getQualifications(
    String eventId,
    String participantId,
  ) async {
    final result = await super.getQualifications(eventId, participantId);
    return {
      ...result,
      'qualifications': rows.map((q) => Map<String, dynamic>.of(q)).toList(),
      'history': history.map((h) => Map<String, dynamic>.of(h)).toList(),
    };
  }

  bool loseResponse = false;
  @override
  Future<void> changeQualification(Map<String, dynamic> r) async {
    requests.add(Map.of(r));
    if (history.any((h) => h['operationId'] == r['operationId'])) return;
    final before = rows.map((q) => Map<String, dynamic>.of(q)).toList();
    for (final q in rows) {
      if (r['action'] == 'cancelAll' || q['programId'] == r['programId']) {
        q['entitlementStatus'] = 'revoked';
      }
    }
    history.insert(0, {
      'operationId': r['operationId'],
      'reason': r['reason'],
      'changedBy': 'manager',
      'changedAt': '2026-10-24',
      'before': before,
      'after': rows.map((q) => Map<String, dynamic>.of(q)).toList(),
    });
    if (loseResponse) {
      loseResponse = false;
      throw Exception('response lost');
    }
  }
}

Future<void> mount(WidgetTester tester, CancelFake service, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: Scaffold(
        body: QualificationChangeDialog(
          service: service,
          eventId: 'event',
          participantId: 'person',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Finder cancelButton(String id) =>
    id == 'all' ? find.text('参加をすべてキャンセル') : find.byKey(ValueKey('cancel-$id'));

void main() {
  for (final size in [const Size(1280, 900), const Size(390, 500)]) {
    for (final target in ['cat', 'dog', 'talk', 'all']) {
      testWidgets(
        'direct cancellation $target: confirmation, released slots and manual notice $size',
        (tester) async {
          final service = CancelFake();
          await mount(tester, service, size);
          await tap(tester, cancelButton(target));
          expect(find.text('理由：本人からのキャンセル'), findsOneWidget);
          expect(find.textContaining('取消対象\n'), findsOneWidget);
          expect(find.textContaining('変更前\n'), findsOneWidget);
          expect(find.textContaining('変更後\n'), findsOneWidget);
          final released = tester
              .widget<Text>(find.textContaining('空く参加枠（プログラム・時間枠ごと）'))
              .data!;
          for (final (i, id) in ['cat', 'dog', 'talk'].indexed) {
            expect(
              released.contains(
                '${['猫', '犬', 'トーク'][i]} ${service.rows[i]['slotLabel']} ${i + 1}名',
              ),
              target == 'all' || target == id,
            );
          }
          expect(
            find.descendant(
              of: find.byType(AlertDialog).last,
              matching: find.byType(DropdownButtonFormField<String>),
            ),
            findsNothing,
          );
          expect(service.requests, isEmpty);
          await tap(tester, find.text('戻る'));
          expect(service.requests, isEmpty);
          await tap(tester, cancelButton(target));
          await tap(tester, find.text('確定'));
          expect(service.requests.length, 1);
          expect(service.requests.single['reason'], '本人からのキャンセル');
          expect(
            service.requests.single['action'],
            target == 'all' ? 'cancelAll' : 'cancel',
          );
          expect(
            service.requests.single.containsKey('programId'),
            target != 'all',
          );
          for (final q in service.rows) {
            expect(
              q['entitlementStatus'] == 'revoked',
              target == 'all' || q['programId'] == target,
            );
          }
          expect(service.sends, 0);
          expect(service.history.length, 1);
          await tap(tester, find.byType(ExpansionTile).first);
          await tap(tester, find.text('変更通知を確認・手動送信'));
          expect(
            find.textContaining('宛先：only@example.invalid'),
            findsOneWidget,
          );
          expect(service.sends, 0);
          await tap(tester, find.text('この本人に送信'));
          expect(service.sends, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'cancel reason override, required detail, checked-in lock and lost response $size',
      (tester) async {
        final service = CancelFake()..loseResponse = true;
        await mount(tester, service, size);
        await tap(tester, cancelButton('all'));
        await tap(tester, find.text('理由を変更'));
        final confirm = find.byType(AlertDialog).last;
        final field = find.descendant(
          of: confirm,
          matching: find.byType(DropdownButtonFormField<String>),
        );
        await tap(tester, field);
        await tap(tester, find.text('その他').last);
        await tap(tester, find.text('確定'));
        expect(service.requests, isEmpty);
        final detail = find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.byType(TextFormField),
        );
        await tester.ensureVisible(detail);
        await tester.enterText(detail, '事務局の判断');
        await tap(tester, find.text('確定'));
        expect(service.requests.single['reason'], 'その他：事務局の判断');
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '参加をすべてキャンセル'),
              )
              .onPressed,
          isNull,
        );
        await tap(tester, find.text('同じ操作を再試行'));
        expect(service.requests.length, 2);
        expect(service.requests[0], service.requests[1]);
        expect(service.history.length, 1);
        expect(service.sends, 0);
        await tester.pumpWidget(const SizedBox());
        final locked = CancelFake();
        locked.rows.last['checkedIn'] = true;
        await mount(tester, locked, size);
        expect(
          tester.widget<TextButton>(cancelButton('talk')).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '参加をすべてキャンセル'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester.widget<TextButton>(cancelButton('cat')).onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final cancelled in [
    {'cat'},
    {'dog'},
    {'talk'},
    {'cat', 'dog', 'talk'},
  ]) {
    test(
      'cancel $cancelled: program/time planned totals, CSV and Excel preserve other slots',
      () {
        final now = DateTime.utc(2026, 10, 24), ids = ['cat', 'dog', 'talk'];
        final report = AttendanceReport.fromJson({
          'eventId': 'event',
          'eventName': '架空イベント',
          'programs': [
            for (final id in ids) {'programId': id, 'name': id},
          ],
          'participants': [
            {
              'participantId': 'person',
              'name': '架空',
              'status': 'active',
              'batchCommitted': true,
              'programs': [
                for (final (i, id) in ids.indexed)
                  {
                    'programId': id,
                    'plannedCount': i + 1,
                    'timeText': '10:00-11:00',
                    'entitlementStatus': cancelled.contains(id)
                        ? 'revoked'
                        : 'active',
                    'checkedIn': false,
                  },
              ],
            },
            {
              'participantId': 'other',
              'name': '別参加者',
              'status': 'active',
              'batchCommitted': true,
              'programs': [
                {
                  'programId': 'cat',
                  'plannedCount': 9,
                  'timeText': '12:00-13:00',
                  'checkedIn': false,
                },
              ],
            },
          ],
        });
        final status = buildReceptionStatus(report, judgedAt: now);
        for (final (i, id) in ids.indexed) {
          final p = status.programs.singleWhere((p) => p.programId == id);
          expect(
            p.plannedTotal,
            (cancelled.contains(id) ? 0 : i + 1) + (id == 'cat' ? 9 : 0),
          );
          expect(
            p.slots
                .where((s) => s.label == '10:00-11:00')
                .fold<int>(0, (sum, s) => sum + s.plannedTotal),
            cancelled.contains(id) ? 0 : i + 1,
          );
        }
        final csv = buildReceptionStatusCsv(
          eventId: 'event',
          rows: status.rows,
          exportedAt: now,
          conditions: ReceptionStatusCsvConditions(
            eventName: '架空',
            dataUpdatedAt: now,
          ),
        );
        expect(utf8.decode(csv.bytes), contains('取消'));
        final cells = readXlsxSheets(
          buildAttendanceReportXlsx(report, exportedAt: now).bytes,
        ).expand((s) => s.rows).expand((r) => r).toList();
        expect(cells, contains('資格取消'));
        expect(cells, contains('12:00-13:00'));
        for (final id in ids.where((id) => !cancelled.contains(id))) {
          expect(cells, contains('$id：参加予定'));
        }
      },
    );
  }
}
