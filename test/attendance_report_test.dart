// 最終実績Excel出力。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて架空(メールは .invalid)。
//  - xlsxの書き出し(文字列を数値・数式にしない・日時・先頭行固定・オートフィルター)を、取込用の読み取り器で読み戻して確認
//  - 第5回相当(HEBEL: ハウス3・メゾン2・いいえ5)+ 未知・空欄・属性なし・同じメールの別participant・受付済/未受付・
//    複数program・人数訂正後の値・受付取消(未受付)・0 participant・特殊文字を含むイベント名
//  - 画面: 説明文・出力ボタン・保存(ダウンロード)・エラー表示。/console のイベント管理画面からの入口
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/attendance_report_page.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';
import 'package:jm_quick/confirmed/xlsx_writer.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'reception_staff_key_fake.dart';
import 'reminder_test.dart' show FakeReminderService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService;

const _haus = 'ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）';
const _maison = 'ヘーベルメゾンにお住まい';
const _none = '該当なし（いいえ）';

/// サーバー(getConfirmedAttendanceReport)と同じ形の応答。
Map<String, dynamic> _reportJson({String eventName = '架空イベント/最終実績:テスト*?'}) {
  Map<String, dynamic> hebel(String category, String label, [String? raw]) => {
    'category': category,
    'label': label,
    'rawValue': ?raw,
  };
  Map<String, dynamic> entry(
    String programId, {
    int planned = 2,
    String? time,
    bool checkedIn = false,
    int? attended,
    String? at,
  }) => {
    'programId': programId,
    'plannedCount': planned,
    'timeText': time,
    'checkedIn': checkedIn,
    'attendedCount': attended,
    'checkedInAt': at,
  };
  Map<String, dynamic> person(
    int i, {
    int sequence = 5,
    Map<String, dynamic>? hebelResidence,
    List<Map<String, dynamic>> programs = const [],
    String? email,
  }) => {
    'participantId': 'p${i.toString().padLeft(2, '0')}',
    'importSequence': sequence,
    'batchCommitted': true,
    'importRow': i + 1,
    'name': '架空 参加者$i',
    'kana': 'かくう',
    'email': email ?? 'report$i@example.invalid',
    'status': 'active',
    'hebelResidence': ?hebelResidence,
    'programs': programs,
  };
  const hebels = [
    _haus,
    _haus,
    _haus,
    _maison,
    _maison,
    _none,
    _none,
    _none,
    _none,
    _none,
  ];
  const categories = [
    'hebelHaus',
    'hebelHaus',
    'hebelHaus',
    'hebelMaison',
    'hebelMaison',
    'none',
    'none',
    'none',
    'none',
    'none',
  ];
  return {
    'eventId': 'evReport0123456789',
    'eventName': eventName,
    'programs': [
      {'programId': 'program-1', 'name': '架空の譲渡会A', 'inEvent': true},
      {'programId': 'program-2', 'name': '架空の譲渡会B', 'inEvent': true},
      {'programId': 'program-3', 'name': '架空トーク', 'inEvent': true},
    ],
    'participants': [
      for (var i = 1; i <= 10; i++)
        person(
          i,
          hebelResidence: hebel(categories[i - 1], hebels[i - 1]),
          programs: switch (i) {
            // 受付済み(人数は訂正後の3)+ 2つ目のprogramも受付済み
            1 => [
              entry(
                'program-1',
                time: '10:30-11:10',
                checkedIn: true,
                attended: 3,
                at: '2026-11-30T01:23:45.000Z',
              ),
              entry(
                'program-3',
                planned: 1,
                checkedIn: true,
                attended: 1,
                at: '2026-11-30T05:00:00.000Z',
              ),
            ],
            // 受付取消(正本では未受付に戻っている)
            2 => [entry('program-1', time: '10:30-11:10')],
            // 3program
            5 => [
              entry('program-1', time: '10:30-11:10'),
              entry(
                'program-2',
                planned: 3,
                time: '14:10-14:50',
                checkedIn: true,
                attended: 4,
                at: '2026-11-30T05:10:00.000Z',
              ),
              entry('program-3', planned: 1),
            ],
            _ => [entry('program-2', planned: 3, time: '14:10-14:50')],
          },
        ),
      person(
        11,
        sequence: 6,
        hebelResidence: hebel('unknown', '未知のHEBEL属性', '架空の未知の回答'),
        programs: [entry('program-1')],
      ),
      person(
        12,
        sequence: 6,
        hebelResidence: hebel('unset', '未設定（空欄）'),
        programs: [entry('program-1')],
      ),
      // HEBEL列の無い取込(属性なし)。1人目と同じメールアドレスの別participant
      person(
        13,
        sequence: 7,
        email: 'report1@example.invalid',
        programs: [entry('program-2')],
      ),
      // programの無いparticipant
      person(14, sequence: 7),
    ],
  };
}

AttendanceReport _report({String? eventName}) => AttendanceReport.fromJson(
  jsonDecode(
        jsonEncode(_reportJson(eventName: eventName ?? '架空イベント/最終実績:テスト*?')),
      )
      as Map<String, dynamic>,
);

/// 書き出したxlsxを、取込用の読み取り器で読み戻す(1シート)。
XlsxSheet _readBack(Uint8List bytes) {
  final sheets = readXlsxSheets(bytes);
  expect(sheets.length, 1);
  return sheets.single;
}

String _part(Uint8List bytes, String name) => utf8.decode(
  ZipDecoder()
      .decodeBytes(bytes)
      .files
      .firstWhere((f) => f.name == name)
      .readBytes()!,
);

class _FakeReportService implements AttendanceReportService {
  _FakeReportService({this.report, this.error});
  final AttendanceReport? report;
  final Object? error;
  final calls = <String>[];
  @override
  Future<AttendanceReport> getReport(String eventId) async {
    calls.add(eventId);
    if (error != null) throw error!;
    return report!;
  }
}

void main() {
  group('xlsxの書き出し', () {
    test('文字列は文字列のまま(数値・数式・エスケープ表記にしない)。数値・日時は値として読める', () {
      final bytes = buildXlsx(
        sheetName: 'テスト',
        columns: const [
          (header: '文字', width: 10),
          (header: '数値', width: 10),
          (header: '日時', width: 20),
        ],
        rows: [
          ['00123', 3, XlsxDateTime(DateTime.utc(2026, 11, 30, 10, 23, 45))],
          ['=1+1', 2.5, null],
          ['_x0041_ & <a> "q"\u0001', null, null],
          [null, null, null],
        ],
      );
      final sheet = _readBack(bytes);
      expect(sheet.rows[0], ['文字', '数値', '日時']);
      expect(sheet.rows[1], ['00123', '3', '2026-11-30 10:23:45']);
      expect(sheet.rows[2], ['=1+1', '2.5']);
      expect(sheet.rows[3], [
        '_x0041_ & <a> "q"',
      ], reason: '制御文字はXMLに入れられないため除く');
      expect(sheet.formulaCellCount, 0);
      final xml = _part(bytes, 'xl/worksheets/sheet1.xml');
      expect(xml, contains('t="inlineStr"'));
      expect(RegExp('<f>').hasMatch(xml), isFalse, reason: '数式のセルは作らない');
    });

    test('先頭行の固定・オートフィルター・列幅・列名の太字・日時の書式', () {
      final bytes = buildXlsx(
        sheetName: '最終実績',
        columns: const [(header: 'A', width: 8), (header: 'B', width: 30)],
        rows: const [
          ['x', 1],
          ['y', 2],
        ],
      );
      final xml = _part(bytes, 'xl/worksheets/sheet1.xml');
      expect(
        xml,
        contains(
          '<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>',
        ),
      );
      expect(xml, contains('<autoFilter ref="A1:B3"/>'));
      expect(
        xml,
        contains('<col min="2" max="2" width="30.0" customWidth="1"/>'),
      );
      expect(xml, contains('<c r="A1" t="inlineStr" s="1">'));
      expect(_part(bytes, 'xl/workbook.xml'), contains("'最終実績'!\$A\$1:\$B\$3"));
      expect(
        _part(bytes, 'xl/styles.xml'),
        contains('formatCode="yyyy/mm/dd hh:mm:ss"'),
      );
    });
  });

  group('最終実績 → Excel', () {
    test('列: 固定列 → programごとの6列(イベントの表示順・program名はイベント設定から)→ イベント来場状況', () {
      final file = buildAttendanceReportXlsx(
        _report(),
        exportedAt: DateTime.utc(2026, 11, 30, 16, 0),
      );
      final header = _readBack(file.bytes).rows.first;
      expect(header, [
        '取込回',
        '氏名',
        'かな',
        'メールアドレス',
        'HEBEL属性',
        '参加者状態',
        for (final name in ['架空の譲渡会A', '架空の譲渡会B', '架空トーク'])
          for (final s in ['参加予定', '予定人数', '予定時間', '受付', '実来場人数', '受付時刻'])
            '$name：$s',
        'イベント来場状況',
      ]);
      expect(header.length, 6 + 3 * 6 + 1);
    });

    test(
      '参加者全員(未来場・属性なし・programなし・同じメールの別participant)を1行ずつ。HEBEL属性は受付画面と同じ表示',
      () {
        final file = buildAttendanceReportXlsx(
          _report(),
          exportedAt: DateTime.utc(2026, 11, 30),
        );
        final rows = _readBack(file.bytes).rows.skip(1).toList();
        expect(file.participantCount, 14);
        expect(rows.length, 14);
        String col(List<String> r, int i) => i < r.length ? r[i] : '';
        final hebel = <String, int>{};
        for (final r in rows) {
          hebel[col(r, 4)] = (hebel[col(r, 4)] ?? 0) + 1;
        }
        expect(hebel, {
          _haus: 3,
          _maison: 2,
          _none: 5,
          '未知のHEBEL属性（原文：架空の未知の回答）': 1,
          '未設定（空欄）': 1,
          '': 2,
        });
        expect(rows.map((r) => col(r, 0)).toList(), [
          ...List.filled(10, '5'),
          '6',
          '6',
          '7',
          '7',
        ]);
        expect(
          rows.where((r) => col(r, 3) == 'report1@example.invalid').length,
          2,
          reason: '同じメールでも統合しない',
        );
        expect(rows.every((r) => col(r, 5) == '有効'), isTrue);
      },
    );

    test('予定人数・予定時間・受付済/未受付・実来場人数(訂正後)・受付時刻(日本時間)・受付取消・イベント来場状況', () {
      final rows = _readBack(
        buildAttendanceReportXlsx(
          _report(),
          exportedAt: DateTime.utc(2026, 11, 30),
        ).bytes,
      ).rows;
      final header = rows.first;
      String cell(int row, String name) {
        final r = rows[row];
        final i = header.indexOf(name);
        return i < r.length ? r[i] : '';
      }

      // 1人目: 譲渡会A 受付済み(訂正後の3名)・トークも受付済み
      expect(cell(1, '架空の譲渡会A：参加予定'), 'あり');
      expect(cell(1, '架空の譲渡会A：予定人数'), '2');
      expect(cell(1, '架空の譲渡会A：予定時間'), '10:30-11:10');
      expect(cell(1, '架空の譲渡会A：受付'), '受付済');
      expect(cell(1, '架空の譲渡会A：実来場人数'), '3');
      expect(
        cell(1, '架空の譲渡会A：受付時刻'),
        '2026-11-30 10:23:45',
        reason: 'UTC 01:23:45 → 日本時間 10:23:45',
      );
      expect(cell(1, '架空の譲渡会B：参加予定'), 'なし');
      expect(cell(1, '架空の譲渡会B：受付'), '');
      expect(cell(1, '架空トーク：受付'), '受付済');
      expect(cell(1, 'イベント来場状況'), '受付あり');
      // 2人目: 受付取消(未受付)・実来場人数と受付時刻は空
      expect(cell(2, '架空の譲渡会A：受付'), '未受付');
      expect(cell(2, '架空の譲渡会A：実来場人数'), '');
      expect(cell(2, '架空の譲渡会A：受付時刻'), '');
      expect(cell(2, 'イベント来場状況'), '未来場');
      // 5人目: 3programの横展開
      expect(cell(5, '架空の譲渡会A：受付'), '未受付');
      expect(cell(5, '架空の譲渡会B：受付'), '受付済');
      expect(cell(5, '架空の譲渡会B：実来場人数'), '4');
      expect(cell(5, '架空トーク：参加予定'), 'あり');
      expect(cell(5, 'イベント来場状況'), '受付あり');
      // programの無いparticipantは判定不能(空欄)
      expect(cell(14, 'イベント来場状況'), '');
      final statuses = rows.skip(1).map((r) => r.last).toList();
      expect(statuses.where((s) => s == '受付あり').length, 2);
    });

    test('受付時刻はExcelの日時の値(書式つき)。人数は数値。氏名等は文字列のセル', () {
      final bytes = buildAttendanceReportXlsx(
        _report(),
        exportedAt: DateTime.utc(2026, 11, 30),
      ).bytes;
      final xml = _part(bytes, 'xl/worksheets/sheet1.xml');
      // 1人目の譲渡会A: 実来場人数(K2)は数値、受付時刻(L2)は日時の書式(s=2)
      expect(xml, contains('<c r="K2"><v>3</v></c>'));
      expect(RegExp(r'<c r="L2" s="2"><v>46356\.433').hasMatch(xml), isTrue);
      expect(xml, contains('<c r="B2" t="inlineStr">'));
    });

    test('ファイル名: JM_Quick_イベント名_最終実績_YYYYMMDD.xlsx(日本時間の日付・使えない文字は「_」)', () {
      final file = buildAttendanceReportXlsx(
        _report(),
        exportedAt: DateTime.utc(2026, 11, 30, 16, 0),
      );
      expect(file.fileName, 'JM_Quick_架空イベント_最終実績_テスト___最終実績_20261201.xlsx');
      expect(
        attendanceReportFileName('  ', DateTime.utc(2026, 1, 1)),
        'JM_Quick_イベント_最終実績_20260101.xlsx',
      );
    });

    test('0 participant: 列名だけのExcelを出力できる', () {
      final empty = AttendanceReport.fromJson({
        ..._reportJson(),
        'participants': <Object>[],
      });
      final file = buildAttendanceReportXlsx(
        empty,
        exportedAt: DateTime.utc(2026, 11, 30),
      );
      final sheet = _readBack(file.bytes);
      expect(file.participantCount, 0);
      expect(sheet.rows.length, 1);
      expect(
        _part(file.bytes, 'xl/worksheets/sheet1.xml'),
        contains('<autoFilter ref="A1:Y1"/>'),
      );
    });

    test('イベント設定に無いprogram・同じ名前のprogramも列として区別する。HEBEL属性の無いイベントでも出力できる', () {
      final json = _reportJson();
      json['programs'] = [
        {'programId': 'program-1', 'name': '同名', 'inEvent': true},
        {'programId': 'program-2', 'name': '同名', 'inEvent': true},
        {'programId': 'gone', 'name': 'gone', 'inEvent': false},
      ];
      for (final p in json['participants'] as List) {
        (p as Map).remove('hebelResidence');
      }
      final rows = _readBack(
        buildAttendanceReportXlsx(
          AttendanceReport.fromJson(json),
          exportedAt: DateTime.utc(2026),
        ).bytes,
      ).rows;
      expect(
        rows.first,
        containsAll([
          '同名：参加予定',
          '同名（program-2）：参加予定',
          'gone（イベント設定に無いprogram）：参加予定',
        ]),
      );
      expect(rows.skip(1).every((r) => r.length < 5 || r[4] == ''), isTrue);
    });
  });

  group('画面', () {
    Widget page(
      _FakeReportService service,
      List<(String, String, int)> saved,
    ) => MaterialApp(
      home: AttendanceReportPage(
        eventId: 'evReport0123456789',
        eventName: '架空イベント',
        service: service,
        now: () => DateTime.utc(2026, 11, 30, 3),
        saver: (bytes, name, mime) => saved.add((name, mime, bytes.length)),
      ),
    );

    testWidgets('説明文と出力ボタン。押すとサーバーの明細からExcelを作り、ブラウザで保存させる(1回だけ)', (
      tester,
    ) async {
      final service = _FakeReportService(report: _report(eventName: '架空イベント'));
      final saved = <(String, String, int)>[];
      await tester.pumpWidget(page(service, saved));
      expect(find.text('参加者・受付結果をExcelで出力します。データは変更されません。'), findsOneWidget);
      expect(service.calls, isEmpty, reason: '開いただけでは読み込まない');
      await tester.tap(find.byKey(const Key('export-final-report')));
      await tester.pumpAndSettle();
      expect(service.calls, ['evReport0123456789']);
      expect(saved.length, 1);
      expect(saved.single.$1, 'JM_Quick_架空イベント_最終実績_20261130.xlsx');
      expect(saved.single.$2, xlsxMimeType);
      expect(find.byKey(const Key('final-report-done')), findsOneWidget);
      expect(find.textContaining('参加者14名'), findsOneWidget);
      expect(
        find.textContaining('架空 参加者'),
        findsNothing,
        reason: '明細(個人情報)は画面に表示しない',
      );
    });

    testWidgets('権限なし等のエラーは表示し、保存しない', (tester) async {
      final service = _FakeReportService(
        error: const WinnerSendException('この操作を行う権限がありません。'),
      );
      final saved = <(String, String, int)>[];
      await tester.pumpWidget(page(service, saved));
      await tester.tap(find.byKey(const Key('export-final-report')));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('この操作を行う権限がありません。'), findsOneWidget);
    });
  });

  group('入口(/console のイベント管理画面)', () {
    testWidgets('「最終実績Excel出力」から、このイベントの出力画面を開く(eventIdは引き継ぐだけ)', (
      tester,
    ) async {
      final service = _FakeReportService(report: _report());
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedConsolePage(
            initialEventId: 'evfixture0123456789',
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              const AccessCheck.granted(AccessRole.admin),
            ]),
            receptionStaffKeyIssuer: FakeReceptionStaffKeyIssuer(),
            eventSummaryService: FakeImportService(
              event: const ImportEventSummary(
                eventId: 'evfixture0123456789',
                eventName: '架空イベント',
                startAt: null,
                venue: '架空会場',
                programs: [],
              ),
            ),
            winnerMailService: FakeWinnerMailService(),
            winnerSendService: FakeSendService(),
            reminderService: FakeReminderService(),
            attendanceReportService: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最終実績Excel出力'), findsOneWidget);
      expect(find.text('参加者・受付結果をExcelで出力します。データは変更されません。'), findsOneWidget);
      expect(
        find.text('参加者管理'),
        findsOneWidget,
        reason: '参加者管理は準備中のまま(別機能を同時に作らない)',
      );
      await tester.ensureVisible(find.text('最終実績Excel出力'));
      await tester.tap(find.text('最終実績Excel出力'));
      await tester.pumpAndSettle();
      expect(find.byType(AttendanceReportPage), findsOneWidget);
      expect(
        tester
            .widget<AttendanceReportPage>(find.byType(AttendanceReportPage))
            .eventId,
        'evfixture0123456789',
      );
      expect(service.calls, isEmpty);
    });

    test('受付スタッフの機能には含まれない', () {
      expect(staffFeatureLabels, isNot(contains('最終実績Excel出力')));
      expect(eventConsoleFeatureLabels, contains('最終実績Excel出力'));
    });
  });
}
