import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';
import 'package:jm_quick/confirmed/reception_status_summary.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';

const types = ['dog', 'cat', 'dog_cat', 'talk', 'dog_talk', 'cat_talk', 'dog_cat_talk'];
const ids = {'dog': 'program-2', 'cat': 'program-1', 'talk': 'program-3'};
const counts = {'dog': 3, 'cat': 2, 'talk': 4};
const times = {'dog': '14:10-14:50', 'cat': '10:10-10:50', 'talk': '16:00〜17:00'};

Map<String, dynamic> fixture(String type) => {
  'eventId': 'synthetic', 'eventName': '架空イベント',
  'programs': [for (final role in ids.keys) {'programId': ids[role], 'name': role, 'inEvent': true}],
  'participants': [{
    'participantId': 'synthetic-1', 'name': '架空申込', 'email': 'test@example.invalid', 'status': 'active',
    'batchCommitted': true, 'notificationType': 'normal',
    'programs': [for (final role in type.split('_')) {
      'programId': ids[role], 'plannedCount': counts[role], 'timeText': times[role], 'checkedIn': false,
      'notificationType': role == 'talk' ? 'normal' : 'waitlistPromotion',
    }],
  }],
};

void main() {
  final path = Platform.environment['JM_QR_REPORT_FIXTURE'];
  final actual = path == null ? null : jsonDecode(File(path).readAsStringSync()) as List;
  for (final type in types) {
    test('$type: 申込1件・プログラム別人数・時間・当選区分が一覧/CSV/Excelで一致', () {
      final json = actual == null ? fixture(type)
          : Map<String, dynamic>.from((actual.firstWhere((x) => x['type'] == type) as Map)['output'] as Map);
      final report = AttendanceReport.fromJson(json);
      final status = buildReceptionStatus(report);
      final roles = type.split('_');
      expect(status.totals.applications, 1);
      expect(status.totals.plannedTotal, roles.fold<int>(0, (n, r) => n + counts[r]!));
      expect(status.rows.length, roles.length);
      final at = DateTime.utc(2026, 11, 1);
      final csv = buildReceptionStatusCsv(eventId: report.eventId, rows: status.rows, exportedAt: at,
          conditions: ReceptionStatusCsvConditions(eventName: report.eventName, dataUpdatedAt: at));
      final lines = const CsvToListConverter(shouldParseNumbers: false).convert(utf8.decode(csv.bytes).replaceFirst('\ufeff', ''));
      final headerIndex = lines.indexWhere((r) => r.isNotEmpty && r.first == '氏名');
      final csvRows = lines.skip(headerIndex + 1).where((r) => r.length >= 8).toList();
      expect(csvRows.length, roles.length);
      final file = buildAttendanceReportXlsx(report, exportedAt: at);
      final sheets = readXlsxSheets(file.bytes);
      expect(sheets.map((s) => s.name), ['最終実績', '出力情報']);
      final headers = sheets.first.rows[0], values = sheets.first.rows[1];
      expect(sheets.first.rows.length, 2);
      for (final role in roles) {
        final program = report.programs.firstWhere((p) => p.programId == ids[role]);
        final row = csvRows.firstWhere((r) => r[2] == program.name);
        expect(row[3], times[role]);
        expect(row[4], counts[role].toString());
        expect(values[headers.indexOf('${program.name}：予定時間')], times[role]);
        expect(values[headers.indexOf('${program.name}：予定人数')], counts[role].toString());
        expect(values[headers.indexOf('${program.name}：当選区分')], role == 'talk' ? '通常当選' : '繰り上げ当選');
      }
    });
  }
  test('資格取消は予定人数から除外し、実際の受付人数と申込は維持する', () {
    final data = fixture('dog_talk');
    final programs = ((data['participants'] as List).single as Map)['programs'] as List;
    (programs.first as Map).addAll(<String, Object?>{'entitlementStatus': 'revoked', 'checkedIn': true, 'attendedCount': 2});
    final report = AttendanceReport.fromJson(data);
    final status = buildReceptionStatus(report);
    expect(status.totals.applications, 1);
    expect(status.totals.plannedTotal, 4);
    expect(status.totals.attendedTotal, 2);
    expect(status.rows.firstWhere((r) => r.programId == ids['dog']).revoked, true);
    (programs.first as Map).addAll(<String, Object?>{'checkedIn': false, 'attendedCount': null});
    final cancelled = buildReceptionStatus(AttendanceReport.fromJson(data),
      judgedAt: DateTime.utc(2027), eventEndAt: DateTime.utc(2026));
    expect(cancelled.rows.firstWhere((r) => r.programId == ids['dog']).state, ReceptionAttendanceState.cancelled);
    expect(cancelled.programs.firstWhere((r) => r.programId == ids['dog']).entries, 0);
  });
}
