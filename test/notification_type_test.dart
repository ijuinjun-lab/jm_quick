// 通常当選/キャンセル待ち繰り上げ当選(画面・モデル)。通信はすべて差し替え(外部通信0)。データはすべて架空(メールは .invalid)。
//  - mapping・batchId・リクエスト: 通常当選(キャンセル行なし)は従来と完全に同じ。キャンセル行があれば自動除外の規則、繰り上げは判定規則
//  - 取込画面: 通知種別は必須(選ぶまで検証へ進めない)。変えたら検証は無効。検証結果の冒頭に通知種別・使用メール・件数・繰り上げ先
//  - 自動除外の行は「原本でキャンセル・自動除外」(取り消せない)。取り違えの警告。CSVの繰り上げは止める
//  - 判定不能の理由の表示・送信管理の通知種別・最終実績Excelの通知種別・繰り上げ当選メールの設定
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/attendance_report_xlsx.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/import_profile.dart';
import 'package:jm_quick/confirmed/import_service.dart';
import 'package:jm_quick/confirmed/winner_mail_page.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';
import 'package:jm_quick/confirmed/winner_send_page.dart';
import 'package:jm_quick/confirmed/winner_send_service.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';

import 'import_page_test.dart' show FakeImportService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService, FakeMailService, committed;
import 'xlsx_fixture.dart';

const _programs = [
  (programId: 'program-1', name: '架空の譲渡会（ねこ）', order: 0),
  (programId: 'program-2', name: '架空の譲渡会（いぬ）', order: 1),
  (programId: 'program-3', name: '架空トーク', order: 2),
];
const _waitlistHeaders = [
  ...fixtureHeaders,
  'キャンセル待希望枠',
  'キャンセル待希望人数',
];
const _dogAll = '午後の部（犬）14:10-14:50,午後の部（犬）14:50-15:30,午後の部（犬）15:30-16:10';

/// 架空の行(区分・待ち枠・待ち人数だけ変える)
List<Object?> _row(int i, String category, {String wait = '', String waitN = '', String am = '参加を希望しない'}) => [
  category, 'id$i', '架空 参加者$i', 'かくう', 'wait$i@example.invalid', 'いいえ',
  am, am == '参加を希望しない' ? null : '2', '参加を希望しない', null, '参加を希望しない', null, '2026-09-01 10:00:00',
  wait, waitN,
];

CsvTable _table(List<List<Object?>> rows, {List<String> headers = _waitlistHeaders}) => CsvTable(
  headers: headers,
  records: [for (final r in rows) [for (final c in r) c?.toString() ?? '']],
);

Uint8List _waitlistXlsx({String sheet = '15時30分～16時10分', List<List<Object?>>? rows}) => buildXlsx([
  XSheet(sheet, [
    _waitlistHeaders,
    ...(rows ??
        [
          _row(1, '提出なし', wait: _dogAll, waitN: '1名'),
          _row(2, '提出なし', wait: _dogAll, waitN: '2名'),
          _row(3, 'キャンセル', wait: _dogAll, waitN: '3名'),
        ]),
  ]),
]);

Map<String, dynamic> _validationJson({required String type, Map<String, dynamic>? waitlist, bool autoExcluded = true}) => {
  'batchId': 'bfixture',
  'totalRecords': 3,
  'totalRows': 3,
  'blankRecordCount': 0,
  'okCount': 2,
  'warningCount': 0,
  'errorCount': 0,
  'findingCounts': <String, int>{},
  'existingEmailDuplicateCount': 0,
  'csvEmailDuplicateCount': 0,
  'existingActiveParticipantCount': 0,
  'errorRows': <int>[],
  'reviewRows': <int>[],
  'excludedRowCount': autoExcluded ? 1 : 0,
  'importRowCount': autoExcluded ? 2 : 3,
  'expectedImportSequence': 1,
  'nextImportSequence': 1,
  'validationFingerprint': 'f' * 64,
  'notificationType': type,
  'waitlistPromotion': ?waitlist,
  if (autoExcluded) ...{'autoExcludedRowCount': 1, 'autoExcludedRows': [4]},
  'rows': [
    {'sourceRowNumber': 2, 'classification': 'ready', 'result': 'ok', 'findings': <Object>[], 'programIds': ['program-2']},
    {'sourceRowNumber': 3, 'classification': 'ready', 'result': 'ok', 'findings': <Object>[], 'programIds': ['program-2']},
    {
      'sourceRowNumber': 4, 'classification': 'review', 'result': 'warning', 'findings': <Object>[], 'programIds': <String>[],
      if (autoExcluded) ...{'excluded': true, 'autoExcluded': true},
    },
  ],
};

const _summary = ImportEventSummary(
  eventId: 'evfixture0123456789',
  eventName: '架空イベント',
  startAt: null,
  venue: '架空会場',
  programs: _programs,
);

Future<void> _openImport(WidgetTester tester, FakeImportService service, PickedCsv Function() pick) async {
  await tester.binding.setSurfaceSize(const Size(900, 5000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ConfirmedImportPage(eventId: 'evfixture0123456789', service: service, picker: () async => pick()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  group('mapping・batchId・リクエスト', () {
    final profile = sipposample2026Profile;

    test('通常当選でキャンセル行の無いファイルは、mapping・batchId・リクエストが従来と同じ(新しい項目を送らない)', () {
      final table = _table([_row(1, '新規申込', am: '10:30-11:10')], headers: fixtureHeaders.toList());
      expect(tableHasCancelledRows(profile, table), isFalse);
      final mapping = buildMappingFromProfile(profile, _programs, autoExcludeCancelled: tableHasCancelledRows(profile, table));
      final json = mapping.toJson();
      expect(json.containsKey('autoExcludeRows'), isFalse);
      expect(json.containsKey('waitlist'), isFalse);
      final legacy = buildImportRequest(eventId: 'ev1', fileName: 'a.xlsx', fileBytes: Uint8List(1), table: table, mapping: mapping, sheetName: '申込情報');
      final normal = buildImportRequest(eventId: 'ev1', fileName: 'a.xlsx', fileBytes: Uint8List(1), table: table, mapping: mapping,
          sheetName: '申込情報', notificationType: NotificationType.normal);
      expect(normal.batchId, legacy.batchId);
      expect(jsonEncode(normal.json), jsonEncode(legacy.json));
      expect(normal.json.containsKey('notificationType'), isFalse);
      expect(normal.json.containsKey('sourceSheetName'), isFalse);
      expect(normal.json.containsKey('sourceSheetCandidates'), isFalse);
    });

    test('キャンセル行があれば自動除外の規則(区分=キャンセル)を入れる。繰り上げ当選は判定規則とシート名を送り、batchIdも別', () {
      final table = _table([_row(1, '提出なし', wait: _dogAll, waitN: '1名'), _row(2, ' キャンセル ', wait: _dogAll, waitN: '2名')]);
      expect(tableHasCancelledRows(profile, table), isTrue);
      final normal = buildMappingFromProfile(profile, _programs, autoExcludeCancelled: true);
      expect(normal.toJson()['autoExcludeRows'], [
        {'column': '区分', 'values': ['キャンセル']},
      ]);
      expect(normal.mappedColumns(), contains('区分'));
      final waitlist = buildMappingFromProfile(profile, _programs, autoExcludeCancelled: true, notificationType: NotificationType.waitlistPromotion);
      expect(waitlist.toJson()['waitlist'], {
        'optionsColumn': 'キャンセル待希望枠',
        'countColumn': 'キャンセル待希望人数',
        'options': [
          {'label': '午前の部（猫）', 'programId': 'program-1', 'kind': '猫'},
          {'label': '午後の部（犬）', 'programId': 'program-2', 'kind': '犬'},
        ],
      });
      expect(waitlist.mappedColumns(), containsAll(['キャンセル待希望枠', 'キャンセル待希望人数']));
      final request = buildImportRequest(eventId: 'ev1', fileName: '【犬15時30分～16時10分】架空.xlsx', fileBytes: Uint8List(1), table: table,
          mapping: waitlist, sheetName: '15時30分～16時10分', notificationType: NotificationType.waitlistPromotion);
      expect(request.json['notificationType'], 'waitlistPromotion');
      expect(request.json['sourceSheetName'], '15時30分～16時10分');
      final asNormal = deriveBatchId(eventId: 'ev1', fileHash: request.json['fileHash'] as String, mappingJson: waitlist.toJson(),
          sheetName: '15時30分～16時10分');
      expect(request.batchId, isNot(asNormal), reason: '同じファイルでも通知種別が違えば別の取込');
    });

    test('キャンセルの表記ゆれ(全角・半角・前後の空白等)は、サーバー(NFKC＋空白の除去)と同じ判定(共有fixture)', () {
      final fixture = jsonDecode(File('functions/test/fixtures/category_variants.json').readAsStringSync()) as Map<String, dynamic>;
      final variants = (fixture['variants'] as List).cast<Map<String, dynamic>>();
      expect(variants.length, greaterThanOrEqualTo(20));
      for (final v in variants) {
        final value = v['value'] as String;
        final cancel = v['cancel'] as bool;
        expect(comparableCategory(value) == comparableCategory(fixture['target'] as String), cancel, reason: jsonEncode(value));
        // 画面: キャンセルと判定した行が1つでもあれば、自動除外の規則をmappingへ入れる(サーバーが同じ行を除外する)
        final table = _table([_row(1, '提出なし', wait: _dogAll, waitN: '1名'), _row(2, value, wait: _dogAll, waitN: '2名')]);
        expect(tableHasCancelledRows(profile, table), cancel, reason: jsonEncode(value));
      }
      expect(comparableCategory('ｶﾞｲﾄﾞ'), 'ガイド', reason: '半角の濁点は合成する(NFKCと同じ)');
    });

    test('シート名の時間枠の読み取り(画面の取り違え警告用)', () {
      expect(parseSheetTimeRange('15時30分～16時10分'), (start: 930, end: 970));
      expect(parseSheetTimeRange('１５：３０〜１６：１０'), (start: 930, end: 970));
      expect(parseSheetTimeRange('申込情報'), isNull);
      expect(parseSheetTimeRange(null), isNull);
    });

    test('検証の応答: 通知種別・繰り上げ先・自動除外を読む(項目の無い応答は通常当選)', () {
      final v = ImportValidation.fromJson(_validationJson(type: 'waitlistPromotion', waitlist: {
        'programId': 'program-2', 'slotLabel': '15:30-16:10', 'kind': '犬',
        'rows': [{'sourceRowNumber': 2, 'plannedCount': 1}, {'sourceRowNumber': 3, 'plannedCount': 2}],
      }));
      expect(v.notificationType, NotificationType.waitlistPromotion);
      expect(v.waitlistPromotion!.slotLabel, '15:30-16:10');
      expect(v.waitlistPromotion!.rows.map((r) => r.plannedCount), [1, 2]);
      expect(v.autoExcludedRowCount, 1);
      expect(v.rows.last.autoExcluded, isTrue);
      final legacy = ImportValidation.fromJson({..._validationJson(type: 'normal'), 'notificationType': null});
      expect(legacy.notificationType, NotificationType.normal);
      expect(legacy.waitlistPromotion, isNull);
    });

    test('判定不能のエラーは「一意に判定できません」と具体的な理由(行番号つき)を示す', () {
      final e = CallableImportService.errorFrom(400, {
        'error': {
          'status': 'FAILED_PRECONDITION',
          'details': {
            'code': 'waitlist-undetermined',
            'reasons': [
              {'code': 'sheet-name-not-time-range'},
              {'code': 'count-missing', 'sourceRowNumber': 3},
            ],
          },
        },
      });
      expect(e.code, 'waitlist-undetermined');
      expect(e.message, contains('このファイルは繰り上げ先を一意に判定できません。'));
      expect(e.message, contains('シート名を時間枠'));
      expect(e.message, contains('3行目: キャンセル待ち希望人数が空です'));
    });
  });

  group('取込画面', () {
    testWidgets('通知種別を選ぶまで検証へ進めない。繰り上げを選ぶと判定規則・シート名を送り、検証結果の冒頭に種別・メール・件数・繰り上げ先', (tester) async {
      final service = FakeImportService(
        event: _summary,
        validateHandler: (request) async => ImportValidation.fromJson(_validationJson(
          type: request.json['notificationType'] as String? ?? 'normal',
          waitlist: request.json['notificationType'] == 'waitlistPromotion'
              ? {
                  'programId': 'program-2', 'slotLabel': '15:30-16:10', 'kind': '犬',
                  'rows': [{'sourceRowNumber': 2, 'plannedCount': 1}, {'sourceRowNumber': 3, 'plannedCount': 2}],
                }
              : null,
        )),
      );
      await _openImport(tester, service, () => (name: '【犬15時30分～16時10分】架空の繰り上げリスト.xlsx', bytes: _waitlistXlsx()));
      expect(find.byKey(const ValueKey('notification-normal')), findsOneWidget);
      expect(find.byKey(const ValueKey('notification-waitlistPromotion')), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsNothing, reason: '通知種別を選ぶまで検証へ進めない');
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('pick-file'))).onPressed, isNull, reason: '通知種別を選ぶまでファイル選択へ進めない');
      // program・犬猫・時間枠・人数・シートを入力・選択させる欄は無い
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);

      await _tap(tester, const ValueKey('notification-waitlistPromotion'));
      expect(find.text('使用メール：お席のご用意ができました：ご参加予約確定のお知らせ'), findsOneWidget);
      await _tap(tester, const Key('pick-file'));
      expect(find.byKey(const Key('file-sheet')), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'ファイル選択後も、繰り上げ先を入力させる欄は無い');
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await _tap(tester, const Key('run-validate'));
      final sent = service.validations.single.json;
      expect(sent['notificationType'], 'waitlistPromotion');
      expect(sent['sourceSheetName'], '15時30分～16時10分');
      expect(sent['sourceSheetCandidates'], ['15時30分～16時10分'], reason: 'サーバーが対象のシートが1枚であることを確かめる');
      expect((sent['mapping'] as Map)['waitlist'], isNotNull);
      expect((sent['mapping'] as Map)['autoExcludeRows'], isNotNull, reason: 'キャンセル行があるので自動除外の規則を入れる');
      expect(find.text('通知種別：キャンセル待ち繰り上げ当選'), findsOneWidget);
      expect(find.byKey(const Key('summary-waitlist-target')), findsOneWidget);
      expect(find.textContaining('架空の譲渡会（いぬ）　15:30-16:10'), findsOneWidget);
      expect(find.textContaining('2行目 1名、3行目 2名'), findsOneWidget);
      expect(find.textContaining('1行(原本でキャンセル)'), findsOneWidget);
      expect(find.textContaining('今回の取込から除外(原本でキャンセル・自動除外)'), findsOneWidget);
      expect(find.byKey(const ValueKey('unexclude-4')), findsNothing, reason: '自動除外は取り消せない');

      // 通知種別を変えたら、検証はやり直し
      await _tap(tester, const ValueKey('notification-normal'));
      expect(find.byKey(const Key('notification-summary')), findsNothing);
      expect(find.byKey(const Key('notification-mixup')), findsOneWidget, reason: '繰り上げリストらしいファイルを通常当選に指定した');
      await _tap(tester, const Key('run-validate'));
      expect(service.validations.last.json.containsKey('notificationType'), isFalse);
      expect(service.validations.last.json.containsKey('sourceSheetCandidates'), isFalse, reason: '通常当選のリクエストは従来と同じ');
      expect((service.validations.last.json['mapping'] as Map).containsKey('waitlist'), isFalse);
      expect(find.text('通知種別：通常当選'), findsOneWidget);
    });

    testWidgets('通常当選のまま繰り上げらしいファイルを進めると、取り違えの警告が通知種別の欄・検証結果・プレビュー・確定の確認まで残る(種別は変えない)', (tester) async {
      final service = FakeImportService(event: _summary);
      await _openImport(tester, service, () => (name: '架空の繰り上げリスト.xlsx', bytes: _waitlistXlsx()));
      await _tap(tester, const ValueKey('notification-normal'));
      await _tap(tester, const Key('pick-file'));
      const message = 'キャンセル待ち繰り上げ用ファイルの可能性があります。通知種別が「通常当選」で正しいか確認してください。';
      Finder warningIn(String key) => find.descendant(of: find.byKey(Key(key)), matching: find.text(message));
      expect(warningIn('notification-mixup'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: '新しい入力欄は作らない');
      expect(find.byType(Checkbox), findsNothing, reason: '警告の確認用のチェックボックスも作らない');

      await _tap(tester, const Key('run-validate'));
      expect(warningIn('validation-mixup'), findsOneWidget, reason: '検証結果にも残す');
      for (final key in ['allow-all-review', 'ack-existing-duplicates', 'ack-csv-duplicates', 'ack-new-import']) {
        if (find.byKey(Key(key)).evaluate().isNotEmpty) await _tap(tester, Key(key));
      }
      await _tap(tester, const Key('run-preview'));
      expect(warningIn('preview-mixup'), findsOneWidget, reason: 'プレビューにも残す');
      expect(find.textContaining('シート名が時間枠(「15時30分～16時10分」)'), findsWidgets);

      await _tap(tester, const Key('commit'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(message)), findsOneWidget, reason: '取込確定の直前にも残す');
      expect(find.byKey(const Key('confirm-mixup')), findsOneWidget);
      // 通知種別はシステムが変えない(通常当選のまま。止めもしない)
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('通常当選')), findsOneWidget);
      expect(service.validations.every((r) => !r.json.containsKey('notificationType')), isTrue);
      expect(service.previews.single.json.containsKey('notificationType'), isFalse);
      await tester.tap(find.text('キャンセル'));
      await tester.pumpAndSettle();
      expect(service.commits, isEmpty);
    });

    testWidgets('通常のファイル(シート名が時間枠でない)には、取り違えの警告を出さない', (tester) async {
      final service = FakeImportService(event: _summary);
      await _openImport(tester, service, () => (name: '架空の申込リスト.xlsx', bytes: _waitlistXlsx(sheet: '申込情報')));
      await _tap(tester, const ValueKey('notification-normal'));
      await _tap(tester, const Key('pick-file'));
      await _tap(tester, const Key('run-validate'));
      for (final key in ['allow-all-review', 'ack-existing-duplicates', 'ack-csv-duplicates', 'ack-new-import']) {
        if (find.byKey(Key(key)).evaluate().isNotEmpty) await _tap(tester, Key(key));
      }
      await _tap(tester, const Key('run-preview'));
      await _tap(tester, const Key('commit'));
      expect(find.byType(AlertDialog), findsOneWidget);
      for (final key in ['notification-mixup', 'validation-mixup', 'preview-mixup', 'confirm-mixup']) {
        expect(find.byKey(Key(key)), findsNothing, reason: key);
      }
    });

    testWidgets('CSVを繰り上げ当選として取り込もうとすると止める(シート名が無く、繰り上げ先を一意に判定できない)', (tester) async {
      final service = FakeImportService(event: _summary);
      final csv = [
        _waitlistHeaders.join(','),
        _row(1, '提出なし', wait: '"$_dogAll"', waitN: '1名').map((c) => c?.toString() ?? '').join(','),
      ].join('\n');
      await _openImport(tester, service, () => (name: '架空.csv', bytes: Uint8List.fromList(utf8.encode(csv))));
      await _tap(tester, const ValueKey('notification-waitlistPromotion'));
      await _tap(tester, const Key('pick-file'));
      expect(find.byKey(const Key('notification-error')), findsOneWidget);
      expect(find.textContaining('このファイルは繰り上げ先を一意に判定できません'), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsNothing);
    });

    testWidgets('対象のシートが複数あるExcelは、繰り上げ当選として取り込まない(シートを選ばせて時間枠を決めさせない)', (tester) async {
      final service = FakeImportService(event: _summary);
      final bytes = buildXlsx([
        XSheet('14時10分～14時50分', [_waitlistHeaders, _row(1, '提出なし', wait: _dogAll, waitN: '1名')]),
        XSheet('15時30分～16時10分', [_waitlistHeaders, _row(2, '提出なし', wait: _dogAll, waitN: '2名')]),
      ]);
      await _openImport(tester, service, () => (name: '架空の繰り上げリスト.xlsx', bytes: bytes));
      await _tap(tester, const ValueKey('notification-waitlistPromotion'));
      await _tap(tester, const Key('pick-file'));
      await _tap(tester, const ValueKey('choose-sheet-15時30分～16時10分'));
      expect(find.byKey(const Key('notification-error')), findsOneWidget);
      expect(find.textContaining('対象のシートが2枚あり'), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsNothing);
      expect(service.validations, isEmpty);
    });

    test('匿名fixtureのExcel(繰り上げ)を読み、シート名・列が読み取れる', () {
      final sheets = readXlsxSheets(_waitlistXlsx());
      expect(sheets.single.name, '15時30分～16時10分');
      expect(sheets.single.rows.first, _waitlistHeaders);
    });
  });

  group('送信管理・最終実績・繰り上げ当選メール', () {
    testWidgets('取込回ごとに通知種別を表示し、送信前の確認に通知種別・件名・件数を示す(テンプレートは選べない)', (tester) async {
      final normal = committed('bnormal', 1, 3);
      final w = committed('bwait', 2, 2);
      final waitlist = SendBatch(
        batchId: w.batchId, sequence: w.sequence, label: w.label, status: w.status, canCreateJob: true, blockedReasons: const [],
        importedCount: 2, targetCount: 2, excludedInactiveCount: 0, consistent: true, previewParticipantId: 'p002',
        notificationType: 'waitlistPromotion', notificationTypeLabel: 'キャンセル待ち繰り上げ当選',
        mailSubject: '【お席のご用意ができました：ご参加予約確定のお知らせ】 架空', mailTemplateVersion: 1,
      );
      final service = FakeSendService(batches: [normal, waitlist]);
      await tester.binding.setSurfaceSize(const Size(900, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: WinnerSendPage(initialEventId: 'evfixture', service: service, mailService: FakeMailService()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('通知種別：通常当選'), findsOneWidget);
      expect(find.text('通知種別：キャンセル待ち繰り上げ当選'), findsOneWidget);
      expect(find.text('【お席のご用意ができました：ご参加予約確定のお知らせ】 架空'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing, reason: 'テンプレートを選ぶ欄は無い');
      // 既存の取込回(通知種別の項目なし)は通常当選
      final legacy = SendBatch.fromJson({'batchId': 'b1', 'sequence': 1, 'label': '第1回', 'status': 'committed'});
      expect(legacy.notificationType, 'normal');
      expect(legacy.notificationTypeLabel, '通常当選');
    });

    test('最終実績Excel: 通知種別の列(既存の取込回は通常当選)', () {
      final report = AttendanceReport.fromJson({
        'eventId': 'ev', 'eventName': '架空',
        'programs': [{'programId': 'program-2', 'name': '架空の譲渡会（いぬ）'}],
        'participants': [
          {'participantId': 'a', 'importSequence': 1, 'batchCommitted': true, 'name': '架空 一', 'kana': 'かくう', 'email': 'a@example.invalid',
            'status': 'active', 'programs': <Object>[]},
          {'participantId': 'b', 'importSequence': 2, 'batchCommitted': true, 'notificationType': 'waitlistPromotion', 'name': '架空 二',
            'kana': 'かくう', 'email': 'b@example.invalid', 'status': 'active',
            'programs': [{'programId': 'program-2', 'plannedCount': 2, 'timeText': '15:30-16:10', 'checkedIn': false}]},
        ],
      });
      final rows = readXlsxSheets(buildAttendanceReportXlsx(report, exportedAt: DateTime.utc(2026, 11, 30)).bytes).single.rows;
      final col = rows.first.indexOf('通知種別');
      expect(col, 6);
      expect(rows[1][col], '通常当選');
      expect(rows[2][col], 'キャンセル待ち繰り上げ当選');
    });

    testWidgets('繰り上げ当選メール: 文案を入力して保存できる(通常当選メールとは別)', (tester) async {
      final service = FakeWinnerMailService(settings: WinnerMailSettings.fromJson({
        'eventId': 'evfixture',
        'event': {'eventName': '架空イベント', 'venue': '架空会場'},
        'template': {'subject': '【ご参加予約確定のお知らせ】 架空', 'introBody': '架空の冒頭', 'closingBody': '架空の締め', 'version': 1},
        'ready': true, 'problems': <String>[], 'missingOptional': <String>[],
        'suggestedWaitlistTemplate': {'subject': '【お席のご用意ができました：ご参加予約確定のお知らせ】 架空', 'introBody': '架空', 'closingBody': '架空'},
        'previewParticipantId': 'p001',
      }));
      await tester.binding.setSurfaceSize(const Size(900, 6000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: WinnerMailPage(initialEventId: 'evfixture', service: service)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('waitlist-mail-card')), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, '繰り上げ当選メールの件名'), '【お席のご用意ができました：ご参加予約確定のお知らせ】 架空');
      await tester.enterText(find.widgetWithText(TextField, '繰り上げ当選メールの冒頭本文'), 'キャンセル待ちで承っておりましたお席のご用意ができました');
      await tester.enterText(find.widgetWithText(TextField, '繰り上げ当選メールの締め本文'), '架空の締め');
      await _tap(tester, const Key('save-waitlist-template'));
      expect(service.calls, contains('updateWaitlist:evfixture:【お席のご用意ができました：ご参加予約確定のお知らせ】 架空'));
      expect(service.calls.where((c) => c.startsWith('update:')), isEmpty, reason: '通常当選メールは保存しない');
    });
  });
}
