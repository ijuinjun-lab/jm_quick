import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/winner_mail_page.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;

class FakeWinnerMailService implements WinnerMailService {
  FakeWinnerMailService({
    this.settings,
    this.previewResult,
    this.settingsError,
    this.updateError,
  });
  WinnerMailSettings? settings;
  WinnerMailPreview? previewResult;
  WinnerMailException? settingsError;
  WinnerMailException? updateError;
  final List<String> calls = [];
  final List<Map<String, String>> updates = [];

  @override
  Future<WinnerMailSettings> getSettings(String eventId) async {
    calls.add('get:$eventId');
    if (settingsError != null) throw settingsError!;
    return settings!;
  }

  @override
  Future<int> updateTemplate({
    required String eventId,
    required String subject,
    required String introBody,
    required String closingBody,
    required String notesBody,
    required String address,
    required String access,
  }) async {
    calls.add('update:$eventId');
    if (updateError != null) throw updateError!;
    updates.add({
      'subject': subject,
      'introBody': introBody,
      'closingBody': closingBody,
      'notesBody': notesBody,
      'address': address,
      'access': access,
    });
    return 3;
  }

  @override
  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  }) async {
    calls.add('preview:$eventId:$participantId');
    return previewResult!;
  }
}

WinnerMailSettings _settings({
  bool ready = true,
  List<String> problems = const [],
}) => WinnerMailSettings(
  eventId: 'event-a',
  eventName: 'テスト譲渡会',
  subject: '【当選】ご案内',
  introBody: '冒頭です',
  closingBody: '締めです',
  notesBody: '',
  address: '',
  access: '',
  version: 2,
  ready: ready,
  problems: problems,
  missingOptional: const [],
);

Widget _page(FakeWinnerMailService service) => MaterialApp(
  home: WinnerMailPage(service: service, initialEventId: 'event-a'),
);

Future<void> _load(WidgetTester tester) async {
  // 縦長の画面(スクロールなしでボタンまで届く)にして、テストがレイアウトに左右されないようにする。
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // initialEventIdがあれば自動で読み込まれる(Phase 11D)。念のため「最新の状態に更新」で確実に読み込む。
  await tester.pumpAndSettle();
  if (find.text('最新の状態に更新').evaluate().isNotEmpty) {
    await tester.tap(find.text('最新の状態に更新'));
    await tester.pumpAndSettle();
  }
}

void main() {
  group('当選メール設定画面', () {
    testWidgets('読み込むと保存済みの文章が入り、自動挿入される項目は編集できないと説明される', (tester) async {
      final service = FakeWinnerMailService(settings: _settings());
      await tester.pumpWidget(_page(service));
      await _load(tester);
      expect(find.text('【当選】ご案内'), findsOneWidget);
      expect(find.text('冒頭です'), findsOneWidget);
      expect(find.textContaining('自動で挿入します'), findsOneWidget);
      // 自動挿入項目(宛名・QR・URL等)を編集する入力欄は無い
      expect(find.widgetWithText(TextField, '宛名'), findsNothing);
      expect(find.widgetWithText(TextField, 'QRコード'), findsNothing);
      expect(find.widgetWithText(TextField, 'Web参加証URL'), findsNothing);
    });

    testWidgets('不足している必須項目は日本語で表示され、コードや"null"は出ない', (tester) async {
      final service = FakeWinnerMailService(
        settings: _settings(
          ready: false,
          problems: ['event-venue-missing', 'template-closing-invalid'],
        ),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      expect(find.text('会場が未設定です。'), findsOneWidget);
      expect(find.text('締め本文が未設定です。'), findsOneWidget);
      expect(find.textContaining('event-venue-missing'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('必須項目が空なら通信せずに案内する', (tester) async {
      final service = FakeWinnerMailService(settings: _settings());
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('件名を入力してください。'), findsOneWidget);
      expect(service.updates, isEmpty);
    });

    testWidgets('件名は1行入力の欄で、改行は入力できない', (tester) async {
      final service = FakeWinnerMailService(settings: _settings());
      await tester.pumpWidget(_page(service));
      await _load(tester);
      final subject = tester.widget<TextField>(
        find.widgetWithText(TextField, '件名'),
      );
      expect(subject.maxLines, 1);
    });

    testWidgets('保存すると編集した文章だけが送られ、新しいversionが表示される', (tester) async {
      final service = FakeWinnerMailService(settings: _settings());
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '新しい件名');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(service.updates.single['subject'], '新しい件名');
      expect(service.updates.single['introBody'], '冒頭です');
      expect(find.textContaining('保存しました(テンプレートversion 3)'), findsOneWidget);
    });

    testWidgets('サーバーの入力エラーは内部情報なしで表示される', (tester) async {
      final service = FakeWinnerMailService(
        settings: _settings(),
        updateError: const WinnerMailException('件名: 長すぎます'),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('件名: 長すぎます'), findsOneWidget);
    });

    testWidgets('読み込み失敗時はエディタを表示しない', (tester) async {
      final service = FakeWinnerMailService(
        settingsError: const WinnerMailException('対象が見つかりません'),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      expect(find.text('対象が見つかりません'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
    });

    testWidgets('プレビューはサーバーが作った件名・本文をそのまま表示し、送信はしない', (tester) async {
      final service = FakeWinnerMailService(
        settings: _settings(),
        previewResult: const WinnerMailPreview(
          ready: true,
          problems: [],
          subject: '【当選】ご案内',
          text: '架空 花子 様\n参加証: https://example.invalid/p/x',
          templateVersion: 2,
        ),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.enterText(
        find.widgetWithText(TextField, '参加者ID'),
        'batch-000001',
      );
      await tester.tap(find.text('プレビューを表示'));
      await tester.pumpAndSettle();
      expect(find.textContaining('架空 花子 様'), findsOneWidget);
      expect(find.textContaining('受付用QRコードの画像が表示されます'), findsOneWidget);
      expect(service.calls.last, 'preview:event-a:batch-000001');
      expect(service.calls.any((c) => c.startsWith('update')), isFalse);
    });

    testWidgets('プレビューできない理由は日本語で表示される', (tester) async {
      final service = FakeWinnerMailService(
        settings: _settings(),
        previewResult: const WinnerMailPreview(
          ready: false,
          problems: ['no-attendance'],
        ),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.enterText(find.widgetWithText(TextField, '参加者ID'), 'p1');
      await tester.tap(find.text('プレビューを表示'));
      await tester.pumpAndSettle();
      expect(find.text('この参加者には参加するprogramがありません。'), findsOneWidget);
    });
  });

  group('コンソールでの表示(admin専用)', () {
    // イベント選択後の管理画面(/console?eventId=…)に「当選メール設定」が表示される想定なので、
    // eventIdとイベント名表示に使う読み取り専用のサービス(FakeImportService)を渡す。
    Widget console(AccessRole role) => MaterialApp(
      home: ConfirmedConsolePage(
        authClient: FakeAuthClient(signedIn: true),
        accessService: FakeAccessService([AccessCheck.granted(role)]),
        winnerMailService: FakeWinnerMailService(settings: _settings()),
        eventSummaryService: FakeImportService(),
        initialEventId: 'evfixture0123456789',
      ),
    );

    testWidgets('adminには「当選メール設定」が表示され、開ける(選択済みeventIdが自動的に引き継がれ、読み込まれる)', (
      tester,
    ) async {
      await tester.pumpWidget(console(AccessRole.admin));
      await tester.pumpAndSettle();
      expect(find.text('当選メール設定'), findsOneWidget);
      await tester.ensureVisible(find.text('当選メール設定'));
      await tester.tap(find.text('当選メール設定'));
      await tester.pumpAndSettle();
      // eventIdを入力させる欄は無く、選択済みイベントの設定が自動で読み込まれる。
      expect(find.byType(TextField).evaluate().any((e) {
        final widget = e.widget as TextField;
        return widget.decoration?.labelText == 'イベントID';
      }), isFalse);
      expect(
        find.textContaining('テスト譲渡会'),
        findsWidgets,
        reason: '自動で読み込まれた設定が表示される',
      );
    });

    testWidgets('staffには「当選メール設定」が表示されない', (tester) async {
      await tester.pumpWidget(console(AccessRole.staff));
      await tester.pumpAndSettle();
      expect(find.text('当選メール設定'), findsNothing);
    });
  });

  group('Phase 11D: eventIdはイベント管理画面から内部的に渡されるものだけを正本とする', () {
    testWidgets(
      'initialEventIdなしで直接開くと、eventId入力欄は出さず「イベント管理画面から開いてください」と案内する',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (_) =>
                  WinnerMailPage(service: FakeWinnerMailService()),
              settings: settings,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == 'イベントID',
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('missing-event-notice')), findsOneWidget);
        expect(find.text('イベント管理画面から開いてください。'), findsOneWidget);
        expect(find.byKey(const Key('back-to-event-console')), findsOneWidget);
        await tester.tap(find.byKey(const Key('back-to-event-console')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('CallableWinnerMailService', () {
    CallableWinnerMailService service(
      MockClient client, {
      FakeAuthClient? auth,
    }) => CallableWinnerMailService(
      authClient: auth ?? FakeAuthClient(signedIn: true, token: 'tok'),
      httpClient: client,
      baseUrl: 'https://example.invalid',
    );

    test('IDトークンだけを送り、uid・roleは送らない。update本文は文章と会場情報だけ', () async {
      late http.Request seen;
      final s = service(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'result': {'version': 4},
            }),
            200,
          );
        }),
      );
      final version = await s.updateTemplate(
        eventId: 'e1',
        subject: 's',
        introBody: 'i',
        closingBody: 'c',
        notesBody: '',
        address: '',
        access: '',
      );
      expect(version, 4);
      expect(
        seen.url.toString(),
        'https://example.invalid/updateConfirmedWinnerMailTemplate',
      );
      expect(seen.headers['Authorization'], 'Bearer tok');
      final data = (jsonDecode(seen.body) as Map)['data'] as Map;
      expect(data.keys.toSet(), {'eventId', 'template', 'venueInfo'});
      expect(seen.body.contains('uid'), isFalse);
      expect(seen.body.contains('role'), isFalse);
    });

    test('ログインしていなければ通信しない', () async {
      var called = false;
      final s = service(
        MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
        auth: FakeAuthClient(signedIn: false),
      );
      await expectLater(
        s.getSettings('e1'),
        throwsA(isA<WinnerMailException>()),
      );
      expect(called, isFalse);
    });

    test('サーバーのエラーはstatusで判別され、内部情報を含まないメッセージになる', () async {
      String msg(int code, Map<String, dynamic> error) =>
          CallableWinnerMailService.errorMessage(code, {'error': error});
      expect(msg(403, {'status': 'PERMISSION_DENIED'}), 'この操作を行う権限がありません。');
      expect(
        msg(400, {
          'status': 'FAILED_PRECONDITION',
          'message': 'このイベントは新方式(confirmed)ではありません。',
        }),
        'このイベントは新方式(confirmed)ではありません。',
      );
      expect(
        msg(400, {
          'status': 'INVALID_ARGUMENT',
          'message': 'リクエストが不正です: invalid-template',
          'details': {
            'errors': [
              {'code': 'too-long', 'path': 'subject'},
            ],
          },
        }),
        '件名: 長すぎます',
      );
      expect(
        msg(500, {'status': 'INTERNAL', 'message': 'stack trace'}),
        '処理に失敗しました。もう一度お試しください。',
      );
    });

    test('通信例外は内部情報を出さない', () async {
      final s = service(
        MockClient((request) async => throw Exception('secret-host')),
      );
      try {
        await s.getSettings('e1');
        fail('should throw');
      } on WinnerMailException catch (e) {
        expect(e.message.contains('secret-host'), isFalse);
      }
    });

    test('getSettingsの結果はモデルに変換される(未設定のtemplateはnullでも落ちない)', () async {
      final s = service(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'result': {
                'eventId': 'e1',
                'template': null,
                'venueInfo': {'address': '', 'access': ''},
                'event': {'eventName': '名前'},
                'ready': false,
                'problems': ['template-not-configured'],
                'missingOptional': [],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      final settings = await s.getSettings('e1');
      expect(settings.ready, isFalse);
      expect(settings.subject, '');
      expect(settings.problems, ['template-not-configured']);
    });
  });
}
