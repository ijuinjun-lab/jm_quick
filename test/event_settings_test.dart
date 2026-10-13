// イベント設定(基本情報の確認・修正)。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて架空。
//  - 日本時間の入力 ⇔ UTC(ISO)の変換・暦として成立しない値の拒否
//  - 変更点の計算: 変更したフィールドだけ・変更なし・開始>=終了・終了の削除不可・未設定の終了の追加・日付をまたぐ終了の日数を保つ
//  - 画面: 保存前に変更前→変更後を確認・読み込んだ時点の値(expected)を送る・送信済みメールの警告・同時更新の競合・保存後の再読み込み
//  - 入口: イベント管理画面の「イベント設定」(準備中ではない)。戻るとイベント情報を読み直す
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/event_settings_page.dart';
import 'package:jm_quick/confirmed/event_settings_service.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'reception_staff_key_fake.dart';
import 'reminder_test.dart' show FakeReminderService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService;

const _eventId = 'evSettings0123456789';

EventSettings _settings({
  String eventName = '架空イベント',
  String? startAt = '2026-11-30T01:00:00.000Z', // 日本時間 10:00
  String? endAt = '2026-11-30T08:00:00.000Z', // 日本時間 17:00
  String venue = '架空会場',
  String? address = '架空県架空市1-2-3',
  String? access = '架空駅から徒歩5分',
}) => EventSettings.fromJson({
  'eventName': eventName, 'startAt': startAt, 'endAt': endAt, 'venue': venue, 'address': address, 'access': access,
});

EventSettingsInput _input(EventSettings s, {String? name, String? date, String? start, String? end, String? venue, String? address, String? access}) => (
  eventName: name ?? s.eventName,
  date: date ?? (s.startAt == null ? '' : jstDateText(s.startAt!)),
  startTime: start ?? (s.startAt == null ? '' : jstTimeText(s.startAt!)),
  endTime: end ?? (s.endAt == null ? '' : jstTimeText(s.endAt!)),
  venue: venue ?? s.venue,
  address: address ?? s.address ?? '',
  access: access ?? s.access ?? '',
);

class _FakeSettingsService implements EventSettingsService {
  _FakeSettingsService(this.views, {this.updateError});
  final List<EventSettingsView> views;
  WinnerSendException? updateError;
  int getCalls = 0;
  final updates = <({Map<String, Object?> changes, Map<String, Object?> expected})>[];

  @override
  Future<EventSettingsView> getSettings(String eventId) async {
    getCalls += 1;
    return views.length > 1 ? views.removeAt(0) : views.first;
  }

  @override
  Future<EventSettings> update(String eventId, {required Map<String, Object?> changes, required Map<String, Object?> expected}) async {
    updates.add((changes: changes, expected: expected));
    if (updateError != null) throw updateError!;
    return views.first.settings;
  }
}

EventSettingsView _view(EventSettings s, {EventSentMail sentMail = const EventSentMail()}) => EventSettingsView(settings: s, sentMail: sentMail);

Future<void> _open(WidgetTester tester, _FakeSettingsService service) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: EventSettingsPage(eventId: _eventId, service: service)));
  await tester.pumpAndSettle();
}

ButtonStyleButton _saveButton(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.ancestor(of: find.text('変更内容を確認して保存'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));

void main() {
  group('日本時間の入力と変換', () {
    test('日本時間の日付・時刻 → UTC。表示はその逆', () {
      expect(jstInputToUtc('2026/11/30', '10:00'), DateTime.utc(2026, 11, 30, 1));
      expect(jstInputToUtc('2026-12-01', '8:30'), DateTime.utc(2026, 11, 30, 23, 30), reason: '日本時間 12/1 08:30 = UTC 11/30 23:30');
      expect(jstDateText(DateTime.utc(2026, 11, 30, 23, 30)), '2026/12/01');
      expect(jstTimeText(DateTime.utc(2026, 11, 30, 23, 30)), '08:30');
      for (final (d, t) in [('2026/02/30', '10:00'), ('2026/11/30', '25:00'), ('2026/11/30', '10:60'), ('2026/13/01', '10:00'), ('11/30', '10:00'), ('2026/11/30', '10時')]) {
        expect(jstInputToUtc(d, t), isNull, reason: '$d $t');
      }
    });
  });

  group('変更点の計算', () {
    final s = _settings();
    test('変更なしは送るものが無い。変更したフィールドだけ(イベント名・会場・住所・アクセス)', () {
      expect(computeEventSettingsChanges(s, _input(s)).changes, isEmpty);
      final r = computeEventSettingsChanges(s, _input(s, name: ' 架空イベント(訂正) ', venue: '架空第二会場', access: ''));
      expect(r.error, isNull);
      expect(r.changes, {'eventName': '架空イベント(訂正)', 'venue': '架空第二会場', 'access': null});
      expect(r.diff.map((d) => d.$1), ['イベント名', '会場名', 'アクセス']);
      expect(r.diff.last, ('アクセス', '架空駅から徒歩5分', '(未設定)'));
    });

    test('開催日の変更は開始・終了の両方をUTCのISOで送る(日本時間で表示)', () {
      final r = computeEventSettingsChanges(s, _input(s, date: '2026/12/05'));
      expect(r.changes, {'startAt': '2026-12-05T01:00:00.000Z', 'endAt': '2026-12-05T08:00:00.000Z'});
      expect(r.diff.first, ('開始日時', '2026/11/30 10:00', '2026/12/05 10:00'));
    });

    test('開始>=終了・形式違い・空のイベント名/会場はエラー(送らない)', () {
      for (final input in [
        _input(s, end: '10:00'),
        _input(s, start: '18:00'),
        _input(s, date: '2026/02/30'),
        _input(s, end: '5pm'),
        _input(s, name: '  '),
        _input(s, venue: ''),
      ]) {
        final r = computeEventSettingsChanges(s, input);
        expect(r.error, isNotNull, reason: '$input');
        expect(r.changes, isEmpty);
      }
    });

    test('未設定の終了時刻は追加できる。設定済みの終了時刻は削除できない', () {
      final noEnd = _settings(endAt: null);
      expect(computeEventSettingsChanges(noEnd, _input(noEnd)).changes, isEmpty);
      expect(computeEventSettingsChanges(noEnd, _input(noEnd, end: '17:00')).changes, {'endAt': '2026-11-30T08:00:00.000Z'});
      expect(computeEventSettingsChanges(s, _input(s, end: '')).error, contains('削除できません'));
    });

    test('終了日時が開始と別の日付なら日数の差を保つ。秒のある保存値は、触らなければ変更なし', () {
      final overnight = _settings(startAt: '2026-11-30T10:00:00.000Z', endAt: '2026-11-30T16:00:00.000Z'); // 19:00〜翌01:00(日本時間)
      expect(computeEventSettingsChanges(overnight, _input(overnight)).changes, isEmpty);
      expect(computeEventSettingsChanges(overnight, _input(overnight, end: '02:00')).changes, {'endAt': '2026-11-30T17:00:00.000Z'});
      final seconds = _settings(startAt: '2026-11-30T01:00:30.000Z');
      expect(computeEventSettingsChanges(seconds, _input(seconds)).changes, isEmpty);
    });
  });

  group('画面', () {
    testWidgets('保存されている値を表示し、変更が無ければ保存できない。変更すると確認(変更前→変更後)を経て、変更したフィールドと読み込んだ時点の値だけを送る', (tester) async {
      final service = _FakeSettingsService([_view(_settings()), _view(_settings(eventName: '架空イベント(訂正)'))]);
      await _open(tester, service);
      expect(tester.widget<TextField>(find.byKey(const Key('event-settings-name'))).controller!.text, '架空イベント');
      expect(tester.widget<TextField>(find.byKey(const Key('event-settings-date'))).controller!.text, '2026/11/30');
      expect(tester.widget<TextField>(find.byKey(const Key('event-settings-start'))).controller!.text, '10:00');
      expect(tester.widget<TextField>(find.byKey(const Key('event-settings-end'))).controller!.text, '17:00');
      expect(find.byKey(const Key('event-settings-no-change')), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      expect(find.byKey(const Key('event-settings-mail-warning')), findsNothing, reason: '送信済みメールが無ければ警告しない');

      await tester.enterText(find.byKey(const Key('event-settings-name')), '架空イベント(訂正)');
      await tester.pumpAndSettle();
      expect(_saveButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('event-settings-save')));
      await tester.pumpAndSettle();
      expect(find.text('変更前：架空イベント'), findsOneWidget);
      expect(find.text('変更後：架空イベント(訂正)'), findsOneWidget);
      expect(service.updates, isEmpty, reason: '確定するまで送らない');
      await tester.tap(find.byKey(const Key('event-settings-confirm-save')));
      await tester.pumpAndSettle();
      expect(service.updates.single.changes, {'eventName': '架空イベント(訂正)'});
      expect(service.updates.single.expected, {'eventName': '架空イベント'});
      expect(service.getCalls, 2, reason: '保存後に最新の内容を読み直す');
      expect(find.byKey(const Key('event-settings-saved')), findsOneWidget);
    });

    testWidgets('やめるを押せば保存しない', (tester) async {
      final service = _FakeSettingsService([_view(_settings())]);
      await _open(tester, service);
      await tester.enterText(find.byKey(const Key('event-settings-venue')), '別の会場');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-settings-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('やめる'));
      await tester.pumpAndSettle();
      expect(service.updates, isEmpty);
    });

    testWidgets('送信済みメールがあれば、画面と保存前の確認の両方で警告する(再送はしない旨)', (tester) async {
      final service = _FakeSettingsService([_view(_settings(), sentMail: const EventSentMail(sentCount: 10, unknownCount: 1, jobCount: 2))]);
      await _open(tester, service);
      expect(find.byKey(const Key('event-settings-mail-warning')), findsOneWidget);
      expect(find.textContaining('送信済み10件・結果不明1件'), findsOneWidget);
      expect(find.textContaining('メールの再送や変更のお知らせは送られません'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('event-settings-access')), '架空駅から徒歩7分');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-settings-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-settings-confirm-mail-warning')), findsOneWidget);
    });

    testWidgets('未設定の終了時刻: 案内を出し、入力すると終了日時だけを送る(読み込んだ時点の値はnull)', (tester) async {
      final service = _FakeSettingsService([_view(_settings(endAt: null))]);
      await _open(tester, service);
      expect(find.byKey(const Key('event-settings-end-missing')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('event-settings-end')), '17:00');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-settings-save')));
      await tester.pumpAndSettle();
      expect(find.text('変更前：(未設定)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('event-settings-confirm-save')));
      await tester.pumpAndSettle();
      expect(service.updates.single.changes, {'endAt': '2026-11-30T08:00:00.000Z'});
      expect(service.updates.single.expected, {'endAt': null});
    });

    testWidgets('入力エラー(終了が開始より前)は保存できない', (tester) async {
      final service = _FakeSettingsService([_view(_settings())]);
      await _open(tester, service);
      await tester.enterText(find.byKey(const Key('event-settings-end')), '09:00');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-settings-input-error')), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
    });

    testWidgets('同時更新の競合・権限なしはエラーを表示し、「データベースに保存されたデータを読み込む」で読み直せる', (tester) async {
      final service = _FakeSettingsService([_view(_settings())],
          updateError: const WinnerSendException('ほかの操作でイベント設定が変更されています。最新の内容を読み込み直してから、もう一度保存してください。', code: 'event-settings-changed'));
      await _open(tester, service);
      await tester.enterText(find.byKey(const Key('event-settings-venue')), '別の会場');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-settings-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-settings-confirm-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-settings-save-error')), findsOneWidget);
      expect(find.textContaining('ほかの操作でイベント設定が変更されています'), findsOneWidget);
      expect(find.text('データベースに保存されたデータを読み込む'), findsOneWidget);
      expect(find.text('最新の内容を読み込む'), findsNothing);
      await tester.tap(find.byKey(const Key('event-settings-reload')));
      await tester.pumpAndSettle();
      expect(service.getCalls, 2);
      expect(tester.widget<TextField>(find.byKey(const Key('event-settings-venue'))).controller!.text, '架空会場');
    });

    test('サーバーの理由コードを表示用のメッセージにする', () {
      Map<String, dynamic> body(String status, String code) => {'error': {'status': status, 'details': {'code': code}}};
      expect(CallableEventSettingsService.errorFrom(409, body('ABORTED', 'event-settings-changed')).message, contains('ほかの操作'));
      expect(CallableEventSettingsService.errorFrom(400, body('FAILED_PRECONDITION', 'no-change')).message, '変更がありません。');
      expect(CallableEventSettingsService.errorFrom(400, body('INVALID_ARGUMENT', 'invalid-time-range')).message, contains('開始日時より後'));
      expect(CallableEventSettingsService.errorFrom(403, body('PERMISSION_DENIED', 'x')).message, 'この操作を行う権限がありません。');
    });

    testWidgets('390px幅で重大なoverflowや例外が出ない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: EventSettingsPage(
        eventId: _eventId,
        service: _FakeSettingsService([_view(_settings(), sentMail: const EventSentMail(sentCount: 3))]),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('入口(イベント管理画面)', () {
    testWidgets('「イベント設定」は押せる機能。このイベントの設定画面を開き、戻るとイベント情報を読み直す', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final summaries = FakeImportService(event: const ImportEventSummary(
        eventId: _eventId, eventName: '架空イベント', startAt: null, venue: '架空会場', programs: [],
      ));
      final settings = _FakeSettingsService([_view(_settings())]);
      await tester.pumpWidget(MaterialApp(
        home: ConfirmedConsolePage(
          initialEventId: _eventId,
          authClient: FakeAuthClient(signedIn: true),
          accessService: FakeAccessService([const AccessCheck.granted(AccessRole.admin)]),
          receptionStaffKeyIssuer: FakeReceptionStaffKeyIssuer(),
          eventSummaryService: summaries,
          winnerMailService: FakeWinnerMailService(),
          winnerSendService: FakeSendService(),
          reminderService: FakeReminderService(),
          eventSettingsService: settings,
        ),
      ));
      await tester.pumpAndSettle();
      final callsBefore = summaries.eventCalls.length;
      expect(find.text('イベント名・日時・会場などの基本情報を確認・修正します'), findsOneWidget);
      await tester.tap(find.text('イベント設定'));
      await tester.pumpAndSettle();
      expect(find.byType(EventSettingsPage), findsOneWidget);
      expect(tester.widget<EventSettingsPage>(find.byType(EventSettingsPage)).eventId, _eventId);
      expect(settings.getCalls, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(summaries.eventCalls.length, callsBefore + 1, reason: '戻ったらイベント情報(名前・日時。欠席判定に渡す終了日時を含む)を読み直す');
      expect(staffFeatureLabels, isNot(contains('イベント設定')), reason: '受付スタッフには出さない');
    });
  });
}
