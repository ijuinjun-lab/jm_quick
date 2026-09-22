import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/access_service.dart';
import 'package:jm_quick/confirmed/auth_client.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/login_page.dart';

/// Firebaseへ接続しないAuthClient。ログイン状態は手動で操作する。
class FakeAuthClient implements AuthClient {
  FakeAuthClient({this.signedIn = false, this.token = 'test-token'});
  bool signedIn;
  String? token;
  AuthFailure? signInFailure;
  int signOutCalls = 0;
  final List<(String, String)> signInCalls = [];
  final List<StreamController<bool>> _listeners = [];

  void setSignedIn(bool value) {
    signedIn = value;
    for (final listener in List.of(_listeners)) {
      listener.add(value);
    }
  }

  /// FirebaseAuth.authStateChanges と同じく、購読時に現在の状態を流し、以後は変化を流す。
  @override
  Stream<bool> signedInChanges() {
    late StreamController<bool> controller;
    controller = StreamController<bool>(
      onListen: () {
        controller.add(signedIn);
        _listeners.add(controller);
      },
      onCancel: () => _listeners.remove(controller),
    );
    return controller.stream;
  }

  @override
  Future<void> signIn(String email, String password) async {
    signInCalls.add((email, password));
    if (signInFailure != null) throw signInFailure!;
    setSignedIn(true);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    setSignedIn(false);
  }

  @override
  Future<String?> idToken({bool forceRefresh = false}) async =>
      signedIn ? token : null;
}

class FakeAccessService implements AccessService {
  FakeAccessService(this.results);
  final List<AccessCheck> results;
  int calls = 0;
  @override
  Future<AccessCheck> fetchMyAccess() async {
    final index = calls < results.length ? calls : results.length - 1;
    calls++;
    return results[index];
  }
}

Widget _console(FakeAuthClient auth, AccessService access) => MaterialApp(
  home: ConfirmedConsolePage(authClient: auth, accessService: access),
);

/// 機能一覧(ListTile)のタイトル。ページタイトル(AppBar)などとは区別して検査する。
List<String> _featureTitles(WidgetTester tester) => [
  for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
    (tile.title as Text).data!,
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  group('AuthGate(画面の境界)', () {
    testWidgets('未ログインならログイン画面を表示し、権限確認は行わない', (tester) async {
      final auth = FakeAuthClient(signedIn: false);
      final access = FakeAccessService([
        const AccessCheck.granted(AccessRole.admin),
      ]);
      await tester.pumpWidget(_console(auth, access));
      await _settle(tester);
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(find.text('メールアドレス'), findsOneWidget);
      expect(find.text('パスワード'), findsOneWidget);
      expect(access.calls, 0);
      for (final label in [...consoleTopFeatureLabels, ...staffFeatureLabels]) {
        expect(find.text(label), findsNothing);
      }
    });

    testWidgets('adminはログイン後にサーバーが確認した結果で、管理トップの機能(イベント固有機能は含まない)が表示される', (
      tester,
    ) async {
      final auth = FakeAuthClient(signedIn: true);
      await tester.pumpWidget(
        _console(
          auth,
          FakeAccessService([const AccessCheck.granted(AccessRole.admin)]),
        ),
      );
      await _settle(tester);
      expect(find.text('ログイン中：管理者'), findsOneWidget);
      expect(_featureTitles(tester), consoleTopFeatureLabels);
    });

    testWidgets('staffには受付系だけが表示され、管理機能は一切表示されない', (tester) async {
      final auth = FakeAuthClient(signedIn: true);
      await tester.pumpWidget(
        _console(
          auth,
          FakeAccessService([const AccessCheck.granted(AccessRole.staff)]),
        ),
      );
      await _settle(tester);
      expect(find.text('ログイン中：受付スタッフ'), findsOneWidget);
      // 機能の一覧(ListTile)は受付系だけ。管理機能(CSV取込・スタッフ管理など)は含まれない。
      expect(_featureTitles(tester), staffFeatureLabels);
      expect(
        _featureTitles(
          tester,
        ).any(['CSV取込', 'スタッフ管理', 'イベント設定', '当選メール送信'].contains),
        isFalse,
      );
      expect(find.text('CSV取込'), findsNothing);
      expect(find.text('スタッフ管理'), findsNothing);
    });

    testWidgets('ログイン済みでも権限なし(accessRolesなし・active=false・未知role)なら「権限がありません」', (
      tester,
    ) async {
      final auth = FakeAuthClient(signedIn: true);
      await tester.pumpWidget(
        _console(auth, FakeAccessService([const AccessCheck.denied()])),
      );
      await _settle(tester);
      expect(find.text('権限がありません'), findsOneWidget);
      for (final label in [...consoleTopFeatureLabels, ...staffFeatureLabels]) {
        expect(find.text(label), findsNothing);
      }
      await tester.tap(find.text('ログアウト'));
      await _settle(tester);
      expect(auth.signOutCalls, 1);
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
    });

    testWidgets('サーバーがログイン無効(トークン切れ)と判断したらログアウトしてログイン画面へ戻る', (tester) async {
      final auth = FakeAuthClient(signedIn: true);
      await tester.pumpWidget(
        _console(
          auth,
          FakeAccessService([const AccessCheck.unauthenticated()]),
        ),
      );
      await _settle(tester);
      expect(auth.signOutCalls, 1);
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
    });

    testWidgets('通信エラーは権限ありとせず、再試行できる', (tester) async {
      final auth = FakeAuthClient(signedIn: true);
      final access = FakeAccessService([
        const AccessCheck.error(),
        const AccessCheck.granted(AccessRole.staff),
      ]);
      await tester.pumpWidget(_console(auth, access));
      await _settle(tester);
      expect(find.text('権限を確認できませんでした'), findsOneWidget);
      expect(find.text('当日の受付'), findsNothing);
      await tester.tap(find.text('再試行'));
      await _settle(tester);
      expect(access.calls, 2);
      expect(find.text('当日の受付'), findsOneWidget);
    });

    testWidgets('ログイン→権限確認→機能表示の流れ。ログアウトでログイン画面へ戻り、機能は消える', (tester) async {
      final auth = FakeAuthClient(signedIn: false);
      final access = FakeAccessService([
        const AccessCheck.granted(AccessRole.admin),
      ]);
      await tester.pumpWidget(_console(auth, access));
      await _settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'メールアドレス'),
        ' staff@example.invalid ',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'パスワード'),
        'pass-word',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
      await _settle(tester);
      expect(auth.signInCalls.single, (' staff@example.invalid ', 'pass-word'));
      expect(access.calls, 1);
      // 管理トップ(イベント未選択)はイベント一覧・イベント作成・スタッフ管理だけ(CSV取込等は出ない)。
      expect(find.text('イベント一覧'), findsOneWidget);
      expect(find.text('CSV取込'), findsNothing);
      await tester.ensureVisible(find.text('ログアウト'));
      await tester.tap(find.text('ログアウト'));
      await _settle(tester);
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(find.text('イベント一覧'), findsNothing);
    });

    testWidgets('ログイン失敗は内部情報を含まないメッセージで表示され、権限確認へは進まない', (tester) async {
      final auth = FakeAuthClient(signedIn: false)
        ..signInFailure = const AuthFailure('メールアドレスまたはパスワードが正しくありません。');
      final access = FakeAccessService([
        const AccessCheck.granted(AccessRole.admin),
      ]);
      await tester.pumpWidget(_console(auth, access));
      await _settle(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'メールアドレス'),
        'x@example.invalid',
      );
      await tester.enterText(find.widgetWithText(TextField, 'パスワード'), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
      await _settle(tester);
      expect(find.text('メールアドレスまたはパスワードが正しくありません。'), findsOneWidget);
      expect(access.calls, 0);
    });

    testWidgets('入力が空なら通信せずに案内する', (tester) async {
      final auth = FakeAuthClient(signedIn: false);
      await tester.pumpWidget(
        _console(auth, FakeAccessService([const AccessCheck.denied()])),
      );
      await _settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'ログイン'));
      await _settle(tester);
      expect(find.text('メールアドレスとパスワードを入力してください。'), findsOneWidget);
      expect(auth.signInCalls, isEmpty);
    });

    testWidgets('確認中にログアウトされたら、古い結果(admin)は捨てられ権限は表示されない', (tester) async {
      final auth = FakeAuthClient(signedIn: true);
      final completer = Completer<AccessCheck>();
      final slow = _SlowAccessService(completer.future);
      await tester.pumpWidget(_console(auth, slow));
      await tester.pump();
      expect(find.text('権限を確認中…'), findsOneWidget);
      auth.setSignedIn(false);
      await _settle(tester);
      completer.complete(const AccessCheck.granted(AccessRole.admin));
      await _settle(tester);
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(find.text('CSV取込'), findsNothing);
    });
  });

  group('ロールの解釈', () {
    test('admin/staff以外の値は権限なし(null)', () {
      expect(AccessRole.fromValue('admin'), AccessRole.admin);
      expect(AccessRole.fromValue('staff'), AccessRole.staff);
      for (final value in ['Admin', 'owner', '', null, 1, true, 'admin ']) {
        expect(AccessRole.fromValue(value), isNull, reason: '$value');
      }
    });
    test('firebase_authのエラーコードは、アカウントの有無を推測させない同じ文言になる', () {
      final same = {
        for (final code in [
          'user-not-found',
          'wrong-password',
          'invalid-credential',
          'invalid-email',
        ])
          FirebaseAuthClient.messageForCode(code),
      };
      expect(same, {'メールアドレスまたはパスワードが正しくありません。'});
      expect(
        FirebaseAuthClient.messageForCode('something-else'),
        'ログインできませんでした。',
      );
    });
  });

  group('CallableAccessService(getMyAccessRole)', () {
    AccessService service(FakeAuthClient auth, MockClient client) =>
        CallableAccessService(
          authClient: auth,
          httpClient: client,
          uri: Uri.parse('https://example.invalid/getMyAccessRole'),
        );

    test('IDトークンをAuthorizationヘッダで送り、本文にuid・role・emailを含めない', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'result': {'authenticated': true, 'role': 'admin'},
          }),
          200,
        );
      });
      final check = await service(
        FakeAuthClient(signedIn: true, token: 'abc.def'),
        client,
      ).fetchMyAccess();
      expect(check.outcome, AccessOutcome.granted);
      expect(check.role, AccessRole.admin);
      expect(captured.headers['Authorization'], 'Bearer abc.def');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'data': <String, dynamic>{}});
      for (final forbidden in ['uid', 'role', 'email', 'admin']) {
        expect(captured.body.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('staffのロールを受け取る', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'result': {'authenticated': true, 'role': 'staff'},
          }),
          200,
        ),
      );
      expect(
        (await service(
          FakeAuthClient(signedIn: true),
          client,
        ).fetchMyAccess()).role,
        AccessRole.staff,
      );
    });

    test('ログインしていない(トークンなし)なら通信せずunauthenticated', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });
      final check = await service(
        FakeAuthClient(signedIn: false),
        client,
      ).fetchMyAccess();
      expect(check.outcome, AccessOutcome.unauthenticated);
      expect(requests, 0);
    });

    test('403=権限なし、401=ログイン無効、その他・例外=エラー(権限ありにはならない)', () async {
      Future<AccessOutcome> outcome(
        Future<http.Response> Function() respond,
      ) async => (await service(
        FakeAuthClient(signedIn: true),
        MockClient((_) => respond()),
      ).fetchMyAccess()).outcome;
      expect(
        await outcome(
          () async =>
              http.Response('{"error":{"status":"PERMISSION_DENIED"}}', 403),
        ),
        AccessOutcome.denied,
      );
      expect(
        await outcome(
          () async =>
              http.Response('{"error":{"status":"UNAUTHENTICATED"}}', 401),
        ),
        AccessOutcome.unauthenticated,
      );
      expect(
        await outcome(() async => http.Response('oops', 500)),
        AccessOutcome.error,
      );
      expect(
        await outcome(() async => http.Response('not json', 200)),
        AccessOutcome.error,
      );
      expect(
        await outcome(() async => throw const SocketException('offline')),
        AccessOutcome.error,
      );
    });

    test('200でも、authenticatedがtrueでない・roleがadmin/staff以外なら許可しない', () {
      AccessCheck interpret(Object body) =>
          CallableAccessService.interpret(200, jsonEncode(body));
      expect(
        interpret({
          'result': {'authenticated': false, 'role': 'admin'},
        }).outcome,
        AccessOutcome.error,
      );
      expect(
        interpret({
          'result': {'authenticated': true, 'role': 'owner'},
        }).outcome,
        AccessOutcome.denied,
      );
      expect(
        interpret({
          'result': {'authenticated': true},
        }).outcome,
        AccessOutcome.denied,
      );
      expect(
        interpret({
          'result': {'authenticated': true, 'role': 'Admin'},
        }).outcome,
        AccessOutcome.denied,
      );
      expect(interpret({}).outcome, AccessOutcome.error);
    });
  });

  group('境界の静的検査', () {
    final files = Directory('lib/confirmed')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test(
      'lib/confirmed はFirestoreを直接使わず、accessRolesを読まない(権限確認はcallable経由のみ)',
      () {
        expect(files, isNotEmpty);
        for (final file in files) {
          final text = file
              .readAsLinesSync()
              .where((line) => !line.trimLeft().startsWith('//'))
              .join('\n');
          expect(text, isNot(contains('cloud_firestore')), reason: file.path);
          expect(text, isNot(contains('accessRoles')), reason: file.path);
          expect(text, isNot(contains('FirebaseFirestore')), reason: file.path);
        }
      },
    );

    test(
      'Phase 11D: confirmedの通常管理UIに、利用者がeventIdを入力するTextField(欄)が残っていない',
      () {
        expect(files, isNotEmpty);
        for (final file in files) {
          final text = file
              .readAsLinesSync()
              .where((line) => !line.trimLeft().startsWith('//'))
              .join('\n');
          // かつて reminder_page.dart・winner_mail_page.dart・winner_send_page.dart・
          // import_page.dart にあった「イベントID」ラベルのTextFieldは、すべてイベント管理画面から
          // 内部的に渡されるeventId(initialEventId等)だけを正本とするよう置き換えた。
          expect(
            text.contains("labelText: 'イベントID'"),
            isFalse,
            reason: file.path,
          );
          expect(text.contains("Key('event-id')"), isFalse, reason: file.path);
        }
      },
    );

    test('認可の判断はサーバーの確認結果だけで行い、emailやクライアントの値を根拠にしない', () {
      final gate = File('lib/confirmed/auth_gate.dart').readAsStringSync();
      expect(gate, contains('fetchMyAccess'));
      expect(gate, isNot(contains('.email')));
      expect(
        File('lib/confirmed/auth_client.dart').readAsStringSync(),
        isNot(contains('.email;')),
      );
    });

    // Phase 10C: 以前は「従来方式のルートはAuthGateで包まれていない」を検査していた。認証境界の導入で、
    // 従来方式の管理画面(/admin・/demo-admin・/admin/events/{id})はadminのログインが必須になった(以前の許可から変更)。
    // 参加者本人のマイページ(/p/{id})と当日参加登録(/e/{id}/walk-in)は、ログイン不要のまま(capability・公開API)。
    test('Phase 10C: 従来方式の管理画面はLegacyAdminGateで包まれ、参加者本人・当日参加登録の公開ページは包まれない', () {
      final main = File('lib/main.dart').readAsStringSync();
      // Phase 11A: 作成直後のイベントIDを引き継ぐため、/console は initialEventId を受け取る(認可の構造は変わらない)
      // Phase 11F: トップ(/)も、Not Found(catch-all)にならないよう /console と同じ画面になった。
      expect(main, contains("'/' || '/console' => ConfirmedConsolePage("));
      expect(
        'ConfirmedConsolePage'.allMatches(main).length,
        1,
        reason: '/consoleの1か所だけ',
      );
      expect(
        'LegacyAdminGate('.allMatches(main).length,
        2,
        reason: '/admin(・/demo-admin)と/admin/events/{id}の2か所',
      );
      // 管理画面は、gateのbuilderの中でだけ作られる(gateの外で直接作られない)
      final adminIndex = main.indexOf("'/admin' || '/demo-admin'");
      expect(main.indexOf('EventListPage(api: api)'), greaterThan(adminIndex));
      expect(
        main.indexOf('LegacyAdminGate('),
        lessThan(main.indexOf('EventListPage(api: api)')),
      );
      expect(
        main,
        contains('DemoAdminPage(eventId: uri.pathSegments[2], api: api)'),
      );
      expect(main, isNot(contains('const EventListPage()')));
      // 受付QRは入口(ReceptionRoutePage)が、従来方式でもAuthGateで包む
      expect(
        File('lib/confirmed/reception_route.dart').readAsStringSync(),
        contains('AuthGate('),
      );
      // ログイン不要の公開ページ(参加者本人・当日参加登録)は、Firestoreを直接読まない
      for (final legacy in ['WalkInPage(', 'ParticipantPage(']) {
        final line = main.split('\n').firstWhere((l) => l.contains(legacy));
        expect(line, isNot(contains('AdminGate')), reason: legacy);
      }
    });
  });
}

class _SlowAccessService implements AccessService {
  _SlowAccessService(this.future);
  final Future<AccessCheck> future;
  @override
  Future<AccessCheck> fetchMyAccess() => future;
}
