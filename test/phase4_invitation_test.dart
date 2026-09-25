// Phase 4: 未登録の人をイベント管理者・スタッフとして招待する画面と、招待リンク(`/invite`)の画面。通信はすべて差し替え(外部通信0)。
//  - 任命フォームで未登録のメールアドレスを入れると、確認ダイアログのあと招待メールを送る(登録済みは従来どおり即任命)
//  - 「招待中」に メールアドレス・役割・状態・有効期限 を表示し、取消できる。invitationId・token・uidは表示しない
//  - 招待リンク: 本人Auth登録→ ログイン → 招待を受ける → 完了。期限切れ・取消・受諾済み・不正を区別して表示
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/auth_client.dart';
import 'package:jm_quick/confirmed/assignment_pages.dart';
import 'package:jm_quick/confirmed/assignment_service.dart';
import 'package:jm_quick/confirmed/invitation_page.dart';
import 'package:jm_quick/confirmed/invitation_service.dart';

import 'confirmed_auth_test.dart' show FakeAuthClient;
import 'phase3_roles_test.dart' show FakeAssignmentService;

const _evA = 'evPhase4A0123456789';
const _token = 'tokFixture0123456789abcdefghijklmnopqrstuvw';

class FakeInvitationService implements InvitationService {
  FakeInvitationService(this.info, {this.acceptError});
  InvitationInfo info;
  InvitationException? acceptError;
  final List<String> calls = [];

  @override
  Future<InvitationInfo> getInvitation(String token) async {
    calls.add('get');
    return info;
  }

  @override
  Future<InvitationAcceptResult> accept(String token) async {
    calls.add('accept');
    final error = acceptError;
    if (error != null) throw error;
    return const InvitationAcceptResult(
      eventName: '犬猫譲渡会・トークショー(架空)',
      role: EventRole.eventManager,
    );
  }
}

InvitationInfo _pending({bool accountExists = false}) => InvitationInfo(
  status: InvitationStatus.pending,
  eventName: '犬猫譲渡会・トークショー(架空)',
  role: EventRole.eventManager,
  emailHint: 'ne***@example.invalid',
  email: 'new.manager@example.invalid',
  expiresAt: DateTime(2026, 12, 7, 10),
  accountExists: accountExists,
);

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

Widget _assignmentPage(FakeAssignmentService service, EventRole role) =>
    MaterialApp(
      home: EventAssignmentPage(
        eventId: _evA,
        eventName: '犬猫譲渡会・トークショー(架空)',
        targetRole: role,
        service: service,
      ),
    );

FakeAssignmentService _unregistered() => FakeAssignmentService(
  assignError: AssignmentException(
    assignmentErrorMessage('NOT_FOUND', 'user-not-found'),
    code: 'user-not-found',
  ),
);

void main() {
  group('任命フォーム: 未登録なら招待', () {
    testWidgets('イベント管理者: 確認ダイアログのあと招待メールを送り、「招待中」に表示する(内部の値は出さない)', (
      tester,
    ) async {
      final service = _unregistered();
      await tester.pumpWidget(_assignmentPage(service, EventRole.eventManager));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'New.Manager@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      final message = tester
          .widget<Text>(find.byKey(const Key('invite-confirm-message')))
          .data!;
      expect(message, contains('このメールアドレスはJM Quickに未登録です。'));
      expect(message, contains('イベント管理者として招待メールを送信します。'));
      await tester.tap(find.byKey(const Key('invite-confirm')));
      await tester.pumpAndSettle();
      expect(service.inviteCalls.single, (
        _evA,
        'New.Manager@example.invalid',
        EventRole.eventManager,
      ));
      expect(find.textContaining('招待メールを送信しました。'), findsOneWidget);
      expect(find.text('招待中'), findsOneWidget);
      expect(find.text('new.manager@example.invalid'), findsOneWidget);
      expect(
        find.textContaining('イベント管理者 / 招待中 / 期限 2026/12/07 10:00'),
        findsOneWidget,
      );
      final text = _allText(tester);
      for (final internal in [
        'ei${'c' * 64}',
        _evA,
        'event_manager',
        'token',
        'uid',
      ]) {
        expect(text.contains(internal), isFalse, reason: internal);
      }
    });

    testWidgets('スタッフ: 「スタッフとして招待メールを送信します。」。キャンセルなら送らない', (tester) async {
      final service = _unregistered();
      await tester.pumpWidget(_assignmentPage(service, EventRole.staff));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'new.staff@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('invite-confirm-message')))
            .data,
        contains('スタッフとして招待メールを送信します。'),
      );
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(service.inviteCalls, isEmpty);
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invite-confirm')));
      await tester.pumpAndSettle();
      expect(service.inviteCalls.single.$3, EventRole.staff);
      // 取消
      await tester.tap(
        find.byKey(
          const ValueKey('invitation-revoke:new.staff@example.invalid'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invitation-revoke-confirm')));
      await tester.pumpAndSettle();
      expect(service.revokeCalls.single, (_evA, 'ei${'c' * 64}'));
      expect(find.text('招待中'), findsNothing);
      expect(find.text('招待を取り消しました。'), findsOneWidget);
    });

    testWidgets('登録済みのメールアドレスは従来どおり即任命(招待のダイアログは出ない)', (tester) async {
      final service = FakeAssignmentService();
      await tester.pumpWidget(_assignmentPage(service, EventRole.staff));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('assignment-email-field')),
        'registered@example.invalid',
      );
      await tester.tap(find.byKey(const Key('assignment-add-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invite-confirm-message')), findsNothing);
      expect(service.assignCalls.length, 1);
      expect(service.inviteCalls, isEmpty);
      expect(find.text('スタッフを追加しました。'), findsOneWidget);
    });
  });

  group('招待リンク(/invite)', () {
    testWidgets('本人登録: 招待メール固定・password確認・登録後自動受諾', (tester) async {
      final auth = FakeAuthClient();
      final service = FakeInvitationService(_pending());
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationAcceptPage(
            token: _token,
            authClient: auth,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('invitation-register-email')),
            )
            .initialValue,
        'new.manager@example.invalid',
      );
      final emailInput = find.descendant(
        of: find.byKey(const Key('invitation-register-email')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(emailInput).readOnly, isTrue);
      // DOM相当の表示値を強制改変しても、登録には招待正本のメールだけを使う。
      tester.widget<EditableText>(emailInput).controller.text = 'other@example.invalid';
      await tester.enterText(
        find.byKey(const Key('invitation-register-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('invitation-confirm-password')),
        'different',
      );
      await tester.ensureVisible(find.byKey(const Key('invitation-register')));
      await tester.tap(find.byKey(const Key('invitation-register')));
      await tester.pumpAndSettle();
      expect(auth.registerCalls, isEmpty);
      expect(service.calls, ['get']);
      expect(find.text('パスワードが一致しません。'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('invitation-confirm-password')),
        'fixture-password',
      );
      await tester.ensureVisible(find.byKey(const Key('invitation-register')));
      await tester.tap(find.byKey(const Key('invitation-register')));
      await tester.pumpAndSettle();
      expect(auth.registerCalls.single, (
        'new.manager@example.invalid',
        'fixture-password',
      ));
      expect(service.calls, ['get', 'get', 'accept']);
      expect(find.byKey(const Key('invitation-done')), findsOneWidget);
      expect(_allText(tester).contains('fixture-password'), isFalse);
    });

    testWidgets('Auth成功・accept失敗: 同じ画面と再訪で登録を繰り返さず復旧', (tester) async {
      final auth = FakeAuthClient();
      final service = FakeInvitationService(
        _pending(),
        acceptError: const InvitationException('一時的な失敗'),
      );
      Widget page() => MaterialApp(
        home: InvitationAcceptPage(
          token: _token,
          authClient: auth,
          service: service,
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invitation-register-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('invitation-confirm-password')),
        'fixture-password',
      );
      await tester.ensureVisible(find.byKey(const Key('invitation-register')));
      await tester.tap(find.byKey(const Key('invitation-register')));
      await tester.pumpAndSettle();
      expect(auth.registerCalls.length, 1);
      expect(find.byKey(const Key('invitation-accept')), findsOneWidget);
      // 同じ画面の再試行。まだ失敗しても新規登録はしない。
      await tester.tap(find.byKey(const Key('invitation-accept')));
      await tester.pumpAndSettle();
      expect(auth.registerCalls.length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      service.info = _pending(accountExists: true);
      service.acceptError = null;
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invitation-accept')));
      await tester.pumpAndSettle();
      expect(auth.registerCalls.length, 1);
      expect(find.byKey(const Key('invitation-done')), findsOneWidget);
    });

    testWidgets('登録競合email-already-in-useでもログインで再開できる', (tester) async {
      final auth = FakeAuthClient()
        ..registerFailure = const AuthFailure(
          '登録済みです。',
          code: 'email-already-in-use',
        );
      final service = FakeInvitationService(_pending());
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationAcceptPage(
            token: _token,
            authClient: auth,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invitation-register-password')),
        'fixture-password',
      );
      await tester.enterText(
        find.byKey(const Key('invitation-confirm-password')),
        'fixture-password',
      );
      await tester.ensureVisible(find.byKey(const Key('invitation-register')));
      await tester.tap(find.byKey(const Key('invitation-register')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-login')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('invitation-login-password')),
        'fixture-password',
      );
      await tester.ensureVisible(find.byKey(const Key('invitation-login')));
      await tester.tap(find.byKey(const Key('invitation-login')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invitation-accept')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-done')), findsOneWidget);
      expect(auth.registerCalls.length, 1);
    });

    testWidgets('初期設定済み: ログイン → 招待を受ける → 完了表示', (tester) async {
      final auth = FakeAuthClient();
      final service = FakeInvitationService(_pending(accountExists: true));
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationAcceptPage(
            token: _token,
            authClient: auth,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('invitation-login-password')),
        'fixture-password',
      );
      await tester.tap(find.byKey(const Key('invitation-login')));
      await tester.pumpAndSettle();
      expect(auth.signInCalls.single.$1, 'new.manager@example.invalid');
      expect(service.calls, ['get'], reason: 'ログインだけでは受諾しない');
      await tester.tap(find.byKey(const Key('invitation-accept')));
      await tester.pumpAndSettle();
      expect(service.calls, ['get', 'accept']);
      expect(find.byKey(const Key('invitation-done')), findsOneWidget);
      expect(find.text('設定が完了しました'), findsOneWidget);
      expect(
        find.textContaining('犬猫譲渡会・トークショー(架空)のイベント管理者として登録されました。'),
        findsOneWidget,
      );
      expect(find.text('JM Quickを開く'), findsOneWidget);
    });

    testWidgets('別のメールアドレスでログインして受諾しようとすると、分かる文言で拒否される', (tester) async {
      final service = FakeInvitationService(
        _pending(accountExists: true),
        acceptError: InvitationException(
          invitationErrorMessage(
            'PERMISSION_DENIED',
            'invitation-email-mismatch',
          ),
          code: 'invitation-email-mismatch',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationAcceptPage(
            token: _token,
            authClient: FakeAuthClient(
              signedIn: true,
              email: 'other@example.invalid',
            ),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invitation-accept')));
      await tester.pumpAndSettle();
      expect(find.text('招待されたメールアドレスでログインしてください。'), findsOneWidget);
      expect(find.byKey(const Key('invitation-done')), findsNothing);
    });

    for (final (status, key, text) in [
      (InvitationStatus.expired, 'invitation-expired', 'この招待の有効期限が切れています。'),
      (InvitationStatus.revoked, 'invitation-revoked', 'この招待は取り消されています。'),
      (InvitationStatus.accepted, 'invitation-accepted', 'この招待は受諾済みです。'),
      (InvitationStatus.invalid, 'invitation-invalid', 'この招待リンクは利用できません。'),
    ]) {
      testWidgets('${status.name}: 案内だけを表示し、イベント名・役割・操作ボタンは出さない', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: InvitationAcceptPage(
              token: _token,
              authClient: FakeAuthClient(),
              service: FakeInvitationService(InvitationInfo(status: status)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(Key(key)), findsOneWidget);
        expect(find.textContaining(text), findsOneWidget);
        expect(find.text('犬猫譲渡会・トークショー(架空)'), findsNothing);
        expect(find.byKey(const Key('invitation-start-setup')), findsNothing);
        expect(find.byKey(const Key('invitation-accept')), findsNothing);
      });
    }

    testWidgets('tokenの無いリンクは、通信せずに無効として表示する', (tester) async {
      final service = FakeInvitationService(_pending());
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationAcceptPage(
            token: null,
            authClient: FakeAuthClient(),
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-invalid')), findsOneWidget);
      expect(service.calls, isEmpty);
    });

    test('サーバーの理由コードを日本語へ(期限切れ・取消・受諾済み・メールアドレス不一致)', () {
      InvitationException error(String body) {
        try {
          CallableInvitationService.interpret(400, body);
        } on InvitationException catch (e) {
          return e;
        }
        fail('例外になるはず');
      }

      expect(
        error(
          '{"error":{"status":"FAILED_PRECONDITION","details":{"code":"invitation-expired"}}}',
        ).message,
        startsWith('この招待の有効期限が切れています。'),
      );
      expect(
        error(
          '{"error":{"status":"FAILED_PRECONDITION","details":{"code":"invitation-accepted"}}}',
        ).message,
        startsWith('この招待は受諾済みです。'),
      );
      expect(
        error(
          '{"error":{"status":"PERMISSION_DENIED","details":{"code":"invitation-email-mismatch"}}}',
        ).message,
        '招待されたメールアドレスでログインしてください。',
      );
      final info = InvitationInfo.fromJson({
        'status': 'pending',
        'eventName': 'A',
        'role': 'admin',
      });
      expect(info.status, InvitationStatus.invalid, reason: '未知のroleは表示しない');
      expect(
        InvitationInfo.fromJson({
          'status': 'expired',
          'eventName': '漏れてはいけない',
        }).eventName,
        '',
      );
    });
  });

  group('390px・PC幅でoverflowなし', () {
    final pages = <String, Widget Function()>{
      '招待中を含むスタッフ管理': () {
        final service = FakeAssignmentService();
        service.invitations[_evA] = [
          EventInvitationEntry(
            invitationId: 'ei${'d' * 64}',
            role: EventRole.staff,
            email: 'very.long.invited.address.for.overflow@example.invalid',
            expiresAt: DateTime(2026, 12, 7, 10),
            expired: false,
            mailFailed: false,
          ),
          EventInvitationEntry(
            invitationId: 'ei${'e' * 64}',
            role: EventRole.staff,
            email: 'expired@example.invalid',
            expiresAt: DateTime(2026, 9, 1, 10),
            expired: true,
            mailFailed: false,
          ),
        ];
        return _assignmentPage(service, EventRole.staff);
      },
      '招待リンク(初期設定前)': () => MaterialApp(
        home: InvitationAcceptPage(
          token: _token,
          authClient: FakeAuthClient(),
          service: FakeInvitationService(_pending()),
        ),
      ),
      '招待リンク(ログイン)': () => MaterialApp(
        home: InvitationAcceptPage(
          token: _token,
          authClient: FakeAuthClient(),
          service: FakeInvitationService(_pending(accountExists: true)),
        ),
      ),
      '招待リンク(期限切れ)': () => MaterialApp(
        home: InvitationAcceptPage(
          token: _token,
          authClient: FakeAuthClient(),
          service: FakeInvitationService(
            const InvitationInfo(status: InvitationStatus.expired),
          ),
        ),
      ),
    };
    for (final size in const [Size(390, 844), Size(1280, 900)]) {
      for (final entry in pages.entries) {
        testWidgets('${entry.key} ${size.width.toInt()}px', (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(entry.value());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
