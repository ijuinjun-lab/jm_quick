// Phase 11B: confirmed CSV取込の画面・サービス。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて完全な架空。
//  - adminだけ到達でき、イベント表示→ファイル選択→列の対応→プレビュー→内容確認→確定→完了の順でしか進めない
//  - プレビューなしでは確定できず、ファイル・列の対応を変えるとプレビューは無効になる
//  - 二重クリックで確定は1回。通信失敗後は同じ内容(同じbatchId)で再試行でき、完了とは表示しない
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/import_service.dart';
import 'package:jm_quick/confirmed/login_page.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'functions/test/fixtures/import_ui_case.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

PickedCsv _csv([String? text, String name = '架空取込.csv']) => (
  name: name,
  bytes: Uint8List.fromList(utf8.encode(text ?? _fixture['csvText'] as String)),
);

const _event = ImportEventSummary(
  eventId: 'evfixture0123456789',
  eventName: 'PHASE11 STEP3 TEST(架空)',
  startAt: null,
  venue: '架空ホール',
  programs: [
    (programId: 'program-a', name: '架空プログラムA', order: 0),
    (programId: 'program-b', name: '架空プログラムB', order: 1),
    (programId: 'custom-zeta-9', name: '架空プログラムZ', order: 2),
  ],
);

ImportPreview _preview({
  int ready = 3,
  int review = 1,
  int error = 1,
  String? existing,
  int? existingSequence,
}) => ImportPreview.fromJson({
  'batchId': 'b1',
  'totalRecords': 5,
  'totalRows': 4,
  'readyCount': ready,
  'reviewCount': review,
  'errorCount': error,
  'blankRecordCount': 1,
  'participantCandidateCount': ready + review,
  'attendanceCandidateCount': 6,
  'issueCounts': {'row-check-failed': 1, 'count-invalid': 1},
  'sameFileBatches': [],
  if (existing != null)
    'existingBatch': {'status': existing, 'sequence': existingSequence ?? 1},
  'mappingWarnings': [],
  'rows': [
    for (var i = 0; i < ready; i++)
      {
        'sourceRowNumber': 2 + i,
        'importRecordId': 'x',
        'classification': 'ready',
        'issueCodes': [],
        'programIds': ['program-a'],
      },
    for (var i = 0; i < review; i++)
      {
        'sourceRowNumber': 20 + i,
        'importRecordId': 'x',
        'classification': 'review',
        'issueCodes': ['row-check-failed'],
        'programIds': [],
      },
    for (var i = 0; i < error; i++)
      {
        'sourceRowNumber': 30 + i,
        'importRecordId': 'x',
        'classification': 'error',
        'issueCodes': ['count-invalid'],
        'programIds': [],
      },
  ],
});

class FakeImportService implements ImportService {
  FakeImportService({this.previewHandler, this.commitHandler, this.eventError});
  final Future<ImportPreview> Function(ImportRequest)? previewHandler;
  final Future<ImportResult> Function(ImportRequest, List<int>)? commitHandler;
  final ImportException? eventError;
  final List<String> eventCalls = [];
  final List<ImportRequest> previews = [];
  final List<({ImportRequest request, List<int> approved})> commits = [];

  @override
  Future<ImportEventSummary> getEvent(String eventId) async {
    eventCalls.add(eventId);
    if (eventError != null) throw eventError!;
    return _event;
  }

  @override
  Future<ImportPreview> preview(ImportRequest request) async {
    previews.add(request);
    return previewHandler != null ? previewHandler!(request) : _preview();
  }

  @override
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
  }) async {
    commits.add((request: request, approved: approvedReviewRows));
    if (commitHandler != null) {
      return commitHandler!(request, approvedReviewRows);
    }
    return ImportResult.fromJson({
      'batchId': request.batchId,
      'status': 'committed',
      'sequence': 1,
      'label': '第1回',
      'totalRows': 4,
      'totalRecords': 5,
      'createdCount': 3 + approvedReviewRows.length,
      'reviewPendingCount': 1 - approvedReviewRows.length,
      'errorCount': 1,
      'blankRecordCount': 1,
    });
  }
}

Future<void> _open(
  WidgetTester tester,
  FakeImportService service, {
  PickedCsv? Function()? pick,
  double width = 900,
  void Function(BuildContext, String)? onDone,
  String? eventId = 'evfixture0123456789',
}) async {
  await tester.binding.setSurfaceSize(Size(width, 4000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: ConfirmedImportPage(
        eventId: eventId,
        service: service,
        picker: () async => (pick ?? _csv)(),
        onDone: onDone,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _pickAndMap(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pick-file')));
  await tester.pumpAndSettle();
  await _select(tester, 'map-name', '氏名');
  await _select(tester, 'map-email', 'メールアドレス');
  await _select(tester, 'program-count-0', '午前参加人数');
  await _select(tester, 'program-count-1', '午後参加人数');
  await _select(tester, 'program-count-2', 'トークショー人数');
}

Future<void> _preview_(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('run-preview')));
  await tester.tap(find.byKey(const Key('run-preview')));
  await tester.pumpAndSettle();
}

Future<void> _commitDialog(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('commit')));
  await tester.tap(find.byKey(const Key('commit')));
  await tester.pumpAndSettle();
}

void main() {
  group('入口(認可)', () {
    testWidgets('未ログインではログイン画面だけ。権限なし・staffでは取込画面が出ない。adminだけ表示される', (
      tester,
    ) async {
      final service = FakeImportService();
      Widget route(FakeAuthClient auth, FakeAccessService access) =>
          MaterialApp(
            home: ConfirmedImportRoute(
              eventId: 'ev1',
              authClient: auth,
              accessService: access,
              service: service,
              picker: () async => _csv(),
            ),
          );
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        route(FakeAuthClient(signedIn: false), FakeAccessService([])),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfirmedLoginPage), findsOneWidget);
      expect(find.byKey(const Key('pick-file')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([const AccessCheck.denied()]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('権限がありません'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([AccessCheck.granted(AccessRole.staff)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CSVの取込は管理者のみ利用できます'), findsOneWidget);
      expect(find.byKey(const Key('pick-file')), findsNothing);
      expect(service.eventCalls, isEmpty, reason: 'staff・未認証ではイベントの読み込みもしない');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        route(
          FakeAuthClient(signedIn: true),
          FakeAccessService([AccessCheck.granted(AccessRole.admin)]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pick-file')), findsOneWidget);
      expect(service.eventCalls, ['ev1']);
    });
  });

  group('イベントの表示', () {
    testWidgets(
      '取り込み先のイベント名・会場・programを表示する。遷移で渡されたeventIdは固定(別のイベントへ切り替える入力欄はない)',
      (tester) async {
        final service = FakeImportService();
        await _open(tester, service);
        expect(find.text('PHASE11 STEP3 TEST(架空)'), findsOneWidget);
        expect(find.text('架空ホール'), findsOneWidget);
        expect(find.textContaining('架空プログラムA'), findsWidgets);
        expect(find.textContaining('custom-zeta-9'), findsWidgets);
        expect(find.byKey(const Key('event-id')), findsNothing);
        expect(service.eventCalls, ['evfixture0123456789']);
        expect(find.byKey(const Key('pick-file')), findsOneWidget);
      },
    );
    testWidgets(
      'eventIdが無い場合は、イベントID入力欄を出さず、管理画面からやり直す案内だけを表示する(利用者にIDを意識させない)',
      (tester) async {
        final service = FakeImportService();
        await _open(tester, service, eventId: null);
        expect(find.byKey(const Key('event-id')), findsNothing);
        expect(find.byKey(const Key('load-event')), findsNothing);
        expect(find.byKey(const Key('no-event-id-notice')), findsOneWidget);
        expect(find.text('イベント管理画面からCSV取込を選択してください。'), findsOneWidget);
        expect(find.byKey(const Key('back-to-console')), findsOneWidget);
        expect(find.byKey(const Key('pick-file')), findsNothing);
        expect(service.eventCalls, isEmpty, reason: 'eventIdが無ければイベントを問い合わせない');
      },
    );

    testWidgets(
      '読み込めないイベント(legacy・存在しない)では、eventId入力欄を出さずエラー表示のみで、ファイル選択に進めない',
      (tester) async {
        final service = FakeImportService(
          eventError: const ImportException('新方式のイベントを確認できませんでした。'),
        );
        await _open(tester, service, eventId: 'legacy1');
        expect(find.byKey(const Key('event-id')), findsNothing);
        expect(find.byKey(const Key('load-event')), findsNothing);
        expect(find.text('新方式のイベントを確認できませんでした。'), findsOneWidget);
        expect(find.byKey(const Key('pick-file')), findsNothing);
        expect(service.eventCalls, ['legacy1']);
      },
    );

    testWidgets(
      '正常なeventId付きで開くと、イベントを取得した直後にファイル選択が自動で始まる(「CSVファイルを選択」を押さなくてよい)',
      (tester) async {
        final service = FakeImportService();
        await _open(tester, service); // pickは既定(_csv)。ここではpick-fileを一切タップしない。
        expect(service.eventCalls, ['evfixture0123456789']);
        expect(find.text('選択中: 架空取込.csv'), findsOneWidget);
        expect(find.text('5行 / 15列'), findsOneWidget);
        expect(find.text('PHASE11 STEP3 TEST(架空)'), findsOneWidget);
        expect(find.textContaining('架空プログラムA'), findsWidgets);
        // 自動で選ばれたファイルの列は、まだ自動では選ばれていない(要件どおり)
        expect(find.byKey(const Key('map-name')), findsOneWidget);
        expect(
          tester
              .widget<DropdownButtonFormField<String?>>(
                find.byKey(const Key('map-name')),
              )
              .initialValue,
          isNull,
        );
      },
    );

    testWidgets('自動のファイル選択をキャンセルしても画面に留まり、「CSVファイルを選択」から改めて選べる', (
      tester,
    ) async {
      final service = FakeImportService();
      var calls = 0;
      await _open(
        tester,
        service,
        pick: () {
          calls += 1;
          return null; // 自動選択・手動選択とも、常にキャンセルする
        },
      );
      expect(calls, 1, reason: 'イベント読込直後に自動で1回だけ開く');
      expect(find.byKey(const Key('pick-file')), findsOneWidget);
      expect(find.text('CSVファイルを選択'), findsOneWidget);
      expect(
        find.text('PHASE11 STEP3 TEST(架空)'),
        findsOneWidget,
      ); // イベント情報は表示されたまま
      expect(find.byKey(const Key('map-name')), findsNothing);
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '「CSVファイルを選択」から再度、手動で開ける');
      expect(tester.takeException(), isNull);
    });
  });

  group('正常フロー', () {
    testWidgets(
      'ファイル選択→列の対応→プレビュー→(確認が必要な行を承認)→内容確認→確定→完了。確定に送るのはプレビューしたリクエストそのもの',
      (tester) async {
        final service = FakeImportService();
        String? doneEvent;
        await _open(tester, service, onDone: (context, id) => doneEvent = id);
        expect(
          find.byKey(const Key('commit')),
          findsNothing,
          reason: 'プレビュー前は確定できない',
        );
        await _pickAndMap(tester);
        expect(find.text('選択中: 架空取込.csv'), findsOneWidget);
        expect(find.text('5行 / 15列'), findsOneWidget);
        await _preview_(tester);
        expect(service.previews.length, 1);
        expect(service.commits, isEmpty, reason: 'プレビューでは何も確定しない');
        final previewed = service.previews.single;
        expect(previewed.json['eventId'], 'evfixture0123456789');
        expect(previewed.json['totalRecords'], 5);
        expect(find.text('プレビュー結果(まだ取り込まれていません)'), findsOneWidget);
        expect(find.text('取込対象'), findsWidgets);
        expect(find.textContaining('行の確認(区分など)に合いません'), findsWidgets);
        expect(find.text('取り込まれる件数: 3件(取込対象+承認した確認の行)'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('review-20')));
        await tester.tap(find.byKey(const ValueKey('review-20')));
        await tester.pumpAndSettle();
        expect(find.text('取り込まれる件数: 4件(取込対象+承認した確認の行)'), findsOneWidget);
        await _commitDialog(tester);
        expect(find.text('この内容で取り込みます'), findsOneWidget);
        Finder inDialog(String t) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(t),
        );
        expect(inDialog('PHASE11 STEP3 TEST(架空)'), findsOneWidget);
        expect(inDialog('架空取込.csv'), findsOneWidget);
        expect(inDialog('5行'), findsOneWidget);
        expect(inDialog('4件'), findsOneWidget);
        expect(inDialog('1件(取り込まれません)'), findsWidgets);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('午前参加人数'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('メールは送信されません'),
          ),
          findsOneWidget,
        );
        expect(service.commits, isEmpty, reason: '確認ダイアログの間は確定しない');
        await tester.tap(find.text('取込を確定'));
        await tester.pumpAndSettle();
        expect(service.commits.length, 1);
        expect(
          identical(service.commits.single.request, previewed),
          isTrue,
          reason: 'プレビューしたリクエストをそのまま送る(再構成しない)',
        );
        expect(service.commits.single.approved, [20]);
        expect(find.byKey(const Key('result-committed')), findsOneWidget);
        expect(find.text('取込完了'), findsOneWidget);
        expect(find.text('作成した参加者'), findsOneWidget);
        expect(find.text('4件'), findsWidgets);
        expect(find.textContaining('batch識別情報'), findsOneWidget);
        expect(find.textContaining('メールは送信されていません'), findsOneWidget);
        expect(
          find.textContaining('当選メール'),
          findsNothing,
          reason: 'メール送信への案内・自動遷移をしない',
        );
        await tester.ensureVisible(find.byKey(const Key('back-to-event')));
        await tester.tap(find.byKey(const Key('back-to-event')));
        expect(doneEvent, 'evfixture0123456789');
      },
    );

    testWidgets('確認ダイアログでキャンセルすれば確定しない。承認しない確認行は取り込まれない(承認は空)', (tester) async {
      final service = FakeImportService();
      await _open(tester, service);
      await _pickAndMap(tester);
      await _preview_(tester);
      await _commitDialog(tester);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(service.commits, isEmpty);
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commits.single.approved, isEmpty);
    });
  });

  group('プレビュー必須・無効化', () {
    testWidgets('プレビュー前は確定の入口がない。列の対応が不足していればプレビューできず、理由を表示する(サーバーへ送らない)', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(tester, service);
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commit')), findsNothing);
      await _preview_(tester);
      expect(find.textContaining('氏名の列を選択してください'), findsOneWidget);
      expect(service.previews, isEmpty);
    });

    testWidgets('プレビュー後に列の対応・programの選択を変えると、プレビュー結果は消えて確定できなくなる(再プレビューが必要)', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(tester, service);
      await _pickAndMap(tester);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      await _select(tester, 'map-kana', 'かな');
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(find.text('プレビュー結果(まだ取り込まれていません)'), findsNothing);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      expect(service.previews.length, 2);
      await tester.ensureVisible(find.byKey(const Key('program-enabled-2')));
      await tester.tap(find.byKey(const Key('program-enabled-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commit')), findsNothing);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      // 別のファイルを選び直しても無効になり、列の対応も選び直しになる
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(service.commits, isEmpty);
    });

    testWidgets('確認が必要な行の承認を変えても、承認していない行は取り込まれない。取り込める行が0件なら確定できない', (
      tester,
    ) async {
      final service = FakeImportService(
        previewHandler: (_) async => _preview(ready: 0, review: 1, error: 1),
      );
      await _open(tester, service);
      await _pickAndMap(tester);
      await _preview_(tester);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('commit'))).onPressed,
        isNull,
      );
      expect(find.textContaining('取り込める行がありません'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('approve-all')));
      await tester.tap(find.byKey(const Key('approve-all')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('commit'))).onPressed,
        isNotNull,
      );
    });
  });

  group('二重操作・通信失敗', () {
    testWidgets('確定は処理中ボタンが無効で、連打しても送信は1回', (tester) async {
      final release = Completer<void>();
      final service = FakeImportService(
        commitHandler: (r, a) async {
          await release.future;
          return ImportResult.fromJson({
            'batchId': r.batchId,
            'status': 'committed',
            'sequence': 1,
            'createdCount': 3,
          });
        },
      );
      await _open(tester, service);
      await _pickAndMap(tester);
      await _preview_(tester);
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('commit'))).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('commit')), warnIfMissed: false);
      await tester.tap(
        find.byKey(const Key('run-preview')),
        warnIfMissed: false,
      );
      await tester.pump();
      release.complete();
      await tester.pumpAndSettle();
      expect(service.commits.length, 1);
      expect(service.previews.length, 1, reason: '確定中にプレビューし直せない');
    });

    testWidgets('通信失敗(確定の有無が不明)では完了と表示せず、同じ内容(同じbatchId)で再実行できる', (
      tester,
    ) async {
      var attempt = 0;
      final service = FakeImportService(
        commitHandler: (r, a) async {
          attempt++;
          if (attempt == 1) {
            throw const ImportException('通信に失敗しました。', ambiguous: true);
          }
          return ImportResult.fromJson({
            'batchId': r.batchId,
            'status': 'committed',
            'sequence': 1,
            'createdCount': 3,
            'idempotentReplay': true,
          });
        },
      );
      await _open(tester, service);
      await _pickAndMap(tester);
      await _preview_(tester);
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commit-error')), findsOneWidget);
      expect(find.byKey(const Key('result-committed')), findsNothing);
      expect(find.textContaining('完了したか不明'), findsOneWidget);
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commits.length, 2);
      expect(
        service.commits[0].request.batchId,
        service.commits[1].request.batchId,
      );
      expect(
        identical(service.commits[0].request, service.commits[1].request),
        isTrue,
      );
      expect(find.byKey(const Key('result-committed')), findsOneWidget);
      expect(find.textContaining('既存の結果を表示しています'), findsOneWidget);
    });

    testWidgets('failed・committingは「取込完了」ではない。committedだけが完了として表示される', (
      tester,
    ) async {
      for (final status in ['failed', 'committing']) {
        final service = FakeImportService(
          commitHandler: (r, a) async => ImportResult.fromJson({
            'batchId': r.batchId,
            'status': status,
            'sequence': 1,
            'createdCount': 1,
          }),
        );
        await _open(tester, service);
        await _pickAndMap(tester);
        await _preview_(tester);
        await _commitDialog(tester);
        await tester.tap(find.text('取込を確定'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('result-incomplete')),
          findsOneWidget,
          reason: status,
        );
        expect(
          find.byKey(const Key('result-committed')),
          findsNothing,
          reason: status,
        );
        expect(find.text('取込完了'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets(
      'サーバーの拒否(previewの失敗)は理由を表示し、確定へ進めない。既存の取込(committed / 途中)を知らせる',
      (tester) async {
        await _open(
          tester,
          FakeImportService(
            previewHandler: (_) async =>
                throw const ImportException('列の対応(mapping)に問題があります。'),
          ),
        );
        await _pickAndMap(tester);
        await _preview_(tester);
        expect(find.text('列の対応(mapping)に問題があります。'), findsOneWidget);
        expect(find.byKey(const Key('commit')), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await _open(
          tester,
          FakeImportService(
            previewHandler: (_) async =>
                _preview(existing: 'committed', existingSequence: 2),
          ),
        );
        await _pickAndMap(tester);
        await _preview_(tester);
        expect(find.byKey(const Key('existing-committed')), findsOneWidget);
        expect(find.textContaining('第2回'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
        await _open(
          tester,
          FakeImportService(
            previewHandler: (_) async => _preview(existing: 'committing'),
          ),
        );
        await _pickAndMap(tester);
        await _preview_(tester);
        expect(find.byKey(const Key('existing-incomplete')), findsOneWidget);
      },
    );
  });

  group('ファイル・レイアウト', () {
    testWidgets('UTF-8でないCSV・空のCSVは、対応形式を示して拒否し、列の対応に進まない', (tester) async {
      final sjis = (
        name: 'sjis.csv',
        bytes: Uint8List.fromList([0x82, 0xA0, 0x82, 0xA2, 0x0A, 0x82, 0xA0]),
      );
      await _open(tester, FakeImportService(), pick: () => sjis);
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(find.textContaining('UTF-8'), findsWidgets);
      expect(find.byKey(const Key('map-name')), findsNothing);
      expect(find.byKey(const Key('run-preview')), findsNothing);
    });

    testWidgets('列は自動では選ばれない(初期は未選択)。ファイルを選び直すと列の対応も選び直しになる', (tester) async {
      await _open(tester, FakeImportService());
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(find.text('選択してください'), findsWidgets);
      await _select(tester, 'map-name', '氏名');
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String?>>(
              find.byKey(const Key('map-name')),
            )
            .initialValue,
        isNull,
      );
    });

    testWidgets('390px幅でも、取込画面全体(mapping・プレビュー・確認)で重大なoverflowや例外が出ない', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(tester, service, width: 390);
      await _pickAndMap(tester);
      await tester.tap(find.byKey(const Key('add-rowcheck')));
      await tester.pumpAndSettle();
      await _select(tester, 'rowcheck-column-0', '区分');
      await tester.enterText(
        find.byKey(const Key('rowcheck-values-0')),
        '新規申込',
      );
      await _select(tester, 'program-participation-0', '午前参加時間');
      await tester.enterText(
        find.byKey(const Key('program-notattending-0')),
        '参加を希望しない',
      );
      await _preview_(tester);
      await _commitDialog(tester);
      expect(find.text('この内容で取り込みます'), findsOneWidget);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 行の確認・参加の値が、リクエストのmappingに反映される(サーバーの契約どおり)
      final mapping = service.previews.single.json['mapping'] as Map;
      expect(mapping['rowChecks'], [
        {
          'column': '区分',
          'allowedValues': ['新規申込'],
        },
      ]);
      final a = (mapping['programs'] as List).first as Map;
      expect(a['participationColumn'], '午前参加時間');
      expect(a['notAttendingValues'], ['参加を希望しない']);
    });
  });

  group('CallableImportService', () {
    test(
      'IDトークンを送り、previewとcommitは同じリクエスト本体を送る。commitだけに承認した行が付く。publicIdやeventの内容は送らない',
      () async {
        final bodies = <String, Map<String, dynamic>>{};
        final headers = <String, String?>{};
        final service = CallableImportService(
          authClient: FakeAuthClient(signedIn: true, token: 'admin-token'),
          baseUrl: 'https://example.invalid',
          httpClient: MockClient((request) async {
            final name = request.url.pathSegments.last;
            bodies[name] =
                (jsonDecode(request.body) as Map)['data']
                    as Map<String, dynamic>;
            headers[name] = request.headers['Authorization'];
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({
                  'result': name == 'getConfirmedEventSummary'
                      ? {'eventId': 'ev1', 'eventName': '架空', 'programs': []}
                      : {'batchId': 'b1', 'status': 'committed'},
                }),
              ),
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );
        final request = ImportRequest(
          json: {'eventId': 'ev1', 'clientRequestId': 'b1', 'rows': []},
          fileName: 'a.csv',
          batchId: 'b1',
          totalRecords: 0,
        );
        await service.getEvent('ev1');
        await service.preview(request);
        await service.commit(request, approvedReviewRows: [7, 3]);
        await service.commit(request);
        expect(bodies['getConfirmedEventSummary'], {'eventId': 'ev1'});
        expect(
          bodies['previewConfirmedImport']!.containsKey('approvedReviewRows'),
          isFalse,
        );
        expect(
          bodies['commitConfirmedImport']!.keys.contains('clientRequestId'),
          isTrue,
        );
        for (final h in headers.values) {
          expect(h, 'Bearer admin-token');
        }
      },
    );
    test(
      '未ログインなら通信しない。エラーは表示用に変換され、通信失敗・5xx・commit-interruptedは「不明(再実行は安全)」',
      () async {
        var requests = 0;
        final signedOut = CallableImportService(
          authClient: FakeAuthClient(signedIn: false, token: null),
          httpClient: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        await expectLater(
          signedOut.getEvent('x'),
          throwsA(isA<ImportException>()),
        );
        expect(requests, 0);
        ImportException map(int status, Map<String, dynamic> error) =>
            CallableImportService.errorFrom(status, {'error': error});
        expect(
          map(403, {'status': 'PERMISSION_DENIED'}).message,
          contains('権限'),
        );
        expect(
          map(400, {
            'status': 'INVALID_ARGUMENT',
            'details': {'code': 'invalid-mapping'},
          }).message,
          contains('列の対応'),
        );
        expect(
          map(409, {
            'status': 'ALREADY_EXISTS',
            'details': {'code': 'batch-content-mismatch'},
          }).message,
          contains('異なる内容'),
        );
        final interrupted = map(500, {
          'status': 'INTERNAL',
          'details': {'code': 'commit-interrupted'},
        });
        expect(interrupted.ambiguous, isTrue);
        expect(interrupted.message, contains('続きから'));
        final server = map(500, {
          'status': 'INTERNAL',
          'message': 'secret-internal-path/firestore',
        });
        expect(server.ambiguous, isTrue);
        expect(server.message.contains('secret'), isFalse);
        expect(map(412, {'status': 'FAILED_PRECONDITION'}).ambiguous, isFalse);
      },
    );
  });

  group('境界の静的検査', () {
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    final files = [
      'lib/confirmed/import_models.dart',
      'lib/confirmed/import_service.dart',
      'lib/confirmed/import_page.dart',
    ];
    test('取込のコードはFirestoreを直接使わず、publicIdを生成せず、メール送信・配送を起動しない', () {
      for (final path in files) {
        final text = code(path);
        for (final forbidden in [
          'cloud_firestore',
          'FirebaseFirestore',
          '.snapshots(',
          '.collection(',
          'FieldValue',
          'publicId',
          'randomPublicId',
          'sendJobs',
          'mailDeliveries',
          'mailLogs',
          'reminderEnabled',
          "'sendParticipantMail'",
          'createConfirmedWinnerMailJob',
          'processConfirmedWinnerMailJob',
          'startConfirmed',
        ]) {
          expect(
            text.contains(forbidden),
            isFalse,
            reason: '$path: $forbidden',
          );
        }
      }
    });
    test('人物単位の統合(メール・氏名・参照コードによるdedupe)をしない。1行=1参加者', () {
      for (final path in files) {
        final text = code(path).toLowerCase();
        for (final forbidden in [
          'dedupe',
          'duplicate',
          'identitykey',
          'toset()',
          'distinct',
          'unique',
        ]) {
          // 列名の重複検査(同じ列を2回選ぶ設定ミス)と、参考表示のための値の一覧だけは別
          if (forbidden == 'toset()') continue;
          expect(
            text.contains(forbidden),
            isFalse,
            reason: '$path: $forbidden',
          );
        }
      }
    });
    test('取込画面は完了後に、当選メール送信など別機能へ自動遷移しない(戻り先は新方式の管理画面だけ)', () {
      final text = code('lib/confirmed/import_page.dart');
      expect(text.contains('winner_send'), isFalse);
      expect(text.contains('WinnerSendPage'), isFalse);
      expect(text.contains("'/console?eventId="), isTrue);
    });
    test('legacyの取込(csv_import_service)とは経路を共有しない', () {
      for (final path in files) {
        expect(
          code(path).contains('csv_import_service'),
          isFalse,
          reason: path,
        );
        expect(code(path).contains('demo_repository'), isFalse, reason: path);
      }
    });
    test('eventIdを利用者へ入力・選択させるUI(テキスト欄・読込ボタン)は存在しない', () {
      final text = code('lib/confirmed/import_page.dart');
      for (final forbidden in [
        "Key('event-id')",
        "Key('load-event')",
        'イベントID',
        'イベントを読み込む',
      ]) {
        expect(text.contains(forbidden), isFalse, reason: forbidden);
      }
      // eventIdはNavigator経由(widget.eventId)でだけ受け取る。
      expect(text.contains('widget.eventId'), isTrue);
    });
    test('サーバーの上限(行数5000・値2000文字・列60)と同じ値を使う', () {
      expect(
        (importMaxRows, importMaxValueLength, importMaxHeaders),
        (5000, 2000, 60),
      );
      final serverSource = File(
        'functions/confirmed/import_request.js',
      ).readAsStringSync();
      expect(serverSource, contains('MAX_ROWS = 5000'));
      expect(serverSource, contains('MAX_VALUE_LENGTH = 2000'));
      expect(serverSource, contains('MAX_HEADERS = 60'));
    });
  });
}
