// 主催者用「受付状況一覧」。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて架空(メールは .invalid)。
//  - 集計: 申込件数は参加者単位・予定/実来場人数は延べ・program別は参加者×program単位の件数ベースの受付率・時間帯別
//  - 受付状態の正本はサーバー応答(programAttendancesの現在値): 取消済み=未受付・訂正後の人数・対象外の参加者
//  - 画面: 開いたときに1回だけ取得・手動更新のみ(自動更新なし)・二重取得の防止・エラー時は前回の内容を残す
//  - 一覧: 1行=参加者×program・氏名検索・program/受付状態の絞り込み・受付時刻の並べ替え・1,000行
//  - 入口・権限: システム管理者・イベント管理者のイベント管理画面だけ。スタッフには出さない。サーバーの権限はeventManager
//  - HEBEL属性(この画面だけの3分類): hebelHaus / hebelMaison / それ以外(none・unset・unknown・属性なし)=該当なし。
//    属性別集計(参加者単位)・一覧の列・絞り込み(他の条件とAND、追加の通信なし)
//  - 表示中の一覧のCSV出力: 検索・絞り込み・並び順を反映した全行(描画範囲に依存しない)・固定の8列・UTF-8 BOM・CRLF・
//    RFC 4180のエスケープ・日本時間・0行は出力しない・二重保存の防止・追加の通信なし
//  - 表示切替(参加者一覧 / 受付集計): 初期は参加者一覧・切替では通信しない・検索/絞り込み/並び順/CSVの対象は保持・集計値は不変
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/assignment_service.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:csv/csv.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';
import 'package:jm_quick/confirmed/reception_status_page.dart';
import 'package:jm_quick/confirmed/reception_status_summary.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'phase3_roles_test.dart' show FakeAssignmentService;
import 'reception_staff_key_fake.dart';
import 'reminder_test.dart' show FakeReminderService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService;

const _eventId = 'evStatus0123456789';
const _haus = 'ヘーベルハウス居住（メゾンオーナー含む）';
const _maison = 'ヘーベルメゾン居住';

/// 最終実績の応答のHEBEL属性(サーバーの hebelResidenceView と同じ形)。
Map<String, dynamic> _hebel(String category, {String? raw}) => {
  'category': category,
  'label': switch (category) {
    'hebelHaus' => 'ヘーベルハウスにお住まい（ヘーベルメゾンのオーナー様含む）',
    'hebelMaison' => 'ヘーベルメゾンにお住まい',
    'none' => '該当なし（いいえ）',
    'unset' => '未設定（空欄）',
    _ => '未知のHEBEL属性',
  },
  'rawValue': ?raw,
};

Map<String, dynamic> _entry(
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

Map<String, dynamic> _person(
  String id,
  String name, {
  List<Map<String, dynamic>> programs = const [],
  String status = 'active',
  bool? committed = true,
  Map<String, dynamic>? hebel,
  bool noHebel = false,
}) => {
  'participantId': id,
  'importSequence': committed == null ? null : 1,
  'batchCommitted': committed,
  'importRow': 2,
  'name': name,
  'kana': 'かくう$id',
  'email': '$id@example.invalid',
  'status': status,
  if (!noHebel) 'hebelResidence': hebel ?? _hebel('none'),
  'programs': programs,
};

const _programs = [
  {'programId': 'program-1', 'name': '架空の譲渡会（ねこ）', 'inEvent': true},
  {'programId': 'program-2', 'name': '架空の譲渡会（いぬ）', 'inEvent': true},
  {'programId': 'program-3', 'name': '架空トーク', 'inEvent': true},
];

/// 基本のfixture。overridesで参加者のprogramsを差し替える(訂正・取消後の再取得用)。
AttendanceReport _report({
  Map<String, List<Map<String, dynamic>>> overrides = const {},
}) {
  List<Map<String, dynamic>> programsOf(
    String id,
    List<Map<String, dynamic>> base,
  ) => overrides[id] ?? base;
  final json = {
    'eventId': _eventId,
    'eventName': '架空イベント',
    'programs': _programs,
    'participants': [
      // ねこ(受付済み・人数は訂正後の3)+ いぬ(未受付)
      _person('p01', '架空 一郎', hebel: _hebel('hebelHaus'), programs: programsOf('p01', [
        _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 3, at: '2026-11-30T01:23:45.000Z'),
        _entry('program-2', planned: 1, time: '14:10-14:50'),
      ])),
      // 受付取消済み(正本では未受付に戻っている)
      _person('p02', '架空 二郎', programs: programsOf('p02', [
        _entry('program-1', time: '11:10-11:50'),
      ])),
      // いぬ・トークとも受付済み
      _person('p03', '架空 三子', hebel: _hebel('hebelMaison'), programs: programsOf('p03', [
        _entry('program-3', planned: 1, time: '13:00-14:00', checkedIn: true, attended: 1, at: '2026-11-30T04:00:00.000Z'),
        _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
      ])),
      _person('p04', '架空 四郎', hebel: _hebel('unset'), programs: programsOf('p04', [
        _entry('program-3', time: '13:00-14:00'),
      ])),
      // 対象外: 有効でない参加者・未確定の取込回・申込programなし
      _person('p05', '架空 対象外五', status: 'inactive', hebel: _hebel('hebelHaus'), programs: [
        _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 9, at: '2026-11-30T01:00:00.000Z'),
      ]),
      _person('p06', '架空 対象外六', committed: false, hebel: _hebel('hebelMaison'), programs: [_entry('program-1', planned: 9)]),
      _person('p07', '架空 対象外七'),
      // 取込回なし(対象)・時間未設定・HEBEL属性なし(列の無い取込)
      _person('p08', '架空 八子', committed: null, noHebel: true, programs: programsOf('p08', [
        _entry('program-2', planned: 1),
      ])),
    ],
  };
  return AttendanceReport.fromJson(
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
  );
}

/// 応答を順に返す。completerを使うと、取得中の状態を保てる。
class _FakeService implements AttendanceReportService {
  _FakeService(this.responses);
  final List<Object> responses; // AttendanceReport | Object(エラー) | Completer<AttendanceReport>
  final calls = <String>[];

  @override
  Future<AttendanceReport> getReport(String eventId) async {
    calls.add(eventId);
    final next = responses.length > 1 ? responses.removeAt(0) : responses.first;
    if (next is AttendanceReport) return next;
    if (next is Completer<AttendanceReport>) return next.future;
    throw next;
  }
}

Widget _page(
  _FakeService service, {
  DateTime Function()? now,
  ReceptionStatusCsvSaver? csvSaver,
}) => MaterialApp(
  home: ReceptionStatusPage(
    eventId: _eventId,
    eventName: '架空イベント',
    service: service,
    now: now ?? () => DateTime.utc(2026, 11, 30, 3, 4, 5),
    csvSaver: csvSaver ?? (_, _, _) => fail('CSVを保存しない想定'),
  ),
);

/// 表示切替(参加者一覧 / 受付集計)。切替ボタンは画面上部(常に表示)。
Future<void> _view(WidgetTester tester, ReceptionStatusView view) async {
  final chip = find.byKey(ValueKey('reception-status-view-${view.name}'));
  await tester.ensureVisible(chip);
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

/// 一覧の上の部品(遅延して作られる)までスクロールする。
Future<void> _scrollTo(WidgetTester tester, Key key) async {
  final scrollable = find.descendant(
    of: find.byKey(const Key('reception-status-scroll')),
    matching: find.byType(Scrollable),
  ).first;
  await tester.scrollUntilVisible(find.byKey(key), 200, scrollable: scrollable);
  await tester.pumpAndSettle();
}

/// 保存されたCSV(テスト用の差し替え)。
class _SavedCsv {
  final saves = <({Uint8List bytes, String fileName, String mimeType})>[];
  void call(Uint8List bytes, String fileName, String mimeType) =>
      saves.add((bytes: bytes, fileName: fileName, mimeType: mimeType));
}

/// CSVを読み戻す(BOMを除いて、CRLF・RFC 4180で解釈)。数値のセルは数値として読める。
List<List<dynamic>> _parseCsv(Uint8List bytes) {
  expect(bytes.take(3), [0xef, 0xbb, 0xbf], reason: 'UTF-8 BOM');
  final text = utf8.decode(bytes.sublist(3));
  return const CsvToListConverter(eol: '\r\n', shouldParseNumbers: true)
      .convert(text)
      .where((r) => !(r.length == 1 && r.first == ''))
      .toList();
}

Future<void> _wide(WidgetTester tester, {double height = 2400}) async {
  await tester.binding.setSurfaceSize(Size(1280, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

String _tile(WidgetTester tester, String key) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
  ))
    t.data ?? '',
].join('|');

List<String> _cells(WidgetTester tester, Key key) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: find.byKey(key), matching: find.byType(Text)),
  ))
    t.data ?? '',
];

Future<void> _choose(WidgetTester tester, String key, String item) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  group('集計(純粋関数)', () {
    test('全体: 申込件数は参加者単位、予定人数・実来場人数は延べ。受付率=受付済み申込件数÷申込件数。対象外の参加者は数えない', () {
      final t = buildReceptionStatus(_report()).totals;
      expect(t.applications, 5, reason: 'p01〜p04・p08(複数programのp01・p03も1件)。p05〜p07は対象外');
      expect(t.plannedTotal, 2 + 1 + 2 + 1 + 3 + 2 + 1, reason: '予定人数は全programの合計(延べ)');
      expect(t.checkedInApplications, 2, reason: 'いずれかのprogramが受付済み(p01・p03)');
      expect(t.attendedTotal, 3 + 1 + 3, reason: '実来場人数は受付済みprogramの合計(延べ)');
      expect(t.notCheckedInApplications, 3);
      expect(t.rate, 40.0);
    });

    test('program別: 参加者×program単位。受付率は件数ベース(人数ベースではない)。名前・順はイベント設定から', () {
      final programs = buildReceptionStatus(_report()).programs;
      expect(programs.map((p) => p.name), ['架空の譲渡会（ねこ）', '架空の譲渡会（いぬ）', '架空トーク']);
      final cat = programs[0];
      expect((cat.entries, cat.checkedInEntries, cat.plannedTotal, cat.attendedTotal, cat.notCheckedInEntries),
          (2, 1, 4, 3, 1));
      expect(cat.rate, 50.0, reason: '件数ベース(1/2)。人数ベースなら3/4=75%');
      final dog = programs[1];
      expect((dog.entries, dog.checkedInEntries, dog.plannedTotal, dog.attendedTotal), (3, 1, 5, 3));
      expect(dog.rate!.toStringAsFixed(1), '33.3');
      final talk = programs[2];
      expect((talk.entries, talk.checkedInEntries, talk.plannedTotal, talk.attendedTotal), (2, 1, 3, 1));
    });

    test('時間帯別: 開始時刻の順、時間の無い申込は「時間未設定」で末尾。時間帯は固定せずデータから', () {
      final programs = buildReceptionStatus(_report()).programs;
      expect(programs[0].slots.map((s) => s.label), ['10:30-11:10', '11:10-11:50']);
      expect(programs[1].slots.map((s) => s.label), ['14:10-14:50', '14:50-15:30', noSlotLabel]);
      expect(programs[2].slots.map((s) => s.label), ['13:00-14:00']);
      final first = programs[0].slots.first;
      expect((first.entries, first.checkedInEntries, first.plannedTotal, first.attendedTotal), (1, 1, 2, 3));
      final talk = programs[2].slots.single;
      expect((talk.entries, talk.checkedInEntries, talk.plannedTotal, talk.attendedTotal), (2, 1, 3, 1));
      expect(slotStartMinutes('10時30分～11時10分'), 630);
      expect(slotStartMinutes('９:００'), isNull);
      expect(slotStartMinutes('午前の部'), isNull);
    });

    test('1行=参加者×program(複数programは複数行・programの表示順)。未受付の行は人数・時刻を持たない', () {
      final rows = buildReceptionStatus(_report()).rows;
      expect(rows.length, 7);
      expect(
        [for (final r in rows) '${r.participantId}:${r.programId}'],
        ['p01:program-1', 'p01:program-2', 'p02:program-1', 'p03:program-2', 'p03:program-3', 'p04:program-3', 'p08:program-2'],
      );
      final p01dog = rows[1];
      expect((p01dog.checkedIn, p01dog.attendedCount, p01dog.checkedInAt), (false, null, null));
      expect(rows[0].checkedInAt, DateTime.utc(2026, 11, 30, 1, 23, 45));
    });

    test('人数訂正・受付取消の反映: 正本の最新値(訂正後の人数・取消済みは未受付)だけで集計する', () {
      final after = buildReceptionStatus(_report(overrides: {
        // 人数訂正 3 → 2
        'p01': [
          _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 2, at: '2026-11-30T01:23:45.000Z'),
          _entry('program-2', planned: 1, time: '14:10-14:50'),
        ],
        // トークの受付取消(未受付に戻る)
        'p03': [
          _entry('program-3', planned: 1, time: '13:00-14:00'),
          _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
        ],
      }));
      expect(after.totals.attendedTotal, 2 + 3);
      expect(after.totals.checkedInApplications, 2, reason: 'p03はいぬが受付済みのまま');
      expect(after.programs[2].checkedInEntries, 0);
      expect(after.programs[2].attendedTotal, 0);
    });

    test('参加者0件: すべて0件・受付率は「—」(0で割らない)。programの行は残る', () {
      final s = buildReceptionStatus(AttendanceReport.fromJson({
        'eventId': _eventId,
        'eventName': '架空イベント',
        'programs': _programs,
        'participants': <Object>[],
      }));
      expect(s.rows, isEmpty);
      expect((s.totals.applications, s.totals.plannedTotal, s.totals.attendedTotal), (0, 0, 0));
      expect(s.totals.rate, isNull);
      expect(formatRate(s.totals.rate), '—');
      expect(s.programs.length, 3);
      expect(s.programs.every((p) => p.rate == null && p.slots.isEmpty), isTrue);
    });

    test('検索(空白を無視)・program・受付状態の絞り込み・受付時刻の並べ替え(未受付は末尾)', () {
      final rows = buildReceptionStatus(_report()).rows;
      String ids(List<ReceptionStatusRow> list) => [for (final r in list) '${r.participantId}:${r.programId}'].join(',');
      expect(ids(filterReceptionRows(rows, query: '架空一郎')), 'p01:program-1,p01:program-2');
      expect(ids(filterReceptionRows(rows, query: ' 三子 ')), 'p03:program-2,p03:program-3');
      expect(ids(filterReceptionRows(rows, programId: 'program-3')), 'p03:program-3,p04:program-3');
      expect(ids(filterReceptionRows(rows, state: ReceptionStateFilter.checkedIn)), 'p01:program-1,p03:program-2,p03:program-3');
      expect(filterReceptionRows(rows, state: ReceptionStateFilter.notCheckedIn).length, 4);
      expect(
        ids(filterReceptionRows(rows, sort: ReceptionSort.checkedInAtDesc)),
        'p03:program-2,p03:program-3,p01:program-1,p01:program-2,p02:program-1,p04:program-3,p08:program-2',
      );
      expect(
        ids(filterReceptionRows(rows, sort: ReceptionSort.checkedInAtAsc)).split(',').take(3).join(','),
        'p01:program-1,p03:program-3,p03:program-2',
      );
      expect(filterReceptionRows(rows, query: '該当なし'), isEmpty);
    });

    test('HEBEL属性の3分類: hebelHaus・hebelMaison以外(none・unset・unknown・属性なし)はすべて「該当なし」', () {
      expect(ReceptionHebelGroup.fromCategory('hebelHaus'), ReceptionHebelGroup.hebelHaus);
      expect(ReceptionHebelGroup.fromCategory('hebelMaison'), ReceptionHebelGroup.hebelMaison);
      for (final c in ['none', 'unset', 'unknown', null, '', '想定外の値']) {
        expect(ReceptionHebelGroup.fromCategory(c), ReceptionHebelGroup.none, reason: '$c');
      }
      expect([for (final g in ReceptionHebelGroup.values) g.label], [_haus, _maison, '該当なし'], reason: '3分類だけ');
      final s = buildReceptionStatus(AttendanceReport.fromJson(jsonDecode(jsonEncode({
        'eventId': _eventId,
        'eventName': '架空イベント',
        'programs': _programs,
        'participants': [
          _person('u1', '架空 未知', hebel: _hebel('unknown', raw: '架空の想定外の回答'), programs: [_entry('program-1')]),
          _person('u2', '架空 属性なし', noHebel: true, programs: [_entry('program-1')]),
        ],
      })) as Map<String, dynamic>));
      expect(s.rows.map((r) => r.hebel), [ReceptionHebelGroup.none, ReceptionHebelGroup.none]);
      expect(s.hebelGroups.last.applications, 2);
    });

    test('HEBEL属性別: 参加者単位(複数programでも1件)。受付済み=いずれかのprogramが受付済み。合計は全体の申込件数と一致。対象外は数えない', () {
      final s = buildReceptionStatus(_report());
      String line(ReceptionHebelStatus g) =>
          '${g.group.name}:${g.applications}/${g.checkedInApplications}/${g.notCheckedInApplications}/${formatRate(g.rate)}';
      expect(s.hebelGroups.map(line), [
        'hebelHaus:1/1/0/100.0%', // p01(ねこ受付済み・いぬ未受付の2programで1件)。対象外のp05は数えない
        'hebelMaison:1/1/0/100.0%', // p03(2programとも受付済みで1件)。未確定の取込回のp06は数えない
        'none:3/0/3/0.0%', // p02(none)・p04(unset)・p08(属性なし)
      ]);
      expect(s.hebelGroups.fold(0, (n, g) => n + g.applications), s.totals.applications);
      expect(s.hebelGroups.fold(0, (n, g) => n + g.checkedInApplications), s.totals.checkedInApplications);
    });

    test('HEBEL属性別: 0件の分類も常に3分類を表示し、受付率は「—」。全員未回答のイベント(10名)は該当なし10件', () {
      final s = buildReceptionStatus(AttendanceReport.fromJson(jsonDecode(jsonEncode({
        'eventId': _eventId,
        'eventName': '架空イベント',
        'programs': _programs,
        'participants': [
          for (var i = 0; i < 10; i++)
            _person('e$i', '架空 検証$i', hebel: _hebel('unset'), programs: [_entry('program-2', time: '15:30-16:10')]),
        ],
      })) as Map<String, dynamic>));
      expect([for (final g in s.hebelGroups) (g.group, g.applications, formatRate(g.rate))], [
        (ReceptionHebelGroup.hebelHaus, 0, '—'),
        (ReceptionHebelGroup.hebelMaison, 0, '—'),
        (ReceptionHebelGroup.none, 10, '0.0%'),
      ]);
      final empty = buildReceptionStatus(AttendanceReport.fromJson({
        'eventId': _eventId, 'eventName': '架空イベント', 'programs': _programs, 'participants': <Object>[],
      }));
      expect(empty.hebelGroups.map((g) => (g.applications, g.rate)), [(0, null), (0, null), (0, null)]);
    });

    test('HEBEL属性別: 受付取消で受付済み件数が減り、人数訂正では申込件数・受付済み件数は変わらない', () {
      final cancelled = buildReceptionStatus(_report(overrides: {
        'p01': [_entry('program-1', time: '10:30-11:10'), _entry('program-2', planned: 1, time: '14:10-14:50')],
      }));
      expect(cancelled.hebelGroups.first.checkedInApplications, 0);
      expect(cancelled.hebelGroups.first.applications, 1);
      expect(cancelled.hebelGroups.first.rate, 0.0);
      final corrected = buildReceptionStatus(_report(overrides: {
        'p01': [
          _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 1, at: '2026-11-30T01:23:45.000Z'),
          _entry('program-2', planned: 1, time: '14:10-14:50'),
        ],
      }));
      expect(
        [for (final g in corrected.hebelGroups) (g.applications, g.checkedInApplications)],
        [for (final g in buildReceptionStatus(_report()).hebelGroups) (g.applications, g.checkedInApplications)],
      );
    });

    test('HEBEL属性の絞り込みは氏名・program・受付状態とAND', () {
      final rows = buildReceptionStatus(_report()).rows;
      String ids(List<ReceptionStatusRow> list) => [for (final r in list) '${r.participantId}:${r.programId}'].join(',');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.hebelHaus)), 'p01:program-1,p01:program-2');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.none)), 'p02:program-1,p04:program-3,p08:program-2');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.hebelHaus, state: ReceptionStateFilter.notCheckedIn)),
          'p01:program-2');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.none, programId: 'program-3')), 'p04:program-3');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.hebelMaison, query: '一郎')), '');
      expect(ids(filterReceptionRows(rows, hebel: ReceptionHebelGroup.hebelMaison, query: '三子', sort: ReceptionSort.checkedInAtAsc)),
          'p03:program-3,p03:program-2');
    });
  });

  group('画面', () {
    testWidgets('HEBEL属性別受付状況(全体とprogram別の間・3分類)と一覧のHEBEL属性列。絞り込みは他の条件とAND・追加の通信なし', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await _view(tester, ReceptionStatusView.summary);
      expect(_cells(tester, const ValueKey('hebel-status-hebelHaus')), [_haus, '1件', '1件', '0件', '100.0%']);
      expect(_cells(tester, const ValueKey('hebel-status-hebelMaison')), [_maison, '1件', '1件', '0件', '100.0%']);
      expect(_cells(tester, const ValueKey('hebel-status-none')), ['該当なし', '3件', '0件', '3件', '0.0%']);
      double y(String key) => tester.getTopLeft(find.byKey(Key(key))).dy;
      final hebelY = tester.getTopLeft(find.byKey(const ValueKey('hebel-status-hebelHaus'))).dy;
      expect(y('total-applications') < hebelY, isTrue);
      expect(hebelY < tester.getTopLeft(find.byKey(const ValueKey('program-status-program-1'))).dy, isTrue);
      await _view(tester, ReceptionStatusView.list);
      expect(_cells(tester, const ValueKey('status-row-p04-program-3'))[1], '該当なし', reason: 'unset');
      expect(_cells(tester, const ValueKey('status-row-p08-program-2'))[1], '該当なし', reason: '属性なし');
      expect(_cells(tester, const ValueKey('status-row-p03-program-2'))[1], _maison);

      await _choose(tester, 'reception-status-hebel', '該当なし');
      expect(find.text('表示中 3行 / 全7行'), findsOneWidget);
      await _choose(tester, 'reception-status-program', '架空トーク');
      expect(find.text('表示中 1行 / 全7行'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-row-p04-program-3')), findsOneWidget);
      await _choose(tester, 'reception-status-state', '受付済み');
      expect(find.text('条件に一致する参加者はいません。'), findsOneWidget);
      await _choose(tester, 'reception-status-program', 'すべて');
      await _choose(tester, 'reception-status-state', 'すべて');
      await _choose(tester, 'reception-status-hebel', _haus);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '一郎');
      await tester.pumpAndSettle();
      expect(find.text('表示中 2行 / 全7行'), findsOneWidget);
      await _choose(tester, 'reception-status-sort', '受付時刻(新しい順)');
      await _choose(tester, 'reception-status-hebel', 'すべて');
      expect(find.text('表示中 2行 / 全7行'), findsOneWidget);
      expect(service.calls.length, 1, reason: '絞り込み・検索・並べ替えでは再取得しない');
      await tester.pump(const Duration(hours: 1));
      expect(service.calls.length, 1);
    });
    testWidgets('開いたときに1回だけ取得し、全体・program別・時間帯別・一覧と最終更新(日本時間)を表示する', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      expect(service.calls, [_eventId]);
      expect(find.text('最終更新：2026/11/30 12:04:05（日本時間）'), findsOneWidget);
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-applications'), '申込件数|5件');
      expect(_tile(tester, 'total-planned'), '予定人数（延べ）|12名|複数プログラムの参加を含む');
      expect(_tile(tester, 'total-checked-in'), '受付済み申込件数|2件');
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|7名|複数プログラムの参加を含む');
      expect(_tile(tester, 'total-not-checked-in'), '未受付申込件数|3件');
      expect(_tile(tester, 'total-rate'), '受付率|40.0%|受付済み申込件数 ÷ 申込件数');
      expect(_cells(tester, const ValueKey('program-status-program-1')),
          ['架空の譲渡会（ねこ）', '4名', '1件', '3名', '1件', '50.0%']);
      expect(_cells(tester, const ValueKey('slot-status-program-2-$noSlotLabel')),
          [noSlotLabel, '1名', '0名', '0件', '1件']);
      void expectNoExtraPersonalData() {
        expect(find.textContaining('@'), findsNothing);
        expect(find.textContaining('かくう'), findsNothing);
        expect(find.textContaining('該当なし（いいえ）'), findsNothing);
        expect(find.textContaining('未設定（空欄）'), findsNothing);
        expect(find.textContaining('お住まい'), findsNothing);
        expect(find.textContaining('対象外'), findsNothing);
      }
      expectNoExtraPersonalData();
      await _view(tester, ReceptionStatusView.list);
      expect(_cells(tester, const ValueKey('status-row-p01-program-1')),
          ['架空 一郎', _haus, '架空の譲渡会（ねこ）', '10:30-11:10', '2名', '3名', '受付済み', '11/30 10:23']);
      expect(_cells(tester, const ValueKey('status-row-p01-program-2')),
          ['架空 一郎', _haus, '架空の譲渡会（いぬ）', '14:10-14:50', '1名', '—', '未受付', '—'],
          reason: '複数programの参加者は各行に同じHEBEL属性');
      expect(find.text('表示中 7行 / 全7行'), findsOneWidget);
      // 不要な個人情報(メールアドレス・かな)・保存されているHEBEL属性の原文/5分類の表示名・対象外の参加者は表示しない
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('かくう'), findsNothing);
      expect(find.textContaining('該当なし（いいえ）'), findsNothing);
      expect(find.textContaining('未設定（空欄）'), findsNothing);
      expect(find.textContaining('お住まい'), findsNothing);
      expect(find.textContaining('対象外'), findsNothing);
    });

    testWidgets('自動更新はしない(時間が経っても再取得しない)。「最新の状態に更新」を押したときだけ取得し、訂正・取消を反映する', (tester) async {
      await _wide(tester);
      var clock = DateTime.utc(2026, 11, 30, 3);
      final service = _FakeService([
        _report(),
        _report(overrides: {
          'p01': [
            _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 2, at: '2026-11-30T01:23:45.000Z'),
            _entry('program-2', planned: 1, time: '14:10-14:50'),
          ],
          'p03': [
            _entry('program-3', planned: 1, time: '13:00-14:00'),
            _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
          ],
        }),
      ]);
      await tester.pumpWidget(_page(service, now: () => clock));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(hours: 2));
      expect(service.calls.length, 1, reason: 'タイマー・自動更新なし');

      clock = DateTime.utc(2026, 11, 30, 5, 30);
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pumpAndSettle();
      expect(service.calls.length, 2);
      expect(find.text('最終更新：2026/11/30 14:30:00（日本時間）'), findsOneWidget);
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|5名|複数プログラムの参加を含む');
      await _view(tester, ReceptionStatusView.list);
      expect(_cells(tester, const ValueKey('status-row-p01-program-1'))[5], '2名', reason: '人数訂正後の値');
      expect(_cells(tester, const ValueKey('status-row-p03-program-3')).sublist(5),
          ['—', '未受付', '—'], reason: '取消済みは未受付');
      await tester.pump(const Duration(hours: 1));
      expect(service.calls.length, 2);
    });

    testWidgets('取得中はボタンを押せず、二重に取得しない', (tester) async {
      await _wide(tester);
      final pending = Completer<AttendanceReport>();
      final service = _FakeService([_report(), pending, _report()]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pump();
      expect(service.calls.length, 2);
      expect(find.text('取得中…'), findsOneWidget);
      final button = find.ancestor(
        of: find.text('取得中…'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      await tester.tap(find.byKey(const Key('reception-status-refresh')), warnIfMissed: false);
      await tester.pump();
      expect(service.calls.length, 2, reason: '取得中は再取得しない');
      expect(find.text('表示中 7行 / 全7行'), findsOneWidget, reason: '取得中も前回の内容を表示したまま');
      pending.complete(_report());
      await tester.pumpAndSettle();
      expect(find.text('最新の状態に更新'), findsOneWidget);
      expect(service.calls.length, 2);
    });

    testWidgets('通信エラー: 前回取得した内容を残してエラーを表示する。初回のエラーは内容なしでエラーと更新ボタン', (tester) async {
      await _wide(tester);
      final service = _FakeService([
        _report(),
        const WinnerSendException('通信に失敗しました。通信状態を確認して、もう一度お試しください。', code: 'network'),
        _report(),
      ]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reception-status-error')), findsOneWidget);
      expect(find.textContaining('通信に失敗しました。'), findsOneWidget);
      expect(find.textContaining('前回取得したもの'), findsOneWidget);
      expect(find.text('表示中 7行 / 全7行'), findsOneWidget, reason: '参加者一覧も前回の内容のまま');
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-applications'), '申込件数|5件');
      expect(find.text('最終更新：2026/11/30 12:04:05（日本時間）'), findsOneWidget, reason: '最終更新は成功した取得の時刻のまま');
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reception-status-error')), findsNothing);

      final denied = _FakeService([const WinnerSendException('この操作を行う権限がありません。')]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_page(denied));
      await tester.pumpAndSettle();
      expect(find.text('この操作を行う権限がありません。'), findsOneWidget);
      expect(find.byKey(const Key('reception-status-count')), findsNothing);
      await _view(tester, ReceptionStatusView.summary);
      expect(find.byKey(const Key('total-applications')), findsNothing);
      expect(find.text('最終更新：—'), findsOneWidget);
      expect(find.text('最新の状態に更新'), findsOneWidget);
    });

    testWidgets('参加者0件: 0件・受付率「—」と、対象者がいない旨を表示する', (tester) async {
      await _wide(tester);
      final service = _FakeService([
        AttendanceReport.fromJson({'eventId': _eventId, 'eventName': '架空イベント', 'programs': _programs, 'participants': <Object>[]}),
      ]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-applications'), '申込件数|0件');
      expect(_tile(tester, 'total-rate'), '受付率|—|受付済み申込件数 ÷ 申込件数');
      await _view(tester, ReceptionStatusView.list);
      expect(find.text('受付の対象となる参加者はいません。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('氏名検索・program・受付状態の絞り込み・受付時刻の並べ替え', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(_page(_FakeService([_report()])));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('reception-status-search')), '一郎');
      await tester.pumpAndSettle();
      expect(find.text('表示中 2行 / 全7行'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '');
      await tester.pumpAndSettle();

      await _choose(tester, 'reception-status-program', '架空トーク');
      expect(find.text('表示中 2行 / 全7行'), findsOneWidget);
      await _choose(tester, 'reception-status-state', '受付済み');
      expect(find.text('表示中 1行 / 全7行'), findsOneWidget);
      expect(find.byKey(const ValueKey('status-row-p03-program-3')), findsOneWidget);
      await _choose(tester, 'reception-status-program', 'すべて');
      await _choose(tester, 'reception-status-state', 'すべて');
      await _choose(tester, 'reception-status-sort', '受付時刻(新しい順)');
      final order = [
        for (final e in tester.widgetList<Container>(find.byWidgetPredicate(
          (w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('status-row-'),
        )))
          (e.key! as ValueKey<String>).value,
      ];
      expect(order.take(3), ['status-row-p03-program-2', 'status-row-p03-program-3', 'status-row-p01-program-1']);
      await _choose(tester, 'reception-status-state', '未受付');
      expect(find.text('表示中 4行 / 全7行'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '該当しない名前');
      await tester.pumpAndSettle();
      expect(find.text('条件に一致する参加者はいません。'), findsOneWidget);
    });

    testWidgets('1,000行規模: 表示中の行だけを作り(一覧全体を一度に作らない)、絞り込みも動く', (tester) async {
      await _wide(tester, height: 1000);
      final big = AttendanceReport.fromJson(jsonDecode(jsonEncode({
        'eventId': _eventId,
        'eventName': '架空イベント',
        'programs': _programs,
        'participants': [
          for (var i = 0; i < 500; i++)
            _person('q${i.toString().padLeft(4, '0')}', '架空 大量$i',
                hebel: i % 3 == 0 ? _hebel('hebelHaus') : _hebel('hebelMaison'), noHebel: i % 3 == 2, programs: [
              _entry('program-1', time: '10:30-11:10', checkedIn: i.isEven, attended: i.isEven ? 2 : null,
                  at: i.isEven ? '2026-11-30T01:00:00.000Z' : null),
              _entry('program-2', time: '14:10-14:50'),
            ]),
        ],
      })) as Map<String, dynamic>);
      final watch = Stopwatch()..start();
      final bigService = _FakeService([big]);
      await tester.pumpWidget(_page(bigService));
      await tester.pumpAndSettle();
      watch.stop();
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-applications'), '申込件数|500件');
      expect(_tile(tester, 'total-rate'), '受付率|50.0%|受付済み申込件数 ÷ 申込件数');
      // HEBEL属性別(i % 3 == 1 の167名、うち受付済みは偶数のi)
      expect(_cells(tester, const ValueKey('hebel-status-hebelMaison')), [_maison, '167件', '83件', '84件', '49.7%']);
      await _view(tester, ReceptionStatusView.list);
      final built = find.byWidgetPredicate(
        (w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('status-row-'),
      );
      expect(built.evaluate().length, lessThan(100), reason: '画面外の行は作らない');
      final scrollable = find.descendant(
        of: find.byKey(const Key('reception-status-scroll')),
        matching: find.byType(Scrollable),
      ).first;
      await tester.scrollUntilVisible(find.byKey(const Key('reception-status-count')), 300, scrollable: scrollable);
      expect(find.text('表示中 1000行 / 全1000行'), findsOneWidget);
      // 最後の行までスクロールできる(スクロール中も作られている行は一部だけ)
      await tester.scrollUntilVisible(find.byKey(const ValueKey('status-row-q0499-program-2')), 3000, scrollable: scrollable);
      expect(built.evaluate().length, lessThan(100));
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('reception-status-search')), 300, scrollable: scrollable);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '大量499');
      await tester.pumpAndSettle();
      expect(find.text('表示中 2行 / 全1000行'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('status-row-q0499-program-2')), 300, scrollable: scrollable);
      expect(find.byKey(const ValueKey('status-row-q0499-program-1')), findsOneWidget);
      // HEBEL属性の絞り込み(i % 3 == 1 の167名 × 2program)。取得済みのデータで絞り込み、通信しない
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('reception-status-search')), 300, scrollable: scrollable);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '');
      await tester.pumpAndSettle();
      await _choose(tester, 'reception-status-hebel', _maison);
      expect(find.text('表示中 334行 / 全1000行'), findsOneWidget);
      expect(bigService.calls.length, 1);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('390px幅でも重大なoverflowや例外が出ない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_page(_FakeService([_report()])));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('CSV出力(表示中の一覧)', () {
    List<ReceptionStatusRow> rowsOf(AttendanceReport report) => buildReceptionStatus(report).rows;
    final at = DateTime.utc(2026, 10, 12, 11, 30); // 日本時間 2026/10/12 20:30:00

    test('固定の8列・1行=参加者×program・数値セル・未受付の人数/時刻と時間の無い申込は空欄・日本時間・HEBEL 3分類', () {
      final csv = buildReceptionStatusCsv(eventId: _eventId, rows: rowsOf(_report()), exportedAt: at);
      final table = _parseCsv(csv.bytes);
      expect(table.first, ['氏名', 'HEBEL属性', '参加プログラム', '参加時間', '予定人数', '実来場人数', '受付状態', '受付時刻']);
      expect(csv.rowCount, 7);
      expect(table.length, 8);
      expect(table[1], ['架空 一郎', _haus, '架空の譲渡会（ねこ）', '10:30-11:10', 2, 3, '受付済み', '2026/11/30 10:23']);
      expect(table[2], ['架空 一郎', _haus, '架空の譲渡会（いぬ）', '14:10-14:50', 1, '', '未受付', ''], reason: '複数programは別行');
      expect(table[3], ['架空 二郎', '該当なし', '架空の譲渡会（ねこ）', '11:10-11:50', 2, '', '未受付', ''], reason: 'none');
      expect(table[4][1], _maison);
      expect(table[6][1], '該当なし', reason: 'unset');
      expect(table[7], ['架空 八子', '該当なし', '架空の譲渡会（いぬ）', '', 1, '', '未受付', ''], reason: '属性なし・時間なし');
      expect(table[1][4], isA<int>(), reason: '予定人数は数値');
      expect(table[1][5], isA<int>(), reason: '実来場人数は数値');
      final text = utf8.decode(csv.bytes.sublist(3));
      expect(RegExp(r'\d(名|件)').hasMatch(text), isFalse, reason: '単位文字を含めない');
      // 8列以外の個人情報(メール・かな・HEBEL属性の原文/5分類の表示名)・対象外の参加者は含めない
      for (final banned in ['@', 'かくう', 'お住まい', '該当なし（いいえ）', '未設定（空欄）', '対象外']) {
        expect(text.contains(banned), isFalse, reason: banned);
      }
    });

    test('UTF-8 BOM・CRLF(単独のLFなし)・日本語・ファイル名(イベントIDと日本時間の出力日時)', () {
      final csv = buildReceptionStatusCsv(eventId: 'ev8893310df0cceab110fb4c0dd5d7ff', rows: rowsOf(_report()), exportedAt: at);
      expect(csv.fileName, 'JM_Quick_Reception_Status_ev8893310df0cceab110fb4c0dd5d7ff_20261012_203000.csv');
      expect(csv.bytes.sublist(0, 3), [0xef, 0xbb, 0xbf]);
      final text = utf8.decode(csv.bytes.sublist(3));
      expect(RegExp(r'(?<!\r)\n').hasMatch(text), isFalse, reason: '改行はすべてCRLF');
      expect(text.split('\r\n').where((l) => l.isNotEmpty).length, 8);
      expect(text.startsWith('氏名,HEBEL属性,参加プログラム,参加時間,予定人数,実来場人数,受付状態,受付時刻\r\n'), isTrue);
      expect(text.endsWith('\r\n'), isTrue);
    });

    test('RFC 4180のエスケープ(カンマ・ダブルクォーテーション・改行)と数式の無害化。読み戻すと元の値', () {
      final csv = buildReceptionStatusCsv(
        eventId: _eventId,
        exportedAt: at,
        rows: rowsOf(AttendanceReport.fromJson(jsonDecode(jsonEncode({
          'eventId': _eventId,
          'eventName': '架空イベント',
          'programs': [{'programId': 'program-1', 'name': '架空,"譲渡会"', 'inEvent': true}],
          'participants': [
            _person('x1', '架空, "引用" 太郎', programs: [_entry('program-1', time: '午前\n10:30')]),
            _person('x2', '=1+1', programs: [_entry('program-1')]),
          ],
        })) as Map<String, dynamic>)),
      );
      final text = utf8.decode(csv.bytes.sublist(3));
      expect(text, contains('"架空, ""引用"" 太郎",該当なし,"架空,""譲渡会""","午前\n10:30",2,,未受付,\r\n'));
      final table = _parseCsv(csv.bytes);
      expect(table[1].sublist(0, 4), ['架空, "引用" 太郎', '該当なし', '架空,"譲渡会"', '午前\n10:30']);
      expect(table[2][0], "'=1+1", reason: '数式として評価させない(既存の参加者CSVと同じ無害化)');
    });

    test('人数訂正後は最新の人数、受付取消後は未受付(人数・時刻は空欄)', () {
      final csv = buildReceptionStatusCsv(eventId: _eventId, exportedAt: at, rows: rowsOf(_report(overrides: {
        'p01': [
          _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 1, at: '2026-11-30T01:23:45.000Z'),
          _entry('program-2', planned: 1, time: '14:10-14:50'),
        ],
        'p03': [
          _entry('program-3', planned: 1, time: '13:00-14:00'),
          _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
        ],
      })));
      final table = _parseCsv(csv.bytes);
      expect(table[1].sublist(5), [1, '受付済み', '2026/11/30 10:23']);
      final talk = table.firstWhere((r) => r[0] == '架空 三子' && r[2] == '架空トーク');
      expect(talk.sublist(5), ['', '未受付', '']);
    });

    test('0行は出力しない', () {
      expect(() => buildReceptionStatusCsv(eventId: _eventId, rows: const [], exportedAt: at), throwsStateError);
    });

    Finder exportButton() => find.ancestor(
      of: find.text('表示中の一覧をCSV出力'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );

    testWidgets('ボタンと出力対象件数。押すと表示中の全行をブラウザ内で保存(1回だけ)・成功を表示。追加の通信・自動更新なし', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(service, csvSaver: saved.call, now: () => at));
      await tester.pumpAndSettle();
      expect(find.text('表示中の一覧をCSV出力'), findsOneWidget);
      expect(find.text('出力対象：7行'), findsOneWidget);
      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')), warnIfMissed: false);
      await tester.pump();
      expect(saved.saves.length, 1, reason: '連続クリックでも1回だけ');
      expect(tester.widget<ButtonStyleButton>(exportButton()).onPressed, isNull, reason: '出力の直後は押せない');
      await tester.tap(find.byKey(const Key('reception-status-export-csv')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(saved.saves.length, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<ButtonStyleButton>(exportButton()).onPressed, isNotNull, reason: '少し待てば再び出力できる');
      expect(saved.saves.single.fileName, 'JM_Quick_Reception_Status_${_eventId}_20261012_203000.csv');
      expect(saved.saves.single.mimeType, 'text/csv;charset=utf-8');
      expect(_parseCsv(saved.saves.single.bytes).length, 8);
      expect(find.byKey(const Key('reception-status-export-done')), findsOneWidget);
      expect(find.textContaining('(7行)'), findsOneWidget);
      expect(service.calls.length, 1, reason: 'CSV出力では通信しない');
      await tester.pump(const Duration(hours: 1));
      expect(service.calls.length, 1, reason: '自動更新なし');
    });

    testWidgets('検索・program・受付状態・HEBEL属性(AND)と並び順を反映した行だけを、その順で出力する', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(service, csvSaver: saved.call));
      await tester.pumpAndSettle();
      Future<List<List<dynamic>>> export() async {
        await _scrollTo(tester, const Key('reception-status-export-csv'));
        await tester.tap(find.byKey(const Key('reception-status-export-csv')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        return _parseCsv(saved.saves.last.bytes).skip(1).toList();
      }

      List<String> keys(List<List<dynamic>> rows) => [for (final r in rows) '${r[0]}/${r[2]}'];
      await tester.enterText(find.byKey(const Key('reception-status-search')), '一郎');
      await tester.pumpAndSettle();
      expect(find.text('出力対象：2行'), findsOneWidget);
      expect(keys(await export()), ['架空 一郎/架空の譲渡会（ねこ）', '架空 一郎/架空の譲渡会（いぬ）']);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '');
      await tester.pumpAndSettle();

      await _choose(tester, 'reception-status-program', '架空の譲渡会（いぬ）');
      expect(keys(await export()), ['架空 一郎/架空の譲渡会（いぬ）', '架空 三子/架空の譲渡会（いぬ）', '架空 八子/架空の譲渡会（いぬ）']);
      await _choose(tester, 'reception-status-state', '未受付');
      expect(keys(await export()), ['架空 一郎/架空の譲渡会（いぬ）', '架空 八子/架空の譲渡会（いぬ）']);
      await _choose(tester, 'reception-status-hebel', '該当なし');
      expect(find.text('出力対象：1行'), findsOneWidget);
      expect(keys(await export()), ['架空 八子/架空の譲渡会（いぬ）']);

      await _choose(tester, 'reception-status-program', 'すべて');
      await _choose(tester, 'reception-status-state', '受付済み');
      await _choose(tester, 'reception-status-hebel', 'すべて');
      await _choose(tester, 'reception-status-sort', '受付時刻(新しい順)');
      expect(keys(await export()), ['架空 三子/架空の譲渡会（いぬ）', '架空 三子/架空トーク', '架空 一郎/架空の譲渡会（ねこ）']);
      await _choose(tester, 'reception-status-hebel', _maison);
      expect(keys(await export()), ['架空 三子/架空の譲渡会（いぬ）', '架空 三子/架空トーク']);
      expect(service.calls.length, 1, reason: '絞り込み・CSV出力では通信しない');
    });

    testWidgets('0行のときはボタンを押せない(出力しない)。保存に失敗したらエラーを表示する', (tester) async {
      await _wide(tester);
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(_FakeService([_report()]), csvSaver: saved.call));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('reception-status-search')), '該当しない名前');
      await tester.pumpAndSettle();
      expect(find.text('出力対象：0行'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(exportButton()).onPressed, isNull);
      await tester.tap(find.byKey(const Key('reception-status-export-csv')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(saved.saves, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_page(_FakeService([_report()]), csvSaver: (_, _, _) => throw UnsupportedError('保存できない環境')));
      await tester.pumpAndSettle();
      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('reception-status-export-error')), findsOneWidget);
      expect(find.text('CSVを出力できませんでした。もう一度お試しください。'), findsOneWidget);
      expect(find.byKey(const Key('reception-status-export-done')), findsNothing);
    });

    testWidgets('1,000行: 画面に描画されていない行も含め、絞り込みに一致する全行を出力する', (tester) async {
      await _wide(tester, height: 1600);
      final big = AttendanceReport.fromJson(jsonDecode(jsonEncode({
        'eventId': _eventId,
        'eventName': '架空イベント',
        'programs': _programs,
        'participants': [
          for (var i = 0; i < 500; i++)
            _person('q${i.toString().padLeft(4, '0')}', '架空 大量$i',
                hebel: i % 3 == 0 ? _hebel('hebelHaus') : _hebel('hebelMaison'), noHebel: i % 3 == 2, programs: [
              _entry('program-1', time: '10:30-11:10', checkedIn: i.isEven, attended: i.isEven ? 2 : null,
                  at: i.isEven ? '2026-11-30T01:00:00.000Z' : null),
              _entry('program-2', time: '14:10-14:50'),
            ]),
        ],
      })) as Map<String, dynamic>);
      final service = _FakeService([big]);
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(service, csvSaver: saved.call));
      await tester.pumpAndSettle();
      final built = find.byWidgetPredicate(
        (w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('status-row-'),
      );
      expect(built.evaluate().length, lessThan(100));
      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.pumpAndSettle();
      expect(find.text('出力対象：1000行'), findsOneWidget);
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      final all = _parseCsv(saved.saves.single.bytes);
      expect(all.length, 1001);
      expect(all.last[0], '架空 大量499');
      // 絞り込み欄を画面の中ほどへ(画面上端に接していると、選択肢を押せない)
      await _scrollTo(tester, const Key('reception-status-hebel'));
      await tester.drag(find.byKey(const Key('reception-status-scroll')), const Offset(0, 400));
      await tester.pumpAndSettle();
      await _choose(tester, 'reception-status-hebel', '該当なし');
      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      final none = _parseCsv(saved.saves.last.bytes).skip(1).toList();
      expect(none.length, 166 * 2, reason: 'i % 3 == 2 の166名 × 2program');
      expect(none.every((r) => r[1] == '該当なし'), isTrue);
      expect(service.calls.length, 1);
    });

    testWidgets('390px幅: CSV出力のボタン・件数・結果の表示で重大なoverflowや例外が出ない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(_FakeService([_report()]), csvSaver: saved.call));
      await tester.pumpAndSettle();
      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('reception-status-export-done')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('表示切替(参加者一覧 / 受付集計)', () {
    bool selected(WidgetTester tester, ReceptionStatusView v) =>
        tester.widget<ChoiceChip>(find.byKey(ValueKey('reception-status-view-${v.name}'))).selected;
    const summaryKeys = ['total-applications', 'total-rate'];
    const summaryValueKeys = [
      ValueKey('hebel-status-hebelHaus'),
      ValueKey('program-status-program-1'),
      ValueKey('slot-status-program-1-10:30-11:10'),
    ];
    void expectHeader() {
      expect(find.text('架空イベント'), findsOneWidget);
      expect(find.byKey(const Key('reception-status-updated-at')), findsOneWidget);
      expect(find.byKey(const Key('reception-status-refresh')), findsOneWidget);
    }

    void expectListMode({required bool shown}) {
      final m = shown ? findsOneWidget : findsNothing;
      expect(find.byKey(const Key('reception-status-search')), m);
      expect(find.byKey(const Key('reception-status-export-csv')), m);
      expect(find.byKey(const Key('reception-status-count')), m);
      expect(find.byKey(const ValueKey('status-row-p01-program-1')), m);
    }

    void expectSummaryMode({required bool shown}) {
      final m = shown ? findsOneWidget : findsNothing;
      for (final k in summaryKeys) {
        expect(find.byKey(Key(k)), m, reason: k);
      }
      for (final k in summaryValueKeys) {
        expect(find.byKey(k), m, reason: '$k');
      }
    }

    testWidgets('初期表示は参加者一覧(集計表は出さない)。受付集計へ切り替え・戻せる。イベント名・最終更新・更新ボタンは常に表示。切替では通信しない', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      expect(find.text('参加者一覧'), findsOneWidget);
      expect(find.text('受付集計'), findsOneWidget);
      expect(selected(tester, ReceptionStatusView.list), isTrue);
      expect(selected(tester, ReceptionStatusView.summary), isFalse);
      expectHeader();
      expectListMode(shown: true);
      expectSummaryMode(shown: false);
      // 参加者一覧がすぐ見える(画面上部に集計表が無い)
      expect(tester.getTopLeft(find.byKey(const Key('reception-status-search'))).dy, lessThan(600));

      await _view(tester, ReceptionStatusView.summary);
      expect(selected(tester, ReceptionStatusView.summary), isTrue);
      expect(selected(tester, ReceptionStatusView.list), isFalse);
      expectHeader();
      expectSummaryMode(shown: true);
      expectListMode(shown: false);
      expect(_tile(tester, 'total-applications'), '申込件数|5件');

      await _view(tester, ReceptionStatusView.list);
      expect(selected(tester, ReceptionStatusView.list), isTrue);
      expectHeader();
      expectListMode(shown: true);
      expectSummaryMode(shown: false);
      for (var i = 0; i < 3; i++) {
        await _view(tester, ReceptionStatusView.summary);
        await _view(tester, ReceptionStatusView.list);
      }
      expect(service.calls.length, 1, reason: '表示切替では通信しない');
      await tester.pump(const Duration(hours: 1));
      expect(service.calls.length, 1, reason: '自動更新なし');
    });

    testWidgets('検索・絞り込み・並び順は切り替えて戻っても保持され、CSVの出力対象も同じ。集計値は絞り込み・切替で変わらない', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      final saved = _SavedCsv();
      await tester.pumpWidget(_page(service, csvSaver: saved.call));
      await tester.pumpAndSettle();
      await _view(tester, ReceptionStatusView.summary);
      final before = [
        for (final k in ['total-applications', 'total-planned', 'total-checked-in', 'total-attended', 'total-not-checked-in', 'total-rate'])
          _tile(tester, k),
        for (final k in summaryValueKeys) ..._cells(tester, k),
      ];
      await _view(tester, ReceptionStatusView.list);

      await tester.enterText(find.byKey(const Key('reception-status-search')), '三子');
      await tester.pumpAndSettle();
      await _choose(tester, 'reception-status-hebel', _maison);
      await _choose(tester, 'reception-status-state', '受付済み');
      await _choose(tester, 'reception-status-sort', '受付時刻(新しい順)');
      List<String> order() => [
        for (final e in tester.widgetList<Container>(find.byWidgetPredicate(
          (w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('status-row-'),
        )))
          (e.key! as ValueKey<String>).value,
      ];
      final filteredOrder = order();
      expect(filteredOrder, ['status-row-p03-program-2', 'status-row-p03-program-3']);

      await _view(tester, ReceptionStatusView.summary);
      final after = [
        for (final k in ['total-applications', 'total-planned', 'total-checked-in', 'total-attended', 'total-not-checked-in', 'total-rate'])
          _tile(tester, k),
        for (final k in summaryValueKeys) ..._cells(tester, k),
      ];
      expect(after, before, reason: '集計は絞り込み・切替で変わらない');
      await _view(tester, ReceptionStatusView.list);

      expect(tester.widget<TextField>(find.byKey(const Key('reception-status-search'))).controller!.text, '三子');
      String shown(String key) => [
        for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text))))
          t.data ?? '',
      ].join('|');
      expect(shown('reception-status-hebel'), contains(_maison));
      expect(shown('reception-status-state'), contains('受付済み'));
      expect(shown('reception-status-sort'), contains('受付時刻(新しい順)'));
      expect(shown('reception-status-program'), contains('すべて'));
      expect(find.text('表示中 2行 / 全7行'), findsOneWidget);
      expect(find.text('出力対象：2行'), findsOneWidget);
      expect(order(), filteredOrder, reason: '並び順も保持');

      await _scrollTo(tester, const Key('reception-status-export-csv'));
      await tester.tap(find.byKey(const Key('reception-status-export-csv')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      final rows = _parseCsv(saved.saves.single.bytes).skip(1).toList();
      expect([for (final r in rows) '${r[0]}/${r[2]}'], ['架空 三子/架空の譲渡会（いぬ）', '架空 三子/架空トーク']);
      expect(service.calls.length, 1);
    });

    testWidgets('受付集計の表示中も「最新の状態に更新」で再取得でき(モードはそのまま)、通信エラーでは前回の集計を残す', (tester) async {
      await _wide(tester);
      final service = _FakeService([
        _report(),
        _report(overrides: {
          'p03': [
            _entry('program-3', planned: 1, time: '13:00-14:00'),
            _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
          ],
        }),
        const WinnerSendException('通信に失敗しました。通信状態を確認して、もう一度お試しください。', code: 'network'),
      ]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await _view(tester, ReceptionStatusView.summary);
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|7名|複数プログラムの参加を含む');
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pumpAndSettle();
      expect(service.calls.length, 2);
      expect(selected(tester, ReceptionStatusView.summary), isTrue, reason: '更新してもモードは変わらない');
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|6名|複数プログラムの参加を含む', reason: '受付取消の反映');
      await tester.tap(find.byKey(const Key('reception-status-refresh')));
      await tester.pumpAndSettle();
      expect(service.calls.length, 3);
      expect(find.byKey(const Key('reception-status-error')), findsOneWidget);
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|6名|複数プログラムの参加を含む', reason: '前回の内容を保持');
      await _view(tester, ReceptionStatusView.list);
      expect(find.byKey(const Key('reception-status-error')), findsOneWidget, reason: 'エラーはどちらのモードでも表示');
      expect(find.text('表示中 7行 / 全7行'), findsOneWidget);
      expect(service.calls.length, 3);
    });

    testWidgets('390px幅: 切替ボタンと両方のモードで重大なoverflowや例外が出ない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_page(_FakeService([_report()])));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _view(tester, ReceptionStatusView.summary);
      expect(tester.takeException(), isNull);
      await _view(tester, ReceptionStatusView.list);
      expect(tester.takeException(), isNull);
    });
  });

  group('入口・権限', () {
    const summary = ImportEventSummary(
      eventId: _eventId,
      eventName: '架空イベント',
      startAt: null,
      venue: '架空会場',
      programs: [],
    );
    Widget console(AccessCheck access, {List<MyEvent> myEvents = const [], AttendanceReportService? reports}) => MaterialApp(
      home: ConfirmedConsolePage(
        initialEventId: _eventId,
        authClient: FakeAuthClient(signedIn: true),
        accessService: FakeAccessService([access]),
        receptionStaffKeyIssuer: FakeReceptionStaffKeyIssuer(),
        eventSummaryService: FakeImportService(event: summary),
        winnerMailService: FakeWinnerMailService(),
        winnerSendService: FakeSendService(),
        reminderService: FakeReminderService(),
        assignmentService: FakeAssignmentService(myEvents: myEvents),
        attendanceReportService: reports ?? _FakeService([_report()]),
      ),
    );
    MyEvent myEvent(EventRole role) => MyEvent(
      eventId: _eventId,
      eventName: '架空イベント',
      startAt: null,
      venue: '架空会場',
      eventRole: role,
    );

    testWidgets('システム管理者: 「受付状況一覧」(受付・スタッフ管理・最終実績Excelとは別)から、このイベントの一覧を開く', (tester) async {
      await _wide(tester);
      final reports = _FakeService([_report()]);
      await tester.pumpWidget(console(const AccessCheck.granted(AccessRole.admin), reports: reports));
      await tester.pumpAndSettle();
      for (final label in ['受付', 'スタッフ管理', '最終実績Excel出力', '受付状況一覧']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(reports.calls, isEmpty, reason: 'メニューを表示しただけでは取得しない');
      await tester.tap(find.text('受付状況一覧'));
      await tester.pumpAndSettle();
      expect(find.byType(ReceptionStatusPage), findsOneWidget);
      expect(tester.widget<ReceptionStatusPage>(find.byType(ReceptionStatusPage)).eventId, _eventId);
      expect(reports.calls, [_eventId]);
    });

    testWidgets('イベント管理者: 担当イベントの管理画面に「受付状況一覧」が出る', (tester) async {
      await _wide(tester);
      await tester.pumpWidget(console(
        const AccessCheck.eventScoped([EventAssignment(eventId: _eventId, role: EventRole.eventManager)]),
        myEvents: [myEvent(EventRole.eventManager)],
      ));
      await tester.pumpAndSettle();
      expect(find.text('受付状況一覧'), findsOneWidget);
    });

    testWidgets('受付スタッフ: 「受付状況一覧」は出ない(受付スタッフ用QRの入口だけ)', (tester) async {
      await _wide(tester);
      final reports = _FakeService([_report()]);
      await tester.pumpWidget(console(
        const AccessCheck.eventScoped([EventAssignment(eventId: _eventId, role: EventRole.staff)]),
        myEvents: [myEvent(EventRole.staff)],
        reports: reports,
      ));
      await tester.pumpAndSettle();
      expect(find.text('受付スタッフ用QRを表示する'), findsOneWidget);
      expect(find.text('受付状況一覧'), findsNothing);
      expect(reports.calls, isEmpty);
    });

    test('受付スタッフの機能には含まれない。サーバーのAPIはイベント管理者以上(受付キーでは呼べない)', () {
      expect(staffFeatureLabels, isNot(contains('受付状況一覧')));
      expect(eventConsoleFeatureLabels, contains('受付状況一覧'));
      final index = File('functions/index.js').readAsStringSync();
      expect(
        index,
        contains('exports.getConfirmedAttendanceReport = confirmedEventCallable("eventManager", EVENT_SCOPES.dataEventId, attendanceReportApi.getReport'),
      );
      expect(index, isNot(contains('confirmedReceptionKeyCallable(attendanceReportApi')));
    });

    test('受付状況一覧は読み取り専用: 受付操作・Firestoreの直接読取・タイマーを使わない', () {
      for (final path in [
        'lib/confirmed/reception_status_page.dart',
        'lib/confirmed/reception_status_summary.dart',
        'lib/confirmed/reception_status_csv.dart',
      ]) {
        final source = File(path).readAsStringSync();
        for (final banned in ['Timer', 'Stream', 'cloud_firestore', 'snapshots', 'checkIn', 'correct', 'cancel', 'PollingSource']) {
          expect(source.contains(banned), isFalse, reason: '$path: $banned');
        }
      }
    });
  });
}
