// Phase 11B-4: confirmed CSV取込の画面・サービス。通信はすべて差し替え(外部通信0)、Firestoreは使わない。データはすべて完全な架空。
//  - adminだけ到達でき、イベント表示→CSVファイル選択→自動解析→プレビュー→内容確認→確定→完了の順でしか進めない
//  - 通常運用ではCSVの列を利用者に選ばせない(mapping UIは表示しない)。CSVのheaderが今年度の正式フォーマットと
//    一致しない場合は、プレビュー前に明確に拒否する
//  - プレビューなしでは確定できず、ファイルを選び直すとプレビューは無効になる
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
import 'package:jm_quick/confirmed/import_profile.dart';
import 'package:jm_quick/confirmed/import_service.dart';
import 'package:jm_quick/confirmed/login_page.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;

// 今年度の正式フォーマット(sipposample形式)向けの、完全な架空CSV(20列。実CSVの主要列+未使用列)。
const List<String> _headers = [
  '区分', 'rd', '氏名', 'かな', 'メールアドレス', '都道府県', '性別', '年代',
  '午前参加時間', '午前参加人数', '午前相談', '午後参加時間', '午後参加人数', '午後相談',
  'トークショー', 'トークショー人数', 'キャンセル待希望枠', 'キャンセル待希望人数', '登録日時', '備考',
];

String _row(int i) => [
  '新規申込', 'R$i', '架空参加者$i', 'かくうさんかしゃ', 'sippo$i@example.invalid',
  '架空県', '未回答', '未回答', '10:00-11:00', '2', '', '13:00-14:00', '1', '',
  '参加を希望する', '1', '', '', '2026年01月02日 03時04分05秒', '',
].join(',');

/// 5レコード(通常2件・空1件・通常2件)。header名だけで自動解析できる、今年度の正式フォーマット。
String _defaultCsvText() {
  final blank = List.filled(_headers.length, '').join(',');
  final rows = [_row(1), _row(2), blank, _row(3), _row(4)];
  return '${_headers.join(',')}\n${rows.join('\n')}\n';
}

PickedCsv _csv([String? text, String name = '架空取込.csv']) => (
  name: name,
  bytes: Uint8List.fromList(utf8.encode(text ?? _defaultCsvText())),
);

const _event = ImportEventSummary(
  eventId: 'evfixture0123456789',
  eventName: 'PHASE11 STEP3 TEST(架空)',
  startAt: null,
  venue: '架空ホール',
  programs: [
    (programId: 'program-1', name: '架空プログラムA', order: 0),
    (programId: 'program-2', name: '架空プログラムB', order: 1),
    (programId: 'program-3', name: '架空プログラムZ', order: 2),
  ],
);

/// program-1/2/3を持たないイベント(このprofileでは取込に対応していない)。
const _eventWithoutProfilePrograms = ImportEventSummary(
  eventId: 'evother0123456789',
  eventName: '別方式のイベント(架空)',
  startAt: null,
  venue: '架空ホール2',
  programs: [(programId: 'program-x', name: '架空プログラムX', order: 0)],
);

ImportPreview _preview({
  int ready = 3,
  int review = 1,
  int error = 0,
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
        'programIds': ['program-1'],
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

/// プレビューの応答と同じ行の判定を持つ検証結果(サーバーでは同じ計画から作られる)。重複などの追加の指摘は無い。
ImportValidation _validationFromPreview(ImportPreview p) {
  String resultOf(RowClass c) => switch (c) {
    RowClass.ready => 'ok',
    RowClass.review => 'warning',
    RowClass.error => 'error',
  };
  final findingCounts = <String, int>{};
  for (final r in p.rows) {
    for (final c in r.issueCodes.toSet()) {
      findingCounts[c] = (findingCounts[c] ?? 0) + 1;
    }
  }
  return ImportValidation.fromJson({
    'batchId': p.batchId,
    'totalRecords': p.totalRecords,
    'totalRows': p.totalRows,
    'blankRecordCount': p.blankRecordCount,
    'okCount': p.readyCount,
    'warningCount': p.reviewCount,
    'errorCount': p.errorCount,
    'findingCounts': findingCounts,
    'nextImportSequence': 2,
    'participationTypes': p.participationTypes,
    'rows': [
      for (final r in p.rows)
        {
          'sourceRowNumber': r.sourceRowNumber,
          'classification': r.classification.value,
          'result': resultOf(r.classification),
          'findings': [
            for (final c in r.issueCodes)
              {'code': c, 'severity': resultOf(r.classification)},
          ],
          'programIds': r.programIds,
          'participationType': r.participationType,
        },
    ],
  });
}

class FakeImportService implements ImportService {
  FakeImportService({this.previewHandler, this.commitHandler, this.eventError, this.event, this.validateHandler});
  final Future<ImportPreview> Function(ImportRequest)? previewHandler;
  final Future<ImportResult> Function(ImportRequest, List<int>)? commitHandler;
  final Future<ImportValidation> Function(ImportRequest)? validateHandler;
  final ImportException? eventError;
  final ImportEventSummary? event;
  final List<String> eventCalls = [];
  final List<ImportRequest> validations = [];
  final List<ImportRequest> previews = [];
  final List<({ImportRequest request, List<int> approved})> commits = [];
  /// commitに渡された検証結果と、管理者の明示的な許可。
  final List<({ImportValidation? validation, bool existing, bool csv, List<String> keys})> commitAuth = [];

  @override
  Future<ImportValidation> validate(ImportRequest request) async {
    validations.add(request);
    if (validateHandler != null) return validateHandler!(request);
    ImportPreview source;
    try {
      source = previewHandler != null ? await previewHandler!(request) : _preview();
    } catch (_) {
      source = _preview();
    }
    return _validationFromPreview(source);
  }

  @override
  Future<ImportEventSummary> getEvent(String eventId) async {
    eventCalls.add(eventId);
    if (eventError != null) throw eventError!;
    return event ?? _event;
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
    ImportValidation? validation,
    bool acknowledgeExistingEmailDuplicates = false,
    bool acknowledgeCsvEmailDuplicates = false,
    List<String> approvalKeys = const [],
  }) async {
    commits.add((request: request, approved: approvedReviewRows));
    commitAuth.add((validation: validation, existing: acknowledgeExistingEmailDuplicates, csv: acknowledgeCsvEmailDuplicates, keys: approvalKeys));
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

/// CSVファイルを選ぶだけ(通常運用では列を選ぶ操作は無い。イベント読込直後に自動でも開くが、
/// テストでは明示的に選び直すケースのために残す)。
Future<void> _pick(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pick-file')));
  await tester.pumpAndSettle();
}

Future<void> _validate(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('run-validate')));
  await tester.tap(find.byKey(const Key('run-validate')));
  await tester.pumpAndSettle();
}

/// 検証 → プレビュー(検証で必要な確認・許可があれば済ませる)。
Future<void> _preview_(WidgetTester tester) async {
  await _validate(tester);
  for (final key in ['allow-all-review', 'ack-existing-duplicates', 'ack-csv-duplicates', 'ack-new-import']) {
    if (find.byKey(Key(key)).evaluate().isNotEmpty) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }
  }
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
  testWidgets('参加タイプ7集計と各行の結果を既存集計と併記する', (tester) async {
    const values = ['dog', 'cat', 'dog_cat', 'talk', 'dog_talk', 'cat_talk', 'dog_cat_talk'];
    const labels = ['① 犬のみ', '② 猫のみ', '③ 犬＋猫', '④ トークショーのみ', '⑤ 犬＋トークショー', '⑥ 猫＋トークショー', '⑦ 犬＋猫＋トークショー'];
    final service = FakeImportService(previewHandler: (_) async => ImportPreview.fromJson({
      'batchId': 'b1', 'totalRecords': 7, 'totalRows': 7, 'readyCount': 7,
      'participationTypes': [for (var i = 0; i < 7; i++) {'value': values[i], 'label': labels[i], 'count': 1}],
      'rows': [for (var i = 0; i < 7; i++) {
        'sourceRowNumber': i + 2, 'classification': 'ready', 'participationType': values[i],
        'programIds': [
          if (values[i].contains('cat')) 'program-1',
          if (values[i].contains('dog')) 'program-2',
          if (values[i].contains('talk')) 'program-3',
        ],
      }],
    }));
    await _open(tester, service, pick: () => _csv('${_headers.join(',')}\n${List.generate(7, (i) => _row(i + 1)).join('\n')}\n'));
    await _preview_(tester);
    await tester.ensureVisible(find.byKey(const Key('ready-rows')));
    await tester.tap(find.text('取込対象の行(7件)'));
    await tester.pumpAndSettle();
    for (final label in labels) {
      // 検証結果とプレビューの両方に、同じ参加タイプ別の集計が出る
      expect(find.text(label), findsNWidgets(2));
      expect(find.textContaining('参加タイプ: $label'), findsOneWidget);
    }
    for (final label in ['CSV総行数', '空の行', '確認が必要(検証画面で許可済み)', 'program別予定', 'タイプ未確定']) {
      expect(find.text(label), findsWidgets);
    }
  });

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
        expect(find.textContaining('program-3'), findsWidgets);
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
      'このprofileが想定するprogram(program-1/2/3)が無いイベントでは、CSVファイル選択に進めず理由を表示する(ハードコードした特別扱いはしない。データの突合で検出する)',
      (tester) async {
        final service = FakeImportService(event: _eventWithoutProfilePrograms);
        var picked = 0;
        await _open(
          tester,
          service,
          eventId: 'evother0123456789',
          pick: () {
            picked += 1;
            return _csv();
          },
        );
        expect(find.byKey(const Key('event-program-mismatch')), findsOneWidget);
        expect(find.textContaining('program-1'), findsWidgets);
        expect(find.byKey(const Key('pick-file')), findsNothing);
        expect(picked, 0, reason: 'programが揃っていなければファイル選択を自動でも開かない');
      },
    );

    testWidgets(
      '正常なeventId付きで開くと、イベントを取得した直後にファイル選択が自動で始まる(「CSVファイルを選択」を押さなくてよい)',
      (tester) async {
        final service = FakeImportService();
        await _open(tester, service); // pickは既定(_csv)。ここではpick-fileを一切タップしない。
        expect(service.eventCalls, ['evfixture0123456789']);
        expect(find.text('選択中: 架空取込.csv'), findsOneWidget);
        expect(find.text('5行 / ${_headers.length}列'), findsOneWidget);
        expect(find.text('PHASE11 STEP3 TEST(架空)'), findsOneWidget);
        expect(find.textContaining('架空プログラムA'), findsWidgets);
        // CSVの列は自動で認識され、選ぶ操作は不要(mapping UIを表示しない)
        expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget);
        // 次の操作は「検証」。検証の前はプレビューへ進めない
        expect(find.byKey(const Key('run-validate')), findsOneWidget);
        expect(find.byKey(const Key('run-preview')), findsNothing);
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
      expect(find.byKey(const Key('auto-mapping-ok')), findsNothing);
      await tester.tap(find.byKey(const Key('pick-file')));
      await tester.pumpAndSettle();
      expect(calls, 2, reason: '「CSVファイルを選択」から再度、手動で開ける');
      expect(tester.takeException(), isNull);
    });
  });

  group('対応していないCSV(通常のUIで列mappingをさせず、header名で判定する)', () {
    testWidgets('必要な列が欠けているCSVは、プレビュー前に明確に拒否し、不足している列を表示する', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(
        tester,
        service,
        pick: () => _csv('氏名,メールアドレス\n架空太郎,taro@example.invalid\n', '旧形式.csv'),
      );
      expect(find.byKey(const Key('format-error')), findsOneWidget);
      expect(find.textContaining('対応している参加者リストの形式ではありません'), findsOneWidget);
      // 不足している列名を確認できる(個人情報ではないので表示してよい)
      expect(find.byKey(const Key('missing-header-かな')), findsOneWidget);
      expect(find.byKey(const Key('missing-header-午前参加人数')), findsOneWidget);
      expect(find.byKey(const Key('auto-mapping-ok')), findsNothing);
      expect(find.byKey(const Key('run-preview')), findsNothing);
      expect(service.previews, isEmpty);
    });

    testWidgets('列順が変わっても、header名だけで自動解析できる(拒否されない)', (tester) async {
      final shuffledHeaders = [..._headers.reversed];
      final row1 = _row(1).split(',');
      final shuffledRow = [
        for (final h in shuffledHeaders) row1[_headers.indexOf(h)],
      ].join(',');
      await _open(
        tester,
        FakeImportService(),
        pick: () => _csv('${shuffledHeaders.join(',')}\n$shuffledRow\n'),
      );
      expect(find.byKey(const Key('format-error')), findsNothing);
      expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget);
    });

    testWidgets('余分な列(このフォーマットの中の未使用列)があっても、対応している形式として受け入れる', (
      tester,
    ) async {
      final extraHeaders = [..._headers, '未知の自由記述列'];
      final row1 = '${_row(1)},何かの値';
      await _open(
        tester,
        FakeImportService(),
        pick: () => _csv('${extraHeaders.join(',')}\n$row1\n'),
      );
      expect(find.byKey(const Key('format-error')), findsNothing);
      expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget);
    });
  });

  group('正常フロー', () {
    testWidgets(
      'ファイル選択→自動解析→プレビュー→(確認が必要な行を承認)→内容確認→確定→完了。確定に送るのはプレビューしたリクエストそのもの',
      (tester) async {
        final service = FakeImportService();
        String? doneEvent;
        await _open(tester, service, onDone: (context, id) => doneEvent = id);
        expect(
          find.byKey(const Key('commit')),
          findsNothing,
          reason: 'プレビュー前は確定できない',
        );
        expect(find.text('選択中: 架空取込.csv'), findsOneWidget);
        expect(find.text('5行 / ${_headers.length}列'), findsOneWidget);
        await _preview_(tester);
        expect(service.previews.length, 1);
        expect(service.commits, isEmpty, reason: 'プレビューでは何も確定しない');
        final previewed = service.previews.single;
        expect(previewed.json['eventId'], 'evfixture0123456789');
        // 列mappingは利用者の操作なしで自動的に組み立てられ、参加/不参加を示す実際の判定に使う
        // participationColumn等が、サーバーの契約どおりに設定される。
        final mapping = previewed.json['mapping'] as Map;
        final programs = mapping['programs'] as List;
        final program1 = programs.first as Map;
        expect(program1['programId'], 'program-1');
        expect(program1['participationColumn'], '午前参加時間');
        expect(program1['countColumn'], '午前参加人数');
        expect(find.text('プレビュー結果(まだ取り込まれていません)'), findsOneWidget);
        expect(find.text('取込対象'), findsWidgets);
        expect(find.textContaining('行の確認(区分など)に合いません'), findsWidgets);
        // 確認が必要な行(20行目)は検証画面で許可した(プレビューでは許可済みとして表示するだけ)
        expect(find.text('20行目: 許可済み'), findsOneWidget);
        expect(find.text('取り込まれる件数: 4件(取込対象+許可した確認の行)'), findsOneWidget);
        // program別予定が表示される(programIdとCSV列名を利用者へ結び付けさせる操作は無いが、結果は見える)
        expect(find.byKey(const Key('program-summary-program-1')), findsOneWidget);
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
        expect(inDialog('0件(取り込まれません)'), findsWidgets, reason: '今回の取込から除外した行');
        expect(inDialog('確認が必要な行1件を許可して取り込みます'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('program別予定'),
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

    testWidgets('確認ダイアログでキャンセルすれば確定しない。確認が必要な行が無ければ許可は空', (tester) async {
      final service = FakeImportService(previewHandler: (_) async => _preview(review: 0));
      await _open(tester, service);
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

  group(
    'Phase 11G: 確認が必要な行の表示(データ矛盾は具体的な日本語、内部コード・programIdは出さない)',
    () {
      // 午後の譲渡会(program-2)が「参加を希望しない」なのに人数が2になっている行(実CSVで確認した矛盾パターン)。
      String reviewCsv() {
        final blank = List.filled(_headers.length, '').join(',');
        final row = [
          '新規申込', 'R1', '架空参加者1', 'かくうさんかしゃ', 'sippo1@example.invalid',
          '架空県', '未回答', '未回答', '', '', '', '参加を希望しない', '2', '',
          '参加を希望しない', '', '', '', '2026年01月02日 03時04分05秒', '',
        ].join(',');
        return '${_headers.join(',')}\n$row\n$blank\n';
      }

      ImportPreview notAttendingCountPreview() => ImportPreview.fromJson({
        'batchId': 'b1',
        'totalRecords': 2,
        'totalRows': 1,
        'readyCount': 0,
        'reviewCount': 1,
        'errorCount': 0,
        'blankRecordCount': 1,
        'participantCandidateCount': 1,
        'attendanceCandidateCount': 0,
        'issueCounts': {'not-attending-count-present': 1},
        'sameFileBatches': [],
        'mappingWarnings': [],
        'rows': [
          {
            'sourceRowNumber': 2,
            'importRecordId': 'x',
            'classification': 'review',
            'issueCodes': ['not-attending-count-present'],
            'programIds': [],
          },
        ],
      });

      testWidgets(
        '「不参加なのに人数あり」は、program名と人数を使った具体的な日本語になる(内部コード・programIdは出さない)',
        (tester) async {
          final service = FakeImportService(
            previewHandler: (_) async => notAttendingCountPreview(),
          );
          await _open(tester, service, pick: () => _csv(reviewCsv()));
          await _preview_(tester);
          expect(
            find.text(
              '架空プログラムBは『参加を希望しない』となっていますが、参加人数が2名になっています。内容を確認してください。',
            ),
            findsOneWidget,
          );
          // 確認行そのもの(チェックボックスの説明文)には、内部コード・programIdを出さない
          // (画面上部の「取り込み先のイベント」情報(programId表示)は、この確認理由とは別の既存表示のため対象外)。
          final reviewRowText = find.descendant(
            of: find.byKey(const Key('review-2')),
            matching: find.byType(Text),
          );
          final texts = tester
              .widgetList<Text>(reviewRowText)
              .map((t) => t.data ?? '')
              .join('\n');
          expect(texts.contains('not-attending-count-present'), isFalse);
          expect(texts.contains('program-2'), isFalse);
        },
      );

      testWidgets(
        'program別予定は「確定できる予定」と「確認が必要」を分けて表示する(確認待ちを除外した数字を全体の予定に見せない)',
        (tester) async {
          final service = FakeImportService(
            previewHandler: (_) async => notAttendingCountPreview(),
          );
          await _open(tester, service, pick: () => _csv(reviewCsv()));
          await _preview_(tester);
          // 確定できる予定は0(このCSVの1行は不参加のため、どのprogramにも参加候補が無い)。
          expect(
            find.textContaining('確定できる予定: 0人 / 0 participant'),
            findsWidgets,
          );
          // データ矛盾の行はどのprogramへも参加候補にならない(サーバーはattendanceを作らない)ため、
          // program別の「確認が必要」件数には出ない(行自体は下の確認リストに残る)。
          expect(find.byKey(const Key('review-2')), findsOneWidget);
        },
      );
    },
  );

  group('プレビュー必須・無効化', () {
    testWidgets('プレビュー前は確定の入口がない', (tester) async {
      final service = FakeImportService();
      await _open(tester, service);
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(service.previews, isEmpty);
    });

    testWidgets('プレビュー後にファイルを選び直すと、プレビュー結果は消えて確定できなくなる(再プレビューが必要)', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(tester, service);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      await _pick(tester);
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(find.text('プレビュー結果(まだ取り込まれていません)'), findsNothing);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      expect(service.previews.length, 2);
      expect(service.commits, isEmpty);
    });

    testWidgets('確認が必要な行を許可しないとプレビューへ進めない。許可を外すとプレビューは無効になる', (
      tester,
    ) async {
      final service = FakeImportService(
        previewHandler: (_) async => _preview(ready: 0, review: 1),
      );
      await _open(tester, service);
      await _validate(tester);
      bool previewEnabled() => tester.widget<FilledButton>(find.byKey(const Key('run-preview'))).onPressed != null;
      expect(previewEnabled(), isFalse);
      expect(find.textContaining('確認待ち1件'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('allow-20')));
      await tester.tap(find.byKey(const ValueKey('allow-20')));
      await tester.pumpAndSettle();
      expect(previewEnabled(), isTrue);
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.byKey(const Key('commit'))).onPressed, isNotNull);
      await tester.ensureVisible(find.byKey(const ValueKey('allow-20')));
      await tester.tap(find.byKey(const ValueKey('allow-20')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('commit')), findsNothing, reason: '許可を変えたらプレビューはやり直し');
      expect(previewEnabled(), isFalse);
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
                throw const ImportException('サーバーで内容を確認できませんでした。'),
          ),
        );
        await _preview_(tester);
        expect(find.text('サーバーで内容を確認できませんでした。'), findsOneWidget);
        expect(find.byKey(const Key('commit')), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await _open(
          tester,
          FakeImportService(
            previewHandler: (_) async =>
                _preview(existing: 'committed', existingSequence: 2),
          ),
        );
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
        await _preview_(tester);
        expect(find.byKey(const Key('existing-incomplete')), findsOneWidget);
      },
    );
  });

  group('ファイル・レイアウト', () {
    testWidgets('UTF-8でないCSV・空のCSVは、対応形式を示して拒否し、プレビューに進まない', (tester) async {
      final sjis = (
        name: 'sjis.csv',
        bytes: Uint8List.fromList([0x82, 0xA0, 0x82, 0xA2, 0x0A, 0x82, 0xA0]),
      );
      await _open(tester, FakeImportService(), pick: () => sjis);
      await _pick(tester);
      expect(find.textContaining('UTF-8'), findsWidgets);
      expect(find.byKey(const Key('auto-mapping-ok')), findsNothing);
      expect(find.byKey(const Key('run-preview')), findsNothing);
    });

    testWidgets('ファイルを選び直すと、自動解析もプレビューもやり直しになる', (tester) async {
      await _open(tester, FakeImportService());
      expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget);
      await _preview_(tester);
      expect(find.byKey(const Key('commit')), findsOneWidget);
      await _pick(tester);
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget, reason: '選び直した新しいファイルはまた自動解析される');
    });

    testWidgets('390px幅でも、取込画面全体(自動解析・プレビュー・確認)で重大なoverflowや例外が出ない', (
      tester,
    ) async {
      final service = FakeImportService();
      await _open(tester, service, width: 390);
      expect(find.byKey(const Key('auto-mapping-ok')), findsOneWidget);
      await _preview_(tester);
      await _commitDialog(tester);
      expect(find.text('この内容で取り込みます'), findsOneWidget);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 参加/不参加の実際の判定に使うmapping(サーバーの契約どおり)が、利用者の操作なしで送られる。
      final mapping = service.previews.single.json['mapping'] as Map;
      final program1 = (mapping['programs'] as List).first as Map;
      expect(program1['countColumn'], '午前参加人数');
      expect(program1['slotColumn'], '午前参加時間');
      expect(program1['participationColumn'], '午前参加時間');
      expect(program1['notAttendingValues'], ['参加を希望しない']);
      final program3 = (mapping['programs'] as List)[2] as Map;
      expect(program3['participationColumn'], 'トークショー');
      expect(program3['attendingValues'], ['参加を希望する']);
    });
  });

  group('検証ステップ(CSV選択 → 検証 → プレビュー → 取込確定)', () {
    // 既定のCSV(_defaultCsvText)のデータ行: 2,3,5,6行目(4行目は空)。メールは sippo1〜4@example.invalid。
    Map<String, dynamic> vrow(
      int n,
      String classification,
      String result,
      List<Map<String, dynamic>> findings, {
      List<int> duplicateRows = const [],
      String? type,
      Map<String, String>? keys,
    }) => {
      'approvalKeys': ?keys,
      'sourceRowNumber': n,
      'classification': classification,
      'result': result,
      'findings': findings,
      'programIds': ['program-1'],
      'duplicateRows': duplicateRows,
      'participationType': type,
    };
    Map<String, dynamic> f(String code, String severity, [String? programId]) => {
      'code': code,
      'severity': severity,
      'programId': ?programId,
    };
    ImportValidation validationOf(
      List<Map<String, dynamic>> rows, {
      int existingDup = 0,
      int csvDup = 0,
      Map<String, dynamic>? existingBatch,
      List<Map<String, dynamic>> types = const [],
      int? next,
    }) {
      final nextSequence = next ?? (existingBatch == null ? 1 : 2);
      final counts = <String, int>{};
      for (final r in rows) {
        for (final c in {for (final x in r['findings'] as List) (x as Map)['code'] as String}) {
          counts[c] = (counts[c] ?? 0) + 1;
        }
      }
      int count(String result) => rows.where((r) => r['result'] == result).length;
      return ImportValidation.fromJson({
        'batchId': 'b-base',
        'totalRecords': 5,
        'totalRows': rows.length,
        'blankRecordCount': 1,
        'okCount': count('ok'),
        'warningCount': count('warning'),
        'errorCount': count('error'),
        'infoCount': count('info'),
        'findingCounts': counts,
        'existingEmailDuplicateCount': existingDup,
        'csvEmailDuplicateCount': csvDup,
        'existingActiveParticipantCount': existingDup,
        'existingBatch': existingBatch,
        'expectedImportSequence': nextSequence,
        'validationFingerprint': 'f' * 64,
        'importedBatches': [for (var n = 1; n < nextSequence; n++) {'sequence': n, 'status': 'committed'}],
        'participationTypes': types,
        'rows': rows,
      });
    }

    // 検証と同じ行の判定のプレビュー
    ImportPreview previewOf(ImportValidation v) => ImportPreview.fromJson({
      'batchId': 'b-preview',
      'totalRecords': v.totalRecords,
      'totalRows': v.totalRows,
      'readyCount': v.rows.where((r) => r.classification == RowClass.ready).length,
      'reviewCount': v.rows.where((r) => r.classification == RowClass.review).length,
      'errorCount': v.rows.where((r) => r.classification == RowClass.error).length,
      'blankRecordCount': 1,
      'rows': [
        for (final r in v.rows)
          {
            'sourceRowNumber': r.sourceRowNumber,
            'classification': r.classification.value,
            'issueCodes': [for (final x in r.findings) x.code],
            'programIds': r.programIds,
          },
      ],
    });

    FakeImportService serviceFor(ImportValidation v) => FakeImportService(
      validateHandler: (_) async => v,
      previewHandler: (_) async => previewOf(v),
    );

    Finder rowText(int n, String text) => find.descendant(
      of: find.byKey(ValueKey('validation-row-$n')),
      matching: find.textContaining(text),
    );
    bool previewEnabled(WidgetTester tester) =>
        tester.widget<FilledButton>(find.byKey(const Key('run-preview'))).onPressed != null;

    testWidgets('CSV選択の直後はプレビューへ進めない。検証では何も確定せず、正常なら確認なしでプレビューできる', (tester) async {
      final v = validationOf([
        for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'ok', []),
      ]);
      final service = serviceFor(v);
      await _open(tester, service);
      expect(find.byKey(const Key('run-validate')), findsOneWidget);
      expect(find.byKey(const Key('run-preview')), findsNothing);
      await _validate(tester);
      expect(service.validations.length, 1);
      expect(service.previews, isEmpty, reason: '検証ではプレビュー・確定をしない');
      expect(service.commits, isEmpty);
      expect(find.text('検証結果(まだ取り込まれていません)'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('validation-ok')), matching: find.text('4件')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('validation-warning')), matching: find.text('0件')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('validation-error-count')), matching: find.text('0件')), findsOneWidget);
      expect(find.byKey(const Key('ack-existing-duplicates')), findsNothing, reason: '重複が無ければ確認は不要');
      expect(find.byKey(const Key('ack-csv-duplicates')), findsNothing);
      expect(find.byKey(const Key('ack-new-import')), findsNothing);
      expect(previewEnabled(tester), isTrue);
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      expect(service.previews.single.batchId, service.validations.single.batchId, reason: '通常の取込のbatchIdは従来どおり');
      expect(find.byKey(const Key('commit')), findsOneWidget);
    });

    testWidgets('問題のある行は、行番号・氏名・メール・判定・すべての問題内容を表示し、項目別の件数を出す', (tester) async {
      final v = validationOf([
        vrow(2, 'ready', 'warning', [f('email-duplicate-in-csv', 'warning')], duplicateRows: [5]),
        vrow(3, 'error', 'error', [
          f('count-invalid', 'error', 'program-1'),
          f('slot-unparsed', 'warning', 'program-2'),
          f('email-duplicate-existing', 'warning'),
        ]),
        vrow(5, 'ready', 'warning', [f('email-duplicate-in-csv', 'warning')], duplicateRows: [2]),
        vrow(6, 'ready', 'info', [f('not-attending-count-ignored', 'info', 'program-1')]),
      ], existingDup: 1, csvDup: 2);
      await _open(tester, serviceFor(v));
      await _validate(tester);
      expect(rowText(2, '2行目　警告'), findsOneWidget);
      expect(rowText(2, '架空参加者1　sippo1@example.invalid'), findsOneWidget);
      expect(rowText(2, 'CSV内の5行目と同じメールアドレスです。'), findsOneWidget);
      expect(rowText(3, '3行目　エラー'), findsOneWidget);
      expect(rowText(3, '[エラー] 架空プログラムA：人数が不正です'), findsOneWidget);
      expect(rowText(3, '架空プログラムB：時間枠を解釈できません(未知の時間枠)'), findsOneWidget);
      expect(rowText(3, '既存の有効な参加者と同じメールアドレスです'), findsOneWidget);
      expect(rowText(6, '架空プログラムA：不参加ですが人数欄に2が残っています。人数は無視されます。'), findsOneWidget);
      expect(find.byKey(const ValueKey('finding-count-email-duplicate-in-csv')), findsOneWidget);
      expect(find.textContaining('CSV内でメールアドレスが重複しています: 2件'), findsOneWidget);
      expect(find.textContaining('人数が不正です: 1件'), findsOneWidget);
      // エラーがあるのでプレビューへ進めない(確認をしても同じ)
      expect(find.byKey(const Key('validation-blocked')), findsOneWidget);
      for (final key in ['ack-existing-duplicates', 'ack-csv-duplicates']) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }
      expect(previewEnabled(tester), isFalse);
      expect(find.byKey(const Key('preview-locked')), findsOneWidget);
    });

    testWidgets('既存の有効な参加者とのメール重複は警告: 注意を表示し、明示的に確認するまでプレビューできない。確定には許可が付く', (tester) async {
      final v = validationOf([
        for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
      ], existingDup: 4);
      final service = serviceFor(v);
      await _open(tester, service);
      await _validate(tester);
      expect(find.byKey(const Key('duplicate-caution')), findsOneWidget);
      expect(find.textContaining('既存の有効な参加者(4件)とメールアドレスが重複する行: 4件'), findsOneWidget);
      expect(find.textContaining('前日リマインド・受付名簿等でも別参加者として扱われ'), findsOneWidget);
      expect(previewEnabled(tester), isFalse);
      expect(find.byKey(const Key('ack-csv-duplicates')), findsNothing, reason: 'CSV内の重複が無ければ、その確認は出さない');
      await tester.ensureVisible(find.byKey(const Key('ack-existing-duplicates')));
      await tester.tap(find.byKey(const Key('ack-existing-duplicates')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isTrue);
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      await _commitDialog(tester);
      expect(find.byKey(const Key('confirm-duplicate-caution')), findsOneWidget);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      final auth = service.commitAuth.single;
      expect([auth.existing, auth.csv], [true, false]);
      expect(identical(auth.validation, v), isTrue, reason: '検証結果(期待する取込回の番号・指紋)をそのままcommitへ渡す');
    });

    testWidgets('同じCSVが取込済み: 新しい取込回として取り込むことを明示しないとプレビューできず、確認後は別のbatchId(第2回)で取り込む', (tester) async {
      final v = validationOf([
        for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
      ], existingDup: 4, existingBatch: {'status': 'committed', 'sequence': 1});
      final service = serviceFor(v);
      await _open(tester, service);
      await _validate(tester);
      expect(find.byKey(const Key('already-imported')), findsOneWidget);
      expect(find.textContaining('既に第1回として取り込まれています'), findsOneWidget);
      expect(find.textContaining('既に取り込まれている回: 第1回\n次に新規取込すると: 第2回'), findsOneWidget);
      expect(find.text('第2回として新しく取り込みます。'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('ack-existing-duplicates')));
      await tester.tap(find.byKey(const Key('ack-existing-duplicates')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isFalse, reason: '取込済みの内容は、新しい取込回の確認も必要');
      await tester.ensureVisible(find.byKey(const Key('ack-new-import')));
      await tester.tap(find.byKey(const Key('ack-new-import')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isTrue);
      await tester.ensureVisible(find.byKey(const Key('run-preview')));
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      final base = service.validations.single;
      final second = service.previews.single;
      expect(second.json['fileHash'], base.json['fileHash'], reason: 'ファイルは加工しない(同じ内容)');
      expect(second.batchId, isNot(base.batchId));
      expect(
        second.batchId,
        deriveBatchId(
          eventId: 'evfixture0123456789',
          fileHash: base.json['fileHash'] as String,
          mappingJson: base.json['mapping'] as Map<String, dynamic>,
          newImportSequence: 2,
        ),
      );
      await _commitDialog(tester);
      expect(find.text('新しい取込回(第2回)として取り込みます'), findsOneWidget);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(identical(service.commits.single.request, second), isTrue);
      expect(service.commitAuth.single.existing, isTrue);
    });

    testWidgets('既存参加者との重複とCSV内の重複は別々の確認。片方だけではプレビューできず、確定にはそれぞれの許可が付く', (tester) async {
      final v = validationOf([
        vrow(2, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
        vrow(3, 'ready', 'warning', [f('email-duplicate-in-csv', 'warning')], duplicateRows: [5]),
        vrow(5, 'ready', 'warning', [f('email-duplicate-in-csv', 'warning')], duplicateRows: [3]),
        vrow(6, 'ready', 'ok', []),
      ], existingDup: 1, csvDup: 2);
      final service = serviceFor(v);
      await _open(tester, service);
      await _validate(tester);
      expect(find.text('1件すべて許可(既存参加者とは別の参加者として取り込みます)'), findsOneWidget);
      expect(find.text('2件すべて許可(それぞれ別の参加者として取り込みます)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('ack-csv-duplicates')));
      await tester.tap(find.byKey(const Key('ack-csv-duplicates')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isFalse, reason: 'CSV内の重複の確認だけでは、既存参加者との重複は許可されない');
      await tester.tap(find.byKey(const Key('ack-existing-duplicates')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isTrue);
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect([service.commitAuth.single.existing, service.commitAuth.single.csv], [true, true]);
    });

    testWidgets('確定時に「取込状況が変更されました」なら、勝手に次の回にせず検証からやり直し。再検証で第3回が示され、以前の確認は無効', (tester) async {
      var round = 0;
      final first = validationOf([
        for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
      ], existingDup: 4, existingBatch: {'status': 'committed', 'sequence': 1});
      final second = validationOf([
        for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
      ], existingDup: 8, existingBatch: {'status': 'committed', 'sequence': 1}, next: 3);
      final service = FakeImportService(
        validateHandler: (_) async => round++ == 0 ? first : second,
        previewHandler: (_) async => previewOf(first),
        commitHandler: (r, a) async => throw const ImportException('取込状況が変更されました。再度検証してください。', code: 'import-state-changed'),
      );
      await _open(tester, service);
      await _preview_(tester);
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commits.length, 1);
      expect(find.byKey(const Key('result-committed')), findsNothing);
      expect(find.text('検証結果(まだ取り込まれていません)'), findsNothing, reason: '検証結果は無効になる');
      expect(find.byKey(const Key('commit')), findsNothing);
      expect(find.text('取込状況が変更されました。再度検証してください。'), findsOneWidget);
      await _validate(tester);
      expect(find.textContaining('既に取り込まれている回: 第1回、第2回\n次に新規取込すると: 第3回'), findsOneWidget);
      expect(find.text('第3回として新しく取り込みます。'), findsOneWidget);
      for (final key in ['ack-existing-duplicates', 'ack-new-import']) {
        expect(tester.widget<CheckboxListTile>(find.byKey(Key(key))).value, isFalse, reason: '$key: 以前の確認は引き継がない');
      }
      expect(previewEnabled(tester), isFalse);
    });

    testWidgets('確認が必要な行(警告)は検証画面で一括許可でき、許可した行はプレビューで許可済みとして示される', (tester) async {
      final v = validationOf([
        vrow(2, 'ready', 'ok', []),
        vrow(3, 'review', 'warning', [f('attending-count-missing', 'warning', 'program-1')]),
        vrow(5, 'review', 'warning', [f('slot-missing', 'warning', 'program-2')]),
        vrow(6, 'ready', 'warning', [f('participation-type-undetermined', 'warning')], type: null),
      ], types: [
        {'value': 'dog', 'label': '① 犬のみ', 'count': 1},
      ]);
      await _open(tester, serviceFor(v));
      await _validate(tester);
      expect(rowText(3, '架空プログラムA：参加なのに人数がありません'), findsOneWidget);
      expect(rowText(5, '架空プログラムB：参加なのに時間枠がありません'), findsOneWidget);
      expect(rowText(6, '参加タイプ: 判定できません'), findsOneWidget);
      expect(find.textContaining('確認が必要な行: 2件(許可した行だけが取り込まれます)'), findsOneWidget);
      expect(previewEnabled(tester), isFalse, reason: '確認が必要な行は、許可するか除外するまでプレビューできない');
      await tester.ensureVisible(find.byKey(const Key('allow-all-review')));
      await tester.tap(find.byKey(const Key('allow-all-review')));
      await tester.pumpAndSettle();
      expect(previewEnabled(tester), isTrue);
      await tester.ensureVisible(find.byKey(const Key('run-preview')));
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      expect(find.text('3行目: 許可済み'), findsOneWidget);
    });

    // ---- 検証画面での対処(許可・修正・今回の取込から除外) ----------------------------------------------
    // 既定CSVの行: 2(メール不正=error) / 3(人数不正=error) / 5(既存メール重複) / 6(確認が必要=review)。
    // 送られた修正・除外を反映した検証結果を返す(サーバーと同じく、修正しただけでは正常にしない:
    // 修正値が正しい形式のときだけ解消する)。
    ImportValidation handlingValidation(ImportRequest request) {
      final corrections = {
        for (final c in (request.json['corrections'] as List? ?? const []))
          '${(c as Map)['sourceRowNumber']}/${c['column']}': c['value'] as String,
      };
      final excluded = {
        for (final e in (request.json['excludedRows'] as List? ?? const [])) (e as Map)['sourceRowNumber'] as int,
      };
      final emailFixed = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(corrections['2/メールアドレス'] ?? '');
      final countFixed = RegExp(r'^\d+$').hasMatch(corrections['3/午前参加人数'] ?? '');
      final rows = [
        emailFixed ? vrow(2, 'ready', 'ok', []) : vrow(2, 'error', 'error', [f('email-invalid', 'error')]),
        countFixed ? vrow(3, 'ready', 'ok', []) : vrow(3, 'error', 'error', [f('count-invalid', 'error', 'program-1')]),
        vrow(5, 'ready', 'warning', [f('email-duplicate-existing', 'warning')]),
        vrow(6, 'review', 'warning', [f('row-check-failed', 'warning')]),
      ];
      for (final r in rows) {
        if (excluded.contains(r['sourceRowNumber'])) r['excluded'] = true;
        if (corrections.keys.any((k) => k.startsWith('${r['sourceRowNumber']}/'))) r['corrected'] = true;
      }
      final included = rows.where((r) => r['excluded'] != true).toList();
      final v = validationOf(rows, existingDup: included.any((r) => r['sourceRowNumber'] == 5) ? 1 : 0);
      return ImportValidation.fromJson({
        'totalRecords': 5, 'totalRows': 4, 'blankRecordCount': 1,
        'okCount': included.where((r) => r['result'] == 'ok').length,
        'warningCount': included.where((r) => r['result'] == 'warning').length,
        'errorCount': included.where((r) => r['result'] == 'error').length,
        'findingCounts': v.findingCounts,
        'existingEmailDuplicateCount': included.any((r) => r['sourceRowNumber'] == 5) ? 1 : 0,
        'existingActiveParticipantCount': 10,
        'expectedImportSequence': 1, 'validationFingerprint': 'f' * 64,
        'excludedRowCount': excluded.length,
        'correctedRowCount': rows.where((r) => r['corrected'] == true).length,
        'importRowCount': included.length,
        'rows': rows,
      });
    }

    FakeImportService handlingService() => FakeImportService(
      validateHandler: (request) async => handlingValidation(request),
      previewHandler: (request) async {
        final v = handlingValidation(request);
        return ImportPreview.fromJson({
          'totalRecords': 5, 'totalRows': 4, 'blankRecordCount': 1,
          'readyCount': v.rows.where((r) => r.classification == RowClass.ready).length,
          'reviewCount': v.rows.where((r) => r.classification == RowClass.review).length,
          'decisionSummary': {'originalRows': 4, 'correctedRows': v.correctedRowCount, 'excludedRows': v.excludedRowCount, 'importRows': v.importRowCount},
          'rows': [
            for (final r in v.rows)
              {'sourceRowNumber': r.sourceRowNumber, 'classification': r.classification.value, 'programIds': ['program-1'],
                'excluded': r.excluded, 'corrected': r.corrected},
          ],
        });
      },
    );

    Future<void> tapKey(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    testWidgets('問題ごとに意味のある操作だけ: エラーは修正・除外(許可なし)、確認が必要な行は許可・除外、既存メール重複は修正・除外', (tester) async {
      await _open(tester, handlingService());
      await _validate(tester);
      expect(find.byKey(const ValueKey('allow-2')), findsNothing, reason: 'エラーは許可できない');
      expect(find.byKey(const ValueKey('edit-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('exclude-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('allow-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('exclude-6')), findsOneWidget);
      expect(find.byKey(const ValueKey('edit-5')), findsOneWidget, reason: 'メール重複は、メールの修正が意味を持つ');
      expect(find.textContaining('未解決: エラー2件・確認待ち1件・未許可の警告1件'), findsOneWidget);
      expect(find.textContaining('削除'), findsNothing, reason: '「削除」という名称は使わない');
    });

    testWidgets('修正 → サーバーで再検証。修正値が不正なら解消しない。正しい値なら解消し、原本→修正後を表示。取り消せる', (tester) async {
      final service = handlingService();
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const ValueKey('edit-2'));
      expect(find.text('原本: 「sippo1@example.invalid」'), findsOneWidget, reason: '修正欄に原本の値を示す');
      await tester.enterText(find.byKey(const ValueKey('edit-2-メールアドレス')), 'still-broken');
      await tapKey(tester, const ValueKey('apply-edit-2'));
      expect(service.validations.length, 2, reason: '修正したらサーバーで検証し直す');
      expect((service.validations.last.json['corrections'] as List).single,
          {'sourceRowNumber': 2, 'column': 'メールアドレス', 'value': 'still-broken'});
      expect(find.textContaining('未解決: エラー2件'), findsOneWidget, reason: '修正しただけでは正常扱いにしない');
      await tapKey(tester, const ValueKey('edit-2'));
      await tester.enterText(find.byKey(const ValueKey('edit-2-メールアドレス')), 'fixed2@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-2'));
      expect(find.textContaining('未解決: エラー1件'), findsOneWidget);
      expect(find.text('修正: メールアドレス「sippo1@example.invalid」→「fixed2@example.invalid」'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('validation-row-2')), matching: find.textContaining('fixed2@example.invalid')), findsWidgets,
          reason: '表示は最終的な値');
      final base = service.validations.first;
      expect(service.validations.last.batchId, isNot(base.batchId), reason: '対処が変われば別の取込として識別する');
      expect(service.validations.last.json['rows'], base.json['rows'], reason: '原本の値は変えない');
      await tapKey(tester, const ValueKey('uncorrect-2'));
      expect(service.validations.last.json.containsKey('corrections'), isFalse);
      expect(service.validations.last.batchId, base.batchId, reason: '対処が無ければ従来どおりのbatchId');
    });

    testWidgets('今回の取込から除外 → 再検証。除外は取り消せる。エラーを一括除外できる', (tester) async {
      final service = handlingService();
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const ValueKey('exclude-6'));
      expect((service.validations.last.json['excludedRows'] as List).single, {'sourceRowNumber': 6, 'reason': '検証画面で管理者が除外'});
      expect(find.textContaining('6行目　今回の取込から除外'), findsOneWidget);
      expect(find.textContaining('確認待ち0件'), findsOneWidget);
      await tapKey(tester, const ValueKey('unexclude-6'));
      expect(service.validations.last.json.containsKey('excludedRows'), isFalse);
      await tapKey(tester, const Key('exclude-all-errors'));
      expect((service.validations.last.json['excludedRows'] as List).map((e) => (e as Map)['sourceRowNumber']), [2, 3]);
      expect(find.textContaining('未解決: エラー0件'), findsOneWidget);
    });

    testWidgets('既存メール重複は「N件すべて許可」。対処が終わればプレビューで最終内容(原本・修正・除外・取込予定)、確認ダイアログに許可した警告を表示', (tester) async {
      final service = handlingService();
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const ValueKey('edit-2'));
      await tester.enterText(find.byKey(const ValueKey('edit-2-メールアドレス')), 'fixed2@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-2'));
      await tapKey(tester, const ValueKey('exclude-3'));
      await tapKey(tester, const ValueKey('allow-6'));
      expect(find.text('1件すべて許可(既存参加者とは別の参加者として取り込みます)'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('run-preview'))).onPressed, isNull);
      await tapKey(tester, const Key('ack-existing-duplicates'));
      expect(find.text('未解決の問題はありません。'), findsOneWidget);
      await tapKey(tester, const Key('run-preview'));
      expect(find.text('原本CSV: 4件　修正: 1件　除外: 1件　取込予定: 3件'), findsOneWidget);
      // プレビューから検証画面へ戻って対処を変えられる
      await tapKey(tester, const Key('back-to-validation'));
      expect(find.byKey(const Key('commit')), findsNothing);
      await tapKey(tester, const Key('run-preview'));
      await _commitDialog(tester);
      Finder inDialog(String t) => find.descendant(of: find.byType(AlertDialog), matching: find.text(t));
      expect(inDialog('3件'), findsOneWidget, reason: '取込予定');
      expect(inDialog('1件'), findsOneWidget, reason: '修正した行');
      expect(inDialog('1件(取り込まれません)'), findsOneWidget, reason: '今回の取込から除外した行');
      expect(inDialog('既存参加者とのメール重複1件を許可して、別参加者として取り込みます'), findsOneWidget);
      expect(inDialog('確認が必要な行1件を許可して取り込みます'), findsOneWidget);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      final sent = service.commits.single;
      expect(sent.approved, [6]);
      expect(sent.request.json['corrections'], isNotNull);
      expect((sent.request.json['excludedRows'] as List).single, {'sourceRowNumber': 3, 'reason': '検証画面で管理者が除外'});
      expect(service.commitAuth.single.existing, isTrue);
    });

    testWidgets('除外で重複の対象行が変わると、その許可は無効になり改めて確認が必要', (tester) async {
      await _open(tester, handlingService());
      await _validate(tester);
      await tapKey(tester, const Key('ack-existing-duplicates'));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-existing-duplicates'))).value, isTrue);
      await tapKey(tester, const ValueKey('exclude-6'));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-existing-duplicates'))).value, isTrue,
          reason: '対象の行が変わらない許可は引き継ぐ');
      await tapKey(tester, const ValueKey('exclude-5'));
      expect(find.byKey(const Key('ack-existing-duplicates')), findsNothing, reason: '重複行を除外すれば許可は不要');
      await tapKey(tester, const ValueKey('unexclude-5'));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-existing-duplicates'))).value, isFalse,
          reason: '対象が変わったので改めて確認する');
    });

    testWidgets('CSVを選び直すと検証は無効になり、再検証が必要', (tester) async {
      final service = FakeImportService();
      await _open(tester, service);
      await _validate(tester);
      expect(find.byKey(const Key('run-preview')), findsOneWidget);
      await _pick(tester);
      expect(find.text('検証結果(まだ取り込まれていません)'), findsNothing);
      expect(find.byKey(const Key('run-preview')), findsNothing);
      await _validate(tester);
      expect(service.validations.length, 2);
    });

    testWidgets('列の対応(取込profile)が変わると検証は無効になり、再検証が必要', (tester) async {
      final service = FakeImportService();
      await _open(tester, service);
      await _validate(tester);
      expect(find.byKey(const Key('run-preview')), findsOneWidget);
      final changed = ConfirmedImportProfile(
        label: '変更した列の対応(架空)',
        nameColumn: '氏名',
        kanaColumn: 'かな',
        emailColumn: 'メールアドレス',
        programs: [
          for (final p in currentConfirmedImportProfile.programs)
            ConfirmedImportProfileProgram(
              programId: p.programId,
              countColumn: p.countColumn,
              slotColumn: p.slotColumn,
              slotFormat: p.slotFormat,
              participationColumn: p.participationColumn,
              attendingValues: p.attendingValues,
              notAttendingValues: p.notAttendingValues,
              emptyMeansNotAttending: p.emptyMeansNotAttending,
            ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ConfirmedImportPage(
            eventId: 'evfixture0123456789',
            service: service,
            picker: () async => _csv(),
            profile: changed,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('検証結果(まだ取り込まれていません)'), findsNothing);
      expect(find.byKey(const Key('run-preview')), findsNothing);
      await _validate(tester);
      final mapping = service.validations.last.json['mapping'] as Map;
      expect((mapping['participant'] as Map).containsKey('registeredAtColumn'), isFalse, reason: '新しい列の対応で検証し直す');
    });

    testWidgets('プレビューの判定が検証と一致しなければ、プレビュー結果を出さず確定できない', (tester) async {
      final v = validationOf([for (final n in [2, 3, 5, 6]) vrow(n, 'ready', 'ok', [])]);
      final service = FakeImportService(
        validateHandler: (_) async => v,
        previewHandler: (_) async => _preview(ready: 3, review: 1),
      );
      await _open(tester, service);
      await _validate(tester);
      await tester.tap(find.byKey(const Key('run-preview')));
      await tester.pumpAndSettle();
      expect(find.textContaining('検証結果とプレビューの判定が一致しませんでした'), findsOneWidget);
      expect(find.byKey(const Key('commit')), findsNothing);
    });

    // ---- 参考情報(不参加+残存人数)と、行を修正したときの許可の解除 ------------------------------------------
    // 修正(corrections)に応じた検証結果を返す。許可の鍵は、サーバーと同じく行の最終的な値と警告の内容から作る想定
    // (値が変われば鍵も変わる)。build: 修正 ('行/列' → 値) から行を作る。
    FakeImportService keyedService(List<Map<String, dynamic>> Function(Map<String, String> corrections) build,
        {int existingDup = 0, int csvDup = 0}) {
      ImportValidation validationFor(ImportRequest request) {
        final corrections = {
          for (final c in (request.json['corrections'] as List? ?? const []))
            '${(c as Map)['sourceRowNumber']}/${c['column']}': c['value'] as String,
        };
        final rows = build(corrections);
        for (final r in rows) {
          if (corrections.keys.any((k) => k.startsWith('${r['sourceRowNumber']}/'))) r['corrected'] = true;
        }
        return validationOf(rows, existingDup: existingDup, csvDup: csvDup);
      }
      return FakeImportService(
        validateHandler: (request) async => validationFor(request),
        previewHandler: (request) async => previewOf(validationFor(request)),
      );
    }
    String k(String s) => s.padRight(64, '0');
    final infoRow = f('not-attending-count-ignored', 'info', 'program-2');

    testWidgets('A: 不参加+残存人数だけ → 参考情報として表示し、許可なしでプレビュー・確定できる(許可の操作は出さない)', (tester) async {
      final service = keyedService((_) => [
        vrow(2, 'ready', 'ok', []),
        vrow(3, 'ready', 'info', [infoRow]),
        vrow(5, 'ready', 'ok', []),
        vrow(6, 'ready', 'ok', []),
      ]);
      await _open(tester, service);
      await _validate(tester);
      expect(find.byKey(const Key('ignored-counts-panel')), findsOneWidget);
      expect(find.textContaining('参考情報: 不参加のprogramに人数が残っている行: 1件(3行目)'), findsOneWidget);
      expect(find.textContaining('許可は不要です'), findsWidgets);
      expect(find.byKey(const Key('ack-ignored-counts')), findsNothing, reason: '残存人数の一括許可は無い');
      expect(find.byKey(const Key('exclude-all-ignored-counts')), findsNothing);
      expect(find.byKey(const ValueKey('allow-3')), findsNothing, reason: '参考情報の行に許可の操作は無い');
      expect(rowText(3, '3行目　参考'), findsOneWidget);
      expect(rowText(3, '[参考] 架空プログラムB：不参加ですが人数欄に'), findsOneWidget);
      expect(find.byKey(const Key('validation-info')), findsOneWidget);
      expect(find.text('未解決の問題はありません。'), findsOneWidget);
      expect(previewEnabled(tester), isTrue);
      await tapKey(tester, const Key('run-preview'));
      await _commitDialog(tester);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('無視して取り込みます')), findsNothing);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commitAuth.single.keys, isEmpty);
    });

    testWidgets('B: 本番10件相当(既存メール重複+残存人数の参考情報) → 「既存メール重複をすべて許可」だけでプレビューできる', (tester) async {
      final service = keyedService((_) => [
        vrow(2, 'ready', 'warning', [f('email-duplicate-existing', 'warning'), infoRow], keys: {'existingDuplicate': k('e2')}),
        vrow(3, 'ready', 'warning', [f('email-duplicate-existing', 'warning')], keys: {'existingDuplicate': k('e3')}),
        vrow(5, 'ready', 'warning', [f('email-duplicate-existing', 'warning'), infoRow], keys: {'existingDuplicate': k('e5')}),
        vrow(6, 'ready', 'warning', [f('email-duplicate-existing', 'warning'), infoRow], keys: {'existingDuplicate': k('e6')}),
      ], existingDup: 4);
      await _open(tester, service);
      await _validate(tester);
      expect(find.textContaining('参考情報: 不参加のprogramに人数が残っている行: 3件(2行目、5行目、6行目)'), findsOneWidget);
      expect(find.textContaining('未解決: エラー0件・確認待ち0件・未許可の警告4件'), findsOneWidget, reason: '参考情報は未解決に数えない');
      expect(find.byKey(const Key('ack-ignored-counts')), findsNothing);
      await tapKey(tester, const Key('ack-existing-duplicates'));
      expect(find.text('未解決の問題はありません。'), findsOneWidget);
      await tapKey(tester, const Key('run-preview'));
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commitAuth.single.existing, isTrue);
      expect(service.commitAuth.single.keys, [k('e2'), k('e3'), k('e5'), k('e6')]);
    });

    testWidgets('C: reviewを許可 → 同じ行を修正 → 許可は解除され、新しい検証結果で改めて許可が必要(鍵が同じでも引き継がない)', (tester) async {
      // 修正しても同じ確認理由・同じ鍵を返す検証(行番号や鍵が同じでも、修正した行の許可は引き継がないことの確認)
      final service = keyedService((c) => [
        vrow(2, 'ready', 'ok', []), vrow(3, 'ready', 'ok', []), vrow(5, 'ready', 'ok', []),
        vrow(6, 'review', 'warning', [f('slot-unparsed', 'warning', 'program-1')], keys: {'review': k('r6')}),
      ]);
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const ValueKey('allow-6'));
      expect(previewEnabled(tester), isTrue);
      await tapKey(tester, const ValueKey('edit-6'));
      await tester.enterText(find.byKey(const ValueKey('edit-6-午前参加時間')), 'まだ解釈できない時間枠');
      await tapKey(tester, const ValueKey('apply-edit-6'));
      expect(service.validations.length, 2, reason: '修正したら再検証する');
      expect(tester.widget<FilterChip>(find.byKey(const ValueKey('allow-6'))).selected, isFalse, reason: '修正した行の許可は解除');
      expect(find.textContaining('確認待ち1件'), findsOneWidget);
      expect(previewEnabled(tester), isFalse);
      await tapKey(tester, const ValueKey('allow-6'));
      await tapKey(tester, const Key('run-preview'));
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commits.single.approved, [6]);
      expect(service.commitAuth.single.keys, [k('r6')]);
    });

    testWidgets('D: 既存メール重複を許可 → メールを修正 → 許可は解除(別の重複になれば改めて許可)', (tester) async {
      final service = keyedService((c) => [
        vrow(2, 'ready', 'ok', []), vrow(3, 'ready', 'ok', []),
        vrow(5, 'ready', 'warning', [f('email-duplicate-existing', 'warning')], keys: {'existingDuplicate': k('e5-${c['5/メールアドレス'] ?? ''}')}),
        vrow(6, 'ready', 'ok', []),
      ], existingDup: 1);
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const Key('ack-existing-duplicates'));
      expect(previewEnabled(tester), isTrue);
      await tapKey(tester, const ValueKey('edit-5'));
      await tester.enterText(find.byKey(const ValueKey('edit-5-メールアドレス')), 'other-existing@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-5'));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-existing-duplicates'))).value, isFalse);
      expect(find.textContaining('未許可の警告1件'), findsOneWidget);
      expect(previewEnabled(tester), isFalse);
      await tapKey(tester, const Key('ack-existing-duplicates'));
      await tapKey(tester, const Key('run-preview'));
      await _commitDialog(tester);
      await tester.tap(find.text('取込を確定'));
      await tester.pumpAndSettle();
      expect(service.commitAuth.single.keys, [k('e5-other-existing@example.invalid')], reason: '新しい鍵だけを送る');
    });

    testWidgets('E/H: CSV内重複を許可 → 対象行を修正すると解除。修正していない相手の行も、重複の内容(鍵)が変われば解除', (tester) async {
      // 2・5行目が同じメール(CSV内重複)、3行目は既存参加者と重複。3行目のメールを2・5行目と同じにすると、
      // 2・5行目は修正していないが重複の相手が変わる(鍵も変わる)。
      final service = keyedService((c) {
        final widened = c.containsKey('3/メールアドレス');
        String key(int n) => k('c$n-${widened ? 'w' : ''}-${c['$n/メールアドレス'] ?? ''}');
        final partners = widened ? [2, 3, 5] : [2, 5];
        return [
          for (final n in [2, 3, 5, 6])
            partners.contains(n)
                ? vrow(n, 'ready', 'warning', [f('email-duplicate-in-csv', 'warning')],
                    duplicateRows: partners.where((m) => m != n).toList(), keys: {'csvDuplicate': key(n)})
                : n == 3
                ? vrow(3, 'ready', 'warning', [f('email-duplicate-existing', 'warning')], keys: {'existingDuplicate': k('e3')})
                : vrow(n, 'ready', 'ok', []),
        ];
      }, csvDup: 2, existingDup: 1);
      await _open(tester, service);
      await _validate(tester);
      await tapKey(tester, const Key('ack-csv-duplicates'));
      await tapKey(tester, const Key('ack-existing-duplicates'));
      expect(previewEnabled(tester), isTrue);
      // 対象行(2行目)のメールを修正(まだ重複) → 2行目の許可は解除(5行目は鍵が変わらないので許可のまま)
      await tapKey(tester, const ValueKey('edit-2'));
      await tester.enterText(find.byKey(const ValueKey('edit-2-メールアドレス')), 'Sippo1@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-2'));
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-csv-duplicates'))).value, isFalse);
      expect(find.textContaining('未許可の警告1件'), findsOneWidget, reason: '修正した2行目だけ');
      await tapKey(tester, const Key('ack-csv-duplicates'));
      expect(previewEnabled(tester), isTrue);
      // 3行目を2・5行目と同じメールへ修正 → 修正していない2・5行目も、重複の相手が変わったので許可は無効
      await tapKey(tester, const ValueKey('edit-3'));
      await tester.enterText(find.byKey(const ValueKey('edit-3-メールアドレス')), 'sippo1@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-3'));
      expect(find.byKey(const Key('ack-existing-duplicates')), findsNothing, reason: '3行目は既存重複ではなくなった');
      expect(find.textContaining('未許可の警告3件'), findsOneWidget, reason: '古い許可を行番号で流用しない');
      expect(tester.widget<CheckboxListTile>(find.byKey(const Key('ack-csv-duplicates'))).value, isFalse);
      expect(previewEnabled(tester), isFalse);
    });

    testWidgets('G: 問題が消える修正 → 許可は不要になり、そのままプレビューできる', (tester) async {
      final service = keyedService((c) => [
        vrow(2, 'ready', 'ok', []), vrow(3, 'ready', 'ok', []),
        c.containsKey('5/メールアドレス')
            ? vrow(5, 'ready', 'ok', [])
            : vrow(5, 'ready', 'warning', [f('email-duplicate-existing', 'warning')], keys: {'existingDuplicate': k('e5')}),
        vrow(6, 'ready', 'ok', []),
      ], existingDup: 1);
      await _open(tester, service);
      await _validate(tester);
      expect(previewEnabled(tester), isFalse);
      await tapKey(tester, const ValueKey('edit-5'));
      await tester.enterText(find.byKey(const ValueKey('edit-5-メールアドレス')), 'new5@example.invalid');
      await tapKey(tester, const ValueKey('apply-edit-5'));
      expect(find.text('未解決の問題はありません。'), findsOneWidget);
      expect(previewEnabled(tester), isTrue);
    });

    testWidgets('検証の失敗(サーバーの拒否)は理由を表示し、プレビューへ進めない', (tester) async {
      await _open(
        tester,
        FakeImportService(validateHandler: (_) async => throw const ImportException('サーバーで検証できませんでした。')),
      );
      await _validate(tester);
      expect(find.byKey(const Key('validation-error')), findsOneWidget);
      expect(find.byKey(const Key('run-preview')), findsNothing);
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
        await service.validate(request);
        await service.preview(request);
        expect(bodies['validateConfirmedImport'], bodies['previewConfirmedImport'], reason: '検証とプレビューは同じリクエスト本体');
        final checked = ImportValidation.fromJson({'expectedImportSequence': 3, 'validationFingerprint': 'a' * 64});
        await service.commit(request, approvedReviewRows: [7, 3], validation: checked,
            acknowledgeExistingEmailDuplicates: true, acknowledgeCsvEmailDuplicates: true, approvalKeys: ['b' * 64, 'a' * 64]);
        expect(bodies['commitConfirmedImport']!['approvalKeys'], ['a' * 64, 'b' * 64], reason: '許可の鍵を送る');
        expect(bodies['commitConfirmedImport']!.containsKey('acknowledgeIgnoredCounts'), isFalse, reason: '残存人数は参考情報で、確認は送らない');
        final sent = bodies['commitConfirmedImport']!;
        expect([sent['expectedImportSequence'], sent['validationFingerprint']], [3, 'a' * 64], reason: '検証が返した番号と指紋をそのまま送る');
        expect([sent['acknowledgeExistingEmailDuplicates'], sent['acknowledgeCsvEmailDuplicates']], [true, true]);
        await service.commit(request);
        expect(bodies['commitConfirmedImport']!.containsKey('acknowledgeExistingEmailDuplicates'), isFalse, reason: '許可は明示したときだけ送る');
        expect(bodies['commitConfirmedImport']!.containsKey('acknowledgeCsvEmailDuplicates'), isFalse);
        expect(bodies['commitConfirmedImport']!.containsKey('validationFingerprint'), isFalse);
        expect(bodies['commitConfirmedImport']!.containsKey('approvalKeys'), isFalse);
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
      'lib/confirmed/import_profile.dart',
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
        // 「検証」はメールアドレスの重複を見せて管理者に確認させるだけ(警告)。行の統合・除外はしない。
        // そのため'duplicate'という語は使うが、統合(dedupe)・一意化(distinct・unique)の実装は引き続き持ち込まない。
        for (final forbidden in [
          'dedupe',
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
    test(
      '通常運用(Phase 11B-4)は列mapping UIを一切表示しない(氏名・メール・かな・参照コード・登録日時・行の確認・'
      'programごとの人数/時間枠/参加列/参加値/不参加値、いずれも利用者に選ばせない)。CSVのheaderから自動的に組み立てる',
      () {
        final text = code('lib/confirmed/import_page.dart');
        for (final forbidden in [
          "Key('map-name')",
          "Key('map-email')",
          "Key('map-kana')",
          "Key('map-external')",
          "Key('map-registered')",
          "Key('program-count-",
          "Key('program-slot-",
          "Key('program-enabled-",
          "Key('program-participation-",
          "Key('program-attending-",
          "Key('program-notattending-",
          "Key('rowcheck-column-",
          "Key('rowcheck-values-",
          "Key('add-rowcheck')",
          'DropdownButtonFormField',
        ]) {
          expect(text.contains(forbidden), isFalse, reason: forbidden);
        }
        // 自動解析の結果(選択の操作なし)は表示される。
        expect(text.contains("Key('auto-mapping-ok')"), isTrue);
        expect(text.contains('ConfirmedImportProfile'), isTrue);
      },
    );
    test(
      '「programIdの文字列なら必ずこのCSV列」という対応をシステム全体へハードコードしない(profileの外に置かない)',
      () {
        // import_profile.dart だけが、実際のprogramId(program-1等)とCSV列名の対応を持つ。
        // 画面・モデルのコードは、その対応を経由するだけで、programIdを直接特別扱いしない。
        for (final path in [
          'lib/confirmed/import_page.dart',
          'lib/confirmed/import_models.dart',
        ]) {
          final text = code(path);
          for (final literal in ['program-1', 'program-2', 'program-3']) {
            expect(text.contains(literal), isFalse, reason: '$path: $literal');
          }
        }
      },
    );
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
