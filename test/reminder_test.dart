import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/reminder_page.dart';
import 'package:jm_quick/confirmed/reminder_service.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'package:jm_quick/confirmed/test_mail_page.dart';
import 'app_check_fake.dart';

class FakeBroadcastService extends TestMailService {
  FakeBroadcastService()
    : super(auth: FakeAuthClient(signedIn: true), appCheck: FakeAppCheck());
  int settingsCalls = 0;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    expect(name, 'getConfirmedBroadcastSettings');
    expect(data['eventId'], 'evfixture0123456789');
    settingsCalls++;
    return {'recipients': [], 'history': []};
  }
}

/// サーバーの状態を模したメモリ上の偽サービス(Firestore・ネットワーク・メール送信は一切ない)。
class FakeReminderService implements ReminderService {
  FakeReminderService({
    this.enabled = false,
    this.sendAt,
    this.templateVersion = 2,
    this.targetCount = 150,
    this.excludedCount = 3,
    this.eventName = '架空イベント',
    this.recipients = const [],
    this.unknownWinnerMail = 0,
    this.suspectedDuplicates = 0,
  });
  bool enabled;
  DateTime? sendAt;
  int? templateVersion;
  int targetCount;
  int excludedCount;
  String eventName;

  /// 送信前の宛先一覧・照合値・未解決の件数(サーバーの値を模す)。
  List<ReminderRecipient> recipients;
  int unknownWinnerMail;
  int suspectedDuplicates;
  String targetsFingerprint = 'f' * 64;
  int? currentTargetForChange;

  // ジョブ(作成済みの場合)
  Map<String, DeliveryState>? states;
  String jobStatus = 'ready';
  int jobVersion = 2;
  bool dispatchActive = false;
  String? halted;
  int countSkew = 0;

  // 呼び出しの記録
  int settingsCalls = 0;
  int getJobCalls = 0;
  int startCalls = 0;
  int retryCalls = 0;
  int updateCalls = 0;
  final List<Map<String, Object?>> updates = [];
  final List<Map<String, Object?>> starts = [];
  Completer<void>? startGate;
  WinnerSendException? updateError;

  static Map<String, DeliveryState> ids(Map<DeliveryState, int> counts) {
    final result = <String, DeliveryState>{};
    var n = 1;
    for (final e in counts.entries) {
      for (var i = 0; i < e.value; i++) {
        result['p${(n++).toString().padLeft(3, '0')}'] = e.key;
      }
    }
    return result;
  }

  void seedJob(Map<String, DeliveryState> initial, {String status = 'ready'}) {
    states = Map.of(initial);
    jobStatus = status;
  }

  DeliveryCounts _counts() {
    int c(DeliveryState s) => states!.values.where((v) => v == s).length;
    return DeliveryCounts(
      pending: c(DeliveryState.pending),
      sending: c(DeliveryState.sending),
      sent: c(DeliveryState.sent),
      failed: c(DeliveryState.failed) + countSkew,
      unknown: c(DeliveryState.unknown),
    );
  }

  SendJob? _job() => states == null
      ? null
      : SendJob(
          jobId: 'reminder-event1',
          batchId: '',
          batchLabel: 'リマインド',
          state: JobState.fromValue(jobStatus),
          templateVersion: jobVersion,
          targetCount: states!.length,
          counts: _counts(),
          createdAt: DateTime.utc(2026, 11, 29, 1),
          dispatchActive: dispatchActive,
          dispatchHaltedReason: halted,
        );

  /// サーバーの定期実行(ブラウザとは無関係)を模す。
  void serverSweep() {
    if (!dispatchActive || states == null) return;
    for (final id in states!.keys.toList()) {
      if (states![id] == DeliveryState.pending) {
        states![id] = DeliveryState.sent;
      }
    }
    jobStatus = 'completed';
    dispatchActive = false;
  }

  @override
  Future<ReminderSettings> getSettings(String eventId) async {
    settingsCalls++;
    return ReminderSettings(
      eventId: eventId,
      eventName: eventName,
      enabled: enabled,
      sendAt: sendAt,
      ready: templateVersion != null,
      problems: templateVersion == null
          ? const ['template-not-configured']
          : const [],
      templateVersion: templateVersion,
      subject: templateVersion == null ? '' : '【明日開催】ご案内',
      introBody: templateVersion == null ? '' : 'いよいよ明日です。',
      closingBody: templateVersion == null ? '' : 'お気をつけてお越しください。',
      notesBody: '',
      targetCount: targetCount,
      excludedCount: excludedCount,
      previewParticipantId: 'p001',
      job: _job(),
      changedSinceJob: currentTargetForChange != null && states != null,
      currentTargetCount: currentTargetForChange,
      recipients: recipients,
      targetsFingerprint: targetsFingerprint,
      normalCount: targetCount,
      unknownWinnerMail: unknownWinnerMail,
      suspectedDuplicates: suspectedDuplicates,
    );
  }

  @override
  Future<void> updateSettings({
    required String eventId,
    bool? enabled,
    DateTime? sendAt,
    ({String subject, String introBody, String closingBody, String notesBody})?
    template,
    bool acknowledgePast = false,
  }) async {
    updateCalls++;
    if (updateError != null) throw updateError!;
    updates.add({
      'enabled': enabled,
      'sendAt': sendAt,
      'template': template?.subject,
      'acknowledgePast': acknowledgePast,
    });
    if (enabled != null) this.enabled = enabled;
    if (sendAt != null) this.sendAt = sendAt;
    if (template != null) templateVersion = (templateVersion ?? 0) + 1;
  }

  WinnerMailPreview previewResult = const WinnerMailPreview(
    ready: true,
    problems: [],
    subject: '【明日開催】ご案内',
    text: '【架空イベント】\n\n架空 太郎 様\nいよいよ明日です。\n■ プログラムA\n参加時間：10:00〜11:00\n参加人数：2名',
    webPassUrl: 'https://app.invalid/p/x?publicId=pub_x',
    templateVersion: 2,
    qrPayload:
        'https://app.invalid/reception?eventId=e&participantId=p&publicId=pub_x',
    qrPngBase64:
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final List<String> previewCalls = [];
  @override
  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  }) async {
    previewCalls.add(participantId);
    return previewResult;
  }

  @override
  Future<SendJob> startDelivery(
    String eventId, {
    int? expectedTemplateVersion,
    int? expectedTargetCount,
    String? expectedTargetsFingerprint,
    bool dispatch = true,
  }) async {
    startCalls++;
    starts.add({
      'version': expectedTemplateVersion,
      'count': expectedTargetCount,
      'dispatch': dispatch,
      'fingerprint': expectedTargetsFingerprint,
    });
    if (startGate != null) await startGate!.future;
    if (states == null) {
      // 自動開始と同じジョブへ到達(新規作成)。対象は作成時に確定
      seedJob({
        for (var i = 0; i < targetCount; i++)
          'p${(i + 1).toString().padLeft(3, '0')}': DeliveryState.pending,
      });
      jobVersion = templateVersion ?? 0;
    }
    final hasOpen = states!.values.any(
      (v) => v == DeliveryState.pending || v == DeliveryState.sending,
    );
    if (dispatch && hasOpen && jobStatus == 'ready') {
      dispatchActive = true;
      halted = null;
    }
    return _job()!;
  }

  @override
  Future<SendJobDetail> getJob(
    String eventId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  }) async {
    getJobCalls++;
    final ids = states!.keys.toList()..sort();
    final filtered = [
      for (final id in ids)
        if (itemStatus == null || states![id] == itemStatus) id,
    ];
    final start = after == null ? 0 : filtered.indexOf(after) + 1;
    final page = filtered.skip(start).take(limit).toList();
    return SendJobDetail(
      job: _job()!,
      items: [
        for (final id in page)
          SendItem(participantId: id, name: '架空 $id', state: states![id]),
      ],
      nextAfter: start + page.length < filtered.length ? page.last : null,
    );
  }

  @override
  Future<SendJob> retryFailed(String eventId) async {
    retryCalls++;
    for (final e in states!.entries.toList()) {
      if (e.value == DeliveryState.failed) {
        states![e.key] = DeliveryState.pending;
      }
    }
    if (states!.values.any((v) => v == DeliveryState.pending)) {
      jobStatus = 'ready';
    }
    return _job()!;
  }
}

void setPhone(WidgetTester tester, {double width = 390, double height = 4000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const poll = Duration(seconds: 5);
final fixedNow = DateTime.utc(2026, 11, 28, 3); // JST 11/28 12:00

Widget page(FakeReminderService service) => MaterialApp(
  home: ReminderPage(
    service: service,
    initialEventId: 'event1',
    pollInterval: poll,
    now: () => fixedNow,
  ),
);

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

String count(WidgetTester tester, String state) =>
    tester.widget<Text>(find.byKey(ValueKey('count-$state'))).data!;

void main() {
  group('メニューと認可(admin専用)', () {
    // イベント選択後の管理画面(/console?eventId=…)に「一斉メール送信」が表示される想定なので、
    // eventIdとイベント名表示に使う読み取り専用のサービス(FakeImportService)を渡す。
    Widget console(AccessRole role) => MaterialApp(
      home: ConfirmedConsolePage(
        authClient: FakeAuthClient(signedIn: true),
        accessService: FakeAccessService([AccessCheck.granted(role)]),
        broadcastService: FakeBroadcastService(),
        eventSummaryService: FakeImportService(),
        initialEventId: 'evfixture0123456789',
      ),
    );

    testWidgets('adminには「一斉メール送信」が表示され、開ける', (tester) async {
      await tester.pumpWidget(console(AccessRole.admin));
      await settle(tester);
      expect(find.text('一斉メール送信'), findsOneWidget);
      await tester.ensureVisible(find.text('一斉メール送信'));
      await tester.tap(find.text('一斉メール送信'));
      await settle(tester);
      // eventIdは自動的に引き継がれ、入力欄なしで設定が読み込まれる(Phase 11D)。
      expect(find.text('配送結果を更新'), findsOneWidget);
      expect(find.widgetWithText(TextField, '件名'), findsOneWidget);
      expect(find.widgetWithText(TextField, '本文'), findsOneWidget);
    });

    testWidgets('staffには「一斉メール送信」が表示されない(送信管理・設定も)', (tester) async {
      await tester.pumpWidget(console(AccessRole.staff));
      await settle(tester);
      expect(find.text('一斉メール送信'), findsNothing);
      expect(find.textContaining('一斉メール送信'), findsNothing);
    });
  });

  group('Phase 11D: eventIdはイベント管理画面から内部的に渡されるものだけを正本とする', () {
    testWidgets('イベント管理画面から開くと、eventId入力欄が無い', (tester) async {
      final service = FakeBroadcastService();
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedConsolePage(
            authClient: FakeAuthClient(signedIn: true),
            accessService: FakeAccessService([
              AccessCheck.granted(AccessRole.admin),
            ]),
            broadcastService: service,
            eventSummaryService: FakeImportService(),
            initialEventId: 'evfixture0123456789',
          ),
        ),
      );
      await settle(tester);
      await tester.ensureVisible(find.text('一斉メール送信'));
      await tester.tap(find.text('一斉メール送信'));
      await settle(tester);
      expect(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'イベントID',
        ),
        findsNothing,
      );
      expect(
        service.settingsCalls,
        greaterThan(0),
        reason: 'eventIdは自動的に継承されて読み込まれる',
      );
    });

    testWidgets(
      'initialEventIdなしで直接開くと、eventId入力欄は出さず「イベント管理画面から開いてください」と案内する',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (_) =>
                  ReminderPage(service: FakeReminderService()),
              settings: settings,
            ),
          ),
        );
        await settle(tester);
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
        await settle(tester);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('設定・対象(サーバーの値を表示。手動送信専用)', () {
    testWidgets('対象・対象外・テンプレートversion・文面がサーバーの値で表示される。自動送信・送信予定日時の表示と入力欄は無い', (tester) async {
      setPhone(tester);
      // 過去に自動送信が有効・送信予定日時が保存されていても、画面には出さない(手動送信専用)
      final service = FakeReminderService(
        enabled: true,
        sendAt: DateTime.utc(2026, 11, 29, 1),
      );
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(find.text('150件'), findsOneWidget);
      expect(find.text('3件'), findsOneWidget);
      expect(find.text('v2'), findsOneWidget);
      expect(find.text('架空イベント'), findsOneWidget);
      expect(find.text('【明日開催】ご案内'), findsOneWidget, reason: '文面はサーバーの現在値');
      expect(find.byType(SwitchListTile), findsNothing, reason: '自動送信の切替は無い');
      expect(find.byKey(const ValueKey('switch-enabled')), findsNothing);
      expect(find.widgetWithText(TextField, '送信予定日時(日本時間)'), findsNothing, reason: '送信予定日時の入力欄は無い');
      expect(find.text('自動送信'), findsNothing);
      expect(find.text('送信予定'), findsNothing);
      expect(find.text('2026/11/29 10:00'), findsNothing, reason: '保存済みの送信予定日時も表示しない');
      expect(find.text('有効'), findsNothing);
    });

    testWidgets('手動送信専用であることが分かる(自動送信は無い)', (tester) async {
      setPhone(tester);
      await tester.pumpWidget(page(FakeReminderService()));
      await settle(tester);
      expect(find.byKey(const ValueKey('note-manual-only')), findsOneWidget);
      expect(find.textContaining('自動送信はありません'), findsOneWidget);
    });

    testWidgets('テンプレート未設定は「未設定」と理由が表示される', (tester) async {
      setPhone(tester);
      await tester.pumpWidget(
        page(FakeReminderService()..templateVersion = null),
      );
      await settle(tester);
      expect(find.textContaining('テンプレートが未設定'), findsOneWidget);
    });

    testWidgets('対象人数はサーバーの値をそのまま表示する(同一メール・同一氏名でも減らさない: 100件は100件)', (
      tester,
    ) async {
      setPhone(tester);
      await tester.pumpWidget(
        page(
          FakeReminderService()
            ..targetCount = 100
            ..excludedCount = 0,
        ),
      );
      await settle(tester);
      expect(find.text('100件'), findsOneWidget);
    });
  });

  group('文面の保存(保存だけでは送信しない。自動送信の設定は送らない)', () {
    testWidgets('保存: 確認ダイアログ → 保存。送るのは文面だけ(自動送信の有効化・送信予定日時は送らない)。メールは送られず、ジョブも作られない', (tester) async {
      setPhone(tester);
      final service = FakeReminderService();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '新しい件名');
      await tester.tap(find.text('文面を保存'));
      await settle(tester);
      expect(find.text('リマインドの文面を保存します'), findsOneWidget);
      expect(find.text('テンプレート：文面を更新します(v3)'), findsOneWidget);
      expect(find.textContaining('この保存では、メールは送信されません'), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('自動送信')), findsNothing,
          reason: '保存の確認に自動送信の項目は無い');
      expect(service.updateCalls, 0, reason: '確認するまで保存しない');
      await tester.tap(find.text('保存').last);
      await settle(tester);
      expect(service.updates.single, {'enabled': null, 'sendAt': null, 'template': '新しい件名', 'acknowledgePast': false});
      expect(service.startCalls, 0, reason: '保存だけでは引き渡さない');
      expect(find.textContaining('メールは送信していません'), findsOneWidget);
    });

    testWidgets('キャンセルなら保存しない', (tester) async {
      setPhone(tester);
      final service = FakeReminderService();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '新しい件名');
      await tester.tap(find.text('文面を保存'));
      await settle(tester);
      await tester.tap(find.text('キャンセル'));
      await settle(tester);
      expect(service.updateCalls, 0);
    });

    testWidgets('文面に変更が無ければ保存しない(案内する)', (tester) async {
      setPhone(tester);
      final service = FakeReminderService();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(find.text('文面を保存'));
      await settle(tester);
      expect(find.text('文面に変更がありません。'), findsOneWidget);
      expect(service.updateCalls, 0);
    });

    testWidgets('サーバーが拒否した場合は理由が表示される', (tester) async {
      setPhone(tester);
      final service = FakeReminderService()
        ..updateError = const WinnerSendException(
          'リマインドの自動送信は使用できません。宛先一覧を確認してから、手動で送信してください。',
          code: 'auto-send-disabled',
        );
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '新しい件名');
      await tester.tap(find.text('文面を保存'));
      await settle(tester);
      await tester.tap(find.text('保存').last);
      await settle(tester);
      expect(find.textContaining('自動送信は使用できません'), findsOneWidget);
    });

    testWidgets('作成済みジョブがある場合の文面変更は、ジョブを作り直さない(保存の確認に明示される)', (tester) async {
      setPhone(tester);
      final service = FakeReminderService()
        ..seedJob(FakeReminderService.ids({DeliveryState.pending: 5}))
        ..dispatchActive = true;
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, '件名'), '新しい件名');
      await tester.tap(find.text('文面を保存'));
      await settle(tester);
      expect(find.textContaining('この変更では止まりません・作り直されません'), findsOneWidget);
      await tester.tap(find.text('保存').last);
      await settle(tester);
      expect(service.updates.single['template'], '新しい件名');
      expect(service.updates.single['enabled'], isNull);
      expect(service.startCalls, 0);
      expect(service.dispatchActive, isTrue, reason: '配送中のジョブは止まらない');
    });
  });

  group('プレビュー', () {
    testWidgets('件名・本文・QR・Web参加証URL・versionを表示(サーバーが実送信と同じレンダラーで作成)', (
      tester,
    ) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(find.text('プレビューを表示'));
      await settle(tester);
      expect(service.previewCalls, ['p001']);
      expect(find.text('【明日開催】ご案内'), findsWidgets);
      expect(find.textContaining('参加時間：10:00〜11:00'), findsOneWidget);
      expect(find.textContaining('■ プログラムA'), findsOneWidget);
      expect(find.byKey(const ValueKey('reminder-preview-qr')), findsOneWidget);
      expect(
        find.text('https://app.invalid/p/x?publicId=pub_x'),
        findsOneWidget,
      );
      expect(find.textContaining('当選メールと同じQR'), findsOneWidget);
    });

    testWidgets('作成できない場合は理由が表示される', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..previewResult = const WinnerMailPreview(
          ready: false,
          problems: ['template-not-configured'],
        );
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(find.text('プレビューを表示'));
      await settle(tester);
      expect(find.textContaining('まだ作成できません'), findsOneWidget);
    });
  });

  group('手動開始(自動開始と同じジョブ)', () {
    testWidgets(
      'プレビュー確認まで押せない。確認ダイアログ(イベント・対象・テンプレート)→ 確認した対象人数・versionを添えて引き渡し',
      (tester) async {
        setPhone(tester, height: 6000);
        final service = FakeReminderService(
          enabled: true,
          sendAt: DateTime.utc(2026, 11, 29, 1),
        );
        await tester.pumpWidget(page(service));
        await settle(tester);
        final button = find.widgetWithText(OutlinedButton, '今すぐリマインド送信を開始…');
        expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
        await tester.tap(find.text('プレビューを表示'));
        await settle(tester);
        expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
        await tester.tap(button);
        await settle(tester);
        expect(find.text('リマインドを今すぐ開始します'), findsOneWidget);
        expect(find.text('イベント：架空イベント'), findsOneWidget);
        expect(find.text('送信対象：150件(当選メール送信済みの参加者。通常当選150件・繰り上げ当選0件)'), findsOneWidget);
        expect(find.textContaining('宛先は、この画面の宛先一覧のとおりです'), findsOneWidget);
        expect(find.text('テンプレート：v2'), findsOneWidget);
        expect(find.textContaining('二重には作られません'), findsOneWidget);
        await tester.tap(find.text('キャンセル'));
        await settle(tester);
        expect(service.startCalls, 0);
        await tester.tap(button);
        await settle(tester);
        await tester.tap(find.text('送信を開始'));
        await settle(tester);
        expect(service.starts, [
          {'version': 2, 'count': 150, 'dispatch': true, 'fingerprint': 'f' * 64},
        ]);
        expect(
          find.byKey(const ValueKey('reminder-server-running')),
          findsOneWidget,
        );
        expect(
          find.text('今すぐリマインド送信を開始…'),
          findsNothing,
          reason: '開始後は既存ジョブの状況を表示(別便のボタンなし)',
        );
      },
    );

    testWidgets('連打しても二重に開始しない(処理中はボタンが無効)', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()..startGate = Completer<void>();
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(find.text('プレビューを表示'));
      await settle(tester);
      await tester.tap(find.text('今すぐリマインド送信を開始…'));
      await settle(tester);
      await tester.tap(find.text('送信を開始'));
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '今すぐリマインド送信を開始…'),
            )
            .onPressed,
        isNull,
      );
      expect(service.startCalls, 1);
      service.startGate!.complete();
      await settle(tester);
      expect(service.startCalls, 1);
    });
  });

  group('送信状況(pending / sending / sent / failed / unknown を区別)', () {
    testWidgets('ジョブの状態・件数・テンプレートversionが表示され、5状態が別の欄になる', (tester) async {
      setPhone(tester, height: 6000);
      final service =
          FakeReminderService(
              enabled: true,
              sendAt: DateTime.utc(2026, 11, 29, 1),
            )
            ..seedJob(
              FakeReminderService.ids({
                DeliveryState.pending: 2,
                DeliveryState.sending: 3,
                DeliveryState.sent: 6,
                DeliveryState.failed: 3,
                DeliveryState.unknown: 1,
              }),
            )
            ..dispatchActive = true;
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(
        [
          count(tester, 'pending'),
          count(tester, 'sending'),
          count(tester, 'sent'),
          count(tester, 'failed'),
          count(tester, 'unknown'),
        ],
        ['2', '3', '6', '3', '1'],
      );
      for (final label in ['未送信', '送信中', '送信済み', '失敗', '結果確認が必要']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('15件(作成時に確定)'), findsOneWidget);
      expect(find.textContaining('v2(作成時に固定)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('reminder-server-running')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reminder-unknown')), findsOneWidget);
      expect(find.textContaining('自動では再送されません'), findsOneWidget);
    });

    testWidgets('件数の合計が対象数と一致しない場合は「状態を確認できません」(正常表示しない)', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..seedJob(
          FakeReminderService.ids({DeliveryState.sent: 10}),
          status: 'completed',
        )
        ..countSkew = 1;
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('reminder-untrustworthy')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('count-sent')), findsNothing);
    });

    testWidgets('ジョブ作成後に参加者が追加・変更された場合の注意(既存ジョブへは自動追加しない)', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..seedJob(
          FakeReminderService.ids({DeliveryState.sent: 100}),
          status: 'completed',
        )
        ..currentTargetForChange = 108;
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(find.byKey(const ValueKey('reminder-changed')), findsOneWidget);
      expect(
        find.textContaining('現在の有効な参加者 108件 / ジョブの対象 100件'),
        findsOneWidget,
      );
      expect(find.textContaining('既存のジョブへは自動で追加されません'), findsOneWidget);
    });

    testWidgets('画面の再読込: サーバーの状態(送信済み・失敗・結果確認)がそのまま復元される。ローカル状態に依存しない', (
      tester,
    ) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..seedJob(
          FakeReminderService.ids({
            DeliveryState.sent: 4,
            DeliveryState.failed: 2,
            DeliveryState.unknown: 1,
          }),
          status: 'completed',
        );
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(
        [
          count(tester, 'sent'),
          count(tester, 'failed'),
          count(tester, 'unknown'),
        ],
        ['4', '2', '1'],
      );
    });

    testWidgets(
      'pollingは、サーバーが処理中の間だけ間隔を空けて再取得し、完了したら止まる。配送はサーバーが行い、画面は起動しない',
      (tester) async {
        setPhone(tester, height: 6000);
        final service = FakeReminderService()
          ..seedJob(FakeReminderService.ids({DeliveryState.pending: 6}))
          ..dispatchActive = true;
        await tester.pumpWidget(page(service));
        await tester.pump();
        await tester.pump();
        final before = service.settingsCalls;
        await tester.pump(const Duration(seconds: 2));
        expect(service.settingsCalls, before, reason: '過剰な頻度では取得しない');
        await tester.pump(poll);
        await tester.pump();
        expect(service.settingsCalls, greaterThan(before));
        expect(service.startCalls, 0, reason: 'pollingは処理を起動しない');
        service.serverSweep(); // サーバーの定期実行
        await tester.pump(poll);
        await tester.pump();
        expect(count(tester, 'sent'), '6');
        final done = service.settingsCalls;
        await tester.pump(poll * 3);
        await tester.pump();
        expect(service.settingsCalls, done, reason: '終端でpolling停止');
      },
    );
  });

  group('送信状況画面(共通): failedだけ再送・unknown/sentに通常再送なし', () {
    Future<void> openJob(
      WidgetTester tester,
      FakeReminderService service,
    ) async {
      await tester.pumpWidget(page(service));
      await settle(tester);
      await tester.tap(find.text('送信状況を開く'));
      await settle(tester);
    }

    testWidgets(
      'failedがあれば「失敗分だけ再送」。確認ダイアログに失敗件数・sent/unknownは再送しない旨。実行 → 再送(failedだけ)→ サーバーへ引き渡し',
      (tester) async {
        setPhone(tester, height: 6000);
        final service = FakeReminderService()
          ..seedJob(
            FakeReminderService.ids({
              DeliveryState.sent: 6,
              DeliveryState.failed: 2,
              DeliveryState.unknown: 2,
            }),
            status: 'completed',
          );
        await openJob(tester, service);
        expect(find.text('失敗分だけ再送(2件)'), findsOneWidget);
        await tester.tap(find.text('失敗分だけ再送(2件)'));
        await settle(tester);
        expect(find.text('失敗分だけを再送します'), findsOneWidget);
        expect(find.text('再送対象：失敗 2件'), findsOneWidget);
        expect(find.text('送信済み・結果確認が必要な宛先は再送しません。'), findsOneWidget);
        await tester.tap(find.text('キャンセル'));
        await settle(tester);
        expect(service.retryCalls, 0);
        await tester.tap(find.text('失敗分だけ再送(2件)'));
        await settle(tester);
        await tester.tap(find.text('失敗分を再送'));
        await settle(tester);
        expect(service.retryCalls, 1);
        expect(service.startCalls, 1, reason: '再送もサーバーへ引き渡す');
        service.serverSweep();
        await tester.pump(poll);
        await tester.pump();
        expect(
          [
            count(tester, 'sent'),
            count(tester, 'failed'),
            count(tester, 'unknown'),
          ],
          ['8', '0', '2'],
          reason: 'unknownは不変',
        );
      },
    );

    testWidgets('unknownだけ・sentだけのジョブには再送ボタンが出ない(結果確認が必要と警告)', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..seedJob(
          FakeReminderService.ids({
            DeliveryState.sent: 4,
            DeliveryState.unknown: 1,
          }),
          status: 'completed',
        );
      await openJob(tester, service);
      expect(find.byKey(const ValueKey('banner-unknown')), findsOneWidget);
      expect(find.textContaining('結果確認が必要'), findsWidgets);
      expect(find.textContaining('失敗分だけ再送'), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('宛先一覧は participantId・表示名・状態だけ(メールアドレスなし)', (tester) async {
      setPhone(tester, height: 6000);
      final service = FakeReminderService()
        ..seedJob(
          FakeReminderService.ids({DeliveryState.sent: 3}),
          status: 'completed',
        );
      await openJob(tester, service);
      expect(find.text('架空 p001'), findsOneWidget);
      expect(find.text('p001'), findsOneWidget);
      expect(find.textContaining('@'), findsNothing);
    });
  });

  group('レイアウト', () {
    testWidgets('390px幅でも、はみ出さず表示される', (tester) async {
      setPhone(tester, height: 8000);
      final service =
          FakeReminderService(
              enabled: true,
              sendAt: DateTime.utc(2026, 11, 29, 1),
            )
            ..seedJob(
              FakeReminderService.ids({
                DeliveryState.pending: 2,
                DeliveryState.sent: 6,
                DeliveryState.failed: 3,
                DeliveryState.unknown: 1,
              }),
            )
            ..dispatchActive = true;
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('日時の解釈(日本時間 → 絶対時刻)', () {
    test('JSTの入力がUTCの絶対時刻になる。形式・日付が不正ならnull', () {
      expect(
        parseJstDateTime('2026/11/29 10:00'),
        DateTime.utc(2026, 11, 29, 1),
      );
      expect(
        parseJstDateTime('2026-11-29 10:00'),
        DateTime.utc(2026, 11, 29, 1),
      );
      expect(
        parseJstDateTime('2026/11/29 00:30'),
        DateTime.utc(2026, 11, 28, 15, 30),
      );
      for (final bad in [
        '',
        '明日',
        '2026/13/01 10:00',
        '2026/02/30 10:00',
        '2026/11/29 25:00',
        '2026/11/29 10:60',
        '2026/11/29',
      ]) {
        expect(parseJstDateTime(bad), isNull, reason: bad);
      }
    });
  });

  group('CallableReminderService / アダプタ', () {
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    CallableReminderService service(
      MockClient client, {
      FakeAuthClient? auth,
    }) => CallableReminderService(
      authClient: auth ?? FakeAuthClient(signedIn: true, token: 'tok'),
      httpClient: client,
      baseUrl: 'https://example.invalid',
    );

    test('保存: IDトークンを送り、変更した項目だけを送る。送信日時は絶対時刻(ISO)', () async {
      late http.Request seen;
      final s = service(
        MockClient((r) async {
          seen = r;
          return json({
            'result': {'eventId': 'event1'},
          }, 200);
        }),
      );
      await s.updateSettings(
        eventId: 'event1',
        enabled: true,
        sendAt: DateTime.utc(2026, 11, 29, 1),
        acknowledgePast: true,
      );
      expect(
        seen.url.toString(),
        'https://example.invalid/updateConfirmedReminderSettings',
      );
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect((jsonDecode(seen.body) as Map)['data'], {
        'round': 1,
        'eventId': 'event1',
        'reminderEnabled': true,
        'reminderSendAt': '2026-11-29T01:00:00.000Z',
        'acknowledgePast': true,
      });
      await s.updateSettings(eventId: 'event1', enabled: false);
      expect((jsonDecode(seen.body) as Map)['data'], {
        'round': 1,
        'eventId': 'event1',
        'reminderEnabled': false,
      });
    });

    test(
      '呼び先はリマインド専用のadmin callable(旧mailJobs・当選メールのcallableではない)。アダプタはjobIdをeventIdへ対応させる',
      () async {
        final urls = <String>[];
        final s = service(
          MockClient((r) async {
            urls.add(r.url.path);
            return json({
              'result': {
                'jobId': 'reminder-event1',
                'status': 'ready',
                'templateVersion': 1,
                'targetCount': 1,
                'pendingCount': 1,
                'eventId': 'event1',
                'enabled': false,
                'targets': {},
                'job': {
                  'jobId': 'reminder-event1',
                  'status': 'ready',
                  'counts': {},
                  'conservation': {},
                },
                'items': [],
              },
            }, 200);
          }),
        );
        final adapter = ReminderJobAdapter(s);
        await s.getSettings('event1');
        await s.preview(eventId: 'event1', participantId: 'p1');
        await adapter.getJob('reminder-event1');
        await adapter.startDelivery('reminder-event1');
        await adapter.retryFailed('reminder-event1');
        await adapter.createJob(
          eventId: 'event1',
          batchId: '',
          expectedTemplateVersion: 1,
        );
        expect(urls, [
          '/getConfirmedReminderSettings',
          '/previewConfirmedReminderMail',
          '/getConfirmedReminderJob',
          '/startConfirmedReminderDelivery',
          '/retryFailedConfirmedReminderMails',
          '/startConfirmedReminderDelivery',
        ]);
        await expectLater(
          adapter.getJob('winner-batchA'),
          throwsA(isA<WinnerSendException>()),
        );
      },
    );

    test('未ログインなら通信しない。エラーは表示用に変換される(過去日時・対象人数変更・権限)', () async {
      var called = false;
      await expectLater(
        service(
          MockClient((_) async {
            called = true;
            return json({}, 200);
          }),
          auth: FakeAuthClient(signedIn: false),
        ).getSettings('e'),
        throwsA(isA<WinnerSendException>()),
      );
      expect(called, isFalse);
      WinnerSendException e(String status, String code) =>
          CallableReminderService.errorFrom(400, {
            'error': {
              'status': status,
              'details': {'code': code},
            },
          });
      expect(
        e('FAILED_PRECONDITION', 'send-at-in-past').message,
        contains('過去'),
      );
      expect(
        e('FAILED_PRECONDITION', 'target-count-changed').message,
        contains('対象人数'),
      );
      expect(
        e('FAILED_PRECONDITION', 'template-version-changed').message,
        contains('バージョン'),
      );
      expect(
        CallableReminderService.errorFrom(403, {
          'error': {'status': 'PERMISSION_DENIED'},
        }).message,
        'この操作を行う権限がありません。',
      );
    });

    test('設定のモデル: 対象・対象外・ジョブ・変更の注意をサーバーの値から読む', () {
      final settings = ReminderSettings.fromJson({
        'eventId': 'event1',
        'eventName': '架空',
        'enabled': true,
        'sendAt': '2026-11-29T01:00:00.000Z',
        'ready': true,
        'problems': [],
        'template': {
          'version': 3,
          'subject': 's',
          'introBody': 'i',
          'closingBody': 'c',
          'notesBody': '',
        },
        'targets': {'targetCount': 150, 'excludedCount': 3},
        'job': {
          'jobId': 'reminder-event1',
          'status': 'ready',
          'templateVersion': 3,
          'targetCount': 150,
          'counts': {'pending': 150},
          'conservation': {'consistent': true, 'completedConsistent': true},
          'dispatch': {'active': true},
        },
        'changedSinceJob': {
          'changed': true,
          'currentTargetCount': 155,
          'jobTargetCount': 150,
        },
      });
      expect(
        [
          settings.targetCount,
          settings.excludedCount,
          settings.templateVersion,
          settings.enabled,
          settings.changedSinceJob,
          settings.currentTargetCount,
        ],
        [150, 3, 3, true, true, 155],
      );
      expect(settings.job!.dispatchActive, isTrue);
      expect(settings.job!.trustworthy, isTrue);
    });
  });

  group('送信前の宛先一覧・誤送信防止', () {
    ReminderRecipient r(String id, String name, {String email = 'x@example.invalid', String type = 'normal', String status = 'sent',
        bool target = true, String duplicate = 'none', int size = 1}) => ReminderRecipient.fromJson({
      'participantId': id, 'name': name, 'email': email, 'notificationType': type, 'winnerStatus': status, 'target': target,
      'excludedReason': target ? null : 'winner-mail-not-sent', 'duplicate': duplicate, 'duplicateGroupSize': size,
      'programs': [{'programId': 'alpha', 'name': '架空プログラムA', 'timeText': '10:00-11:00', 'plannedCount': 2}],
    });

    testWidgets('宛先一覧: 送信予定と対象外を分け、氏名・メール・当選種別・program・時間・人数・当選メールの状態・重複の判定を表示', (tester) async {
      setPhone(tester, width: 1000, height: 8000);
      final service = FakeReminderService(targetCount: 3, recipients: [
        r('p1', '架空 一郎', email: 'family@example.invalid', duplicate: 'shared-address', size: 2),
        r('p2', '架空 花子', email: 'family@example.invalid', duplicate: 'shared-address', size: 2),
        r('p3', '架空 三郎', email: 'w3@example.invalid', type: 'waitlistPromotion'),
        r('p4', '架空 四郎', email: 'n4@example.invalid', status: 'failed', target: false),
        r('p5', '架空 五郎', email: 'n5@example.invalid', status: 'none', target: false),
      ]);
      await tester.pumpWidget(page(service));
      await settle(tester);
      expect(find.byKey(const ValueKey('reminder-recipients')), findsOneWidget);
      expect(find.text('送信予定：3件(通常当選3件・繰り上げ当選0件)　送信対象外：2件'), findsOneWidget);
      expect(find.text('送信予定(3件)'), findsOneWidget);
      expect(find.text('送信対象外(2件。送信されません)'), findsOneWidget);
      expect(find.text('架空 一郎　family@example.invalid'), findsOneWidget);
      expect(find.text('繰り上げ当選　当選メール：送信済み'), findsOneWidget);
      expect(find.text('通常当選　当選メール：送信失敗'), findsOneWidget);
      expect(find.text('通常当選　当選メール：未送信(記録なし)'), findsOneWidget);
      expect(find.text('架空プログラムA　10:00-11:00　2名'), findsNWidgets(5));
      expect(find.text('同じアドレス(別の氏名・共有)(同じアドレス2件)'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('reminder-unknown-warning')), findsNothing);
      expect(find.byKey(const ValueKey('reminder-duplicate-warning')), findsNothing);
      // 参加者を選ぶ・除外する操作は無い
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Switch).evaluate().length, lessThanOrEqualTo(1), reason: '自動送信の切替だけ(宛先の選択は無い)');
    });

    testWidgets('当選メールの結果不明・重複登録の疑いがあれば警告し、開始できない(サーバーも作らない)', (tester) async {
      for (final (unknown, suspected, key) in [(1, 0, 'reminder-unknown-warning'), (0, 2, 'reminder-duplicate-warning')]) {
        setPhone(tester, width: 1000, height: 8000);
        final service = FakeReminderService(targetCount: 2, unknownWinnerMail: unknown, suspectedDuplicates: suspected, recipients: [
          r('p1', '架空 一郎', duplicate: suspected > 0 ? 'suspected-duplicate' : 'none', size: suspected > 0 ? 2 : 1),
          r('p2', '架空 一郎', duplicate: suspected > 0 ? 'suspected-duplicate' : 'none', size: suspected > 0 ? 2 : 1),
          if (unknown > 0) r('p3', '架空 三郎', status: 'unknown', target: false),
        ]);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(page(service));
        await settle(tester);
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
        await tester.tap(find.text('プレビューを表示'));
        await settle(tester);
        final button = find.widgetWithText(OutlinedButton, '今すぐリマインド送信を開始…');
        expect(tester.widget<OutlinedButton>(button).onPressed, isNull, reason: 'プレビュー済みでも開始できない');
        expect(find.byKey(const ValueKey('reminder-start-blocked')), findsOneWidget);
        expect(service.startCalls, 0);
        if (unknown > 0) expect(find.text('通常当選　当選メール：結果不明(要確認)'), findsOneWidget);
        if (suspected > 0) expect(find.text('重複登録の疑い(同じアドレス2件)'), findsNWidgets(2));
      }
    });

    test('サーバーの理由コード(確認後の変更・未解決・確認なし)を表示用のメッセージにする', () {
      Map<String, dynamic> body(String code) => {'error': {'status': 'FAILED_PRECONDITION', 'details': {'code': code}}};
      expect(CallableReminderService.errorFrom(400, body('targets-changed')).message, contains('宛先一覧をもう一度確認'));
      expect(CallableReminderService.errorFrom(400, body('reminder-targets-unresolved')).message, contains('重複登録の疑い'));
      expect(CallableReminderService.errorFrom(400, body('targets-fingerprint-required')).message, contains('宛先一覧を確認してから'));
    });
  });

  group('構造(ソース)の固定', () {
    String read(String path) => File(path).readAsStringSync();
    final files = [
      'reminder_page',
      'reminder_service',
    ].map((n) => 'lib/confirmed/$n.dart');

    test('Firestoreを直接読まない・snapshotを使わない。旧mailJobsを使わない', () {
      for (final f in files) {
        final source = read(f);
        expect(source.contains('cloud_firestore'), isFalse, reason: f);
        expect(source.contains('snapshots()'), isFalse, reason: f);
        expect(source.contains("collection('"), isFalse, reason: f);
        expect(source.contains('mailJobs'), isFalse, reason: f);
      }
    });

    test('対象人数をクライアントで計算しない(重複排除・除外の処理が無い)。配送processorを呼ばない', () {
      for (final f in files) {
        final source = read(f);
        expect(source.contains('toSet()'), isFalse, reason: f);
        expect(source.contains('distinct'), isFalse, reason: f);
        expect(source.contains('registeredCount'), isFalse, reason: f);
        // メールアドレスは、送信前の宛先一覧でサーバーの値を表示するだけ。クライアントで比較・正規化・まとめをしない
        // (重複の判定はサーバー。以前は表示も無かったため '.email' 自体を禁じていた)
        expect(RegExp(r'\.email\s*(==|!=)|==\s*\w+\.email|\.email\.(trim|toLowerCase)|groupBy').hasMatch(source), isFalse, reason: f);
        expect(
          source.contains('processConfirmedWinnerMailJob'),
          isFalse,
          reason: f,
        );
        expect(source.contains('processJob'), isFalse, reason: f);
      }
    });

    test('リマインドは当選メールのテンプレート・callableを使わない(別データ・別callable)', () {
      for (final f in files) {
        final source = read(f);
        expect(source.contains('winnerMailTemplate'), isFalse, reason: f);
        expect(
          source.contains('getConfirmedWinnerMailSettings'),
          isFalse,
          reason: f,
        );
        expect(
          source.contains('updateConfirmedWinnerMailTemplate'),
          isFalse,
          reason: f,
        );
      }
    });
  });
}
