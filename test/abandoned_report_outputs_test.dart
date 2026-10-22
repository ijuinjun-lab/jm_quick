import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';
import 'package:jm_quick/confirmed/reception_status_summary.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';

Map<String, dynamic> synthetic({bool used = false}) => {
  'eventId': 'synthetic', 'eventName': '架空集計',
  'programs': [{'programId': 'dog', 'name': '犬'}, {'programId': 'talk', 'name': 'トーク'}],
  'participants': [
    {'participantId': 'old', 'name': '監査用', 'status': 'active', 'batchCommitted': false,
      'programs': [{'programId': 'dog', 'plannedCount': 99, 'checkedIn': used, 'attendedCount': used ? 3 : null}]},
    {'participantId': 'valid', 'name': '有効申込', 'status': 'active', 'batchCommitted': true,
      'programs': [{'programId': 'dog', 'plannedCount': 3, 'checkedIn': true, 'attendedCount': 2},
        {'programId': 'talk', 'plannedCount': 4, 'checkedIn': false}]},
  ],
};

void verify(Map<String, dynamic> json, {required int applications, required int planned, required int attended, required int auditRows}) {
  final report = AttendanceReport.fromJson(json);
  final status = buildReceptionStatus(report);
  expect(status.totals.applications, applications);
  expect(status.totals.plannedTotal, planned);
  expect(status.totals.attendedTotal, attended);
  final at = DateTime.utc(2026, 11, 30);
  final file = buildAttendanceReportXlsx(report, exportedAt: at);
  final sheets = readXlsxSheets(file.bytes);
  final info = {for (final r in sheets[1].rows.skip(1)) r[0]: r[1]};
  expect(file.participantCount, applications);
  expect(info['参加者数'], '$applications');
  expect(info['予定人数（プログラム別延べ人数）'], '$planned');
  expect(info['実来場人数（プログラム別延べ人数）'], '$attended');
  expect(info['集計対象外の明細行数'], '$auditRows');
  expect(sheets.first.rows.length - 1, applications + auditRows);
  final headers = sheets.first.rows.first;
  int excelPlanned = 0;
  for (final row in sheets.first.rows.skip(1)) {
    for (final program in report.programs) {
      final i = headers.indexOf('${program.name}：予定人数');
      excelPlanned += int.tryParse(i < row.length ? row[i] : '') ?? 0;
    }
  }
  expect(excelPlanned, planned, reason: '監査行を含む明細の予定人数を合計しても正式集計と一致');
  if (status.rows.isNotEmpty) {
    final csv = buildReceptionStatusCsv(eventId: report.eventId, rows: status.rows, exportedAt: at,
      conditions: ReceptionStatusCsvConditions(eventName: report.eventName, dataUpdatedAt: at));
    final rows = const CsvToListConverter(shouldParseNumbers: false).convert(utf8.decode(csv.bytes).replaceFirst('\ufeff', ''));
    final head = rows.indexWhere((r) => r.isNotEmpty && r.first == '氏名');
    final data = rows.skip(head + 1).where((r) => r.length >= 8).toList();
    expect(data.length, status.rows.length, reason: 'CSVの明細は申込×プログラム単位');
    expect(data.fold<int>(0, (n, r) => n + (int.tryParse('${r[4]}') ?? 0)), planned);
    expect(data.fold<int>(0, (n, r) => n + (int.tryParse('${r[5]}') ?? 0)), attended);
    for (final program in status.programs) {
      final programRows = data.where((r) => r[2] == program.name);
      expect(programRows.fold<int>(0, (n, r) => n + (int.tryParse('${r[4]}') ?? 0)), program.plannedTotal);
      expect(info['${program.name}：予定人数'], '${program.plannedTotal}');
      expect(info['${program.name}：実来場人数'], '${program.attendedTotal}');
    }
  } else {
    expect(applications, 0);
  }
}

void main() {
  for (final used in [false, true]) {
    test('監査行は正式件数・予定人数から除外し、過去実績は変更しない used=$used', () {
      final data = synthetic(used: used), before = jsonEncode(synthetic(used: used));
      verify(data, applications: 1, planned: 7, attended: 2, auditRows: 1);
      expect(jsonEncode(data), before);
      final sheets = readXlsxSheets(buildAttendanceReportXlsx(AttendanceReport.fromJson(data), exportedAt: DateTime.utc(2026)).bytes);
      final headers = sheets.first.rows.first, audit = sheets.first.rows[1];
      expect(audit[headers.indexOf('犬：参加予定')], '対象外');
      expect(audit[headers.indexOf('犬：予定人数')], '');
      expect(audit[headers.indexOf('犬：実来場人数')], used ? '3' : '');
      expect(audit[headers.indexOf('犬：受付')], used ? '受付済' : '未受付');
    });
  }
  final path = Platform.environment['JM_M1_REPORT_FIXTURE'];
  if (path != null) {
    final actual = jsonDecode(File(path).readAsStringSync()) as List;
    for (final item in actual) {
      test('Emulatorの正式取込・放棄・再取込結果から一覧/CSV/Excelまで一致 ${item['eventId']}', () {
        final id = item['eventId'];
        verify(Map<String, dynamic>.from(item['output'] as Map),
          applications: id == 'm1A' || id == 'm1B' ? 2 : 0,
          planned: id == 'm1A' ? 14 : id == 'm1B' ? 6 : 0,
          attended: id == 'm1A' ? 5 : 0, auditRows: id == 'm1A' ? 0 : 1);
      });
    }
  }
}
