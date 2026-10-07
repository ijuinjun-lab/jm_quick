// Phase 10C: 従来方式(legacy)の認証境界(Flutter側)。通信はすべてMockClient(外部通信0)、Firestoreは使わない(Firebase未初期化のまま動く)。
//  - サーバーAPIの呼び出し: 管理・受付はIDトークン(Authorizationのみ)、参加者本人・当日参加登録はトークンなし。uid/role/emailは本文に入れない
//  - 管理画面はadminとして確認できるまで何も取得しない。staffは「管理者のみ」
//  - 新方式のイベントを開いても、従来機能の購読・表示をしない(案内だけ)
//  - 従来方式の画面のソースにFirestoreの直接読み書きが残っていない
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/pages/participant_page.dart';
import 'package:jm_quick/pages/reception_page.dart';
import 'package:jm_quick/pages/walk_in_page.dart';
import 'package:jm_quick/services/app_check.dart';
import 'package:jm_quick/services/demo_repository.dart';
import 'package:jm_quick/services/event_kind_service.dart';
import 'package:jm_quick/services/legacy_api.dart';
import 'package:jm_quick/services/polling_source.dart';

import 'app_check_fake.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;

class _Call {
  _Call(this.name, this.headers, this.data);
  final String name;
  final Map<String, String> headers;
  final Map<String, dynamic> data;
}

/// callableの応答を返すだけのサーバー役。呼び出しはすべて記録する。
class _Server {
  _Server(this.handlers);
  final Map<String, Object? Function(Map<String, dynamic> data)> handlers;
  final List<_Call> calls = [];

  http.Client get client => MockClient((request) async {
    final name = request.url.pathSegments.last;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final data = Map<String, dynamic>.from(body['data'] as Map);
    calls.add(_Call(name, request.headers, data));
    final handler = handlers[name];
    if (handler == null) {
      return _error(404, 'NOT_FOUND', '想定外のAPI');
    }
    final result = handler(data);
    if (result is http.Response) return result;
    return _json({'result': result}, 200);
  });

  List<String> get names => calls.map((c) => c.name).toList();
}

http.Response _json(Object? body, int code) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  code,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(int code, String status, String message) => _json({
  'error': {'message': message, 'status': status},
}, code);

Map<String, dynamic> _eventDto(
  String id, {
  String? flow,
  String name = 'テストイベント',
}) => {
  'eventId': id,
  'flow': flow,
  'eventName': name,
  'senderName': '送信者',
  'venue': '会場',
  'contact': '',
  'startAt': '2030-01-02T01:00:00.000Z',
  'endAt': null,
  'registrationDeadline': '2030-01-01T01:00:00.000Z',
  'confirmationSendAt': '2030-01-01T00:00:00.000Z',
  'reconfirmEnabled': false,
};

Map<String, dynamic> _participantDto(String id) => {
  'participantId': id,
  'eventId': 'e1',
  'publicId': 'pub_server_generated_0123456789',
  'name': '架空 太郎',
  'email': 'taro@example.invalid',
  'registeredCount': 2,
  'registrationType': 'preRegistered',
  'participationConfirmed': false,
};

LegacyApiClient _api(_Server server, {FakeAuthClient? auth}) => LegacyApiClient(
  appCheck: FakeAppCheck(),
  authClient: auth ?? FakeAuthClient(signedIn: true, token: 'admin-token'),
  httpClient: server.client,
);

Widget _app(Widget child) => MaterialApp(home: child);

void main() {
  group('LegacyApiClient(認証つき/参加者capabilityの呼び分け)', () {
    test('管理・受付の呼び出しはIDトークンをAuthorizationで送り、本文にuid・role・emailを入れない', () async {
      final server = _Server({
        'listLegacyEvents': (_) => {'events': []},
      });
      await _api(server).call('listLegacyEvents', const {});
      final call = server.calls.single;
      expect(call.headers['Authorization'], 'Bearer admin-token');
      expect(call.data, isEmpty);
      final raw = jsonEncode(call.data);
      for (final forbidden in ['uid', 'role', 'email']) {
        expect(raw.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('未ログイン(トークンなし)なら通信せずUNAUTHENTICATED', () async {
      final server = _Server({
        'listLegacyEvents': (_) => {'events': []},
      });
      final api = LegacyApiClient(
        authClient: FakeAuthClient(signedIn: false, token: null),
        httpClient: server.client,
      );
      await expectLater(
        api.call('listLegacyEvents', const {}),
        throwsA(
          isA<LegacyApiException>().having(
            (e) => e.isUnauthenticated,
            'unauth',
            isTrue,
          ),
        ),
      );
      expect(server.calls, isEmpty);
    });

    test('参加者本人・当日参加登録の呼び出し(authenticated=false)は、ログイン済みでもトークンを送らない', () async {
      final server = _Server({
        'registerWalkIn': (_) => {'success': true},
      });
      await _api(
        server,
      ).call('registerWalkIn', {'eventId': 'e1'}, authenticated: false);
      expect(server.calls.single.headers.containsKey('Authorization'), isFalse);
      // Phase 10D: 公開APIにはApp Checkトークンを付ける
      expect(
        server.calls.single.headers[appCheckHeaderName],
        'test-app-check-token',
      );
    });

    test(
      'Phase 10D: 公開APIはApp Checkトークンを取得できないとき、サーバーへ送らずに失敗する(未設定・取得失敗)。管理・受付の呼び出しはApp Checkを使わない',
      () async {
        for (final appCheck in [FakeAppCheck(null), FakeAppCheck.throwing()]) {
          final server = _Server({
            'registerWalkIn': (_) => {'success': true},
            'listLegacyEvents': (_) => {'events': []},
          });
          final api = LegacyApiClient(
            authClient: FakeAuthClient(signedIn: true),
            httpClient: server.client,
            appCheck: appCheck,
          );
          await expectLater(
            api.call('registerWalkIn', {'eventId': 'e1'}, authenticated: false),
            throwsA(
              isA<LegacyApiException>().having(
                (e) => e.status,
                'status',
                'APP_CHECK_UNAVAILABLE',
              ),
            ),
          );
          expect(server.calls, isEmpty, reason: '送信しない');
          // 管理・受付は、認証(IDトークン)とサーバー側のaccessRolesが境界。App Checkのトークンは取得しない
          await api.call('listLegacyEvents', const {});
          expect(
            server.calls.single.headers.containsKey(appCheckHeaderName),
            isFalse,
          );
          expect(appCheck.calls, 1, reason: '公開APIの1回だけ');
        }
      },
    );

    test('サーバーのエラーは、表示できる文と状態コードに変換される。通信失敗は内部情報を含まない', () async {
      final api = LegacyApiClient(
        authClient: FakeAuthClient(signedIn: true),
        httpClient: MockClient(
          (_) async => _error(403, 'PERMISSION_DENIED', 'この操作を行う権限がありません。'),
        ),
      );
      await expectLater(
        api.call('deleteEvent', {'eventId': 'e1'}),
        throwsA(
          isA<LegacyApiException>()
              .having((e) => e.isPermissionDenied, 'denied', isTrue)
              .having((e) => e.message, 'message', 'この操作を行う権限がありません。'),
        ),
      );
      final broken = LegacyApiClient(
        authClient: FakeAuthClient(signedIn: true),
        httpClient: MockClient(
          (_) async => throw const SocketException('secret-host.internal'),
        ),
      );
      await expectLater(
        broken.call('deleteEvent', {'eventId': 'e1'}),
        throwsA(
          isA<LegacyApiException>().having(
            (e) => e.message.contains('secret-host'),
            'leak',
            isFalse,
          ),
        ),
      );
    });
  });

  group('PollingSource(Firestore購読の代わり)', () {
    test('購読者がいない間は取得しない。最初の購読で即時に1回取得し、購読者どうしで取得を共有する', () async {
      var fetches = 0;
      final source = PollingSource<int>(
        () async => ++fetches,
        interval: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fetches, 0);
      final a = <int>[];
      final b = <int>[];
      final subA = source.stream.listen(a.add);
      final subB = source.stream.listen(b.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fetches, 1);
      expect(a, [1]);
      expect(b, [1]);
      // 後から購読した側にも、取得済みの値がすぐ渡る(再取得を待たない)
      final c = <int>[];
      final subC = source.stream.listen(c.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c, [1]);
      await subA.cancel();
      await subB.cancel();
      await subC.cancel();
    });

    test('周期で取り直し、最後の購読が外れたら止まる。失敗はエラーとして流し、次の周期で回復する', () async {
      var fetches = 0;
      final source = PollingSource<int>(() async {
        fetches++;
        if (fetches == 2) throw StateError('temporary');
        return fetches;
      }, interval: const Duration(milliseconds: 40));
      final values = <int>[];
      final errors = <Object>[];
      final sub = source.stream.listen(values.add, onError: errors.add);
      await Future<void>.delayed(const Duration(milliseconds: 170));
      expect(values.first, 1);
      expect(errors, isNotEmpty);
      expect(values.length, greaterThanOrEqualTo(2));
      await sub.cancel();
      final stopped = fetches;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(fetches, stopped, reason: '購読者がいなければ通信しない');
    });
  });

  group('DemoRepository(サーバーAPI経由。Firestoreに触れない)', () {
    test('イベント詳細: 従来方式は参加者・受付・一括メール進捗を返し、新方式は参加者を返さない', () async {
      final server = _Server({
        'getLegacyEventAdminView': (data) => data['eventId'] == 'e1'
            ? {
                'legacy': true,
                'event': _eventDto('e1'),
                'participants': [_participantDto('p1')],
                'checkIns': [
                  {
                    'participantId': 'p1',
                    'eventId': 'e1',
                    'checkedIn': true,
                    'attendedCount': 2,
                  },
                ],
                'jobs': {
                  'invitation': {
                    'jobId': 'e1_invitation',
                    'eventId': 'e1',
                    'type': 'invitation',
                    'status': 'running',
                    'totalCount': 3,
                  },
                },
              }
            : {
                'legacy': false,
                'event': _eventDto('c1', flow: 'confirmed'),
                'participants': [],
                'checkIns': [],
                'jobs': {},
              },
      });
      final legacy = DemoRepository(
        selectedEventId: 'e1',
        api: _api(server),
        pollInterval: const Duration(minutes: 5),
      );
      final participants = await legacy.watchParticipants().first;
      expect(participants.single.name, '架空 太郎');
      expect((await legacy.watchCheckIns().first).single.attendedCount, 2);
      final job = await legacy.watchBulkMailJob('invitation').first;
      expect(job?.isRunning, isTrue);
      expect(await legacy.watchBulkMailJob('reconfirmation').first, isNull);
      expect((await legacy.watchEvent().first)?.isLegacyFlow, isTrue);
      expect(server.names.toSet(), {'getLegacyEventAdminView'});
      final confirmed = DemoRepository(
        selectedEventId: 'c1',
        api: _api(server),
        pollInterval: const Duration(minutes: 5),
      );
      final event = await confirmed.watchEvent().first;
      expect(event?.isLegacyFlow, isFalse);
      expect(event?.isConfirmedFlow, isTrue);
      expect(await confirmed.watchParticipants().first, isEmpty);
    });

    test(
      '参加者の手動登録: participantId・publicIdをクライアントから送らない(サーバーが生成)。メールアドレスは小文字に正規化',
      () async {
        final server = _Server({
          'getLegacyEventAdminView': (_) => {
            'legacy': true,
            'event': _eventDto('e1'),
            'participants': [],
            'checkIns': [],
            'jobs': {},
          },
          'createLegacyParticipant': (_) => {
            'participant': _participantDto('auto1'),
          },
        });
        final repo = DemoRepository(
          selectedEventId: 'e1',
          api: _api(server),
          pollInterval: const Duration(minutes: 5),
        );
        final created = await repo.createParticipant(
          name: ' 架空 太郎 ',
          email: 'Taro@Example.INVALID',
          registeredCount: 2,
          registrationType: 'preRegistered',
        );
        expect(created.id, 'auto1');
        final sent = server.calls
            .firstWhere((c) => c.name == 'createLegacyParticipant')
            .data;
        expect(sent.keys.toSet(), {
          'eventId',
          'name',
          'email',
          'registeredCount',
          'registrationType',
        });
        expect(sent['email'], 'taro@example.invalid');
        expect(sent['name'], '架空 太郎');
      },
    );

    test('当日参加登録: トークンを送らず、送るのはeventId・氏名・メール・人数だけ(件名・本文・送信者は送らない)', () async {
      final server = _Server({
        'registerWalkIn': (_) => {
          'success': true,
          'participantId': 'p9',
          'publicId': 'pub_x',
          'mailSent': true,
        },
      });
      final repo = DemoRepository(selectedEventId: 'e1', api: _api(server));
      final result = await repo.registerWalkIn(
        name: ' 当日 太郎 ',
        email: 'Walk@Example.invalid',
        registeredCount: 1,
      );
      expect(result.participantId, 'p9');
      expect(result.mailError, isNull);
      final call = server.calls.single;
      expect(call.headers.containsKey('Authorization'), isFalse);
      expect(call.data.keys.toSet(), {
        'eventId',
        'name',
        'email',
        'registeredCount',
      });
    });

    test(
      '受付: 既に受付済みならStateError。QRのeventId・participantId・publicIdをサーバーへ送り、判断はサーバーに任せる',
      () async {
        final server = _Server({
          'checkInLegacyParticipant': (_) => {'alreadyCheckedIn': true},
        });
        final repo = DemoRepository(selectedEventId: 'e1', api: _api(server));
        await expectLater(
          repo.checkInByKey(
            participantId: 'p1',
            publicId: 'pub_x',
            attendedCount: 2,
          ),
          throwsA(isA<StateError>()),
        );
        expect(server.calls.single.data, {
          'eventId': 'e1',
          'participantId': 'p1',
          'publicId': 'pub_x',
          'attendedCount': 2,
        });
      },
    );

    test('マイページ: サーバーが「無効」と答えたらnull(存在しない・publicId不一致・新方式は区別されない)', () async {
      final server = _Server({
        'getLegacyParticipantPage': (_) =>
            _error(404, 'NOT_FOUND', 'ページを確認できませんでした。'),
      });
      final repo = DemoRepository(api: _api(server));
      expect(await repo.loadParticipantPage('p1', 'pub_x'), isNull);
      expect(await repo.loadParticipantPage(null, 'pub_x'), isNull);
      expect(server.calls.length, 1);
      expect(server.calls.single.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('認証ゲートと画面', () {
    testWidgets('マイページ: 無効な組は「有効なマイページURLではありません」だけ。有効なら氏名を表示し、メールアドレスは表示しない', (
      tester,
    ) async {
      var valid = false;
      final server = _Server({
        'getLegacyParticipantPage': (_) => valid
            ? {
                'event': {
                  'eventId': 'e1',
                  'eventName': '従来イベント',
                  'startAt': '2030-01-02T01:00:00.000Z',
                  'venue': '会場',
                  'reconfirmEnabled': false,
                },
                'participant': {
                  'name': '架空 太郎',
                  'registeredCount': 2,
                  'participationConfirmed': false,
                  'attendanceResponse': null,
                },
                'checkIn': {'checkedIn': false, 'attendedCount': null},
              }
            : _error(404, 'NOT_FOUND', 'ページを確認できませんでした。'),
        'confirmLegacyParticipation': (_) => {
          'event': {
            'eventId': 'e1',
            'eventName': '従来イベント',
            'startAt': '2030-01-02T01:00:00.000Z',
            'venue': '会場',
            'reconfirmEnabled': false,
          },
          'participant': {
            'name': '架空 太郎',
            'registeredCount': 2,
            'participationConfirmed': true,
            'attendanceResponse': null,
          },
          'checkIn': {'checkedIn': false, 'attendedCount': null},
        },
      });
      final repo = DemoRepository(api: _api(server));
      await tester.pumpWidget(
        _app(
          ParticipantPage(
            participantId: 'p1',
            publicId: 'pub_bad',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有効なマイページURLではありません。'), findsOneWidget);
      valid = true;
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ParticipantPage(
            participantId: 'p1',
            publicId: 'pub_ok',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('架空 太郎様'), findsOneWidget);
      expect(find.textContaining('@'), findsNothing);
      await tester.tap(find.text('正式登録する'));
      await tester.pumpAndSettle();
      expect(find.text('正式登録が完了しました'), findsOneWidget);
      for (final call in server.calls) {
        expect(
          call.headers.containsKey('Authorization'),
          isFalse,
          reason: call.name,
        );
        expect(
          call.data.keys.toSet().difference({'participantId', 'publicId'}),
          isEmpty,
          reason: call.name,
        );
      }
    });

    testWidgets('受付画面: サーバーが受付不可と答えたQRは案内だけ。受付するとサーバーへ送り、結果をサーバーの値で表示し直す', (
      tester,
    ) async {
      var checkedIn = false;
      final server = _Server({
        'getLegacyReceptionView': (data) => data['publicId'] == 'pub_bad'
            ? _error(412, 'FAILED_PRECONDITION', 'この参加証は受付できません。')
            : {
                'eventName': 'イベント',
                'participantName': '架空 花子',
                'registeredCount': 2,
                'reconfirmed': true,
                'checkedIn': checkedIn,
                'attendedCount': checkedIn ? 2 : null,
              },
        'checkInLegacyParticipant': (_) {
          checkedIn = true;
          return {'alreadyCheckedIn': false};
        },
      });
      final repo = DemoRepository(selectedEventId: 'e1', api: _api(server));
      await tester.pumpWidget(
        _app(
          ReceptionPage(
            eventId: 'e1',
            participantId: 'p1',
            publicId: 'pub_bad',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有効な受付用QRコードまたはリンクから開いてください。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ReceptionPage(
            eventId: 'e1',
            participantId: 'p1',
            publicId: 'pub_ok',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('架空 花子様'), findsOneWidget);
      await tester.tap(find.text('受付する'));
      await tester.pumpAndSettle();
      expect(find.text('受付済みです'), findsOneWidget);
      final sent = server.calls.firstWhere(
        (c) => c.name == 'checkInLegacyParticipant',
      );
      expect(sent.data['attendedCount'], 2);
      expect(sent.headers['Authorization'], 'Bearer admin-token');
    });

    testWidgets('当日参加登録: 登録ボタンは処理中は押せず(二重送信しない)、1回だけ送る', (tester) async {
      final release = Completer<void>();
      final requests = <String>[];
      final repo = DemoRepository(
        selectedEventId: 'e1',
        api: LegacyApiClient(
          appCheck: FakeAppCheck(),
          authClient: FakeAuthClient(signedIn: true),
          httpClient: MockClient((request) async {
            requests.add(request.url.pathSegments.last);
            await release.future;
            return _json({
              'result': {
                'success': true,
                'participantId': 'p9',
                'publicId': 'pub_x',
                'mailSent': true,
              },
            }, 200);
          }),
        ),
      );
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(WalkInPage(eventId: 'e1', repository: repo)),
      );
      await tester.enterText(find.widgetWithText(TextField, '氏名'), '当日 太郎');
      await tester.enterText(
        find.widgetWithText(TextField, 'メールアドレス'),
        'walk@example.invalid',
      );
      await tester.tap(find.text('登録する'));
      await tester.pump();
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull, reason: '処理中は押せない');
      await tester.tap(find.byType(FilledButton), warnIfMissed: false);
      await tester.pump();
      release.complete();
      await tester.pumpAndSettle();
      expect(find.text('登録完了'), findsOneWidget);
      expect(requests, ['registerWalkIn']);
    });
  });

  group('event kind API(受付QRの方式判定。Firestoreを使わない)', () {
    test(
      'kind(legacy/confirmed)だけを受け取る。ログイン済みのIDトークンで呼び、未知・不正・存在しないは「確認できない」',
      () async {
        final server = _Server({
          'getEventKind': (data) => switch (data['eventId']) {
            'l1' => {'kind': 'legacy'},
            'c1' => {'kind': 'confirmed'},
            'odd' => {'kind': 'something-else'},
            _ => _error(412, 'FAILED_PRECONDITION', 'イベントを確認できませんでした。'),
          },
        });
        final service = ApiEventKindService(api: _api(server));
        expect(await service.kindOf('l1'), EventKind.legacy);
        expect(await service.kindOf('c1'), EventKind.confirmed);
        expect(await service.kindOf('odd'), EventKind.unsupported);
        expect(await service.kindOf('gone'), EventKind.unsupported);
        for (final call in server.calls) {
          expect(call.headers['Authorization'], 'Bearer admin-token');
          expect(call.data.keys.toList(), ['eventId']);
          expect(call.headers.containsKey(appCheckHeaderName), isFalse);
        }
      },
    );

    test('未ログイン・通信失敗は例外(legacyやconfirmedと仮定しない)', () async {
      final server = _Server({
        'getEventKind': (_) => {'kind': 'legacy'},
      });
      final signedOut = ApiEventKindService(
        api: LegacyApiClient(
          authClient: FakeAuthClient(signedIn: false, token: null),
          httpClient: server.client,
          appCheck: FakeAppCheck(),
        ),
      );
      await expectLater(
        signedOut.kindOf('l1'),
        throwsA(isA<LegacyApiException>()),
      );
      expect(server.calls, isEmpty, reason: '未認証ではイベントを問い合わせない');
      final broken = ApiEventKindService(
        api: LegacyApiClient(
          authClient: FakeAuthClient(signedIn: true),
          httpClient: MockClient((_) async => throw const SocketException('x')),
          appCheck: FakeAppCheck(),
        ),
      );
      await expectLater(
        broken.kindOf('l1'),
        throwsA(isA<LegacyApiException>()),
      );
    });
  });

  group('境界の静的検査(従来方式の画面・サービス)', () {
    final legacyFiles = [
      'lib/services/demo_repository.dart',
      'lib/services/legacy_api.dart',
      'lib/services/polling_source.dart',
      'lib/pages/participant_page.dart',
      'lib/pages/reception_page.dart',
      'lib/pages/walk_in_page.dart',
    ];
    String code(String path) => File(path)
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    // Phase 10D: 以前(10C時点)は、受付QRの方式判定のevents/{id}の直接readが1か所だけ残っていた。サーバーAPI(getEventKind)へ移し、実行時の
    // Firestore直接アクセスは0件になった(以前の許可から変更)。
    test(
      'Phase 10D: Flutterの実行コードにFirestoreの直接read/write・購読が0件(型のためのimportはモデルだけ)',
      () {
        for (final path in legacyFiles) {
          final text = code(path);
          for (final forbidden in [
            'cloud_firestore',
            'FirebaseFirestore',
            '.snapshots(',
            '.collection(',
            'runTransaction',
            'FieldValue',
          ]) {
            expect(
              text.contains(forbidden),
              isFalse,
              reason: '$path: $forbidden',
            );
          }
        }
        final all = Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();
        for (final file in all) {
          final text = code(file.path);
          for (final forbidden in [
            'FirebaseFirestore',
            '.snapshots(',
            '.collection(',
            'runTransaction',
            'FieldValue',
            'FirebaseFirestore.instance',
          ]) {
            expect(
              text.contains(forbidden),
              isFalse,
              reason: '${file.path}: $forbidden',
            );
          }
        }
        final users =
            all
                .where((f) => code(f.path).contains('cloud_firestore'))
                .map((f) => f.path)
                .toList()
              ..sort();
        expect(users, [
          'lib/models/demo_models.dart',
          'lib/models/program_models.dart',
        ], reason: 'Timestamp・DocumentSnapshotの型のためだけ');
        final kind = code('lib/services/event_kind_service.dart');
        expect(kind.contains('cloud_firestore'), isFalse);
        expect(kind.contains("'getEventKind'"), isTrue);
      },
    );

    test('クライアントは認可の根拠(uid・role・email)をAPIへ送らない', () {
      final api = code('lib/services/legacy_api.dart');
      final repo = code('lib/services/demo_repository.dart');
      for (final forbidden in ["'uid'", "'role'", "'accessRoles'"]) {
        expect(api.contains(forbidden), isFalse, reason: forbidden);
        expect(repo.contains(forbidden), isFalse, reason: forbidden);
      }
      expect(
        RegExp(r"'email':\s*email\.trim\(\)\.toLowerCase\(\)").hasMatch(repo),
        isTrue,
        reason: 'emailは参加者の登録内容としてだけ送る(認可には使わない)',
      );
    });

    test('DemoRepositoryが呼ぶAPIは、認証つき(管理・受付)と公開(参加者本人・当日参加登録)が固定されている', () {
      final repo = code('lib/services/demo_repository.dart');
      final publicCalls = RegExp(
        r"authenticated: false",
      ).allMatches(repo).length;
      // 参加者本人3(取得・正式登録・回答)+当日参加登録1
      expect(publicCalls, 4);
      for (final name in [
        'sendParticipantMail',
        'startBulkInvitationMail',
        'startBulkReconfirmationMail',
        'deleteParticipant',
        'deleteEvent',
      ]) {
        final index = repo.indexOf("'$name'");
        expect(index, greaterThan(0), reason: name);
        expect(
          repo
              .substring(index, repo.indexOf(');', index))
              .contains('authenticated: false'),
          isFalse,
          reason: name,
        );
      }
    });
  });
}
