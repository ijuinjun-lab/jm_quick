// Phase 11B-2: confirmedイベント一覧(/console/events)。管理画面→イベント選択→そのイベントの管理機能への入口。
//  - 既存のadmin専用callable(listLegacyEvents)を再利用し、Functions/Rulesは変更しない
//  - flow=="confirmed"だけを一覧に出し、legacyイベントは出さない(誤ってconfirmed管理画面へ入れない)
//  - 選択すると既存の/console?eventId=…へ進む(eventIdは利用者に入力させない)
//  - データはすべて完全な架空(本番の実イベント名・実eventIdはここに写さない)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/confirmed_event_list_page.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/event_list_service.dart';
import 'package:jm_quick/confirmed/login_page.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

http.Response _json(Object? body, int code) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  code,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

class FakeEventListService implements EventListService {
  FakeEventListService({this.items = const [], this.error});
  List<ConfirmedEventListItem> items;
  EventListException? error;
  int calls = 0;

  @override
  Future<List<ConfirmedEventListItem>> listConfirmedEvents() async {
    calls++;
    if (error != null) throw error!;
    return items;
  }
}

const _confirmedA = ConfirmedEventListItem(
  eventId: 'evfixtureconfirmedA',
  eventName: '架空テストイベントA(confirmed)',
  startAt: null,
  venue: '架空会場A',
);

Widget _app(Widget child) => MaterialApp(home: child);

void main() {
  group('入口(認可)', () {
    testWidgets('未ログインではログイン画面だけ。権限なし・staffでは一覧が出ない。adminだけ表示される', (
      tester,
    ) async {
      final service = FakeEventListService(items: [_confirmedA]);
      Widget route(FakeAuthClient auth, FakeAccessService access) => _app(
        ConfirmedEventListRoute(
          authClient: auth,
          accessService: access,
          service: service,
        ),
      );
      await tester.pumpWidget(
        route(FakeAuthClient(signedIn: false), FakeAccessService([])),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(service.calls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.denied()]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([AccessCheck.granted(AccessRole.staff)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('イベント一覧は管理者のみ利用できます'), findsOneWidget);
      expect(service.calls, 0, reason: 'staffではイベント一覧も問い合わせない');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([AccessCheck.granted(AccessRole.admin)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('架空テストイベントA(confirmed)'), findsOneWidget);
      expect(service.calls, 1);
    });
  });

  group('一覧表示・選択', () {
    testWidgets(
      'イベント名・開催日時・会場を表示し、タップすると/console?eventId=…へ進む(eventIdは入力させない)',
      (tester) async {
        final service = FakeEventListService(
          items: [
            const ConfirmedEventListItem(
              eventId: 'evfixtureconfirmedB',
              eventName: '架空テストイベントB',
              startAt: null,
              venue: '架空会場B',
            ),
          ],
        );
        final routes = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              routes.add(settings.name);
              if (settings.name == '/') {
                return MaterialPageRoute<void>(
                  builder: (_) => ConfirmedEventListPage(service: service),
                  settings: settings,
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('CONSOLE-PAGE')),
                settings: settings,
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('架空テストイベントB'), findsOneWidget);
        expect(find.textContaining('架空会場B'), findsOneWidget);
        // eventIdの入力欄・表示は無い(利用者に意識させない)
        expect(find.textContaining('evfixtureconfirmedB'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        await tester.tap(
          find.byKey(const Key('event-item-evfixtureconfirmedB')),
        );
        await tester.pumpAndSettle();
        expect(routes.last, '/console?eventId=evfixtureconfirmedB');
        expect(find.text('CONSOLE-PAGE'), findsOneWidget);
      },
    );

    testWidgets('イベントが無い場合は、その旨を表示する(空一覧)', (tester) async {
      await tester.pumpWidget(
        _app(ConfirmedEventListPage(service: FakeEventListService())),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-list-empty')), findsOneWidget);
    });

    testWidgets('取得に失敗した場合はエラーと再試行を表示する', (tester) async {
      var attempt = 0;
      final service = FakeEventListService();
      service.error = const EventListException('通信に失敗しました。もう一度お試しください。');
      await tester.pumpWidget(_app(ConfirmedEventListPage(service: service)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-list-error')), findsOneWidget);
      expect(find.text('通信に失敗しました。もう一度お試しください。'), findsOneWidget);
      attempt = service.calls;
      service.error = null;
      service.items = [_confirmedA];
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(service.calls, attempt + 1);
      expect(find.text('架空テストイベントA(confirmed)'), findsOneWidget);
    });
  });

  group(
    'CallableEventListService(既存のlistLegacyEventsを再利用。新しいFunctionsは追加しない)',
    () {
      test(
        'listLegacyEventsを呼び、flow=="confirmed"だけを返す(legacy・flowなし・未知のflowは除く)。開催日時の新しい順',
        () async {
          late http.Request seen;
          final service = CallableEventListService(
            authClient: FakeAuthClient(signedIn: true, token: 'admin-token'),
            baseUrl: 'https://example.invalid',
            httpClient: MockClient((request) async {
              seen = request;
              return _json({
                'result': {
                  'events': [
                    {
                      'eventId': 'evLegacyX',
                      'eventName': '架空legacyイベント',
                      'flow': null,
                      'venue': '会場L',
                      'startAt': '2030-01-01T00:00:00.000Z',
                    },
                    {
                      'eventId': 'evConfirmedOld',
                      'eventName': '架空confirmedイベント(古い)',
                      'flow': 'confirmed',
                      'venue': '会場C1',
                      'startAt': '2030-06-01T00:00:00.000Z',
                    },
                    {
                      'eventId': 'evConfirmedNew',
                      'eventName': '架空confirmedイベント(新しい)',
                      'flow': 'confirmed',
                      'venue': '会場C2',
                      'startAt': '2030-09-01T00:00:00.000Z',
                    },
                    {
                      'eventId': 'evUnknownFlow',
                      'eventName': '架空未知flowイベント',
                      'flow': 'somethingElse',
                      'venue': '会場U',
                      'startAt': '2030-12-01T00:00:00.000Z',
                    },
                  ],
                },
              }, 200);
            }),
          );
          final items = await service.listConfirmedEvents();
          expect(
            seen.url.toString(),
            'https://example.invalid/listLegacyEvents',
          );
          expect(seen.headers['Authorization'], 'Bearer admin-token');
          expect((jsonDecode(seen.body) as Map)['data'], const {});
          expect(
            items.map((e) => e.eventId).toList(),
            ['evConfirmedNew', 'evConfirmedOld'], // confirmedだけ・新しい順
          );
          expect(items.first.eventName, '架空confirmedイベント(新しい)');
          expect(items.first.venue, '会場C2');
        },
      );

      test('未ログインなら通信しない。権限エラーは表示用に変換される', () async {
        var requests = 0;
        final signedOut = CallableEventListService(
          authClient: FakeAuthClient(signedIn: false, token: null),
          httpClient: MockClient((_) async {
            requests++;
            return _json({}, 200);
          }),
        );
        await expectLater(
          signedOut.listConfirmedEvents(),
          throwsA(isA<EventListException>()),
        );
        expect(requests, 0);

        final denied = CallableEventListService(
          authClient: FakeAuthClient(signedIn: true),
          httpClient: MockClient(
            (_) async => _json({
              'error': {'status': 'PERMISSION_DENIED', 'message': 'x'},
            }, 403),
          ),
        );
        await expectLater(
          denied.listConfirmedEvents(),
          throwsA(
            predicate(
              (e) => e is EventListException && e.message.contains('権限'),
            ),
          ),
        );
      });

      test('参加者・メールテンプレート等は返却DTOに要求しない(一覧に必要な最小情報だけを読む)', () async {
        final service = CallableEventListService(
          authClient: FakeAuthClient(signedIn: true),
          httpClient: MockClient(
            (_) async => _json({
              'result': {
                'events': [
                  {
                    'eventId': 'evConfirmedC',
                    'eventName': '架空C',
                    'flow': 'confirmed',
                    'venue': '会場C',
                    'startAt': '2030-01-01T00:00:00.000Z',
                    // サーバーのDTOに含まれていても、参加者情報は一覧側では使わない(無視する)。
                    'summary': {'registered': 999},
                  },
                ],
              },
            }, 200),
          ),
        );
        final items = await service.listConfirmedEvents();
        expect(items.single.eventId, 'evConfirmedC');
      });
    },
  );

  group('管理画面(/console)からの入口', () {
    testWidgets('adminには「イベント一覧」が表示され、staffには表示されない', (tester) async {
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
      expect(find.text('イベント一覧'), findsOneWidget);
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
      expect(find.text('イベント一覧'), findsNothing);
    });

    testWidgets('「イベント一覧」をタップすると/console/eventsへ遷移する', (tester) async {
      final routes = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          onGenerateRoute: (settings) {
            routes.add(settings.name);
            if (settings.name == '/') {
              return MaterialPageRoute<void>(
                builder: (_) => ConfirmedConsolePage(
                  authClient: FakeAuthClient(signedIn: true),
                  accessService: FakeAccessService([
                    AccessCheck.granted(AccessRole.admin),
                  ]),
                ),
                settings: settings,
              );
            }
            return MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('EVENT-LIST-PAGE')),
              settings: settings,
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('イベント一覧'));
      await tester.pumpAndSettle();
      expect(routes.last, '/console/events');
      expect(find.text('EVENT-LIST-PAGE'), findsOneWidget);
    });
  });

  group('境界の静的検査', () {
    test(
      '新しいFunctions callableは追加していない(既存のlistLegacyEventsを再利用)。参加者・Secret等は要求しない',
      () {
        final source = File('lib/confirmed/event_list_service.dart')
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        expect(source, contains('listLegacyEvents'));
        for (final forbidden in [
          'cloud_firestore',
          'FirebaseFirestore',
          '.collection(',
          'getEventAdminView',
          'publicId',
          'participant',
          'mailLogs',
          'sendJobs',
        ]) {
          expect(source.contains(forbidden), isFalse, reason: forbidden);
        }
      },
    );
    test('eventIdの手入力欄は作らない(TextField・TextEditingControllerを使わない)', () {
      final source = File(
        'lib/confirmed/confirmed_event_list_page.dart',
      ).readAsStringSync();
      for (final forbidden in ['TextField(', 'TextEditingController']) {
        expect(source.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });
}

// dart:io をトップレベルでimportする(境界の静的検査でファイルを読むため)。
