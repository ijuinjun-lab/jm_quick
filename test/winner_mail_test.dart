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
  // サーバー(getConfirmedWinnerMailSettings)が選んだ、プレビュー対象のparticipantId。
  // Phase 11I: 利用者は入力しない。既定は「取込済み参加者が1件ある」状態(架空のID)。
  // nullにすると「取込済みの参加者がありません」の案内を再現できる。
  String? previewParticipantId = 'batch-000001-0001',
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
  previewParticipantId: previewParticipantId,
);

Widget _page(FakeWinnerMailService service) => MaterialApp(
  home: WinnerMailPage(service: service, initialEventId: 'event-a'),
);

// 実際にデコードできる最小のPNG(1x1・透明)。サーバーのcomposeWinnerMailForが返すQR画像と同じ形式
// (PNG・base64)であることだけを確認するための架空データ(実物のQRペイロードではない)。
const _fakePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

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

    testWidgets(
      'プレビューは、利用者が入力しなくても、サーバーが選んだ参加者に対して自動的に呼ばれ、'
      'サーバーが作った件名・本文・QR画像・Web参加証URLをそのまま表示する(送信はしない)',
      (tester) async {
        final service = FakeWinnerMailService(
          settings: _settings(previewParticipantId: 'batch-000001-0001'),
          previewResult: const WinnerMailPreview(
            ready: true,
            problems: [],
            subject: '【当選】ご案内',
            text: '架空 花子 様\n参加証: https://example.invalid/p/x',
            templateVersion: 2,
            webPassUrl: 'https://example.invalid/p/batch-000001-0001',
            qrPayload:
                'https://example.invalid/reception?eventId=event-a&participantId=batch-000001-0001',
            qrPngBase64: _fakePngBase64,
          ),
        );
        await tester.pumpWidget(_page(service));
        await _load(tester);
        // 参加者IDを入力する欄自体が存在しない。
        expect(
          find.widgetWithText(TextField, '参加者ID'),
          findsNothing,
        );
        await tester.tap(find.text('プレビューを表示'));
        await tester.pumpAndSettle();
        expect(find.textContaining('架空 花子 様'), findsOneWidget);
        // HTMLメールプレビュー(QR画像を含む)が、テキスト版に加えて表示される。
        expect(find.textContaining('HTMLメールプレビュー'), findsOneWidget);
        expect(find.textContaining('受付QR画像を含む完成形'), findsOneWidget);
        // サーバーが返したQR画像(qrPngBase64)がデコードされ、Image.memoryとして表示される。
        // (ここでQRを作り直していない。サーバーの返却バイト列とウィジェットのバイト列が一致する)
        final image = tester.widget<Image>(find.byType(Image));
        final provider = image.image as MemoryImage;
        expect(provider.bytes, base64Decode(_fakePngBase64));
        // Web参加証URLも、サーバーが返した値がそのまま表示される。
        expect(
          find.text('https://example.invalid/p/batch-000001-0001'),
          findsOneWidget,
        );
        // サーバー(settings.previewParticipantId)が選んだIDがそのまま使われる。
        expect(service.calls.last, 'preview:event-a:batch-000001-0001');
        // メール送信・更新・送信ジョブ関連の呼び出しは一切無い(プレビューは副作用を持たない)。
        expect(service.calls.any((c) => c.startsWith('update')), isFalse);
        expect(service.calls.where((c) => c.startsWith('preview')).length, 1);
      },
    );

    testWidgets(
      'プレビューを何度押しても、preview呼び出しが増えるだけで、送信・配送に類する呼び出しは一切発生しない',
      (tester) async {
        final service = FakeWinnerMailService(
          settings: _settings(),
          previewResult: const WinnerMailPreview(
            ready: true,
            problems: [],
            subject: '【当選】ご案内',
            text: '架空 花子 様',
            templateVersion: 2,
            webPassUrl: 'https://example.invalid/p/x',
            qrPngBase64: _fakePngBase64,
          ),
        );
        await tester.pumpWidget(_page(service));
        await _load(tester);
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.text('プレビューを表示'));
          await tester.pumpAndSettle();
        }
        expect(
          service.calls.where((c) => c.startsWith('preview')).length,
          3,
        );
        // FakeWinnerMailServiceにはそもそも送信・ジョブ作成の手段が無い(WinnerMailServiceの契約に無い)。
        // callsに現れるのは get/update/preview だけであることを確認し、それ以外が紛れ込んでいないことを担保する。
        expect(
          service.calls.every(
            (c) =>
                c.startsWith('get:') ||
                c.startsWith('update:') ||
                c.startsWith('preview:'),
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'サーバーの応答にQR画像が無い・壊れている場合でも、画面全体は落ちずエラー文言だけを表示する',
      (tester) async {
        final service = FakeWinnerMailService(
          settings: _settings(),
          previewResult: const WinnerMailPreview(
            ready: true,
            problems: [],
            subject: '【当選】ご案内',
            text: '架空 花子 様',
            templateVersion: 2,
            webPassUrl: 'https://example.invalid/p/x',
            qrPngBase64: '', // 想定外の空応答
          ),
        );
        await tester.pumpWidget(_page(service));
        await _load(tester);
        await tester.tap(find.text('プレビューを表示'));
        await tester.pumpAndSettle();
        expect(find.text('QR画像を取得できませんでした。'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('プレビューできない理由は日本語で表示される(参加者は自動的に選ばれる)', (tester) async {
      final service = FakeWinnerMailService(
        settings: _settings(previewParticipantId: 'batch-000001-0001'),
        previewResult: const WinnerMailPreview(
          ready: false,
          problems: ['no-attendance'],
        ),
      );
      await tester.pumpWidget(_page(service));
      await _load(tester);
      await tester.tap(find.text('プレビューを表示'));
      await tester.pumpAndSettle();
      expect(find.text('この参加者には参加するprogramがありません。'), findsOneWidget);
    });

    testWidgets(
      '取込済みの参加者が0件なら、案内文だけを表示し、IDを入力させる欄には切り替わらない',
      (tester) async {
        final service = FakeWinnerMailService(
          settings: _settings(previewParticipantId: null),
        );
        await tester.pumpWidget(_page(service));
        await _load(tester);
        expect(find.text('取込済みの参加者がありません。先にCSV取込を行ってください。'), findsOneWidget);
        expect(find.text('プレビューを表示'), findsNothing);
        // 代替として参加者IDやpublicIdを入力させる欄は一切出ない。
        expect(find.byType(TextField).evaluate().any((e) {
          final label = (e.widget as TextField).decoration?.labelText ?? '';
          return label.contains('参加者ID') || label.contains('publicId');
        }), isFalse);
        // 0件なのでpreview呼び出し自体が起きない(サーバーへの無駄打ち・誤ったプレビューを防ぐ)。
        expect(service.calls.any((c) => c.startsWith('preview')), isFalse);
      },
    );

    testWidgets(
      '複数の取込回(バッチ)があっても、画面はサーバーが返したpreviewParticipantIdをそのまま使うだけで、'
      'バッチを気にしない(イベント単位の設計)',
      (tester) async {
        // 「第2回」相当の取込由来のIDでも、画面側は特別扱いせずそのまま使う。
        final service = FakeWinnerMailService(
          settings: _settings(previewParticipantId: 'batch-000002-0007'),
          previewResult: const WinnerMailPreview(
            ready: true,
            problems: [],
            subject: '【当選】ご案内',
            text: '架空 次郎 様',
            templateVersion: 2,
          ),
        );
        await tester.pumpWidget(_page(service));
        await _load(tester);
        await tester.tap(find.text('プレビューを表示'));
        await tester.pumpAndSettle();
        expect(service.calls.last, 'preview:event-a:batch-000002-0007');
      },
    );

    testWidgets('幅390pxでもレイアウト例外(オーバーフロー)が起きない(QR画像プレビューを含む)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = FakeWinnerMailService(
        settings: _settings(),
        previewResult: const WinnerMailPreview(
          ready: true,
          problems: [],
          subject: '【当選】ご案内',
          text: '架空 花子 様',
          templateVersion: 2,
          webPassUrl: 'https://example.invalid/p/batch-000001-0001',
          qrPngBase64: _fakePngBase64,
        ),
      );
      await tester.pumpWidget(_page(service));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('プレビューを表示'));
      await tester.tap(find.text('プレビューを表示'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
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

    test(
      'getSettingsの結果はモデルに変換される(未設定のtemplateはnullでも落ちない。'
      'previewParticipantIdは未指定ならnullのまま)',
      () async {
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
                  'previewParticipantId': null,
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
        expect(settings.previewParticipantId, isNull);
      },
    );

    test(
      'getSettingsが返すpreviewParticipantIdはそのままモデルに反映される'
      '(サーバーが選んだ値をクライアントが書き換えない)',
      () async {
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
                  'previewParticipantId': 'batch-000001-0003',
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            ),
          ),
        );
        final settings = await s.getSettings('e1');
        expect(settings.previewParticipantId, 'batch-000001-0003');
      },
    );
  });
}
