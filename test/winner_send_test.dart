import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';
import 'package:jm_quick/confirmed/winner_send_job_page.dart';
import 'package:jm_quick/confirmed/winner_send_page.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

/// サーバーの状態を模したメモリ上の偽サービス(Firestore・ネットワーク・メール送信は一切ない)。
class FakeSendService implements WinnerSendService {
  FakeSendService({List<SendBatch>? batches, this.templateVersion = 3})
    : batches = batches ?? [];
  int? templateVersion;
  bool templateReady = true;
  List<SendBatch> batches;
  final Map<String, Map<String, DeliveryState>> states = {};
  final Map<String, String> jobStatus = {};
  final Map<String, int> jobTemplate = {};
  final Map<String, int> jobTarget = {};

  // 呼び出しの記録
  int listCalls = 0;
  int getJobCalls = 0;
  int createCalls = 0;
  int startCalls = 0;
  int serverProcessed = 0;
  final Set<String> dispatchActive = {};
  final Map<String, String> haltedReason = {};
  WinnerSendException? startError;
  int retryCalls = 0;
  final List<int?> expectedVersions = [];

  // 振る舞いの調整
  DeliveryState Function(String participantId) outcomeFor = (_) =>
      DeliveryState.sent;
  Completer<void>? createGate;
  bool loseCreateResponse = false;
  WinnerSendException? createError;
  int? createTargetOverride;
  int? createVersionOverride;
  int countSkew = 0; // 件数の合計をずらす(保存則の不一致を再現)
  String? forcedStatus;

  static String jobIdOf(String batchId) => 'winner-$batchId';

  void seedJob(
    String batchId,
    Map<String, DeliveryState> initial, {
    int version = 3,
    String status = 'ready',
  }) {
    states[jobIdOf(batchId)] = Map.of(initial);
    jobStatus[jobIdOf(batchId)] = status;
    jobTemplate[jobIdOf(batchId)] = version;
    jobTarget[jobIdOf(batchId)] = initial.length;
  }

  DeliveryCounts _counts(String jobId) {
    int c(DeliveryState s) => states[jobId]!.values.where((v) => v == s).length;
    return DeliveryCounts(
      pending: c(DeliveryState.pending),
      sending: c(DeliveryState.sending),
      sent: c(DeliveryState.sent),
      failed: c(DeliveryState.failed) + countSkew,
      unknown: c(DeliveryState.unknown),
    );
  }

  JobState? _stateOf(String jobId) =>
      JobState.fromValue(forcedStatus ?? jobStatus[jobId]);

  SendJob _job(String jobId, {String label = '第1回'}) => SendJob(
    jobId: jobId,
    batchId: jobId.replaceFirst('winner-', ''),
    batchLabel: label,
    state: _stateOf(jobId),
    templateVersion: jobTemplate[jobId]!,
    targetCount: jobTarget[jobId]!,
    counts: _counts(jobId),
    createdAt: DateTime.utc(2026, 11, 1, 1, 2),
    dispatchActive: dispatchActive.contains(jobId),
    dispatchHaltedReason: haltedReason[jobId],
  );

  void _settle(String jobId) {
    if (jobStatus[jobId] == 'completed' || jobStatus[jobId] == 'ready') {
      final open = states[jobId]!.values.any(
        (v) => v == DeliveryState.pending || v == DeliveryState.sending,
      );
      jobStatus[jobId] = open ? 'ready' : 'completed';
    }
  }

  @override
  Future<SendBatchList> listBatches(String eventId) async {
    listCalls++;
    return SendBatchList(
      eventId: eventId,
      eventName: '架空イベント',
      templateVersion: templateVersion,
      templateReady: templateReady,
      templateProblems: templateReady
          ? const []
          : const ['template-not-configured'],
      batches: [
        for (final b in batches)
          SendBatch(
            batchId: b.batchId,
            sequence: b.sequence,
            label: b.label,
            status: b.status,
            importedCount: b.importedCount,
            targetCount: b.targetCount,
            excludedInactiveCount: b.excludedInactiveCount,
            consistent: b.consistent,
            previewParticipantId: b.previewParticipantId,
            blockedReasons: states.containsKey(jobIdOf(b.batchId))
                ? [
                    ...b.blockedReasons.where((r) => r != 'job-exists'),
                    'job-exists',
                  ]
                : b.blockedReasons,
            canCreateJob:
                b.canCreateJob && !states.containsKey(jobIdOf(b.batchId)),
            job: states.containsKey(jobIdOf(b.batchId))
                ? _job(jobIdOf(b.batchId), label: b.label)
                : null,
          ),
      ],
    );
  }

  @override
  Future<SendJobDetail> getJob(
    String jobId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  }) async {
    getJobCalls++;
    if (!states.containsKey(jobId)) {
      throw const WinnerSendException('対象が見つかりません。');
    }
    final ids = states[jobId]!.keys.toList()..sort();
    final filtered = [
      for (final id in ids)
        if (itemStatus == null || states[jobId]![id] == itemStatus) id,
    ];
    final start = after == null ? 0 : filtered.indexOf(after) + 1;
    final page = filtered.skip(start).take(limit).toList();
    final label = batches
        .where((b) => jobIdOf(b.batchId) == jobId)
        .map((b) => b.label)
        .firstOrNull;
    return SendJobDetail(
      job: _job(jobId, label: label ?? '第1回'),
      items: [
        for (final id in page)
          SendItem(
            participantId: id,
            name: '架空 $id',
            state: states[jobId]![id],
          ),
      ],
      nextAfter: start + page.length < filtered.length ? page.last : null,
    );
  }

  @override
  Future<SendJob> createJob({
    required String eventId,
    required String batchId,
    required int expectedTemplateVersion,
  }) async {
    createCalls++;
    expectedVersions.add(expectedTemplateVersion);
    if (createGate != null) await createGate!.future;
    if (createError != null) throw createError!;
    final jobId = jobIdOf(batchId);
    if (!states.containsKey(jobId)) {
      final batch = batches.firstWhere((b) => b.batchId == batchId);
      seedJob(batchId, {
        for (var i = 0; i < batch.targetCount!; i++)
          'p${(i + 1).toString().padLeft(3, '0')}': DeliveryState.pending,
      }, version: templateVersion!);
    }
    if (loseCreateResponse) {
      throw const WinnerSendException(
        '通信に失敗しました。サーバーでは処理が行われている可能性があります。',
        code: 'network',
      );
    }
    final job = _job(jobId);
    return SendJob(
      jobId: job.jobId,
      batchId: job.batchId,
      state: job.state,
      templateVersion: createVersionOverride ?? job.templateVersion,
      targetCount: createTargetOverride ?? job.targetCount,
      counts: job.counts,
    );
  }

  /// サーバー側への引き渡し(希望の記録だけ。ここではメールは送られない)。冪等。
  @override
  Future<SendJob> startDelivery(String jobId) async {
    startCalls++;
    if (startError != null) throw startError!;
    final pending = states[jobId]!.values.any(
      (v) => v == DeliveryState.pending || v == DeliveryState.sending,
    );
    if (pending) {
      dispatchActive.add(jobId);
      haltedReason.remove(jobId);
    }
    return _job(jobId);
  }

  /// サーバーの定期実行(ブラウザとは無関係)を模す。引き渡されたジョブを最後まで処理する。
  /// UI(Flutter)からは呼ばれない。テストが「サーバーが進めた」ことを表すために呼ぶ。
  void serverSweep({int chunk = 20}) {
    for (final jobId in dispatchActive.toList()) {
      final pending =
          states[jobId]!.entries
              .where((e) => e.value == DeliveryState.pending)
              .map((e) => e.key)
              .toList()
            ..sort();
      for (final id in pending.take(chunk)) {
        states[jobId]![id] = outcomeFor(id);
      }
      _settle(jobId);
      final open = states[jobId]!.values.any(
        (v) => v == DeliveryState.pending || v == DeliveryState.sending,
      );
      if (!open) dispatchActive.remove(jobId);
      serverProcessed += pending.take(chunk).length;
    }
  }

  @override
  Future<SendJob> retryFailed(String jobId) async {
    retryCalls++;
    for (final e in states[jobId]!.entries.toList()) {
      if (e.value == DeliveryState.failed) {
        states[jobId]![e.key] = DeliveryState.pending;
      }
    }
    _settle(jobId);
    return _job(jobId);
  }
}

class FakeMailService implements WinnerMailService {
  WinnerMailPreview preview_ = const WinnerMailPreview(
    ready: true,
    problems: [],
    subject: '【当選】ご案内',
    text: '架空 太郎 様\n受付QR: (下)\n参加証: https://app.invalid/p/x',
    webPassUrl: 'https://app.invalid/p/x?publicId=pub_x',
    templateVersion: 3,
    qrPayload:
        'https://app.invalid/reception?eventId=e&participantId=p&publicId=pub_x',
    qrPngBase64:
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final List<String> previewCalls = [];
  @override
  Future<WinnerMailSettings> getSettings(String eventId) =>
      throw UnimplementedError();
  @override
  Future<int> updateTemplate({
    required String eventId,
    required String subject,
    required String introBody,
    required String closingBody,
    required String notesBody,
    required String address,
    required String access,
  }) => throw UnimplementedError();
  @override
  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  }) async {
    previewCalls.add(participantId);
    return preview_;
  }
}

SendBatch committed(
  String id,
  int sequence,
  int target, {
  int? imported,
  int excluded = 0,
}) => SendBatch(
  batchId: id,
  sequence: sequence,
  label: '第$sequence回',
  status: 'committed',
  importedCount: imported ?? target + excluded,
  targetCount: target,
  excludedInactiveCount: excluded,
  consistent: true,
  previewParticipantId: 'p001',
  canCreateJob: true,
  blockedReasons: const [],
);

SendBatch notCommitted(String id, int sequence, String status) => SendBatch(
  batchId: id,
  sequence: sequence,
  label: '第$sequence回',
  status: status,
  canCreateJob: false,
  blockedReasons: const ['batch-not-committed'],
);

Map<String, DeliveryState> ids(Map<DeliveryState, int> counts) {
  final result = <String, DeliveryState>{};
  var n = 1;
  for (final e in counts.entries) {
    for (var i = 0; i < e.value; i++) {
      result['p${(n++).toString().padLeft(3, '0')}'] = e.key;
    }
  }
  return result;
}

void setPhone(WidgetTester tester, {double width = 390, double height = 3000}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const poll = Duration(seconds: 5);

Widget sendPage(FakeSendService service, FakeMailService mail) => MaterialApp(
  home: WinnerSendPage(
    service: service,
    mailService: mail,
    initialEventId: 'event1',
    pollInterval: poll,
  ),
);

Widget jobPage(FakeSendService service, {String batchId = 'batchA'}) =>
    MaterialApp(
      home: WinnerSendJobPage(
        service: service,
        eventId: 'event1',
        eventName: '架空イベント',
        jobId: 'winner-$batchId',
        pollInterval: poll,
      ),
    );

Future<void> settle(WidgetTester tester) => tester.pumpAndSettle();

Future<void> previewFirst(WidgetTester tester) async {
  await tester.tap(find.text('プレビューを表示').first);
  await settle(tester);
}

void main() {
  group('取込回の一覧(サーバーの値を表示)', () {
    testWidgets('第1回(送信済み)・第2回(未送信)。取込件数・メール対象・送信状況がサーバーの値で表示される', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(
        batches: [committed('batchA', 1, 90), committed('batchB', 2, 43)],
      )..seedJob('batchA', ids({DeliveryState.sent: 90}), status: 'completed');
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(find.text('第1回'), findsOneWidget);
      expect(find.text('第2回'), findsOneWidget);
      expect(find.text('90件'), findsWidgets);
      expect(find.text('43件'), findsWidgets);
      expect(find.byKey(const ValueKey('count-sent')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('count-sent'))).data,
        '90',
      );
      expect(find.text('送信状況を開く'), findsOneWidget, reason: 'ジョブ作成済みのbatch');
      expect(find.text('この取込回へ送信…'), findsOneWidget, reason: '未送信のbatchだけ');
      expect(
        find.text('現在の当選メールのテンプレート：v3(送信ジョブ作成時にこのバージョンで固定されます)'),
        findsOneWidget,
      );
    });

    testWidgets('committing・failedのbatchは状態だけ表示され、対象人数も送信ボタンも出ない', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(
        batches: [
          notCommitted('batchA', 1, 'committing'),
          notCommitted('batchB', 2, 'failed'),
        ],
      );
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(find.text('取込中(未完了)'), findsOneWidget);
      expect(find.text('取込失敗'), findsOneWidget);
      expect(find.text('メール対象'), findsNothing);
      expect(find.textContaining('この取込回へ送信'), findsNothing);
      expect(find.text('取込が完了(committed)していないため、送信できません。'), findsNWidgets(2));
    });

    testWidgets('同一メール・同一氏名でも、サーバーの対象100件がそのまま「100件」と表示される(UIで絞らない)', (
      tester,
    ) async {
      setPhone(tester, height: 3000);
      final service = FakeSendService(batches: [committed('batchA', 1, 100)]);
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(find.text('100件'), findsNWidgets(2), reason: '取込件数100・メール対象100');
    });

    testWidgets('有効でない参加者は対象外として別に表示される(対象+対象外=取込件数)', (tester) async {
      setPhone(tester, height: 3000);
      final service = FakeSendService(
        batches: [committed('batchA', 1, 8, excluded: 2)],
      );
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(find.text('10件'), findsOneWidget);
      expect(find.text('8件'), findsOneWidget);
      expect(find.text('2件'), findsOneWidget);
    });

    testWidgets('テンプレートが未設定なら、その旨が表示され、送信ボタンは出ない', (tester) async {
      setPhone(tester, height: 3000);
      final service =
          FakeSendService(
              batches: [
                SendBatch(
                  batchId: 'batchA',
                  sequence: 1,
                  label: '第1回',
                  status: 'committed',
                  importedCount: 5,
                  targetCount: 5,
                  consistent: true,
                  canCreateJob: false,
                  blockedReasons: const ['mail-not-ready'],
                ),
              ],
            )
            ..templateVersion = null
            ..templateReady = false;
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(find.text('当選メールのテンプレート：未設定'), findsOneWidget);
      expect(find.textContaining('当選メールの設定が完了していません'), findsOneWidget);
      expect(find.textContaining('この取込回へ送信'), findsNothing);
    });
  });

  group('プレビュー → 最終確認 → ジョブ作成', () {
    testWidgets(
      'プレビューは既存のプレビューcallable(実送信と同じレンダラー)の結果を表示: 件名・本文・QR・Web参加証URL・version',
      (tester) async {
        setPhone(tester, height: 4000);
        final mail = FakeMailService();
        await tester.pumpWidget(
          sendPage(FakeSendService(batches: [committed('batchA', 1, 5)]), mail),
        );
        await settle(tester);
        await previewFirst(tester);
        expect(mail.previewCalls, ['p001'], reason: 'サーバーが返した先頭の参加者IDが既定');
        expect(find.text('【当選】ご案内'), findsOneWidget);
        expect(find.textContaining('架空 太郎 様'), findsOneWidget);
        expect(find.byKey(const ValueKey('preview-qr')), findsOneWidget);
        expect(
          find.text('https://app.invalid/p/x?publicId=pub_x'),
          findsOneWidget,
        );
        expect(find.textContaining('HTMLメール'), findsOneWidget);
      },
    );

    testWidgets('プレビューを確認するまで送信ボタンは押せない', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)]);
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      final button = find.widgetWithText(FilledButton, 'この取込回へ送信…');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.textContaining('プレビューで完成したメールを確認'), findsOneWidget);
      await previewFirst(tester);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });

    testWidgets('プレビューのテンプレートversionが現在と違う場合は、送信ボタンを有効にしない', (tester) async {
      setPhone(tester, height: 4000);
      final mail = FakeMailService()
        ..preview_ = const WinnerMailPreview(
          ready: true,
          problems: [],
          subject: 's',
          text: 't',
          templateVersion: 2,
        );
      await tester.pumpWidget(
        sendPage(FakeSendService(batches: [committed('batchA', 1, 5)]), mail),
      );
      await settle(tester);
      await previewFirst(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'この取込回へ送信…'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('確認ダイアログにイベント名・batch名・対象人数・テンプレートversionが表示され、キャンセルなら何も作成しない', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 43)]);
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      await previewFirst(tester);
      await tester.tap(find.text('この取込回へ送信…'));
      await settle(tester);
      expect(find.text('当選メールを送信します'), findsOneWidget);
      expect(find.text('イベント：架空イベント'), findsOneWidget);
      expect(find.text('対象：第1回'), findsOneWidget);
      expect(find.text('送信対象：43件'), findsOneWidget);
      expect(find.text('テンプレート：v3'), findsOneWidget);
      await tester.tap(find.text('キャンセル'));
      await settle(tester);
      expect(service.createCalls, 0);
      expect(service.startCalls, 0);
    });

    testWidgets(
      '「送信を開始」で、確認したversionを添えてジョブを1つ作成し、サーバーへ引き渡す(1回)。ブラウザは処理を呼ばず、サーバーの処理が進むと状態が更新される',
      (tester) async {
        setPhone(tester, height: 4000);
        final service = FakeSendService(batches: [committed('batchA', 1, 12)]);
        await tester.pumpWidget(sendPage(service, FakeMailService()));
        await settle(tester);
        await previewFirst(tester);
        await tester.tap(find.text('この取込回へ送信…'));
        await settle(tester);
        expect(find.textContaining('送信はサーバーが行い'), findsOneWidget);
        await tester.tap(find.text('送信を開始'));
        await settle(tester);
        expect(service.createCalls, 1);
        expect(service.expectedVersions, [3]);
        expect(service.startCalls, 1, reason: 'サーバーへの引き渡しは1回');
        expect(find.text('送信状況'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('banner-server-running')),
          findsOneWidget,
        );
        expect(service.serverProcessed, 0, reason: '引き渡しの時点ではメールは送られない');
        // サーバーの定期実行が進める(この画面はpollingで状態を取得するだけ)
        service.serverSweep();
        await tester.pump(poll);
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('count-sent'))).data,
          '12',
        );
        expect(find.byKey(const ValueKey('banner-completed')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('banner-server-running')),
          findsNothing,
        );
      },
    );

    testWidgets('連打しても二重にジョブ作成しない(作成中はボタンが無効)', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)])
        ..createGate = Completer<void>();
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      await previewFirst(tester);
      await tester.tap(find.text('この取込回へ送信…'));
      await settle(tester);
      await tester.tap(find.text('送信を開始'));
      await tester.pump();
      await tester.pump();
      final busyButton = find.widgetWithText(FilledButton, 'ジョブを作成中…');
      expect(busyButton, findsOneWidget);
      expect(tester.widget<FilledButton>(busyButton).onPressed, isNull);
      await tester.tap(busyButton, warnIfMissed: false);
      await tester.pump();
      expect(service.createCalls, 1);
      service.createGate!.complete();
      await settle(tester);
      expect(service.createCalls, 1);
      expect(service.startCalls, 1, reason: '二重に引き渡さない');
    });

    testWidgets('確認した対象人数・テンプレートversionとジョブの内容が違えば、処理を始めない(メールは送らない)', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)])
        ..createTargetOverride = 7;
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      await previewFirst(tester);
      await tester.tap(find.text('この取込回へ送信…'));
      await settle(tester);
      await tester.tap(find.text('送信を開始'));
      await settle(tester);
      expect(service.startCalls, 0);
      expect(find.textContaining('メールは送信していません'), findsOneWidget);
    });

    testWidgets('確認後にテンプレートが更新されていた場合はサーバーが作成を拒否し、理由が表示され、処理も始まらない', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)])
        ..createError = const WinnerSendException(
          '確認したテンプレートのバージョンが変更されています。画面を更新して、もう一度確認してください。',
          code: 'template-version-changed',
        );
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      await previewFirst(tester);
      final listBefore = service.listCalls;
      await tester.tap(find.text('この取込回へ送信…'));
      await settle(tester);
      await tester.tap(find.text('送信を開始'));
      await settle(tester);
      expect(find.textContaining('テンプレートのバージョンが変更されています'), findsOneWidget);
      expect(service.startCalls, 0);
      expect(
        service.listCalls,
        greaterThan(listBefore),
        reason: 'サーバーの状態を再取得する',
      );
    });

    testWidgets('応答が届かなかった場合、サーバーの状態を再取得して既存ジョブを復元する(新規送信を促さない・再作成しない)', (
      tester,
    ) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)])
        ..loseCreateResponse = true;
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      await previewFirst(tester);
      await tester.tap(find.text('この取込回へ送信…'));
      await settle(tester);
      await tester.tap(find.text('送信を開始'));
      await settle(tester);
      expect(find.textContaining('サーバーでは処理が行われている可能性'), findsOneWidget);
      // 再取得の結果: ジョブが存在し、新規送信のボタンは無く、既存の状況を開ける
      expect(find.text('送信状況を開く'), findsOneWidget);
      expect(find.textContaining('この取込回へ送信'), findsNothing);
      expect(service.createCalls, 1);
      expect(service.startCalls, 0, reason: '応答を受け取っていないので勝手に引き渡さない');
    });
  });

  group('送信状況(pending / sending / sent / failed / unknown)', () {
    testWidgets('5つの状態が別々の欄・別の名前で表示され、failedとunknownは混同されない', (tester) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 15)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.pending: 2,
            DeliveryState.sending: 3,
            DeliveryState.sent: 6,
            DeliveryState.failed: 3,
            DeliveryState.unknown: 1,
          }),
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      String count(String s) =>
          tester.widget<Text>(find.byKey(ValueKey('count-$s'))).data!;
      expect(
        [
          count('pending'),
          count('sending'),
          count('sent'),
          count('failed'),
          count('unknown'),
        ],
        ['2', '3', '6', '3', '1'],
      );
      for (final label in ['未送信', '送信中', '送信済み', '失敗', '結果確認が必要']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(DeliveryState.failed.label, isNot(DeliveryState.unknown.label));
      expect(
        deliveryColor(DeliveryState.failed),
        isNot(deliveryColor(DeliveryState.unknown)),
      );
      expect(find.text('この送信ではテンプレートv3を使用', skipOffstage: false), findsNothing);
      expect(find.textContaining('この送信ではv3を使用'), findsOneWidget);
    });

    testWidgets('unknownは「結果確認が必要」と目立つ警告で表示され、「失敗」とは書かない。通常の再送ボタンは出ない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 5)])
        ..seedJob(
          'batchA',
          ids({DeliveryState.sent: 4, DeliveryState.unknown: 1}),
          status: 'completed',
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      final banner = find.byKey(const ValueKey('banner-unknown'));
      expect(banner, findsOneWidget);
      expect(
        find.descendant(of: banner, matching: find.textContaining('結果確認が必要')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: banner,
          matching: find.textContaining('自動では再送されません'),
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, '失敗分だけ再送(1件)'), findsNothing);
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason: '未送信も失敗も無いので、送信系のボタンは出ない',
      );
    });

    testWidgets('sentには再送の操作が無い。完了表示は「全件送信済み」', (tester) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 6)])
        ..seedJob('batchA', ids({DeliveryState.sent: 6}), status: 'completed');
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.textContaining('全 6件 送信済み'), findsOneWidget);
    });

    testWidgets('failedがあれば「失敗分だけ再送」が出る。確認ダイアログでは、sent・unknownは対象外と表示される', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 10)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.sent: 6,
            DeliveryState.failed: 2,
            DeliveryState.unknown: 2,
          }),
          status: 'completed',
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      await tester.tap(find.text('失敗分だけ再送(2件)'));
      await settle(tester);
      expect(find.text('失敗分だけを再送します'), findsOneWidget);
      expect(find.text('再送対象：失敗 2件'), findsOneWidget);
      expect(find.text('送信済み・結果確認が必要な宛先は再送しません。'), findsOneWidget);
      await tester.tap(find.text('キャンセル'));
      await settle(tester);
      expect(service.retryCalls, 0);
    });

    testWidgets(
      '再送: retryFailed(failedだけ) → 処理 → 状態を再取得。sent・unknownは変わらず、再送後にfailedが減る',
      (tester) async {
        setPhone(tester);
        final service = FakeSendService(batches: [committed('batchA', 1, 10)])
          ..seedJob(
            'batchA',
            ids({
              DeliveryState.sent: 6,
              DeliveryState.failed: 2,
              DeliveryState.unknown: 2,
            }),
            status: 'completed',
          );
        await tester.pumpWidget(jobPage(service));
        await settle(tester);
        final getsBefore = service.getJobCalls;
        await tester.tap(find.text('失敗分だけ再送(2件)'));
        await settle(tester);
        await tester.tap(find.text('失敗分を再送'));
        await settle(tester);
        expect(service.retryCalls, 1);
        expect(service.startCalls, 1, reason: '再送もサーバーへ引き渡す(ブラウザは処理しない)');
        expect(service.serverProcessed, 0);
        // サーバーの定期実行が、failedからpendingに戻った分だけを処理する
        service.serverSweep();
        await tester.pump(poll);
        await tester.pump();
        String count(String s) =>
            tester.widget<Text>(find.byKey(ValueKey('count-$s'))).data!;
        expect(
          [count('pending'), count('sent'), count('failed'), count('unknown')],
          ['0', '8', '0', '2'],
          reason: 'sent 6+再送2、unknownは不変',
        );
        expect(
          service.getJobCalls,
          greaterThan(getsBefore),
          reason: '最終状態はサーバーから再取得',
        );
        expect(
          find.widgetWithText(OutlinedButton, '失敗分だけ再送(0件)'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '未送信が残るのに、サーバーが処理していない(未引き渡し・安全停止)場合だけ「サーバーで送信を再開」が出る。確認ダイアログ → 引き渡し1回。ブラウザは処理しない',
      (tester) async {
        setPhone(tester);
        final service = FakeSendService(batches: [committed('batchA', 1, 25)])
          ..seedJob('batchA', ids({DeliveryState.pending: 25}));
        await tester.pumpWidget(jobPage(service));
        await settle(tester);
        expect(
          find.byKey(const ValueKey('banner-server-halted')),
          findsOneWidget,
        );
        expect(find.text('サーバーで送信を再開(25件)'), findsOneWidget);
        await tester.tap(find.text('サーバーで送信を再開(25件)'));
        await settle(tester);
        expect(find.text('未送信：25件'), findsOneWidget);
        expect(find.text('テンプレート：v3'), findsOneWidget);
        await tester.tap(find.text('送信を再開'));
        await settle(tester);
        expect(service.startCalls, 1);
        expect(service.serverProcessed, 0, reason: '処理はサーバーが行う。ブラウザは呼ばない');
        expect(
          find.byKey(const ValueKey('banner-server-running')),
          findsOneWidget,
        );
        expect(
          find.text('サーバーで送信を再開(25件)'),
          findsNothing,
          reason: '引き渡し後は再開ボタンを出さない',
        );
        // サーバーが数回のsweepで最後まで進める(ブラウザの操作なし)
        service.serverSweep(chunk: 10);
        service.serverSweep(chunk: 10);
        service.serverSweep(chunk: 10);
        await tester.pump(poll);
        await tester.pump();
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('count-sent'))).data,
          '25',
        );
        expect(find.byKey(const ValueKey('banner-completed')), findsOneWidget);
      },
    );

    testWidgets('サーバーが停止した理由(安全のための自動停止)が表示され、原因確認後に再開できる', (tester) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 4)])
        ..seedJob('batchA', ids({DeliveryState.pending: 4}))
        ..haltedReason['winner-batchA'] = 'no-progress';
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(find.textContaining('安全のため自動の送信処理を停止しました'), findsOneWidget);
      expect(find.textContaining('一定時間、処理が進みませんでした'), findsOneWidget);
      expect(find.text('サーバーで送信を再開(4件)'), findsOneWidget);
    });

    testWidgets('画面を開いただけ(再読込・別端末)では引き渡しも送信もしない。サーバーが処理中のジョブには再開ボタンが出ない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 4)])
        ..seedJob('batchA', ids({DeliveryState.pending: 4}));
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(service.startCalls, 0, reason: '開くだけでは何もしない');
      await tester.pumpWidget(const SizedBox());
      service.dispatchActive.add('winner-batchA'); // サーバーは処理中
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(service.startCalls, 0);
      expect(
        find.byKey(const ValueKey('banner-server-running')),
        findsOneWidget,
      );
      expect(find.textContaining('サーバーで送信を再開'), findsNothing);
      expect(find.textContaining('この画面を閉じても'), findsWidgets);
    });

    testWidgets(
      'ブラウザを閉じても配送は継続する: 引き渡し後に画面を破棄 → サーバーだけで全件処理 → 別画面(再ログイン相当)で完了を確認できる',
      (tester) async {
        setPhone(tester);
        final service = FakeSendService(batches: [committed('batchA', 1, 30)])
          ..seedJob('batchA', ids({DeliveryState.pending: 30}));
        await tester.pumpWidget(jobPage(service));
        await settle(tester);
        await tester.tap(find.text('サーバーで送信を再開(30件)'));
        await settle(tester);
        await tester.tap(find.text('送信を再開'));
        await settle(tester);
        expect(service.startCalls, 1);
        // ブラウザを閉じる(画面を破棄。以後、UIからの呼び出しは一切ない)
        await tester.pumpWidget(const SizedBox());
        final getsWhileClosed = service.getJobCalls;
        service.serverSweep(chunk: 10);
        service.serverSweep(chunk: 10);
        service.serverSweep(chunk: 10);
        await tester.pump(poll * 3);
        expect(
          service.getJobCalls,
          getsWhileClosed,
          reason: '閉じた画面はpollingしない',
        );
        expect(service.startCalls, 1, reason: '引き渡しは1回だけ。UIが処理を呼ぶことはない');
        expect(service.serverProcessed, 30, reason: 'サーバーだけで全件処理された');
        // 後から別の端末で開く: サーバーの状態(完了)がそのまま表示される
        await tester.pumpWidget(jobPage(service));
        await settle(tester);
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('count-sent'))).data,
          '30',
        );
        expect(find.byKey(const ValueKey('banner-completed')), findsOneWidget);
        expect(service.startCalls, 1);
      },
    );

    testWidgets(
      'pollingが止まっても(画面が古くても)サーバーの配送は継続する。pollingは状態の再取得だけで、処理を起動しない',
      (tester) async {
        setPhone(tester);
        final service = FakeSendService(batches: [committed('batchA', 1, 8)])
          ..seedJob('batchA', ids({DeliveryState.pending: 8}));
        service.dispatchActive.add('winner-batchA');
        await tester.pumpWidget(jobPage(service));
        await tester.pump();
        await tester.pump();
        final before = service.getJobCalls;
        // 画面のpollingは何度動いても、サーバーの処理を進めない(処理はサーバーの定期実行だけ)
        await tester.pump(poll);
        await tester.pump();
        expect(service.getJobCalls, greaterThan(before));
        expect(service.serverProcessed, 0);
        expect(service.startCalls, 0);
        service.serverSweep();
        await tester.pump(poll);
        await tester.pump();
        expect(find.byKey(const ValueKey('banner-completed')), findsOneWidget);
      },
    );

    testWidgets('画面の再読込: サーバーの状態(送信中・送信済み・失敗・結果確認)がそのまま復元される(ローカル状態に依存しない)', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 9)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.sending: 2,
            DeliveryState.sent: 4,
            DeliveryState.failed: 2,
            DeliveryState.unknown: 1,
          }),
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      await tester.pumpWidget(const SizedBox()); // 画面を破棄(ブラウザのリロード相当)
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      String count(String s) =>
          tester.widget<Text>(find.byKey(ValueKey('count-$s'))).data!;
      expect(
        [count('sending'), count('sent'), count('failed'), count('unknown')],
        ['2', '4', '2', '1'],
      );
      expect(find.byKey(const ValueKey('banner-unknown')), findsOneWidget);
    });

    testWidgets('件数の合計が対象数と一致しない場合は「状態を確認できません」。完了扱いにせず、操作もできない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 10)])
        ..seedJob('batchA', ids({DeliveryState.sent: 10}), status: 'completed')
        ..countSkew = 1; // failedが1件多く数えられる(合計11 != 対象10)
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('banner-untrustworthy')),
        findsOneWidget,
      );
      expect(find.textContaining('状態を確認できません'), findsWidgets);
      expect(find.byKey(const ValueKey('banner-completed')), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('処理中(ready)でも、件数の合計が対象数と一致しなければ「状態を確認できません」で、送信・再送の操作を出さない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 10)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.pending: 4,
            DeliveryState.sent: 4,
            DeliveryState.failed: 2,
          }),
        )
        ..countSkew = 1; // 合計11 != 対象10
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('banner-untrustworthy')),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('completedと記録されているのに未送信が残っている不整合も、完了扱いにしない', (tester) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 10)])
        ..seedJob(
          'batchA',
          ids({DeliveryState.sent: 8, DeliveryState.pending: 2}),
          status: 'completed',
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      // 偽サーバーの settle は触れない(completedのまま)。サーバーのconservation判定は使わずクライアントでも検証する。
      expect(
        find.byKey(const ValueKey('banner-untrustworthy')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('banner-completed')), findsNothing);
      expect(find.textContaining('未送信分の送信を続ける'), findsNothing);
    });

    testWidgets(
      'pollingは、処理中(sending)の間だけ間隔を空けて再取得し、完了(終端)したら止まる。Firestoreは使わない',
      (tester) async {
        setPhone(tester);
        final service = FakeSendService(batches: [committed('batchA', 1, 4)])
          ..seedJob(
            'batchA',
            ids({DeliveryState.sending: 2, DeliveryState.sent: 2}),
          );
        await tester.pumpWidget(jobPage(service));
        await tester.pump();
        await tester.pump();
        expect(service.getJobCalls, 1);
        await tester.pump(const Duration(seconds: 2));
        expect(service.getJobCalls, 1, reason: '過剰な頻度では取得しない');
        await tester.pump(poll);
        await tester.pump();
        expect(service.getJobCalls, 2);
        // サーバー側で処理が終わった
        service.states['winner-batchA']!.updateAll(
          (_, v) => DeliveryState.sent,
        );
        service.jobStatus['winner-batchA'] = 'completed';
        await tester.pump(poll);
        await tester.pump();
        expect(service.getJobCalls, 3);
        expect(find.byKey(const ValueKey('banner-completed')), findsOneWidget);
        await tester.pump(poll * 3);
        await tester.pump();
        expect(service.getJobCalls, 3, reason: '終端状態ではpollingを停止');
      },
    );

    testWidgets('sendingだけが残る間は再取得を続け、未送信のみ(誰も処理していない)ならpollingしない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 3)])
        ..seedJob('batchA', ids({DeliveryState.pending: 3}));
      await tester.pumpWidget(jobPage(service));
      await tester.pump();
      await tester.pump();
      await tester.pump(poll * 3);
      await tester.pump();
      expect(service.getJobCalls, 1);
    });

    testWidgets('準備が途中のジョブは「準備を完了する」(冪等なcreate)だけが出て、送信系のボタンは出ない', (
      tester,
    ) async {
      setPhone(tester);
      final service = FakeSendService(batches: [committed('batchA', 1, 3)])
        ..seedJob(
          'batchA',
          ids({DeliveryState.pending: 3}),
          status: 'preparing',
        );
      await tester.pumpWidget(jobPage(service));
      await tester.pump();
      await tester.pump();
      expect(find.text('準備を完了する'), findsOneWidget);
      expect(find.textContaining('サーバーで送信を再開'), findsNothing);
      await tester.tap(find.text('準備を完了する'));
      await tester.pump();
      await tester.pump();
      expect(service.createCalls, 1);
      expect(service.expectedVersions, [3]);
      expect(service.startCalls, 0, reason: '準備の完了は引き渡しではない');
    });

    testWidgets('宛先の一覧: 氏名・参加者ID・状態を表示し、状態で絞り込める。メールアドレスは無い', (tester) async {
      setPhone(tester, height: 4000);
      final service = FakeSendService(batches: [committed('batchA', 1, 6)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.sent: 3,
            DeliveryState.failed: 2,
            DeliveryState.unknown: 1,
          }),
          status: 'completed',
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(find.text('架空 p001'), findsOneWidget);
      expect(find.text('p001'), findsOneWidget);
      expect(find.textContaining('@'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '結果確認が必要'));
      await settle(tester);
      expect(find.text('架空 p006'), findsOneWidget);
      expect(find.text('架空 p001'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '失敗'));
      await settle(tester);
      expect(find.text('架空 p004'), findsOneWidget);
      expect(find.text('架空 p005'), findsOneWidget);
      expect(find.text('架空 p006'), findsNothing);
    });

    testWidgets('100件の一覧はページングで「さらに表示」から全件を取得できる', (tester) async {
      setPhone(tester, height: 20000);
      final service = FakeSendService(
        batches: [committed('batchA', 1, 130)],
      )..seedJob('batchA', ids({DeliveryState.sent: 130}), status: 'completed');
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(find.text('さらに表示'), findsOneWidget);
      await tester.tap(find.text('さらに表示'));
      await settle(tester);
      expect(find.text('架空 p130'), findsOneWidget);
      expect(find.text('さらに表示'), findsNothing);
    });

    testWidgets('390px幅のスマートフォンでも、一覧・状況画面が横スクロール・はみ出しなく表示される', (tester) async {
      setPhone(tester, height: 5000);
      final service = FakeSendService(batches: [committed('batchA', 1, 15)])
        ..seedJob(
          'batchA',
          ids({
            DeliveryState.pending: 2,
            DeliveryState.sending: 3,
            DeliveryState.sent: 6,
            DeliveryState.failed: 3,
            DeliveryState.unknown: 1,
          }),
        );
      await tester.pumpWidget(jobPage(service));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(sendPage(service, FakeMailService()));
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('コンソール(admin専用)', () {
    Widget console(AccessRole role) => MaterialApp(
      home: ConfirmedConsolePage(
        authClient: FakeAuthClient(signedIn: true),
        accessService: FakeAccessService([AccessCheck.granted(role)]),
        winnerSendService: FakeSendService(
          batches: [committed('batchA', 1, 3)],
        ),
        winnerMailService: FakeMailService(),
      ),
    );

    testWidgets('adminには「当選メール送信」が表示され、開ける', (tester) async {
      await tester.pumpWidget(console(AccessRole.admin));
      await settle(tester);
      expect(find.text('当選メール送信'), findsOneWidget);
      expect(find.text('当選メール設定'), findsOneWidget, reason: '既存の設定画面は維持');
      await tester.tap(find.text('当選メール送信'));
      await settle(tester);
      expect(find.text('取込回を読み込む'), findsOneWidget);
    });

    testWidgets('staffには、送信管理も設定も一切表示されない', (tester) async {
      await tester.pumpWidget(console(AccessRole.staff));
      await settle(tester);
      expect(find.text('当選メール送信'), findsNothing);
      expect(find.text('当選メール設定'), findsNothing);
      expect(find.textContaining('送信'), findsNothing);
    });
  });

  group('CallableWinnerSendService', () {
    http.Response json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    CallableWinnerSendService service(
      MockClient client, {
      FakeAuthClient? auth,
    }) => CallableWinnerSendService(
      authClient: auth ?? FakeAuthClient(signedIn: true, token: 'tok'),
      httpClient: client,
      baseUrl: 'https://example.invalid',
    );

    test(
      '作成: IDトークンを送り、eventId・batchId・確認したversionだけを送る。応答をモデルに変換する',
      () async {
        late http.Request seen;
        final s = service(
          MockClient((r) async {
            seen = r;
            return json({
              'result': {
                'jobId': 'winner-batchA',
                'batchId': 'batchA',
                'status': 'ready',
                'templateVersion': 3,
                'targetCount': 5,
                'pendingCount': 5,
                'sendingCount': 0,
                'sentCount': 0,
                'failedCount': 0,
                'unknownCount': 0,
                'alreadyExisted': false,
              },
            }, 200);
          }),
        );
        final job = await s.createJob(
          eventId: 'event1',
          batchId: 'batchA',
          expectedTemplateVersion: 3,
        );
        expect(job.state, JobState.ready);
        expect(job.counts.pending, 5);
        expect(job.trustworthy, isTrue);
        expect(
          seen.url.toString(),
          'https://example.invalid/createConfirmedWinnerMailJob',
        );
        expect(seen.headers['Authorization'], 'Bearer tok');
        expect((jsonDecode(seen.body) as Map)['data'], {
          'eventId': 'event1',
          'batchId': 'batchA',
          'expectedTemplateVersion': 3,
        });
      },
    );

    test(
      '処理・再送・一覧・状態取得の呼び先はPhase 6および新規の管理者用callable(旧mailJobsではない)',
      () async {
        final urls = <String>[];
        final s = service(
          MockClient((r) async {
            urls.add(r.url.path);
            return json({
              'result': {
                'jobId': 'winner-a',
                'batchId': 'a',
                'status': 'ready',
                'templateVersion': 1,
                'targetCount': 1,
                'pendingCount': 1,
                'eventId': 'e',
                'batches': [],
                'job': {
                  'jobId': 'winner-a',
                  'status': 'ready',
                  'counts': {},
                  'conservation': {},
                },
                'items': [],
              },
            }, 200);
          }),
        );
        await s.startDelivery('winner-a');
        await s.retryFailed('winner-a');
        await s.listBatches('e');
        await s.getJob('winner-a', itemStatus: DeliveryState.failed);
        expect(urls, [
          '/startConfirmedWinnerMailDelivery',
          '/retryFailedConfirmedWinnerMails',
          '/listConfirmedWinnerMailBatches',
          '/getConfirmedWinnerMailJob',
        ]);
      },
    );

    test('未ログインなら通信しない。通信エラーは「サーバーでは処理が行われている可能性」と案内し、内部情報を出さない', () async {
      var called = false;
      await expectLater(
        service(
          MockClient((_) async {
            called = true;
            return json({}, 200);
          }),
          auth: FakeAuthClient(signedIn: false),
        ).listBatches('e'),
        throwsA(isA<WinnerSendException>()),
      );
      expect(called, isFalse);
      try {
        await service(
          MockClient((_) async => throw Exception('secret-host')),
        ).createJob(eventId: 'e', batchId: 'b', expectedTemplateVersion: 1);
        fail('throws');
      } on WinnerSendException catch (e) {
        expect(e.message.contains('secret-host'), isFalse);
        expect(e.message, contains('処理が行われている可能性'));
        expect(e.code, 'network');
      }
    });

    test('サーバーのエラーは表示用に変換される(権限・テンプレート変更・committed以外)', () {
      WinnerSendException e(String status, [String? code]) =>
          CallableWinnerSendService.errorFrom(400, {
            'error': {
              'status': status,
              if (code != null) 'details': {'code': code},
            },
          });
      expect(e('PERMISSION_DENIED').message, 'この操作を行う権限がありません。');
      expect(
        e('FAILED_PRECONDITION', 'template-version-changed').message,
        contains('バージョンが変更されています'),
      );
      expect(
        e('FAILED_PRECONDITION', 'batch-not-committed').message,
        contains('committed'),
      );
      expect(e('INTERNAL').message, contains('現在の状態を確認'));
    });

    test(
      '状態の対応: pending/sending/sent/failed/unknown が別々の表示名になり、未知の値は状態不明になる',
      () {
        expect(DeliveryState.values.map((s) => s.value), [
          'pending',
          'sending',
          'sent',
          'failed',
          'unknown',
        ]);
        expect(DeliveryState.values.map((s) => s.label).toSet().length, 5);
        expect(DeliveryState.fromValue('weird'), isNull);
        expect(JobState.values.map((s) => s.value), [
          'preparing',
          'ready',
          'completed',
          'failed',
        ]);
        expect(
          JobState.fromValue('running'),
          isNull,
          reason: '勝手な状態名を作らない。未知の状態は信頼しない',
        );
      },
    );

    test(
      '保存則の判定: 合計一致・completedの条件(pending/sendingなし・sent+failed+unknown==対象)',
      () {
        SendJob job(
          JobState state,
          DeliveryCounts counts,
          int target, {
          bool serverOk = true,
        }) => SendJob(
          jobId: 'j',
          batchId: 'b',
          state: state,
          templateVersion: 1,
          targetCount: target,
          counts: counts,
          serverConsistent: serverOk,
          serverCompletedConsistent: serverOk,
        );
        const ok = DeliveryCounts(
          pending: 0,
          sending: 0,
          sent: 7,
          failed: 2,
          unknown: 1,
        );
        expect(job(JobState.completed, ok, 10).trustworthy, isTrue);
        expect(
          job(JobState.completed, ok, 11).trustworthy,
          isFalse,
          reason: '合計 != 対象',
        );
        expect(
          job(
            JobState.completed,
            const DeliveryCounts(
              pending: 1,
              sending: 0,
              sent: 9,
              failed: 0,
              unknown: 0,
            ),
            10,
          ).trustworthy,
          isFalse,
          reason: 'completedなのに未送信',
        );
        expect(
          job(
            JobState.ready,
            const DeliveryCounts(
              pending: 1,
              sending: 0,
              sent: 9,
              failed: 0,
              unknown: 0,
            ),
            10,
          ).trustworthy,
          isTrue,
        );
        expect(
          job(JobState.completed, ok, 10, serverOk: false).trustworthy,
          isFalse,
          reason: 'サーバーが不整合と判定',
        );
        expect(job(JobState.ready, ok, 0).trustworthy, isFalse);
      },
    );
  });

  group('構造(ソース)の固定', () {
    String read(String path) => File(path).readAsStringSync();
    final files = [
      'winner_send_page',
      'winner_send_job_page',
      'winner_send_service',
    ].map((n) => 'lib/confirmed/$n.dart');

    test(
      'Firestoreを直接読まない・snapshotを使わない(sendJobs/items/mailDeliveriesはcallable経由のみ)',
      () {
        for (final f in files) {
          final source = read(f);
          expect(source.contains('cloud_firestore'), isFalse, reason: f);
          expect(source.contains('snapshots()'), isFalse, reason: f);
          expect(source.contains("collection('"), isFalse, reason: f);
          expect(
            source.contains('mailJobs'),
            isFalse,
            reason: '旧mailJobsは使わない',
          );
        }
      },
    );

    test('クライアントで送信対象者を計算しない(重複排除・除外の処理が無い)。旧の人数フィールドも使わない', () {
      for (final f in files) {
        final source = read(f);
        expect(source.contains('toSet()'), isFalse, reason: f);
        expect(source.contains('distinct'), isFalse, reason: f);
        expect(source.contains('registeredCount'), isFalse, reason: f);
        expect(source.contains('.email'), isFalse, reason: 'メールアドレスは扱わない');
      }
    });

    test(
      'Flutterは配送processorを呼ばない(処理callableの呼び出し・処理ループが無い)。ブラウザは状態表示と引き渡しだけ',
      () {
        for (final f in files) {
          final source = read(f);
          expect(
            source.contains('processConfirmedWinnerMailJob'),
            isFalse,
            reason: f,
          );
          expect(source.contains('processJob'), isFalse, reason: f);
          expect(source.contains('ProcessResult'), isFalse, reason: f);
          expect(
            source.contains('while (mounted)'),
            isFalse,
            reason: '処理ループなし: $f',
          );
        }
        final job = read('lib/confirmed/winner_send_job_page.dart');
        expect(job.contains('startDelivery('), isTrue);
        expect(
          job.contains('Timer.periodic'),
          isFalse,
          reason: 'pollingは1回ずつ再取得(終端・非処理中で止まる)',
        );
      },
    );

    test('サーバーの状態(dispatch)をモデルに反映する: active・停止理由', () {
      final job = SendJob.fromView({
        'jobId': 'winner-a',
        'batchId': 'a',
        'status': 'ready',
        'templateVersion': 1,
        'targetCount': 2,
        'counts': {'pending': 2},
        'conservation': {'consistent': true, 'completedConsistent': true},
        'dispatch': {
          'active': false,
          'haltedReason': 'run-limit',
          'lastRunAt': '2026-11-01T00:00:00.000Z',
        },
      });
      expect(job.dispatchActive, isFalse);
      expect(job.dispatchHaltedReason, 'run-limit');
      expect(job.dispatchLastRunAt, isNotNull);
      expect(
        SendJob.fromView({
          'jobId': 'j',
          'status': 'ready',
          'dispatch': {'active': true},
        }).dispatchActive,
        isTrue,
      );
    });

    test('再送ボタンの条件: unknown・sentを対象にする再送操作が無い(retryFailed=failedだけ)', () {
      final source = read('lib/confirmed/winner_send_job_page.dart');
      final start = source.indexOf('bool get _canRetry');
      final canRetry = source.substring(start, source.indexOf(';', start));
      expect(canRetry.contains('counts.failed > 0'), isTrue);
      expect(canRetry.contains('unknown'), isFalse);
      expect(canRetry.contains('sent'), isFalse);
      expect(source.contains('retryFailed('), isTrue);
    });
  });
}
