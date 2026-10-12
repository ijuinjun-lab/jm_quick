// 主催者用「受付状況一覧」。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて架空(メールは .invalid)。
//  - 集計: 申込件数は参加者単位・予定/実来場人数は延べ・program別は参加者×program単位の件数ベースの受付率・時間帯別
//  - 受付状態の正本はサーバー応答(programAttendancesの現在値): 取消済み=未受付・訂正後の人数・対象外の参加者
//  - 画面: 開いたときに1回だけ取得・手動更新のみ(自動更新なし)・二重取得の防止・エラー時は前回の内容を残す
//  - 一覧: 1行=参加者×program・氏名検索・program/受付状態の絞り込み・受付時刻の並べ替え・1,000行
//  - 入口・権限: システム管理者・イベント管理者のイベント管理画面だけ。スタッフには出さない。サーバーの権限はeventManager
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/assignment_service.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/import_models.dart';
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
}) => {
  'participantId': id,
  'importSequence': committed == null ? null : 1,
  'batchCommitted': committed,
  'importRow': 2,
  'name': name,
  'kana': 'かくう$id',
  'email': '$id@example.invalid',
  'status': status,
  'hebelResidence': {'category': 'none', 'label': '該当なし（いいえ）'},
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
      _person('p01', '架空 一郎', programs: programsOf('p01', [
        _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 3, at: '2026-11-30T01:23:45.000Z'),
        _entry('program-2', planned: 1, time: '14:10-14:50'),
      ])),
      // 受付取消済み(正本では未受付に戻っている)
      _person('p02', '架空 二郎', programs: programsOf('p02', [
        _entry('program-1', time: '11:10-11:50'),
      ])),
      // いぬ・トークとも受付済み
      _person('p03', '架空 三子', programs: programsOf('p03', [
        _entry('program-3', planned: 1, time: '13:00-14:00', checkedIn: true, attended: 1, at: '2026-11-30T04:00:00.000Z'),
        _entry('program-2', planned: 3, time: '14:50-15:30', checkedIn: true, attended: 3, at: '2026-11-30T05:10:00.000Z'),
      ])),
      _person('p04', '架空 四郎', programs: programsOf('p04', [
        _entry('program-3', time: '13:00-14:00'),
      ])),
      // 対象外: 有効でない参加者・未確定の取込回・申込programなし
      _person('p05', '架空 対象外五', status: 'inactive', programs: [
        _entry('program-1', time: '10:30-11:10', checkedIn: true, attended: 9, at: '2026-11-30T01:00:00.000Z'),
      ]),
      _person('p06', '架空 対象外六', committed: false, programs: [_entry('program-1', planned: 9)]),
      _person('p07', '架空 対象外七'),
      // 取込回なし(対象)・時間未設定
      _person('p08', '架空 八子', committed: null, programs: programsOf('p08', [
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

Widget _page(_FakeService service, {DateTime Function()? now}) => MaterialApp(
  home: ReceptionStatusPage(
    eventId: _eventId,
    eventName: '架空イベント',
    service: service,
    now: now ?? () => DateTime.utc(2026, 11, 30, 3, 4, 5),
  ),
);

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
  });

  group('画面', () {
    testWidgets('開いたときに1回だけ取得し、全体・program別・時間帯別・一覧と最終更新(日本時間)を表示する', (tester) async {
      await _wide(tester);
      final service = _FakeService([_report()]);
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      expect(service.calls, [_eventId]);
      expect(find.text('最終更新：2026/11/30 12:04:05（日本時間）'), findsOneWidget);
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
      expect(_cells(tester, const ValueKey('status-row-p01-program-1')),
          ['架空 一郎', '架空の譲渡会（ねこ）', '10:30-11:10', '2名', '3名', '受付済み', '11/30 10:23']);
      expect(_cells(tester, const ValueKey('status-row-p01-program-2')),
          ['架空 一郎', '架空の譲渡会（いぬ）', '14:10-14:50', '1名', '—', '未受付', '—']);
      expect(find.text('表示中 7行 / 全7行'), findsOneWidget);
      // 不要な個人情報(メールアドレス・かな・HEBEL属性)・対象外の参加者は表示しない
      expect(find.textContaining('@'), findsNothing);
      expect(find.textContaining('かくう'), findsNothing);
      expect(find.textContaining('該当なし'), findsNothing);
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
      expect(_tile(tester, 'total-attended'), '実来場人数（延べ）|5名|複数プログラムの参加を含む');
      expect(_cells(tester, const ValueKey('status-row-p01-program-1'))[4], '2名', reason: '人数訂正後の値');
      expect(_cells(tester, const ValueKey('status-row-p03-program-3')).sublist(4),
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
      expect(_tile(tester, 'total-applications'), '申込件数|0件');
      expect(_tile(tester, 'total-rate'), '受付率|—|受付済み申込件数 ÷ 申込件数');
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
            _person('q${i.toString().padLeft(4, '0')}', '架空 大量$i', programs: [
              _entry('program-1', time: '10:30-11:10', checkedIn: i.isEven, attended: i.isEven ? 2 : null,
                  at: i.isEven ? '2026-11-30T01:00:00.000Z' : null),
              _entry('program-2', time: '14:10-14:50'),
            ]),
        ],
      })) as Map<String, dynamic>);
      final watch = Stopwatch()..start();
      await tester.pumpWidget(_page(_FakeService([big])));
      await tester.pumpAndSettle();
      watch.stop();
      expect(find.text('表示中 1000行 / 全1000行'), findsOneWidget);
      expect(_tile(tester, 'total-applications'), '申込件数|500件');
      expect(_tile(tester, 'total-rate'), '受付率|50.0%|受付済み申込件数 ÷ 申込件数');
      final built = find.byWidgetPredicate(
        (w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('status-row-'),
      );
      expect(built.evaluate().length, lessThan(100), reason: '画面外の行は作らない');
      final scrollable = find.descendant(
        of: find.byKey(const Key('reception-status-scroll')),
        matching: find.byType(Scrollable),
      ).first;
      // 最後の行までスクロールできる(スクロール中も作られている行は一部だけ)
      await tester.scrollUntilVisible(find.byKey(const ValueKey('status-row-q0499-program-2')), 3000, scrollable: scrollable);
      expect(built.evaluate().length, lessThan(100));
      await tester.scrollUntilVisible(find.byKey(const Key('reception-status-search')), -3000, scrollable: scrollable);
      await tester.enterText(find.byKey(const Key('reception-status-search')), '大量499');
      await tester.pumpAndSettle();
      expect(find.text('表示中 2行 / 全1000行'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('status-row-q0499-program-2')), 300, scrollable: scrollable);
      expect(find.byKey(const ValueKey('status-row-q0499-program-1')), findsOneWidget);
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
      for (final path in ['lib/confirmed/reception_status_page.dart', 'lib/confirmed/reception_status_summary.dart']) {
        final source = File(path).readAsStringSync();
        for (final banned in ['Timer', 'Stream', 'cloud_firestore', 'snapshots', 'checkIn', 'correct', 'cancel', 'PollingSource']) {
          expect(source.contains(banned), isFalse, reason: '$path: $banned');
        }
      }
    });
  });
}
