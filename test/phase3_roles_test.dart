// Phase 3: 3階層の権限(システム管理者 > イベント管理者 > スタッフ)を正式UIへつないだ画面のテスト。
// 通信はすべて差し替え(外部通信0)。権限の判断はサーバーが行い、画面は getMyAccessRole / listMyEvents の結果に従う。
//  - システム管理者: 管理トップ(イベント一覧・イベント作成・イベント管理者設定)、全イベントの管理機能、スタッフ管理
//  - イベント管理者: 担当イベントだけ。イベント作成・イベント管理者設定なし。CSV・メール・リマインド・スタッフ管理・受付
//  - スタッフ: 担当イベントの受付だけ(受付スタッフ用QR)。CSV・メール・リマインド・スタッフ管理なし
//  - 任命UI: メールアドレスだけで追加・解除。uid・assignmentId・内部のrole値は表示しない
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/assignment_pages.dart';
import 'package:jm_quick/confirmed/assignment_service.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';
import 'package:jm_quick/confirmed/reception_staff_qr_page.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'reminder_test.dart' show FakeReminderService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService;

const _evA = 'evPhase3A0123456789';
const _evB = 'evPhase3B0123456789';
const _evC = 'evPhase3C0123456789';

MyEvent _event(String id, String name, EventRole? role) => MyEvent(
  eventId: id,
  eventName: name,
  startAt: DateTime(2026, 11, 30, 10),
  venue: '$nameの会場',
  eventRole: role,
);

ImportEventSummary _summary(String id, String name) => ImportEventSummary(
  eventId: id,
  eventName: name,
  startAt: DateTime(2026, 11, 30, 10),
  venue: '$nameの会場',
  programs: const [(programId: 'alpha', name: 'プログラムA', order: 0)],
);

/// 任命APIの差し替え。assignmentIdは内部値(画面に出ないことを確認する)。
class FakeAssignmentService implements AssignmentService {
  FakeAssignmentService({
    this.myEvents = const [],
    Map<String, List<EventAssignmentEntry>>? assignments,
    this.assignError,
  }) : assignments = assignments ?? {};

  final List<MyEvent> myEvents;
  final Map<String, List<EventAssignmentEntry>> assignments;
  AssignmentException? assignError;
  final List<(String, String, EventRole)> assignCalls = [];
  final List<(String, String)> removeCalls = [];
  int listMyEventsCalls = 0;

  @override
  Future<List<MyEvent>> listMyEvents() async {
    listMyEventsCalls++;
    return myEvents;
  }

  @override
  Future<List<EventAssignmentEntry>> listAssignments(String eventId) async =>
      List.of(assignments[eventId] ?? const []);

  @override
  Future<bool> assign({
    required String eventId,
    required String email,
    required EventRole role,
  }) async {
    assignCalls.add((eventId, email, role));
    final error = assignError;
    if (error != null) throw error;
    (assignments[eventId] ??= []).add(
      EventAssignmentEntry(
        assignmentId: 'ea${'f' * 64}',
        role: role,
        email: email.trim().toLowerCase(),
        isSelf: false,
      ),
    );
    return true;
  }

  @override
  Future<void> remove({
    required String eventId,
    required String assignmentId,
  }) async {
    removeCalls.add((eventId, assignmentId));
    assignments[eventId]?.removeWhere((e) => e.assignmentId == assignmentId);
  }
}

const _managerA = EventAssignment(eventId: _evA, role: EventRole.eventManager);
const _staffA = EventAssignment(eventId: _evA, role: EventRole.staff);
const _staffB = EventAssignment(eventId: _evB, role: EventRole.staff);

Widget _console({
  required AccessCheck access,
  required FakeAssignmentService assignments,
  String? eventId,
  List<String?>? routes,
}) => MaterialApp(
  home: ConfirmedConsolePage(
    initialEventId: eventId,
    authClient: FakeAuthClient(signedIn: true),
    accessService: FakeAccessService([access]),
    eventSummaryService: FakeImportService(
      event: _summary(eventId ?? _evA, '架空イベントA'),
    ),
    winnerMailService: FakeWinnerMailService(),
    winnerSendService: FakeSendService(),
    reminderService: FakeReminderService(),
    assignmentService: assignments,
  ),
  onGenerateRoute: routes == null
      ? null
      : (settings) {
          routes.add(settings.name);
          return MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: Text('遷移:${settings.name}')),
            settings: settings,
          );
        },
);

/// 画面の全テキスト(内部値が表示されていないことの確認用)。
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

void _expectNoInternalValues(WidgetTester tester) {
  final text = _allText(tester);
  for (final internal in [
    'event_manager',
    'system_admin',
    'eventAssignments',
    _evA,
    _evB,
    'ea${'f' * 64}',
    'ea${'a' * 64}',
    'uid',
  ]) {
    expect(text.contains(internal), isFalse, reason: internal);
  }
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  group('システム管理者', () {
    testWidgets('管理トップ: イベント一覧・イベント作成・イベント管理者設定。表示名はシステム管理者', (tester) async {
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.granted(AccessRole.admin),
          assignments: FakeAssignmentService(),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['イベント一覧', 'イベント作成', 'イベント管理者設定']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('ログイン中：システム管理者'), findsOneWidget);
      _expectNoInternalValues(tester);
    });

    testWidgets('イベント管理画面: CSV・メール・リマインド・スタッフ管理・受付をすべて利用でき、スタッフ管理はスタッフを追加できる', (
      tester,
    ) async {
      final service = FakeAssignmentService();
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.granted(AccessRole.admin),
          assignments: service,
          eventId: _evA,
        ),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'CSV取込',
        '当選メール設定',
        '当選メール送信',
        'リマインド',
        'スタッフ管理',
        '受付',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('ログイン中：システム管理者'), findsOneWidget);
      await tester.ensureVisible(find.text('スタッフ管理'));
      await tester.tap(find.text('スタッフ管理'));
      await tester.pumpAndSettle();
      expect(find.byType(EventAssignmentPage), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'staff.one@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      expect(service.assignCalls.single, (
        _evA,
        'staff.one@example.invalid',
        EventRole.staff,
      ));
      expect(find.text('staff.one@example.invalid'), findsOneWidget);
      _expectNoInternalValues(tester);
    });

    testWidgets(
      'イベント管理者設定: confirmedイベントを選び、イベント管理者を追加・解除できる(uid・assignmentIdは表示しない)',
      (tester) async {
        final service = FakeAssignmentService(
          myEvents: [
            _event(_evA, '架空イベントA', null),
            _event(_evB, '架空イベントB', null),
          ],
          assignments: {
            _evA: [
              EventAssignmentEntry(
                assignmentId: 'ea${'a' * 64}',
                role: EventRole.eventManager,
                email: 'manager.a@example.invalid',
                isSelf: false,
              ),
              EventAssignmentEntry(
                assignmentId: 'ea${'b' * 64}',
                role: EventRole.staff,
                email: 'staff.only@example.invalid',
                isSelf: false,
              ),
            ],
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ConfirmedManagerSettingsRoute(
              authClient: FakeAuthClient(signedIn: true),
              accessService: FakeAccessService([
                const AccessCheck.granted(AccessRole.admin),
              ]),
              service: service,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('架空イベントA'), findsOneWidget);
        expect(find.text('架空イベントB'), findsOneWidget);
        await tester.tap(find.text('架空イベントA'));
        await tester.pumpAndSettle();
        expect(find.text('イベント管理者設定'), findsOneWidget);
        expect(find.text('manager.a@example.invalid'), findsOneWidget);
        expect(find.text('イベント管理者'), findsOneWidget);
        expect(
          find.text('staff.only@example.invalid'),
          findsNothing,
          reason: 'この画面はイベント管理者だけ',
        );
        _expectNoInternalValues(tester);
        // 追加
        await tester.enterText(
          find.byKey(const Key('assignment-email-field')),
          ' Manager.Two@Example.INVALID ',
        );
        await tester.tap(find.byKey(const Key('assignment-add-button')));
        await tester.pumpAndSettle();
        expect(service.assignCalls.single.$3, EventRole.eventManager);
        expect(find.text('イベント管理者を追加しました。'), findsOneWidget);
        // 解除(確認ダイアログ → assignmentIdは内部でだけ使う)
        await tester.tap(
          find.byKey(
            const ValueKey('assignment-remove:manager.a@example.invalid'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('assignment-remove-confirm')));
        await tester.pumpAndSettle();
        expect(service.removeCalls.single, (_evA, 'ea${'a' * 64}'));
        expect(find.text('manager.a@example.invalid'), findsNothing);
        expect(find.text('イベント管理者を解除しました。'), findsOneWidget);
      },
    );

    testWidgets('存在しない利用者のメールアドレスは、意味の分かる日本語で表示する', (tester) async {
      final service = FakeAssignmentService(
        assignError: AssignmentException(
          assignmentErrorMessage('NOT_FOUND', 'user-not-found'),
          code: 'user-not-found',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EventAssignmentPage(
            eventId: _evA,
            eventName: '架空イベントA',
            targetRole: EventRole.eventManager,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'nobody@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('assignment-error')), findsOneWidget);
      expect(find.textContaining('このメールアドレスの利用者が登録されていません。'), findsOneWidget);
      // パスワード入力欄は無い(アカウント作成はしない)
      expect(find.textContaining('パスワード'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  group('イベント管理者', () {
    testWidgets('担当1件: そのイベントの管理画面へ直接入る。イベント作成・イベント管理者設定は無い', (tester) async {
      final service = FakeAssignmentService(
        myEvents: [_event(_evA, '架空イベントA', EventRole.eventManager)],
      );
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_managerA]),
          assignments: service,
        ),
      );
      await tester.pumpAndSettle();
      for (final label in [
        'CSV取込',
        '当選メール設定',
        '当選メール送信',
        'リマインド',
        'スタッフ管理',
        '受付',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      for (final label in ['イベント作成', 'イベント管理者設定', 'イベント一覧']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.text('ログイン中：イベント管理者'), findsOneWidget);
      expect(find.text('架空イベントA'), findsOneWidget);
      _expectNoInternalValues(tester);
    });

    testWidgets('スタッフ管理: スタッフを追加・解除できる(イベント管理者を追加するUIは無い。自分には解除ボタンが出ない)', (
      tester,
    ) async {
      final service = FakeAssignmentService(
        assignments: {
          _evA: [
            EventAssignmentEntry(
              assignmentId: 'ea${'a' * 64}',
              role: EventRole.eventManager,
              email: 'me@example.invalid',
              isSelf: true,
            ),
            EventAssignmentEntry(
              assignmentId: 'ea${'b' * 64}',
              role: EventRole.staff,
              email: 'staff.one@example.invalid',
              isSelf: false,
            ),
          ],
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: EventAssignmentPage(
            eventId: _evA,
            eventName: '架空イベントA',
            targetRole: EventRole.staff,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('スタッフを追加'), findsOneWidget);
      expect(find.text('イベント管理者を追加'), findsNothing);
      expect(find.text('staff.one@example.invalid'), findsOneWidget);
      expect(
        find.text('me@example.invalid'),
        findsNothing,
        reason: 'スタッフ管理はスタッフだけを表示',
      );
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'staff.two@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      expect(service.assignCalls.single.$3, EventRole.staff);
      await tester.tap(
        find.byKey(
          const ValueKey('assignment-remove:staff.one@example.invalid'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('assignment-remove-confirm')));
      await tester.pumpAndSettle();
      expect(service.removeCalls.single, (_evA, 'ea${'b' * 64}'));
      _expectNoInternalValues(tester);
    });

    testWidgets('担当が複数: 「担当イベント」に担当分だけを表示し、選ぶと/console?eventId=…へ', (
      tester,
    ) async {
      final routes = <String?>[];
      final service = FakeAssignmentService(
        myEvents: [
          _event(_evA, '架空イベントA', EventRole.eventManager),
          _event(_evB, '架空イベントB', EventRole.staff),
        ],
      );
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_managerA, _staffB]),
          assignments: service,
          routes: routes,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('担当イベント'), findsWidgets);
      expect(find.text('架空イベントA'), findsOneWidget);
      expect(find.text('架空イベントB'), findsOneWidget);
      expect(find.textContaining('イベント管理者'), findsWidgets);
      expect(find.text('イベント作成'), findsNothing);
      expect(find.text('イベント管理者設定'), findsNothing);
      _expectNoInternalValues(tester);
      await tester.tap(find.text('架空イベントA'));
      await tester.pumpAndSettle();
      expect(routes, ['/console?eventId=$_evA']);
    });

    testWidgets('担当外のイベントを指定されても表示しない', (tester) async {
      final service = FakeAssignmentService(
        myEvents: [_event(_evA, '架空イベントA', EventRole.eventManager)],
      );
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_managerA]),
          assignments: service,
          eventId: _evC,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('このイベントを利用する権限がありません。'), findsOneWidget);
      expect(find.text('CSV取込'), findsNothing);
    });

    testWidgets('CSV取込(/console/import): 担当イベントなら取込画面、担当外・スタッフなら権限なし', (
      tester,
    ) async {
      Future<void> open(
        List<EventAssignment> assignments,
        String eventId,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            home: ConfirmedImportRoute(
              eventId: eventId,
              authClient: FakeAuthClient(signedIn: true),
              accessService: FakeAccessService([
                AccessCheck.eventScoped(assignments),
              ]),
              service: FakeImportService(event: _summary(eventId, '架空イベント')),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await open([_managerA], _evA);
      expect(find.byType(ConfirmedImportPage), findsOneWidget);
      await open([_managerA], _evB);
      expect(find.byType(ConfirmedImportPage), findsNothing);
      expect(find.text('このイベントのCSV取込を行う権限がありません。'), findsOneWidget);
      await open([_staffA], _evA);
      expect(find.byType(ConfirmedImportPage), findsNothing);
      expect(find.text('このイベントのCSV取込を行う権限がありません。'), findsOneWidget);
    });

    testWidgets('イベント管理者設定(/console/managers)はシステム管理者専用(イベント管理者には権限なし)', (
      tester,
    ) async {
      final service = FakeAssignmentService(
        myEvents: [_event(_evA, '架空イベントA', EventRole.eventManager)],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedManagerSettingsRoute(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              const AccessCheck.eventScoped([_managerA]),
            ]),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      expect(service.listMyEventsCalls, 0, reason: '一覧も問い合わせない');
    });
  });

  group('スタッフ', () {
    testWidgets('担当1件: 受付の入口だけ。CSV・メール・リマインド・スタッフ管理・イベント作成・イベント管理者設定は無い', (
      tester,
    ) async {
      final service = FakeAssignmentService(
        myEvents: [_event(_evA, '架空イベントA', EventRole.staff)],
      );
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_staffA]),
          assignments: service,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('受付'), findsWidgets);
      expect(find.text('受付スタッフ用QRを表示する'), findsOneWidget);
      expect(find.text('ログイン中：スタッフ'), findsOneWidget);
      expect(find.text('架空イベントA'), findsOneWidget);
      for (final label in [
        'CSV取込',
        '当選メール設定',
        '当選メール送信',
        'リマインド',
        'スタッフ管理',
        'イベント作成',
        'イベント管理者設定',
        'イベント一覧',
      ]) {
        expect(find.text(label), findsNothing, reason: label);
      }
      _expectNoInternalValues(tester);
      // PCのカメラは起動しない: 受付スタッフ用QRを表示する(既存の二段階受付)
      await tester.tap(find.text('受付スタッフ用QRを表示する'));
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmedReceptionStaffQrPage), findsOneWidget);
      expect(find.text('このPCではカメラを使用しません。'), findsOneWidget);
    });

    testWidgets('担当が複数: 担当分だけを一覧表示', (tester) async {
      final service = FakeAssignmentService(
        myEvents: [
          _event(_evA, '架空イベントA', EventRole.staff),
          _event(_evB, '架空イベントB', EventRole.staff),
        ],
      );
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_staffA, _staffB]),
          assignments: service,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('架空イベントA'), findsOneWidget);
      expect(find.text('架空イベントB'), findsOneWidget);
      expect(find.text('ログイン中：スタッフ'), findsOneWidget);
      expect(find.text('CSV取込'), findsNothing);
    });

    testWidgets('受付(/console/scan・/reception)は担当イベントだけ。担当外のイベントは受付画面を出さない', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedScanReceptionRoute(
            eventId: _evB,
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              const AccessCheck.eventScoped([_staffA]),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('このイベントの受付を行う権限がありません。'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: ReceptionRoutePage(
            eventId: _evB,
            participantId: 'p-fixture-1',
            publicId: 'pub_fixture0123456789abcdef',
            legacyBuilder: (_) => const Text('従来の受付'),
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              const AccessCheck.eventScoped([_staffA]),
            ]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('このイベントの受付を行う権限がありません。'), findsOneWidget);
      expect(find.text('従来の受付'), findsNothing);
    });
  });

  group('権限なし・担当なし', () {
    testWidgets('担当イベント0件(権限なし)は「権限がありません」', (tester) async {
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.denied(),
          assignments: FakeAssignmentService(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      expect(find.text('イベント一覧'), findsNothing);
    });

    testWidgets('担当の確認はできたが、表示できる担当イベントが無い', (tester) async {
      await tester.pumpWidget(
        _console(
          access: const AccessCheck.eventScoped([_staffA]),
          assignments: FakeAssignmentService(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('担当しているイベントはありません。'), findsOneWidget);
    });
  });

  group('任命APIの応答の解釈', () {
    test('サーバーの理由コードを日本語へ。内部の値は表示しない', () {
      AssignmentException error(String body) {
        try {
          CallableAssignmentService.interpret(404, body);
        } on AssignmentException catch (e) {
          return e;
        }
        fail('例外になるはず');
      }

      final notFound = error(
        '{"error":{"status":"NOT_FOUND","message":"x","details":{"code":"user-not-found"}}}',
      );
      expect(notFound.message, startsWith('このメールアドレスの利用者が登録されていません。'));
      expect(
        error(
          '{"error":{"status":"FAILED_PRECONDITION","details":{"code":"target-is-system-admin"}}}',
        ).message,
        'この利用者はシステム管理者のため、イベントごとの設定は不要です。',
      );
      expect(
        error(
          '{"error":{"status":"FAILED_PRECONDITION","details":{"code":"self-assignment"}}}',
        ).message,
        '自分自身の権限は変更できません。',
      );
      expect(
        error(
          '{"error":{"status":"PERMISSION_DENIED","details":{"code":"manager-can-assign-staff-only"}}}',
        ).message,
        'この操作を行う権限がありません。',
      );
      expect(error('not json').message, '処理に失敗しました。もう一度お試しください。');
      final ok = CallableAssignmentService.interpret(
        200,
        '{"result":{"events":[]}}',
      );
      expect(ok['events'], isEmpty);
    });

    test('listMyEventsのroleは表示名へ(system_adminはシステム管理者)。未知のroleは表示しない', () {
      final admin = MyEvent.fromJson({
        'eventId': _evA,
        'eventName': 'A',
        'startAt': '2026-11-30T01:00:00.000Z',
        'venue': 'v',
        'role': 'system_admin',
      })!;
      expect(admin.roleLabel, 'システム管理者');
      expect(admin.canManage, isTrue);
      final manager = MyEvent.fromJson({
        'eventId': _evA,
        'role': 'event_manager',
      })!;
      expect((manager.roleLabel, manager.canManage), ('イベント管理者', true));
      final staff = MyEvent.fromJson({'eventId': _evA, 'role': 'staff'})!;
      expect((staff.roleLabel, staff.canManage), ('スタッフ', false));
      expect(MyEvent.fromJson({'eventId': _evA, 'role': 'admin'}), isNull);
      expect(MyEvent.fromJson({'role': 'staff'}), isNull);
    });
  });

  group('390px・PC幅でoverflowなし', () {
    final longEmail =
        'very.long.staff.address.for.overflow.check@example.invalid';
    final pages = <String, Widget Function()>{
      'イベント管理者設定(一覧)': () => MaterialApp(
        home: ManagerSettingsPage(
          service: FakeAssignmentService(
            myEvents: [
              _event(_evA, 'とても長いイベント名の架空イベント・トークショーと譲渡会(架空)', null),
              _event(_evB, '架空イベントB', null),
            ],
          ),
        ),
      ),
      'イベント管理者設定・スタッフ管理(詳細)': () => MaterialApp(
        home: EventAssignmentPage(
          eventId: _evA,
          eventName: 'とても長いイベント名の架空イベント・トークショーと譲渡会(架空)',
          targetRole: EventRole.staff,
          service: FakeAssignmentService(
            assignments: {
              _evA: [
                EventAssignmentEntry(
                  assignmentId: 'ea${'b' * 64}',
                  role: EventRole.staff,
                  email: longEmail,
                  isSelf: false,
                ),
              ],
            },
          ),
        ),
      ),
      '担当イベント一覧': () => _console(
        access: const AccessCheck.eventScoped([_managerA, _staffB]),
        assignments: FakeAssignmentService(
          myEvents: [
            _event(
              _evA,
              'とても長いイベント名の架空イベント・トークショーと譲渡会(架空)',
              EventRole.eventManager,
            ),
            _event(_evB, '架空イベントB', EventRole.staff),
          ],
        ),
      ),
      'スタッフの受付の入口': () => _console(
        access: const AccessCheck.eventScoped([_staffA]),
        assignments: FakeAssignmentService(
          myEvents: [
            _event(_evA, 'とても長いイベント名の架空イベント・トークショーと譲渡会(架空)', EventRole.staff),
          ],
        ),
      ),
    };
    for (final size in const [Size(390, 844), Size(1280, 900)]) {
      for (final entry in pages.entries) {
        testWidgets('${entry.key} ${size.width.toInt()}px', (tester) async {
          await _setSize(tester, size);
          await tester.pumpWidget(entry.value());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
