import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/reception_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';
import 'package:jm_quick/confirmed/reception_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

/// サーバーの受付状態を模したメモリ上の偽サービス(Firestore・ネットワークは一切ない)。
class FakeAdminReception implements ReceptionService, ReceptionAdminService {
  FakeAdminReception(this.programs);
  List<ReceptionProgram> programs;
  final List<String> calls = [];
  final List<Map<String, Object?>> corrections = [];
  Completer<void>? gate;
  ReceptionException? error;
  int viewCalls = 0;

  int _index(String programId) =>
      programs.indexWhere((p) => p.programId == programId);

  @override
  Future<ReceptionView> getView({
    required String eventId,
    required String participantId,
    required String publicId,
  }) async {
    viewCalls++;
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
    calls.add('checkIn:$programId:$attendedCount');
    final i = _index(programId);
    final p = programs[i];
    programs[i] = rp(
      p.programId,
      p.name,
      p.plannedCount,
      checkedIn: true,
      attended: attendedCount,
      time: p.timeText,
    );
    return CheckInResult(alreadyCheckedIn: false, program: programs[i]);
  }

  @override
  Future<AttendanceChange> correct({
    required String eventId,
    required String participantId,
    required String publicId,
    required String programId,
    required int attendedCount,
  }) async {
    calls.add('correct:$programId:$attendedCount');
    corrections.add({'programId': programId, 'attendedCount': attendedCount});
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    final i = _index(programId);
    final p = programs[i];
    if (!p.checkedIn) {
      throw const ReceptionException(
        'このprogramはまだ受付されていないため、訂正できません。画面を更新してください。',
      );
    }
    final changed = p.attendedCount != attendedCount;
    programs[i] = ReceptionProgram(
      programId: p.programId,
      name: p.name,
      timeText: p.timeText,
      plannedCount: p.plannedCount, // 予定人数は変わらない
      checkedIn: true,
      checkedInAt: p.checkedInAt, // 初回受付時刻のまま
      attendedCount: attendedCount,
    );
    return AttendanceChange(
      changed: changed,
      program: programs[i],
      noop: changed ? null : 'no-change',
    );
  }

  @override
  Future<AttendanceChange> cancel({
    required String eventId,
    required String participantId,
    required String publicId,
    required String programId,
  }) async {
    calls.add('cancel:$programId');
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    final i = _index(programId);
    final p = programs[i];
    final changed = p.checkedIn;
    programs[i] = rp(p.programId, p.name, p.plannedCount, time: p.timeText);
    return AttendanceChange(
      changed: changed,
      program: programs[i],
      noop: changed ? null : 'not-checked-in',
    );
  }
}

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

List<ReceptionProgram> threePrograms() => [
  rp('alpha', 'プログラムA', 3, checkedIn: true, attended: 2, time: '10:00-10:40'),
  rp('beta', 'プログラムB', 1, checkedIn: true, attended: 1, time: '11:00-11:40'),
  rp('gamma', 'プログラムC', 2),
];

void setPhone(WidgetTester tester, {double width = 390, double height = 3000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget page(FakeAdminReception service, {bool admin = true}) => MaterialApp(
  home: ConfirmedReceptionPage(
    service: service,
    adminService: admin ? service : null,
    eventId: 'event1',
    participantId: 'batchA-000002',
    publicId: 'pub_x',
  ),
);

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();
final dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);
Finder card(String programName) =>
    find.ancestor(of: find.text(programName), matching: find.byType(Card));
Finder inCard(String programName, Finder what) =>
    find.descendant(of: card(programName), matching: what);

void main() {
  group('adminだけに、受付済みprogramの「人数を訂正」「受付を取り消す」が表示される', () {
    testWidgets('admin: 受付済みprogramに2つの操作。未受付programには従来どおり「受付する」だけ', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      await tester.pumpWidget(page(FakeAdminReception(threePrograms())));
      await settle(tester);
      expect(find.text('人数を訂正'), findsNWidgets(2), reason: 'A・Bの2つ(受付済みだけ)');
      expect(find.text('受付を取り消す'), findsNWidgets(2));
      expect(inCard('プログラムC', find.text('受付する')), findsOneWidget);
      expect(inCard('プログラムC', find.text('人数を訂正')), findsNothing);
      expect(inCard('プログラムC', find.text('受付を取り消す')), findsNothing);
      expect(
        inCard('プログラムA', find.text('受付する')),
        findsNothing,
        reason: '受付済みに通常の受付ボタンは出ない',
      );
    });

    testWidgets('staff: 受付済みprogramは状態表示のみ(訂正・取消のボタンを描画しない)。未受付は「受付する」', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      await tester.pumpWidget(
        page(FakeAdminReception(threePrograms()), admin: false),
      );
      await settle(tester);
      expect(find.text('受付済み'), findsNWidgets(2));
      expect(find.text('実来場人数 2名'), findsOneWidget);
      expect(find.text('人数を訂正'), findsNothing);
      expect(find.text('受付を取り消す'), findsNothing);
      expect(find.text('受付する'), findsOneWidget);
    });

    testWidgets('入口(/reception)でも、adminとして確認できた場合だけ操作が出る。staffには出ない', (
      tester,
    ) async {
      for (final role in [AccessRole.admin, AccessRole.staff]) {
        setPhone(tester, height: 4000);
        final service = FakeAdminReception(threePrograms());
        await tester.pumpWidget(
          MaterialApp(
            home: ReceptionRoutePage(
              eventId: 'event1',
              participantId: 'batchA-000002',
              publicId: 'pub_x',
              legacyBuilder: (_) => const Scaffold(body: Text('LEGACY')),
              authClient: FakeAuthClient(signedIn: true),
              accessService: FakeAccessService([AccessCheck.granted(role)]),
              receptionService: service,
              isLegacyEvent: (_) async => false,
            ),
          ),
        );
        await settle(tester);
        expect(find.text('プログラムA'), findsOneWidget, reason: '$role');
        if (role == AccessRole.admin) {
          expect(find.text('人数を訂正'), findsNWidgets(2));
          expect(find.text('受付を取り消す'), findsNWidgets(2));
        } else {
          expect(find.text('人数を訂正'), findsNothing);
          expect(find.text('受付を取り消す'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('人数の訂正', () {
    testWidgets('確認ダイアログに予定人数・現在の実来場人数・新しい人数と「2名 → 1名」が表示され、確定するまで送信しない', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms());
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('人数を訂正')));
      await settle(tester);
      expect(find.text('実来場人数を訂正'), findsOneWidget);
      expect(find.text('予定人数：3名(変わりません)'), findsOneWidget);
      expect(find.text('現在の実来場人数：2名'), findsOneWidget);
      expect(find.text('変更がありません(現在と同じ人数です)。'), findsOneWidget);
      // 現在と同じ人数では確定できない
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '訂正する'))
            .onPressed,
        isNull,
      );
      await tester.enterText(dialogField, '1');
      await tester.pump();
      expect(find.text('2名 → 1名'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '訂正する'))
            .onPressed,
        isNotNull,
      );
      expect(service.corrections, isEmpty);
      await tester.tap(find.text('やめる'));
      await settle(tester);
      expect(service.corrections, isEmpty, reason: 'キャンセルなら送信しない');
    });

    testWidgets('不正な人数(0・空・文字・上限超)は確定できない', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms());
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('人数を訂正')));
      await settle(tester);
      for (final text in ['0', '', 'abc', '1000', '-1', '1.5']) {
        await tester.enterText(dialogField, text);
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '訂正する'))
              .onPressed,
          isNull,
          reason: text,
        );
        expect(find.textContaining('1〜999名の整数'), findsOneWidget, reason: text);
      }
      expect(service.corrections, isEmpty);
    });

    testWidgets(
      '訂正: 送るのは訂正後の人数だけ。そのprogramの実来場人数だけが更新され、予定人数・受付時刻・他のprogramは変わらない',
      (tester) async {
        setPhone(tester, height: 4000);
        final service = FakeAdminReception(threePrograms());
        await tester.pumpWidget(page(service));
        await settle(tester);
        await tester.tap(inCard('プログラムA', find.text('人数を訂正')));
        await settle(tester);
        await tester.enterText(dialogField, '1');
        await tester.pump();
        await tester.tap(find.text('訂正する'));
        await settle(tester);
        expect(service.corrections, [
          {'programId': 'alpha', 'attendedCount': 1},
        ]);
        expect(inCard('プログラムA', find.text('実来場人数 1名')), findsOneWidget);
        expect(
          inCard('プログラムA', find.text('予定人数 3名')),
          findsOneWidget,
          reason: '予定人数は不変',
        );
        expect(
          inCard('プログラムA', find.text('受付時刻 11:02')),
          findsOneWidget,
          reason: '初回受付時刻のまま',
        );
        expect(inCard('プログラムA', find.text('受付済み')), findsOneWidget);
        expect(inCard('プログラムB', find.text('実来場人数 1名')), findsOneWidget);
        expect(inCard('プログラムC', find.text('未受付')), findsOneWidget);
        expect(find.textContaining('2名 → 1名 に訂正しました'), findsOneWidget);
        expect(service.viewCalls, 1, reason: '他のprogramを再取得して書き換えない');
      },
    );

    testWidgets('サーバーが拒否した場合(未受付になっていた等)は、そのカードにだけ理由が表示され、状態は変わらない', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms())
        ..error = const ReceptionException('この操作を行う権限がありません。');
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('人数を訂正')));
      await settle(tester);
      await tester.enterText(dialogField, '1');
      await tester.pump();
      await tester.tap(find.text('訂正する'));
      await settle(tester);
      expect(find.text('この操作を行う権限がありません。'), findsOneWidget);
      expect(inCard('プログラムA', find.text('実来場人数 2名')), findsOneWidget);
    });
  });

  group('受付の取消(破壊的操作)', () {
    testWidgets(
      '確認ダイアログに参加者名・program名・現在の実来場人数と「このprogramの受付を取り消します」。「やめる」なら送信しない',
      (tester) async {
        setPhone(tester, height: 4000);
        final service = FakeAdminReception(threePrograms());
        await tester.pumpWidget(page(service));
        await settle(tester);
        await tester.tap(inCard('プログラムA', find.text('受付を取り消す')));
        await settle(tester);
        expect(find.text('受付を取り消します'), findsOneWidget);
        expect(find.text('参加者：架空 太郎 様'), findsOneWidget);
        expect(find.text('program：プログラムA'), findsOneWidget);
        expect(find.text('現在の実来場人数：2名'), findsOneWidget);
        expect(find.text('このprogramの受付を取り消します'), findsOneWidget);
        await tester.tap(find.text('やめる'));
        await settle(tester);
        expect(service.calls.where((c) => c.startsWith('cancel')), isEmpty);
        expect(inCard('プログラムA', find.text('受付済み')), findsOneWidget);
      },
    );

    testWidgets('取消: そのprogramだけが未受付に戻り、「受付する」が再表示される。他のprogramは不変。予定人数も残る', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms());
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('受付を取り消す')));
      await settle(tester);
      await tester.tap(find.text('この受付を取り消す'));
      await settle(tester);
      expect(service.calls, ['cancel:alpha']);
      expect(inCard('プログラムA', find.text('未受付')), findsOneWidget);
      expect(
        inCard('プログラムA', find.text('受付する')),
        findsOneWidget,
        reason: '通常の受付ボタンが再表示される',
      );
      expect(inCard('プログラムA', find.text('予定人数 3名')), findsOneWidget);
      expect(inCard('プログラムA', find.text('人数を訂正')), findsNothing);
      expect(inCard('プログラムA', find.text('受付を取り消す')), findsNothing);
      expect(inCard('プログラムB', find.text('受付済み')), findsOneWidget);
      expect(inCard('プログラムB', find.text('実来場人数 1名')), findsOneWidget);
      expect(inCard('プログラムC', find.text('未受付')), findsOneWidget);
      expect(find.textContaining('受付を取り消しました'), findsOneWidget);
    });

    testWidgets('取消後の再受付: 通常の「受付する」(確認 → 初回受付の経路)で受付済みに戻り、入力欄の初期値は予定人数', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms());
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('受付を取り消す')));
      await settle(tester);
      await tester.tap(find.text('この受付を取り消す'));
      await settle(tester);
      expect(
        tester
            .widget<TextField>(inCard('プログラムA', find.byType(TextField)))
            .controller!
            .text,
        '3',
      );
      await tester.tap(inCard('プログラムA', find.text('受付する')));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '受付する').last);
      await settle(tester);
      expect(service.calls, ['cancel:alpha', 'checkIn:alpha:3']);
      expect(inCard('プログラムA', find.text('受付済み')), findsOneWidget);
      expect(inCard('プログラムA', find.text('人数を訂正')), findsOneWidget);
    });

    testWidgets('すでに未受付(二重取消・古い画面)は「すでに未受付です」と案内され、状態は変わらない', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms());
      await tester.pumpWidget(page(service));
      await settle(tester);
      service.programs[0] = rp(
        'alpha',
        'プログラムA',
        3,
        time: '10:00-10:40',
      ); // 別のadminが先に取消した
      await tester.tap(inCard('プログラムA', find.text('受付を取り消す')));
      await settle(tester);
      await tester.tap(find.text('この受付を取り消す'));
      await settle(tester);
      expect(find.textContaining('すでに未受付です'), findsWidgets);
      expect(inCard('プログラムA', find.text('未受付')), findsOneWidget);
    });

    testWidgets('連打しても二重に送信しない(処理中は訂正・取消ボタンが無効)', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeAdminReception(threePrograms())
        ..gate = Completer<void>();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(inCard('プログラムA', find.text('受付を取り消す')));
      await settle(tester);
      await tester.tap(find.text('この受付を取り消す'));
      await tester.pump();
      await tester.pump();
      final cancelButton = inCard(
        'プログラムA',
        find.widgetWithText(TextButton, '受付を取り消す'),
      );
      expect(tester.widget<TextButton>(cancelButton).onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              inCard('プログラムA', find.widgetWithText(OutlinedButton, '人数を訂正')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(cancelButton, warnIfMissed: false);
      await tester.pump();
      expect(service.calls.where((c) => c.startsWith('cancel')).length, 1);
      service.gate!.complete();
      await settle(tester);
      expect(service.calls.where((c) => c.startsWith('cancel')).length, 1);
    });
  });

  group('スマートフォン(390px)', () {
    testWidgets(
      'program名・予定人数・実来場人数・受付状態・人数訂正・受付取消が、はみ出さず操作できる。取消は訂正と離して配置される',
      (tester) async {
        setPhone(tester, height: 4000);
        await tester.pumpWidget(page(FakeAdminReception(threePrograms())));
        await settle(tester);
        expect(tester.takeException(), isNull);
        for (final finder in [
          inCard('プログラムA', find.text('プログラムA')),
          inCard('プログラムA', find.text('予定人数 3名')),
          inCard('プログラムA', find.text('実来場人数 2名')),
          inCard('プログラムA', find.text('受付済み')),
          inCard('プログラムA', find.text('人数を訂正')),
          inCard('プログラムA', find.text('受付を取り消す')),
        ]) {
          final rect = tester.getRect(finder);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(390));
        }
        final correct = tester.getRect(
          inCard('プログラムA', find.widgetWithText(OutlinedButton, '人数を訂正')),
        );
        final cancel = tester.getRect(
          inCard('プログラムA', find.widgetWithText(TextButton, '受付を取り消す')),
        );
        expect(
          cancel.top - correct.bottom,
          greaterThanOrEqualTo(16),
          reason: '破壊的操作を通常操作と離す',
        );
        expect(correct.height, greaterThanOrEqualTo(44));
        // ダイアログも横にはみ出さない
        await tester.tap(inCard('プログラムA', find.text('人数を訂正')));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byType(AlertDialog)).right,
          lessThanOrEqualTo(390),
        );
      },
    );
  });

  group('CallableReceptionService(訂正・取消)', () {
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    test(
      '訂正: IDトークンを送り、QRのID・program・訂正後の人数だけを送る(予定人数・changedBy・役割は送らない)',
      () async {
        late http.Request seen;
        final s = CallableReceptionService(
          authClient: FakeAuthClient(signedIn: true, token: 'tok'),
          baseUrl: 'https://example.invalid',
          httpClient: MockClient((r) async {
            seen = r;
            return json({
              'result': {
                'changed': true,
                'program': {
                  'programId': 'alpha',
                  'plannedCount': 3,
                  'checkedIn': true,
                  'attendedCount': 1,
                  'checkedInAt': '2026-11-30T02:02:00.000Z',
                },
              },
            }, 200);
          }),
        );
        final result = await s.correct(
          eventId: 'event1',
          participantId: 'p1',
          publicId: 'pub_x',
          programId: 'alpha',
          attendedCount: 1,
        );
        expect(
          [
            result.changed,
            result.program.attendedCount,
            result.program.plannedCount,
          ],
          [true, 1, 3],
        );
        expect(
          seen.url.toString(),
          'https://example.invalid/correctConfirmedProgramAttendance',
        );
        expect(seen.headers['Authorization'], 'Bearer tok');
        expect(((jsonDecode(seen.body) as Map)['data'] as Map).keys.toSet(), {
          'eventId',
          'participantId',
          'publicId',
          'programId',
          'attendedCount',
        });
      },
    );

    test('取消: 送るのはQRのID・programだけ。変更なし(noop)の応答も扱える', () async {
      late http.Request seen;
      final s = CallableReceptionService(
        authClient: FakeAuthClient(signedIn: true),
        baseUrl: 'https://example.invalid',
        httpClient: MockClient((r) async {
          seen = r;
          return json({
            'result': {
              'changed': false,
              'noop': 'not-checked-in',
              'program': {
                'programId': 'alpha',
                'plannedCount': 3,
                'checkedIn': false,
              },
            },
          }, 200);
        }),
      );
      final result = await s.cancel(
        eventId: 'event1',
        participantId: 'p1',
        publicId: 'pub_x',
        programId: 'alpha',
      );
      expect(
        [result.changed, result.noop, result.program.checkedIn],
        [false, 'not-checked-in', false],
      );
      expect(
        seen.url.toString(),
        'https://example.invalid/cancelConfirmedProgramCheckIn',
      );
      expect(((jsonDecode(seen.body) as Map)['data'] as Map).keys.toSet(), {
        'eventId',
        'participantId',
        'publicId',
        'programId',
      });
    });

    test('権限なし・未受付のエラーは表示用に変換される(staffが直接呼んでもサーバーが拒否する前提)', () {
      expect(
        CallableReceptionService.errorFrom(403, {
          'error': {'status': 'PERMISSION_DENIED'},
        }).message,
        'この操作を行う権限がありません。',
      );
      final notCheckedIn = CallableReceptionService.errorFrom(400, {
        'error': {
          'status': 'FAILED_PRECONDITION',
          'details': {'code': 'attendance-not-checked-in'},
        },
      });
      expect(notCheckedIn.message, contains('まだ受付されていない'));
      expect(
        notCheckedIn.notAllowed,
        isFalse,
        reason: '画面全体を「受付できません」にしない(そのprogramだけの案内)',
      );
    });
  });

  group('構造(ソース)の固定', () {
    String read(String path) => File(path).readAsStringSync();

    test('受付画面はFirestoreを直接読み書きしない。旧checkInsを使わない。受付状態を自前で計算しない', () {
      final source = [
        'reception_page',
        'reception_service',
        'reception_route',
      ].map((n) => read('lib/confirmed/$n.dart')).join('\n');
      expect(source.contains('cloud_firestore'), isFalse);
      expect(source.contains('snapshots()'), isFalse);
      expect(source.contains('checkIns'), isFalse);
      expect(source.contains('registeredCount'), isFalse);
    });

    test('訂正・取消はadminServiceを渡された場合だけ表示する(staffの経路では渡さない)', () {
      final route = read('lib/confirmed/reception_route.dart');
      expect(route.contains('isAdmin: true'), isTrue);
      expect(route.contains('isAdmin: false'), isTrue);
      final page = read('lib/confirmed/reception_page.dart');
      expect(
        RegExp(r'widget\.adminService == null\s*\?\s*null').hasMatch(page),
        isTrue,
      );
    });

    test('参加証(公開)のコードには、訂正・取消の入口がない(読み取り専用)', () {
      final source =
          read('lib/confirmed/pass_page.dart') +
          read('lib/confirmed/pass_service.dart');
      expect(source.contains('correctConfirmedProgramAttendance'), isFalse);
      expect(source.contains('cancelConfirmedProgramCheckIn'), isFalse);
      expect(source.contains('ReceptionAdminService'), isFalse);
    });
  });
}
