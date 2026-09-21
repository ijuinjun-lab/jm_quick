import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/pass_page.dart';
import 'package:jm_quick/confirmed/pass_service.dart';
import 'package:jm_quick/confirmed/reception_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';
import 'package:jm_quick/confirmed/reception_service.dart';
import 'package:jm_quick/services/event_kind_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

const qrPayload =
    'https://app.invalid/reception?eventId=event1&participantId=batchA-000002&publicId=pub_aaaaaaaaaaaaaaaaaaaaaaaa';

class FakePassService implements PassService {
  FakePassService({this.pass, this.errors = 0});
  ConfirmedPass? pass;
  int errors;
  final List<(String, String)> calls = [];
  @override
  Future<ConfirmedPass?> getPass({
    required String participantId,
    required String publicId,
  }) async {
    calls.add((participantId, publicId));
    if (errors > 0) {
      errors--;
      throw const PassException('通信に失敗しました。');
    }
    return pass;
  }
}

ConfirmedPass threeProgramPass({bool withVenue = true}) => ConfirmedPass(
  eventName: '架空イベント',
  dateTimeText: '2026年11月30日(月) 10:00〜16:00',
  venue: withVenue ? '架空会場ホール' : null,
  address: withVenue ? '架空県架空市1-2-3' : null,
  access: null,
  participantName: '架空 太郎',
  programs: const [
    PassProgram(
      programId: 'alpha',
      name: '譲渡会(ねこ)',
      timeText: '10:00-10:40',
      plannedCount: 2,
      checkedIn: false,
    ),
    PassProgram(
      programId: 'beta',
      name: '譲渡会(いぬ)',
      timeText: '11:00-11:40',
      plannedCount: 1,
      checkedIn: false,
    ),
    PassProgram(
      programId: 'gamma',
      name: 'トークセッション',
      plannedCount: 2,
      checkedIn: false,
    ),
  ],
  qrPayload: qrPayload,
  webPassUrl: 'https://app.invalid/p/batchA-000002?publicId=pub_a',
);

ReceptionProgram rp(
  String id,
  String name,
  int planned, {
  bool checkedIn = false,
  int? attended,
  String? time,
}) => ReceptionProgram(
  programId: id,
  name: name,
  timeText: time,
  plannedCount: planned,
  checkedIn: checkedIn,
  checkedInAt: checkedIn ? DateTime.utc(2026, 11, 30, 2, 2) : null, // JST 11:02
  attendedCount: attended,
);

class FakeReceptionService implements ReceptionService {
  FakeReceptionService({required this.programs, this.viewError});
  List<ReceptionProgram> programs;
  ReceptionException? viewError;
  ReceptionException? checkInError;
  bool alreadyOnCheckIn = false;
  int viewCalls = 0;
  final List<Map<String, Object>> checkIns = [];

  @override
  Future<ReceptionView> getView({
    required String eventId,
    required String participantId,
    required String publicId,
  }) async {
    viewCalls++;
    if (viewError != null) throw viewError!;
    return ReceptionView(
      eventName: '架空イベント',
      participantName: '架空 太郎',
      programs: programs,
    );
  }

  @override
  Future<CheckInResult> checkIn({
    required String eventId,
    required String participantId,
    required String publicId,
    required String programId,
    required int attendedCount,
  }) async {
    checkIns.add({'programId': programId, 'attendedCount': attendedCount});
    if (checkInError != null) throw checkInError!;
    final current = programs.firstWhere((p) => p.programId == programId);
    if (alreadyOnCheckIn) {
      return CheckInResult(
        alreadyCheckedIn: true,
        program: rp(
          programId,
          current.name,
          current.plannedCount,
          checkedIn: true,
          attended: 5,
        ),
      );
    }
    return CheckInResult(
      alreadyCheckedIn: false,
      program: rp(
        programId,
        current.name,
        current.plannedCount,
        checkedIn: true,
        attended: attendedCount,
      ),
    );
  }
}

final threePrograms = [
  rp('alpha', '譲渡会(ねこ)', 2, time: '10:00-10:40'),
  rp('beta', '譲渡会(いぬ)', 1, time: '11:00-11:40'),
  rp('gamma', 'トークセッション', 2),
];

void setPhone(WidgetTester tester, {double width = 390, double height = 844}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget app(Widget child) => MaterialApp(home: child);

void main() {
  group('Web参加証(読み取り専用)', () {
    Widget route(
      FakePassService service, {
      String? id = 'batchA-000002',
      String? token = 'pub_x',
    }) => app(
      PassRoutePage(
        participantId: id,
        publicId: token,
        service: service,
        legacyBuilder: (_) => const Scaffold(body: Text('LEGACY-PAGE')),
      ),
    );

    testWidgets('参加証: イベント名・参加者名・3program(順序・時間・予定人数)・QRを表示し、QRはサーバーの文字列そのもの', (
      tester,
    ) async {
      setPhone(tester, height: 1600);
      final service = FakePassService(pass: threeProgramPass());
      await tester.pumpWidget(route(service));
      await tester.pumpAndSettle();
      expect(find.text('架空イベント'), findsOneWidget);
      expect(find.text('架空 太郎 様'), findsOneWidget);
      final names = ['譲渡会(ねこ)', '譲渡会(いぬ)', 'トークセッション'];
      final tops = [for (final n in names) tester.getTopLeft(find.text(n)).dy];
      expect(tops, [...tops]..sort(), reason: 'サーバーが返した順序で表示');
      expect(find.text('10:00-10:40'), findsOneWidget);
      expect(find.text('11:00-11:40'), findsOneWidget);
      expect(find.text('予定人数 2名'), findsNWidgets(2));
      expect(find.text('予定人数 1名'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pass-qr:$qrPayload')),
        findsOneWidget,
        reason: 'メールQR・受付URLと同じ文字列(クライアントで組み立てない)',
      );
      expect(find.text('会場'), findsOneWidget);
      expect(find.text('架空会場ホール'), findsOneWidget);
      expect(find.text('アクセス'), findsNothing, reason: '未設定の項目は欄ごと出さない');
      expect(find.textContaining('null'), findsNothing);
      expect(find.textContaining('未設定'), findsNothing);
    });

    testWidgets('読み取り専用: 受付・人数変更・取消の操作が一切ない', (tester) async {
      setPhone(tester, height: 1600);
      await tester.pumpWidget(route(FakePassService(pass: threeProgramPass())));
      await tester.pumpAndSettle();
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('受付する'), findsNothing);
      expect(find.textContaining('取消'), findsNothing);
      expect(find.textContaining('キャンセル'), findsNothing);
    });

    testWidgets('受付済みのprogramには「受付済み」の表示だけが出る(受付時刻・人数は出さない)', (tester) async {
      setPhone(tester, height: 1600);
      final pass = threeProgramPass();
      final withChecked = ConfirmedPass(
        eventName: pass.eventName,
        participantName: pass.participantName,
        qrPayload: pass.qrPayload,
        webPassUrl: pass.webPassUrl,
        programs: [
          const PassProgram(
            programId: 'alpha',
            name: '譲渡会(ねこ)',
            plannedCount: 2,
            checkedIn: true,
          ),
          ...pass.programs.skip(1),
        ],
      );
      await tester.pumpWidget(route(FakePassService(pass: withChecked)));
      await tester.pumpAndSettle();
      expect(find.text('受付済み'), findsOneWidget);
    });

    testWidgets('確認できない(存在しない・publicId不一致・無効・従来方式)は参加者の従来ページへ。理由は表示されない', (
      tester,
    ) async {
      final service = FakePassService(pass: null);
      await tester.pumpWidget(route(service));
      await tester.pumpAndSettle();
      expect(find.text('LEGACY-PAGE'), findsOneWidget);
      expect(service.calls, [('batchA-000002', 'pub_x')]);
    });

    testWidgets('publicIdなし・空のURLでは、サーバーへ問い合わせず従来のページへ', (tester) async {
      for (final token in [null, '']) {
        final service = FakePassService(pass: threeProgramPass());
        await tester.pumpWidget(route(service, token: token));
        await tester.pumpAndSettle();
        expect(find.text('LEGACY-PAGE'), findsOneWidget);
        expect(service.calls, isEmpty);
      }
    });

    testWidgets('通信エラーは再読み込みでき、参加証が表示される。内部の状態は出さない', (tester) async {
      final service = FakePassService(pass: threeProgramPass(), errors: 1);
      await tester.pumpWidget(route(service));
      await tester.pumpAndSettle();
      expect(find.textContaining('参加証を確認できませんでした'), findsOneWidget);
      expect(find.textContaining('publicId'), findsNothing);
      await tester.tap(find.text('再読み込み'));
      await tester.pumpAndSettle();
      expect(find.text('架空 太郎 様'), findsOneWidget);
    });

    testWidgets('390px幅でも横スクロール・はみ出しなく表示される', (tester) async {
      setPhone(tester);
      await tester.pumpWidget(route(FakePassService(pass: threeProgramPass())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final n in ['譲渡会(ねこ)', 'トークセッション']) {
        expect(tester.getRect(find.text(n)).right, lessThanOrEqualTo(390));
      }
    });
  });

  group('CallablePassService(公開・ログイン不要)', () {
    CallablePassService service(MockClient client) => CallablePassService(
      httpClient: client,
      baseUrl: 'https://example.invalid',
    );
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test('IDトークン等を送らず、participantIdとpublicIdだけをPOSTする', () async {
      late http.Request seen;
      final s = service(
        MockClient((request) async {
          seen = request;
          return json({
            'result': {
              'eventName': '架空イベント',
              'participantName': '架空 太郎',
              'programs': [
                {
                  'programId': 'alpha',
                  'name': '譲渡会(ねこ)',
                  'plannedCount': 2,
                  'checkedIn': false,
                  'timeText': '10:00-10:40',
                },
              ],
              'qrPayload': qrPayload,
              'webPassUrl': 'https://app.invalid/p/x?publicId=y',
            },
          }, 200);
        }),
      );
      final pass = await s.getPass(
        participantId: 'batchA-000002',
        publicId: 'pub_x',
      );
      expect(pass!.programs.single.timeText, '10:00-10:40');
      expect(pass.qrPayload, qrPayload);
      expect(
        seen.url.toString(),
        'https://example.invalid/getConfirmedParticipantPass',
      );
      expect(seen.headers.containsKey('Authorization'), isFalse);
      expect((jsonDecode(seen.body) as Map)['data'], {
        'participantId': 'batchA-000002',
        'publicId': 'pub_x',
      });
    });

    test('NOT_FOUNDは「確認できない」(null)、その他は通信エラー扱い', () async {
      expect(
        await service(
          MockClient(
            (_) async => json({
              'error': {'status': 'NOT_FOUND', 'message': '参加証を確認できませんでした。'},
            }, 404),
          ),
        ).getPass(participantId: 'a', publicId: 'b'),
        isNull,
      );
      await expectLater(
        service(
          MockClient(
            (_) async => json({
              'error': {'status': 'INTERNAL'},
            }, 500),
          ),
        ).getPass(participantId: 'a', publicId: 'b'),
        throwsA(isA<PassException>()),
      );
      await expectLater(
        service(
          MockClient((_) async => throw Exception('secret-host')),
        ).getPass(participantId: 'a', publicId: 'b'),
        throwsA(
          isA<PassException>().having(
            (e) => e.message.contains('secret-host'),
            'no leak',
            isFalse,
          ),
        ),
      );
    });
  });

  group('受付画面(confirmed・program別)', () {
    Widget page(FakeReceptionService service) => app(
      ConfirmedReceptionPage(
        service: service,
        eventId: 'event1',
        participantId: 'batchA-000002',
        publicId: 'pub_x',
      ),
    );

    testWidgets('参加者名と、参加する3programすべてが順序どおり・予定人数・受付状態つきで表示される', (
      tester,
    ) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      expect(find.text('架空 太郎 様'), findsOneWidget);
      expect(find.text('未受付'), findsNWidgets(3));
      expect(find.text('受付する'), findsNWidgets(3));
      expect(find.text('予定人数 2名'), findsNWidgets(2));
      final tops = [
        for (final n in ['譲渡会(ねこ)', '譲渡会(いぬ)', 'トークセッション'])
          tester.getTopLeft(find.text(n)).dy,
      ];
      expect(tops, [...tops]..sort());
      expect(find.text('10:00-10:40'), findsOneWidget);
    });

    testWidgets('来場人数の初期値は予定人数。予定人数と実来場人数は別の欄・別の値', (tester) async {
      setPhone(tester, height: 1800);
      await tester.pumpWidget(
        page(FakeReceptionService(programs: [...threePrograms])),
      );
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .map((f) => f.controller!.text)
          .toList();
      expect(fields, ['2', '1', '2']);
    });

    testWidgets('受付: 確認ダイアログ→受付。そのprogramだけが「受付済み・受付時刻・実来場人数」になり、他は未受付のまま', (
      tester,
    ) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      // alphaを、予定2名のところ実際1名で受付する
      await tester.enterText(find.byType(TextField).first, '1');
      await tester.tap(find.text('受付する').first);
      await tester.pumpAndSettle();
      expect(find.text('受付の確認'), findsOneWidget);
      expect(service.checkIns, isEmpty, reason: '確認するまで送信しない');
      await tester.tap(find.widgetWithText(FilledButton, '受付する').last);
      await tester.pumpAndSettle();
      expect(service.checkIns, [
        {'programId': 'alpha', 'attendedCount': 1},
      ]);
      expect(find.text('受付済み'), findsOneWidget);
      expect(find.text('受付時刻 11:02'), findsOneWidget);
      expect(find.text('実来場人数 1名'), findsOneWidget);
      expect(find.text('予定人数 2名'), findsNWidgets(2), reason: '予定人数は変わらない');
      expect(find.text('未受付'), findsNWidgets(2));
      expect(
        find.text('受付する'),
        findsNWidgets(2),
        reason: '受付済みのprogramには受付ボタンが出ない',
      );
      expect(
        service.viewCalls,
        1,
        reason: '受付後もFirestore直接監視ではなく、必要な分だけcallable',
      );
    });

    testWidgets('確認ダイアログで「やめる」なら受付しない', (tester) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('受付する').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('やめる'));
      await tester.pumpAndSettle();
      expect(service.checkIns, isEmpty);
      expect(find.text('未受付'), findsNWidgets(3));
    });

    testWidgets('受付済みのprogramは、最初から「受付済み」表示で、受付ボタン・入力欄が無い(同じQRの再読込でも分かる)', (
      tester,
    ) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(
        programs: [
          rp(
            'alpha',
            '譲渡会(ねこ)',
            2,
            checkedIn: true,
            attended: 2,
            time: '10:00-10:40',
          ),
          rp('beta', '譲渡会(いぬ)', 1),
          rp('gamma', 'トークセッション', 2),
        ],
      );
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      expect(find.text('受付済み'), findsOneWidget);
      expect(find.text('未受付'), findsNWidgets(2));
      expect(find.text('受付する'), findsNWidgets(2));
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('二重受付(別端末が先に受付)では、先に受付された内容が表示され、その旨が案内される', (tester) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms])
        ..alreadyOnCheckIn = true;
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('受付する').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '受付する').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('すでに受付済みです'), findsWidgets);
      expect(
        find.text('実来場人数 5名'),
        findsOneWidget,
        reason: '先の受付内容(自分の入力ではない)',
      );
    });

    testWidgets('来場人数が不正(0・空・文字・上限超)なら送信しない', (tester) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      for (final text in ['0', '', 'abc', '1000', '-1', '1.5']) {
        await tester.enterText(find.byType(TextField).first, text);
        await tester.tap(find.text('受付する').first);
        await tester.pumpAndSettle();
        expect(find.textContaining('1〜999名の整数'), findsOneWidget, reason: text);
      }
      expect(service.checkIns, isEmpty);
      expect(find.text('受付の確認'), findsNothing);
    });

    testWidgets('受付に失敗したprogramにだけエラーが出て、未受付のまま(他のprogramは影響なし)', (
      tester,
    ) async {
      setPhone(tester, height: 1800);
      final service = FakeReceptionService(programs: [...threePrograms])
        ..checkInError = const ReceptionException('通信に失敗しました。');
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      await tester.tap(find.text('受付する').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '受付する').last);
      await tester.pumpAndSettle();
      expect(find.text('通信に失敗しました。'), findsOneWidget);
      expect(find.text('未受付'), findsNWidgets(3));
    });

    testWidgets('この参加証は受付できない場合は共通の表示(理由の詳細は画面に出さない)', (tester) async {
      setPhone(tester);
      final service = FakeReceptionService(
        programs: const [],
        viewError: const ReceptionException(
          'この参加証は受付できません。',
          code: 'public-id-mismatch',
          notAllowed: true,
        ),
      );
      await tester.pumpWidget(page(service));
      await tester.pumpAndSettle();
      expect(find.text('この参加証は受付できません。'), findsOneWidget);
      expect(find.textContaining('public-id-mismatch'), findsNothing);
      expect(find.text('受付する'), findsNothing);
    });

    testWidgets(
      '390px幅のスマートフォンで、氏名・program名・時間・予定人数・来場人数入力・状態・受付ボタンが横スクロールなしで操作できる',
      (tester) async {
        setPhone(tester, height: 2000);
        await tester.pumpWidget(
          page(
            FakeReceptionService(
              programs: [
                rp('alpha', '譲渡会(ねこ)', 2, time: '10:00-10:40'),
                rp(
                  'beta',
                  '譲渡会(いぬ)',
                  1,
                  checkedIn: true,
                  attended: 1,
                  time: '11:00-11:40',
                ),
                rp('gamma', 'トークセッション', 2),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'オーバーフローなし');
        for (final finder in [
          find.text('架空 太郎 様'),
          find.text('譲渡会(ねこ)'),
          find.text('10:00-10:40'),
          find.text('予定人数 2名').first,
          find.byType(TextField).first,
          find.text('未受付').first,
          find.text('受付する').first,
          find.text('受付済み'),
        ]) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(390));
        }
        // 受付ボタンは十分な大きさ(誤タップしにくい)
        expect(
          tester
              .getSize(find.widgetWithText(FilledButton, '受付する').first)
              .height,
          greaterThanOrEqualTo(44),
        );
        // 横方向のスクロール領域が無い(1行入力欄の内部のスクロールは除く)
        final horizontal = find.byWidgetPredicate(
          (w) =>
              w is Scrollable &&
              (w.axisDirection == AxisDirection.right ||
                  w.axisDirection == AxisDirection.left),
        );
        expect(
          horizontal.evaluate().length,
          find
              .descendant(of: find.byType(TextField), matching: horizontal)
              .evaluate()
              .length,
        );
      },
    );
  });

  group('受付QRの入口(/reception)の分岐と認可', () {
    Widget route({
      required bool legacy,
      required FakeAuthClient auth,
      required FakeAccessService access,
      required FakeReceptionService reception,
      String? publicId = 'pub_x',
    }) => app(
      ReceptionRoutePage(
        eventId: 'event1',
        participantId: 'batchA-000002',
        publicId: publicId,
        legacyBuilder: (_) => const Scaffold(body: Text('LEGACY-RECEPTION')),
        authClient: auth,
        accessService: access,
        receptionService: reception,
        isLegacyEvent: (_) async => legacy,
      ),
    );

    // Phase 10C: 以前は「従来方式の受付画面はログインも権限確認も要求しない」だった。認証境界の導入で、
    // 従来方式の受付画面もstaff/adminのログインが必要になった(この経路は以前の許可から拒否へ変わった)。
    testWidgets('Phase 10C: 従来方式のイベントの受付画面も、未ログインではログイン画面だけ。受付画面は出ない', (
      tester,
    ) async {
      final auth = FakeAuthClient(signedIn: false);
      final access = FakeAccessService([]);
      await tester.pumpWidget(
        route(
          legacy: true,
          auth: auth,
          access: access,
          reception: FakeReceptionService(programs: []),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('LEGACY-RECEPTION'), findsNothing);
      expect(access.calls, 0);
    });

    testWidgets(
      'Phase 10C: 従来方式の受付画面は、staff・adminとして確認できたあとだけ表示される。権限なしでは出ない',
      (tester) async {
        for (final role in [AccessRole.staff, AccessRole.admin]) {
          await tester.pumpWidget(
            route(
              legacy: true,
              auth: FakeAuthClient(signedIn: true),
              access: FakeAccessService([AccessCheck.granted(role)]),
              reception: FakeReceptionService(programs: []),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('LEGACY-RECEPTION'),
            findsOneWidget,
            reason: '$role',
          );
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pumpWidget(
          route(
            legacy: true,
            auth: FakeAuthClient(signedIn: true),
            access: FakeAccessService([const AccessCheck.denied()]),
            reception: FakeReceptionService(programs: []),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('LEGACY-RECEPTION'), findsNothing);
        expect(find.text('権限がありません'), findsOneWidget);
      },
    );

    testWidgets(
      'Phase 10C: 未知のflow・存在しないイベント・方式を読めないときは、どの受付画面も出さない(fail-closed)',
      (tester) async {
        for (final kind in [EventKind.unsupported, EventKind.missing]) {
          final reception = FakeReceptionService(programs: [...threePrograms]);
          await tester.pumpWidget(
            app(
              ReceptionRoutePage(
                eventId: 'event1',
                participantId: 'batchA-000002',
                publicId: 'pub_x',
                legacyBuilder: (_) =>
                    const Scaffold(body: Text('LEGACY-RECEPTION')),
                authClient: FakeAuthClient(signedIn: true),
                accessService: FakeAccessService([
                  AccessCheck.granted(AccessRole.admin),
                ]),
                receptionService: reception,
                eventKind: (_) async => kind,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('LEGACY-RECEPTION'), findsNothing, reason: '$kind');
          expect(find.text('受付する'), findsNothing, reason: '$kind');
          expect(reception.viewCalls, 0, reason: '$kind');
          await tester.pumpWidget(const SizedBox());
        }
        final reception = FakeReceptionService(programs: [...threePrograms]);
        await tester.pumpWidget(
          app(
            ReceptionRoutePage(
              eventId: 'event1',
              participantId: 'batchA-000002',
              publicId: 'pub_x',
              legacyBuilder: (_) =>
                  const Scaffold(body: Text('LEGACY-RECEPTION')),
              authClient: FakeAuthClient(signedIn: true),
              accessService: FakeAccessService([
                AccessCheck.granted(AccessRole.admin),
              ]),
              receptionService: reception,
              eventKind: (_) async => throw StateError('read failed'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('LEGACY-RECEPTION'), findsNothing);
        expect(find.text('再試行'), findsOneWidget);
        expect(reception.viewCalls, 0);
      },
    );

    testWidgets('必要なパラメータが欠けたURLは従来の受付画面へ(従来の案内表示)', (tester) async {
      final reception = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(
        route(
          legacy: false,
          auth: FakeAuthClient(signedIn: true),
          access: FakeAccessService([]),
          reception: reception,
          publicId: null,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('LEGACY-RECEPTION'), findsOneWidget);
      expect(reception.viewCalls, 0);
    });

    testWidgets('confirmedで未ログイン(参加者本人を含む)ならログイン画面だけ。受付画面も受付ボタンも出ず、受付の通信もしない', (
      tester,
    ) async {
      setPhone(tester, height: 1200);
      final reception = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(
        route(
          legacy: false,
          auth: FakeAuthClient(signedIn: false),
          access: FakeAccessService([]),
          reception: reception,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('受付する'), findsNothing);
      expect(find.text('譲渡会(ねこ)'), findsNothing);
      expect(reception.viewCalls, 0);
    });

    testWidgets('staff・adminはログイン後に受付画面が表示される', (tester) async {
      for (final role in [AccessRole.staff, AccessRole.admin]) {
        setPhone(tester, height: 1800);
        final reception = FakeReceptionService(programs: [...threePrograms]);
        await tester.pumpWidget(
          route(
            legacy: false,
            auth: FakeAuthClient(signedIn: true),
            access: FakeAccessService([AccessCheck.granted(role)]),
            reception: reception,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('架空 太郎 様'), findsOneWidget, reason: '$role');
        expect(find.text('受付する'), findsNWidgets(3));
      }
    });

    testWidgets('権限なしのログインでは受付画面に進まない(受付の通信もしない)', (tester) async {
      final reception = FakeReceptionService(programs: [...threePrograms]);
      await tester.pumpWidget(
        route(
          legacy: false,
          auth: FakeAuthClient(signedIn: true),
          access: FakeAccessService([const AccessCheck.denied()]),
          reception: reception,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      expect(find.text('受付する'), findsNothing);
      expect(reception.viewCalls, 0);
    });
  });

  group('CallableReceptionService', () {
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test(
      'checkInはIDトークンを送り、QRのID・program・実来場人数だけを送る(予定人数・uid・role・時刻は送らない)',
      () async {
        late http.Request seen;
        final s = CallableReceptionService(
          authClient: FakeAuthClient(signedIn: true, token: 'tok'),
          baseUrl: 'https://example.invalid',
          httpClient: MockClient((request) async {
            seen = request;
            return json({
              'result': {
                'alreadyCheckedIn': false,
                'program': {
                  'programId': 'alpha',
                  'plannedCount': 2,
                  'checkedIn': true,
                  'attendedCount': 1,
                  'checkedInAt': '2026-11-30T02:02:00.000Z',
                },
              },
            }, 200);
          }),
        );
        final result = await s.checkIn(
          eventId: 'event1',
          participantId: 'p1',
          publicId: 'pub_x',
          programId: 'alpha',
          attendedCount: 1,
        );
        expect(result.program.attendedCount, 1);
        expect(result.program.plannedCount, 2);
        expect(
          seen.url.toString(),
          'https://example.invalid/checkInConfirmedProgram',
        );
        expect(seen.headers['Authorization'], 'Bearer tok');
        final data = (jsonDecode(seen.body) as Map)['data'] as Map;
        expect(data.keys.toSet(), {
          'eventId',
          'participantId',
          'publicId',
          'programId',
          'attendedCount',
        });
      },
    );

    test('未ログインなら通信しない', () async {
      var called = false;
      final s = CallableReceptionService(
        authClient: FakeAuthClient(signedIn: false),
        httpClient: MockClient((_) async {
          called = true;
          return json({}, 200);
        }),
      );
      await expectLater(
        s.getView(eventId: 'e', participantId: 'p', publicId: 'x'),
        throwsA(isA<ReceptionException>()),
      );
      expect(called, isFalse);
    });

    test('サーバーのエラーは表示用に変換される(受付不可・権限・入力)', () {
      ReceptionException e(
        int code,
        String status, [
        Map<String, dynamic>? details,
      ]) => CallableReceptionService.errorFrom(code, {
        'error': {'status': status, if (details != null) 'details': details},
      });
      expect(
        e(400, 'FAILED_PRECONDITION', {
          'code': 'batch-not-committed',
        }).notAllowed,
        isTrue,
      );
      expect(
        e(400, 'FAILED_PRECONDITION', {'code': 'batch-not-committed'}).message,
        'この参加証は受付できません。',
      );
      expect(e(403, 'PERMISSION_DENIED').message, 'この操作を行う権限がありません。');
      expect(e(401, 'UNAUTHENTICATED').message, 'ログインが必要です。');
      expect(
        e(400, 'INVALID_ARGUMENT', {
          'code': 'invalid-attended-count',
        }).notAllowed,
        isFalse,
      );
      expect(e(500, 'INTERNAL').message, '処理に失敗しました。もう一度お試しください。');
    });
  });

  group('構造(ソース)の固定', () {
    String read(String path) => File(path).readAsStringSync();

    test('Web参加証は読み取り専用: 参加証のコードは受付サービスを使わず、QRの文字列を自前で組み立てない', () {
      final source =
          read('lib/confirmed/pass_page.dart') +
          read('lib/confirmed/pass_service.dart');
      expect(source.contains('reception_service'), isFalse);
      expect(source.contains('checkIn'), isFalse);
      expect(
        source.contains('/reception?'),
        isFalse,
        reason: 'QR生成規則をクライアントに複製しない',
      );
      expect(source.contains('idToken'), isFalse, reason: '公開の参加証はログイン情報を送らない');
    });

    test('受付画面はFirestoreを直接監視・書込みしない(callable経由のみ)', () {
      final source = [
        'reception_page',
        'reception_service',
        'reception_route',
        'pass_page',
        'pass_service',
      ].map((n) => read('lib/confirmed/$n.dart')).join('\n');
      expect(source.contains('cloud_firestore'), isFalse);
      expect(source.contains('snapshots()'), isFalse);
      expect(
        source.contains('checkIns'),
        isFalse,
        reason: '旧checkInsを受付の正本にしない',
      );
    });

    test('/p と /reception は、従来のページを残したまま入口だけを分岐させる', () {
      final main = read('lib/main.dart');
      expect(main.contains('PassRoutePage('), isTrue);
      expect(main.contains('ReceptionRoutePage('), isTrue);
      expect(main.contains('legacyBuilder: (_) => ParticipantPage('), isTrue);
      expect(main.contains('legacyBuilder: (_) => ReceptionPage('), isTrue);
    });
  });
}
