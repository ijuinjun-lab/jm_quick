// Phase 11A: 新方式イベントの作成(サービス・画面・入口)。通信はすべてMockClient(外部通信0)、Firestoreは使わない。
//  - 送るのはrequestId・入力内容だけ(flow・eventId・createdBy・role・uid等は送らない)
//  - adminだけ作成画面に到達でき、内容の確認ダイアログを経て作成する。二重クリックで作成要求は1回
//  - 通信失敗(作成の有無が不明)では同じrequestIdで再試行でき、明確な拒否のときは新しいrequestId
//  - 従来方式のイベント作成とは別の入口
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/event_create_page.dart';
import 'package:jm_quick/confirmed/event_create_service.dart';
import 'package:jm_quick/confirmed/login_page.dart';
import 'package:jm_quick/pages/event_list_page.dart';
import 'package:jm_quick/services/demo_repository.dart';
import 'package:jm_quick/services/legacy_api.dart';

import 'app_check_fake.dart';
import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'package:jm_quick/confirmed/import_models.dart' show ImportEventSummary;

class FakeEventCreateService implements EventCreateService {
  FakeEventCreateService([this.handler]);
  final Future<CreatedConfirmedEvent> Function(
    String requestId,
    ConfirmedEventDraft draft,
  )?
  handler;
  final List<({String requestId, ConfirmedEventDraft draft})> calls = [];

  @override
  Future<CreatedConfirmedEvent> create({
    required String requestId,
    required ConfirmedEventDraft draft,
  }) async {
    calls.add((requestId: requestId, draft: draft));
    if (handler != null) return handler!(requestId, draft);
    return const CreatedConfirmedEvent(
      eventId: 'evtest',
      eventName: 'x',
      created: true,
    );
  }
}

http.Response _json(Object? body, int code) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  code,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

const _draft = ConfirmedEventDraft(
  eventName: ' PHASE11 STEP3 TEST(架空) ',
  startAt: '2030-11-30T10:00:00+09:00',
  endAt: '2030-11-30T17:00:00+09:00',
  venue: '架空ホール',
  address: '',
  access: '架空駅から徒歩5分',
  programs: [
    ConfirmedProgramDraft(programId: 'program-a', name: ' 架空A '),
    ConfirmedProgramDraft(programId: 'custom-zeta-9', name: '架空Z'),
  ],
);

Widget _app(Widget child) => MaterialApp(home: child);

/// 開催日時/終了日時のpicker(カレンダー→時刻)を操作する。[monthsForward]回だけ「次の月」を押してから
/// [day]日を選び、時刻はキーボード入力モードへ切り替えて[hour]:[minute]を入力する。
/// キャンセルはしない(呼び出し側が別途キャンセルの検証をする)。
Future<void> _pickDateTime(
  WidgetTester tester,
  Key buttonKey, {
  int monthsForward = 0,
  required int day,
  required int hour,
  required int minute,
}) async {
  await tester.ensureVisible(find.byKey(buttonKey));
  await tester.tap(find.byKey(buttonKey));
  await tester.pumpAndSettle();
  for (var i = 0; i < monthsForward; i++) {
    await tester.tap(find.byTooltip('Next month'));
    await tester.pumpAndSettle(); // 月送りのページ遷移を完了させてから次のタップへ進む
  }
  await tester.tap(find.text('$day'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('次へ(時刻を選択)'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Switch to text input mode'));
  await tester.pumpAndSettle();
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), hour.toString().padLeft(2, '0'));
  await tester.enterText(fields.at(1), minute.toString().padLeft(2, '0'));
  await tester.tap(find.text('選択する'));
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('event-name')),
    'PHASE11 STEP3 TEST(架空)',
  );
  // now は 2030-01-01 (JST) 固定。11ヶ月先の30日、10:00〜17:00を選ぶ。
  await _pickDateTime(
    tester,
    const Key('start-at'),
    monthsForward: 10,
    day: 30,
    hour: 10,
    minute: 0,
  );
  await _pickDateTime(
    tester,
    const Key('end-at'),
    day: 30,
    hour: 17,
    minute: 0,
  );
  await tester.enterText(find.byKey(const Key('venue')), '架空ホール');
  await tester.enterText(find.byKey(const Key('access')), '架空駅から徒歩5分');
  await tester.enterText(find.byKey(const Key('program-name-0')), '架空プログラムA');
}

Future<void> _open(WidgetTester tester, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(390, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(page));
  await tester.pump();
}

void main() {
  group('parseJstDateTime', () {
    test('日本時間の入力をオフセット付きISOへ。存在しない日付・時刻は不正', () {
      expect(parseJstDateTime('2030-11-30 10:00'), '2030-11-30T10:00:00+09:00');
      expect(parseJstDateTime('2030/1/2 3:04'), '2030-01-02T03:04:00+09:00');
      for (final bad in [
        '',
        'あした',
        '2030-02-30 10:00',
        '2030-11-30 25:00',
        '2030-11-30 10:60',
        '2030-11-30',
        '2030-13-01 10:00',
      ]) {
        expect(parseJstDateTime(bad), isNull, reason: bad);
      }
    });
    test('作成要求IDは推測されにくく、毎回異なる', () {
      final a = newRequestId();
      final b = newRequestId();
      expect(a, isNot(b));
      expect(RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(a), isTrue);
    });
  });

  group('CallableEventCreateService', () {
    test(
      'IDトークンを送り、送る本文は requestId と入力内容だけ(flow・eventId・createdBy・role・uid・emailは含まない)。program順はorder',
      () async {
        late http.Request seen;
        final service = CallableEventCreateService(
          authClient: FakeAuthClient(signedIn: true, token: 'admin-token'),
          httpClient: MockClient((request) async {
            seen = request;
            return _json({
              'result': {
                'eventId': 'evabc',
                'eventName': 'PHASE11 STEP3 TEST(架空)',
                'kind': 'confirmed',
                'created': true,
              },
            }, 200);
          }),
          baseUrl: 'https://example.invalid',
        );
        final created = await service.create(
          requestId: 'req-0123456789abcdef',
          draft: _draft,
        );
        expect((created.eventId, created.created), ('evabc', true));
        expect(
          seen.url.toString(),
          'https://example.invalid/createConfirmedEvent',
        );
        expect(seen.headers['Authorization'], 'Bearer admin-token');
        final data = (jsonDecode(seen.body) as Map)['data'] as Map;
        for (final forbidden in [
          'flow',
          'eventId',
          'createdBy',
          'updatedBy',
          'role',
          'uid',
          'email',
          'reminderEnabled',
          'winnerMailTemplate',
        ]) {
          expect(data.containsKey(forbidden), isFalse, reason: forbidden);
        }
        expect(data['requestId'], 'req-0123456789abcdef');
        expect(data['eventName'], 'PHASE11 STEP3 TEST(架空)');
        expect(data.containsKey('address'), isFalse, reason: '空の任意項目は送らない');
        expect(
          (data['programs'] as List)
              .map((p) => [(p as Map)['programId'], p['name'], p['order']])
              .toList(),
          [
            ['program-a', '架空A', 0],
            ['custom-zeta-9', '架空Z', 1],
          ],
        );
      },
    );
    test('未ログイン(トークンなし)なら通信しない', () async {
      var requests = 0;
      final service = CallableEventCreateService(
        authClient: FakeAuthClient(signedIn: false, token: null),
        httpClient: MockClient((_) async {
          requests++;
          return _json({}, 200);
        }),
      );
      await expectLater(
        service.create(requestId: 'req-0123456789abcdef', draft: _draft),
        throwsA(isA<EventCreateException>()),
      );
      expect(requests, 0);
    });
    test('エラーは表示用に変換される。通信失敗・5xxは「作成の有無が不明」(ambiguous)、明確な拒否はそうでない', () async {
      CallableEventCreateService with_(http.Client client) =>
          CallableEventCreateService(
            authClient: FakeAuthClient(signedIn: true),
            httpClient: client,
          );
      Future<EventCreateException> fail(http.Client client) async {
        try {
          await with_(
            client,
          ).create(requestId: 'req-0123456789abcdef', draft: _draft);
        } on EventCreateException catch (e) {
          return e;
        }
        fail_('拒否されるはず');
        throw StateError('unreachable');
      }

      final denied = await fail(
        MockClient(
          (_) async => _json({
            'error': {'status': 'PERMISSION_DENIED', 'message': 'x'},
          }, 403),
        ),
      );
      expect((denied.ambiguous, denied.message), (false, 'この操作を行う権限がありません。'));
      final past = await fail(
        MockClient(
          (_) async => _json({
            'error': {
              'status': 'INVALID_ARGUMENT',
              'message': 'x',
              'details': {'code': 'start-in-past'},
            },
          }, 400),
        ),
      );
      expect((past.ambiguous, past.code), (false, 'start-in-past'));
      expect(past.message, contains('現在より後'));
      final conflict = await fail(
        MockClient(
          (_) async => _json({
            'error': {
              'status': 'ALREADY_EXISTS',
              'message': 'x',
              'details': {'code': 'request-id-conflict'},
            },
          }, 409),
        ),
      );
      expect(conflict.message, contains('処理された可能性'));
      final server = await fail(
        MockClient(
          (_) async => _json({
            'error': {'status': 'INTERNAL', 'message': 'secret-internal'},
          }, 500),
        ),
      );
      expect(server.ambiguous, isTrue);
      expect(server.message.contains('secret-internal'), isFalse);
      final network = await fail(
        MockClient((_) async => throw const SocketException('secret-host')),
      );
      expect(network.ambiguous, isTrue);
      expect(network.message.contains('secret-host'), isFalse);
      expect(network.message, contains('二重に作られることはありません'));
    });
  });

  group('入口(認可)', () {
    testWidgets('未ログインではログイン画面だけ。権限なし・staffでは作成フォームが出ない。adminだけフォームが表示される', (
      tester,
    ) async {
      final service = FakeEventCreateService();
      await tester.pumpWidget(
        _app(
          ConfirmedEventCreateRoute(
            authClient: FakeAuthClient(signedIn: false),
            accessService: FakeAccessService([]),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(find.byKey(const Key('create-event')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _app(
          ConfirmedEventCreateRoute(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([const AccessCheck.denied()]),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      expect(find.byKey(const Key('create-event')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _app(
          ConfirmedEventCreateRoute(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              AccessCheck.granted(AccessRole.staff),
            ]),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('イベントの作成は管理者のみ利用できます'), findsOneWidget);
      expect(find.byKey(const Key('create-event')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(const Size(390, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ConfirmedEventCreateRoute(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              AccessCheck.granted(AccessRole.admin),
            ]),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('create-event')), findsOneWidget);
      expect(service.calls, isEmpty);
    });

    testWidgets('管理者のコンソールにだけ「イベント作成」の入口がある。staffには表示されない', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ConfirmedConsolePage(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              AccessCheck.granted(AccessRole.admin),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('イベント作成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _app(
          ConfirmedConsolePage(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              AccessCheck.granted(AccessRole.staff),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('イベント作成'), findsNothing);
    });

    testWidgets(
      '作成直後のイベントIDがコンソール(イベント管理画面)に引き継がれ、各機能の初期値になる(利用者はIDを見ない)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final routes = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              routes.add(settings.name);
              if (settings.name == '/') {
                return MaterialPageRoute<void>(
                  builder: (_) => ConfirmedConsolePage(
                    initialEventId: 'evcreated123',
                    authClient: FakeAuthClient(signedIn: true),
                    accessService: FakeAccessService([
                      AccessCheck.granted(AccessRole.admin),
                    ]),
                    eventSummaryService: FakeImportService(
                      event: const ImportEventSummary(
                        eventId: 'evcreated123',
                        eventName: '架空イベント(作成直後)',
                        startAt: null,
                        venue: '架空ホール',
                        programs: [],
                      ),
                    ),
                  ),
                  settings: settings,
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('NEXT-SCREEN')),
                settings: settings,
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        // 画面にはイベント名が出る(生のIDを利用者に見せる欄は無い)。
        expect(find.text('架空イベント(作成直後)'), findsOneWidget);
        expect(find.textContaining('evcreated123'), findsNothing);
        // CSV取込を開くと、evcreated123が内部的に(URLのクエリとして)引き継がれる。
        await tester.ensureVisible(find.text('CSV取込'));
        await tester.tap(find.text('CSV取込'));
        await tester.pumpAndSettle();
        expect(
          routes.last,
          '/console/import?eventId=evcreated123',
        );
      },
    );

    testWidgets('従来方式の「新しいイベントを作成」とは別の入口(「新方式のイベントを作成」)が並ぶ', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repo = DemoRepository(
        pollInterval: const Duration(minutes: 5),
        api: LegacyApiClient(
          authClient: FakeAuthClient(signedIn: true),
          appCheck: FakeAppCheck(),
          httpClient: MockClient(
            (_) async => _json({
              'result': {'events': []},
            }, 200),
          ),
        ),
      );
      await tester.pumpWidget(_app(EventListPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('新しいイベントを作成'), findsOneWidget);
      expect(find.text('新方式のイベントを作成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('作成フォーム', () {
    testWidgets(
      '入力できる項目: イベント名・開催日時・終了日時・会場・住所・アクセス。programを追加・複数・削除でき、順序を入れ替えられる',
      (tester) async {
        await _open(
          tester,
          ConfirmedEventCreatePage(service: FakeEventCreateService()),
        );
        for (final key in [
          'event-name',
          'start-at',
          'end-at',
          'venue',
          'address',
          'access',
          'program-id-0',
          'program-name-0',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        }
        await tester.tap(find.byKey(const Key('add-program')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('add-program')));
        await tester.pump();
        expect(find.byKey(const Key('program-card-2')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('program-name-0')),
          'いちばん上',
        );
        await tester.enterText(find.byKey(const Key('program-name-1')), 'にばんめ');
        await tester.tap(find.byTooltip('下へ').first);
        await tester.pump();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('program-name-0')))
              .controller!
              .text,
          'にばんめ',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('program-name-1')))
              .controller!
              .text,
          'いちばん上',
        );
        await tester.tap(find.byKey(const Key('program-delete-2')));
        await tester.pump();
        expect(find.byKey(const Key('program-card-2')), findsNothing);
        expect(tester.takeException(), isNull, reason: '390px幅でoverflowしない');
      },
    );

    testWidgets('入力不備(空・未選択・過去・終了が開始以前・program不備・ID重複)では作成要求を送らず、確認ダイアログも出ない', (
      tester,
    ) async {
      final service = FakeEventCreateService();
      await _open(
        tester,
        ConfirmedEventCreatePage(
          service: service,
          now: () => DateTime.utc(2030, 1, 1),
        ),
      );
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pump();
      expect(find.textContaining('イベント名を入力してください'), findsOneWidget);
      expect(find.textContaining('会場名を入力してください'), findsOneWidget);
      expect(find.textContaining('表示名を入力してください'), findsOneWidget);
      expect(find.textContaining('開催日時をカレンダーから選択してください'), findsOneWidget);
      expect(find.text('この内容でイベントを作成します'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('event-name')),
        'PHASE11 STEP3 TEST(架空)',
      );
      await tester.enterText(find.byKey(const Key('venue')), '架空ホール');
      await tester.enterText(find.byKey(const Key('access')), '架空駅から徒歩5分');
      await tester.enterText(
        find.byKey(const Key('program-name-0')),
        '架空プログラムA',
      );

      // 今日(2030-01-01)は選べるが、現在(JST 09:00相当)より前の時刻08:00を選ぶと拒否される。
      await _pickDateTime(
        tester,
        const Key('start-at'),
        day: 1,
        hour: 8,
        minute: 0,
      );
      expect(
        find.textContaining('2030-01-01 08:00'), // pickerで選んだ値がそのままボタンに表示されている
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pump();
      expect(find.textContaining('現在より後'), findsOneWidget);

      // 未来の正しい開催日時へ選び直す(11ヶ月先の30日 10:00)。
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      // 終了日時を開始より前(同日09:00)にすると、送信前にも案内が出る。
      await _pickDateTime(
        tester,
        const Key('end-at'),
        day: 30,
        hour: 9,
        minute: 0,
      );
      expect(find.byKey(const Key('date-order-warning')), findsOneWidget);
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pump();
      // 送信前の事前案内(date-order-warning)と、送信時のproblems一覧の両方に同じ理由が出る。
      expect(find.textContaining('終了日時は開催日時より後'), findsWidgets);

      // 終了日時を17:00へ選び直すと、事前案内は消える。
      await _pickDateTime(
        tester,
        const Key('end-at'),
        day: 30,
        hour: 17,
        minute: 0,
      );
      expect(find.byKey(const Key('date-order-warning')), findsNothing);

      await tester.tap(find.byKey(const Key('add-program')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('program-id-1')),
        'program-1',
      );
      await tester.enterText(find.byKey(const Key('program-name-1')), 'B');
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pump();
      expect(find.textContaining('IDが重複'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('program-id-1')), 'Bad_ID');
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pump();
      expect(find.textContaining('英小文字・数字・ハイフン'), findsWidgets);
      expect(service.calls, isEmpty);
    });

    testWidgets('date/time pickerをキャンセルすると、既存の選択値は変更されない', (tester) async {
      await _open(
        tester,
        ConfirmedEventCreatePage(
          service: FakeEventCreateService(),
          now: () => DateTime.utc(2030, 1, 1),
        ),
      );
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      expect(find.textContaining('2030-11-30 10:00'), findsOneWidget);

      // 日付pickerを開いてキャンセルしても、既存値のまま。
      await tester.tap(find.byKey(const Key('start-at')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2030-11-30 10:00'), findsOneWidget);

      // 日付だけ選んで時刻pickerでキャンセルしても、既存値のまま(日付だけ確定させない)。
      await tester.tap(find.byKey(const Key('start-at')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15')); // 同じ月の別の日
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ(時刻を選択)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2030-11-30 10:00'), findsOneWidget);
      expect(find.textContaining('2030-11-15'), findsNothing);
    });

    testWidgets(
      '最終確認ダイアログにイベント名・開催日時・会場・program数・program名が表示され、キャンセルなら作成要求は送られない',
      (tester) async {
        final service = FakeEventCreateService();
        await _open(
          tester,
          ConfirmedEventCreatePage(
            service: service,
            now: () => DateTime.utc(2030, 1, 1),
          ),
        );
        await _fill(tester);
        await tester.tap(find.byKey(const Key('create-event')));
        await tester.pumpAndSettle();
        expect(find.text('この内容でイベントを作成します'), findsOneWidget);
        Finder inDialog(String text) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(text),
        );
        expect(inDialog('PHASE11 STEP3 TEST(架空)'), findsOneWidget);
        expect(inDialog('2030-11-30 10:00'), findsOneWidget);
        expect(inDialog('架空ホール'), findsOneWidget);
        expect(inDialog('1件'), findsOneWidget);
        expect(inDialog('架空プログラムA'), findsOneWidget);
        expect(find.textContaining('メールは送信されません'), findsWidgets);
        await tester.tap(find.text('キャンセル'));
        await tester.pumpAndSettle();
        expect(service.calls, isEmpty);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('create-event')))
              .onPressed,
          isNotNull,
          reason: 'キャンセル後は再び押せる',
        );
      },
    );

    testWidgets(
      '作成中はボタンが無効で、二重クリックでも作成要求は1回。成功後は新方式の管理画面へ遷移する(legacy管理画面へは行かない)',
      (tester) async {
        final release = Completer<void>();
        final service = FakeEventCreateService((requestId, draft) async {
          await release.future;
          return const CreatedConfirmedEvent(
            eventId: 'evnew123',
            eventName: 'x',
            created: true,
          );
        });
        String? navigatedTo;
        await _open(
          tester,
          ConfirmedEventCreatePage(
            service: service,
            now: () => DateTime.utc(2030, 1, 1),
            onCreated: (context, id) => navigatedTo = id,
          ),
        );
        await _fill(tester);
        await tester.tap(find.byKey(const Key('create-event')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('作成する'));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('create-event')))
              .onPressed,
          isNull,
          reason: '作成中は無効',
        );
        await tester.tap(
          find.byKey(const Key('create-event')),
          warnIfMissed: false,
        );
        await tester.pump();
        release.complete();
        await tester.pumpAndSettle();
        expect(service.calls.length, 1);
        expect(navigatedTo, 'evnew123');
        final draft = service.calls.single.draft;
        expect(draft.startAt, '2030-11-30T10:00:00+09:00');
        expect(draft.programs.map((p) => p.programId).toList(), ['program-1']);
      },
    );

    testWidgets(
      '既定の遷移先は新方式の管理画面(/console?eventId=...)。従来方式の管理画面(/admin)へは遷移しない',
      (tester) async {
        final routes = <String?>[];
        await tester.binding.setSurfaceSize(const Size(390, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              routes.add(settings.name);
              if (settings.name == '/') {
                return MaterialPageRoute<void>(
                  builder: (_) => ConfirmedEventCreatePage(
                    service: FakeEventCreateService(),
                    now: () => DateTime.utc(2030, 1, 1),
                  ),
                  settings: settings,
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('NEW-CONSOLE')),
                settings: settings,
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        await _fill(tester);
        await tester.tap(find.byKey(const Key('create-event')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('作成する'));
        await tester.pumpAndSettle();
        expect(routes.last, '/console?eventId=evtest');
        expect(routes.any((r) => r != null && r.startsWith('/admin')), isFalse);
        expect(find.text('NEW-CONSOLE'), findsOneWidget);
      },
    );

    testWidgets(
      '通信失敗(作成の有無が不明)では同じrequestIdで再試行できる。サーバーが明確に拒否したときは新しいrequestId',
      (tester) async {
        var attempt = 0;
        var idCounter = 0;
        final service = FakeEventCreateService((requestId, draft) async {
          attempt++;
          if (attempt == 1) {
            throw const EventCreateException('通信に失敗しました。', ambiguous: true);
          }
          if (attempt == 2) {
            throw const EventCreateException(
              '開催日時は現在より後の日時にしてください。',
              code: 'start-in-past',
            );
          }
          return const CreatedConfirmedEvent(
            eventId: 'evok',
            eventName: 'x',
            created: true,
          );
        });
        await _open(
          tester,
          ConfirmedEventCreatePage(
            service: service,
            now: () => DateTime.utc(2030, 1, 1),
            requestIdFactory: () => 'req-id-${++idCounter}-0123456789',
            onCreated: (context, id) {},
          ),
        );
        await _fill(tester);
        Future<void> submit() async {
          await tester.tap(find.byKey(const Key('create-event')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('作成する'));
          await tester.pumpAndSettle();
        }

        await submit();
        expect(find.text('通信に失敗しました。'), findsOneWidget);
        await submit();
        await submit();
        expect(service.calls.length, 3);
        expect(service.calls.map((c) => c.requestId).toList(), [
          'req-id-1-0123456789',
          'req-id-1-0123456789',
          'req-id-2-0123456789',
        ]);
        expect(
          service.calls[0].requestId,
          service.calls[1].requestId,
          reason: '通信失敗後の再試行は同じrequestId',
        );
        expect(
          service.calls[2].requestId,
          isNot(service.calls[1].requestId),
          reason: '明確な拒否の後は新しいrequestId',
        );
      },
    );
  });

  group('開催日時・終了日時のdate/time picker', () {
    testWidgets(
      '開催日時: カレンダーで日付を選び、時刻を選ぶと、選択値がそのままボタンに表示される(キーボードで文字列を打たなくてよい)',
      (tester) async {
        await _open(
          tester,
          ConfirmedEventCreatePage(
            service: FakeEventCreateService(),
            now: () => DateTime.utc(2030, 1, 1),
          ),
        );
        expect(find.text('日付・時刻を選択'), findsNWidgets(2)); // 開催・終了とも未選択
        await _pickDateTime(
          tester,
          const Key('start-at'),
          monthsForward: 10,
          day: 30,
          hour: 10,
          minute: 0,
        );
        expect(find.textContaining('2030-11-30 10:00'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('start-at')))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('終了日時: 開催日時と同様に選べる。「クリア」で未選択に戻せる(終了日時は任意のまま)', (tester) async {
      await _open(
        tester,
        ConfirmedEventCreatePage(
          service: FakeEventCreateService(),
          now: () => DateTime.utc(2030, 1, 1),
        ),
      );
      expect(
        find.byKey(const Key('end-at-clear')),
        findsNothing,
      ); // 未選択の間はクリアを出さない
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      await _pickDateTime(
        tester,
        const Key('end-at'),
        day: 30,
        hour: 17,
        minute: 0,
      );
      expect(find.textContaining('2030-11-30 17:00'), findsOneWidget);
      expect(find.byKey(const Key('end-at-clear')), findsOneWidget);
      await tester.tap(find.byKey(const Key('end-at-clear')));
      await tester.pump();
      expect(find.textContaining('2030-11-30 17:00'), findsNothing);
      expect(find.byKey(const Key('end-at-clear')), findsNothing);
      // 終了日時は任意なので、クリアしたままでも他が正しければ作成要求を送れる。
      final service = FakeEventCreateService();
      await _open(
        tester,
        ConfirmedEventCreatePage(
          service: service,
          now: () => DateTime.utc(2030, 1, 1),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('event-name')),
        'PHASE11 STEP3 TEST(架空)',
      );
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      await tester.enterText(find.byKey(const Key('venue')), '架空ホール');
      await tester.enterText(
        find.byKey(const Key('program-name-0')),
        '架空プログラムA',
      );
      await tester.tap(find.byKey(const Key('create-event')));
      await tester.pumpAndSettle();
      expect(find.text('この内容でイベントを作成します'), findsOneWidget);
      await tester.tap(find.text('作成する'));
      await tester.pumpAndSettle();
      expect(service.calls.single.draft.endAt, isNull);
    });

    testWidgets('PC相当の幅(900px)でも、date/time pickerを含めて重大なoverflowが出ない', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ConfirmedEventCreatePage(
            service: FakeEventCreateService(),
            now: () => DateTime.utc(2030, 1, 1),
          ),
        ),
      );
      await tester.pump();
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      await _pickDateTime(
        tester,
        const Key('end-at'),
        day: 30,
        hour: 17,
        minute: 0,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('390px幅でも、date/time picker(カレンダー・時刻入力)を含めて重大なoverflowが出ない', (
      tester,
    ) async {
      await _open(
        tester,
        ConfirmedEventCreatePage(
          service: FakeEventCreateService(),
          now: () => DateTime.utc(2030, 1, 1),
        ),
      );
      await _pickDateTime(
        tester,
        const Key('start-at'),
        monthsForward: 10,
        day: 30,
        hour: 10,
        minute: 0,
      );
      await _pickDateTime(
        tester,
        const Key('end-at'),
        day: 30,
        hour: 17,
        minute: 0,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('境界の静的検査', () {
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    test('作成画面・サービスはFirestoreを直接使わず、flow・eventIdをクライアントから送らない', () {
      for (final path in [
        'lib/confirmed/event_create_page.dart',
        'lib/confirmed/event_create_service.dart',
      ]) {
        final text = code(path);
        for (final forbidden in [
          'cloud_firestore',
          'FirebaseFirestore',
          '.snapshots(',
          '.collection(',
          'FieldValue',
          "'flow'",
          "'eventId':",
          "'createdBy'",
          "'role'",
          "'uid'",
        ]) {
          expect(
            text.contains(forbidden),
            isFalse,
            reason: '$path: $forbidden',
          );
        }
      }
      expect(
        code('lib/confirmed/event_create_service.dart'),
        contains('createConfirmedEvent'),
      );
    });
    test('作成画面に固有のprogram名(いぬ・ねこ・トーク等)をハードコードしない', () {
      final text = code('lib/confirmed/event_create_page.dart');
      for (final name in ['いぬ', 'ねこ', 'トーク', 'custom-zeta']) {
        expect(text.contains(name), isFalse, reason: name);
      }
    });
    test('従来方式のイベント作成(createEvent)は従来どおりで、confirmedの作成とは別のAPIを呼ぶ', () {
      final repo = code('lib/services/demo_repository.dart');
      expect(repo, contains("'createLegacyEvent'"));
      expect(repo.contains('createConfirmedEvent'), isFalse);
    });
  });
}

void fail_(String message) => throw TestFailure(message);
