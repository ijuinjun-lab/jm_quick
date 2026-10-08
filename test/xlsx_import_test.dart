// Excel(.xlsx)直接取込とHEBEL属性。すべて匿名の小さなfixture(test/xlsx_fixture.dartがメモリ上で生成)。
//  - xlsxを読める(共有文字列・ふりがな除外・インライン文字列・数値・日付・数式・結合セル・空の行)
//  - CSVとExcelは入口(読み取り)だけが違い、その後は共通の表 → 同じリクエスト(検証・対処・プレビュー・取込)
//  - シート: 1つなら自動、合うシートが複数なら管理者が選ぶ(先頭を勝手に使わない)。空・非表示・不正なファイル
//  - HEBEL属性: header名の正規化で列を見つける(「&#160;」表記)。列が無いファイル(既存CSV)は従来と同じmapping
//  - 検証画面のHEBEL属性の集計・行ごとの表示 / 受付画面(正式staff・受付キー)の表示
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/import_file.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/import_profile.dart';
import 'package:jm_quick/confirmed/import_service.dart';
import 'package:jm_quick/confirmed/reception_page.dart';
import 'package:jm_quick/confirmed/reception_service.dart';
import 'package:jm_quick/confirmed/reception_staff_key_service.dart';
import 'package:jm_quick/confirmed/xlsx_reader.dart';

import 'app_check_fake.dart';
import 'xlsx_fixture.dart';

const _programs = [
  (programId: 'program-1', name: '架空プログラムA', order: 0),
  (programId: 'program-2', name: '架空プログラムB', order: 1),
  (programId: 'program-3', name: '架空プログラムZ', order: 2),
];

/// HEBEL分類A・分類B・該当なし・空欄・未知値、犬/猫/トーク・人数・時間を含む匿名の参加者リスト。
/// 5行目は空の行(空のレコードとして数える)。末尾の空の行は数えない。
List<List<Object?>> _fixtureRows() => [
  fixtureHeaders,
  fixtureRow(1, hebel: hebelHausOption),
  fixtureRow(2, hebel: hebelMaisonOption, am: '参加を希望しない', amCount: null, pm: '14:10-14:50', pmCount: 3),
  fixtureRow(3, hebel: hebelNoneOption, talk: '参加を希望しない', talkCount: null),
  const [],
  fixtureRow(5, hebel: null, pm: '15:30-16:10', pmCount: 1),
  fixtureRow(6, hebel: const XInline('架空の未知の回答')),
  const [],
];

Uint8List _fixtureXlsx({List<XSheet>? sheets}) =>
    buildXlsx(sheets ?? [XSheet('申込情報', _fixtureRows())]);

void main() {
  group('xlsxの読み取り', () {
    test('セルの表データを読む: ふりがなを含めない・数値は整数表記・インライン文字列・日付・数式のキャッシュ・結合セル', () {
      final bytes = buildXlsx([
        XSheet(
          'S',
          [
            ['見出し', '数値', '小数', '日付', '数式', '結合'],
            [const XPhonetic('新規申込', 'シンキモウシコミ'), 2, 2.5, const XDate(46296.5), const XFormula('B2*2', 4), 'X'],
          ],
          merges: ['F2:G2'],
        ),
      ]);
      final sheet = readXlsxSheets(bytes).single;
      expect(sheet.rows[1], ['新規申込', '2', '2.5', '2026-10-01 12:00:00', '4', 'X']);
      expect(sheet.mergedRangeCount, 1);
      expect(sheet.formulaCellCount, 1);
      expect(sheet.hidden, isFalse);
    });

    test('不正なxlsx(zipでない・ブックの無いzip)は、画面に出せる理由で拒否する', () {
      expect(
        () => parseImportFile('架空.xlsx', Uint8List.fromList(utf8.encode('not a zip'))),
        throwsA(isA<ImportFileException>().having((e) => e.message, 'message', contains('Excelファイル(.xlsx)として読み取れません'))),
      );
      expect(() => parseImportFile('架空.xlsx', Uint8List(0)), throwsA(isA<ImportFileException>()));
    });

    test('対応していない形式(.xls・その他の拡張子)は読み取る前に拒否する', () {
      expect(
        () => parseImportFile('架空.xls', Uint8List(4)),
        throwsA(isA<ImportFileException>().having((e) => e.message, 'message', contains('.xlsx'))),
      );
      expect(() => parseImportFile('架空.txt', Uint8List(4)), throwsA(isA<ImportFileException>()));
    });

    test('Excelのシートは共通の表にそろえる: 列名=1行目、間の空の行は空のレコード、末尾の空の行は含めない、短い行は列名の数まで空で埋める', () {
      final file = parseImportFile('架空.xlsx', _fixtureXlsx());
      expect(file.format, ImportFileFormat.xlsx);
      final sheet = file.sheets.single;
      expect(sheet.name, '申込情報');
      final table = sheet.table!;
      expect(table.headers, fixtureHeaders);
      expect(table.records.length, 6); // 2〜7行目(末尾の空の行は除く)
      expect(table.records[3], isEmpty); // 5行目 = 空のレコード
      expect(table.records.where((r) => r.isNotEmpty).every((r) => r.length == fixtureHeaders.length), isTrue);
      expect(table.records[0][0], '新規申込');
      expect(table.records[0][7], '2'); // 数値の人数
      expect(table.records[0][9], ''); // 空のセル
      expect(table.records[4][5], ''); // HEBEL属性の空欄
      expect(table.records[5][5], '架空の未知の回答');
    });

    test('先頭に空の行があるシートは、値のある最初の行を列名とし、その行番号を示す', () {
      final file = parseImportFile('架空.xlsx', buildXlsx([XSheet('S', [const [], fixtureHeaders, fixtureRow(1, hebel: hebelNoneOption)])]));
      expect(file.sheets.single.headerRowNumber, 2);
      expect(file.sheets.single.table!.records.length, 1);
    });
  });

  group('シートの選択', () {
    const profile = currentConfirmedImportProfile;

    test('形式に合うシートが1つなら自動で選ぶ(他のシート・非表示のシートは使わない)', () {
      final file = parseImportFile('架空.xlsx', _fixtureXlsx(sheets: [
        XSheet('メモ', [['説明'], ['架空のメモ']]),
        XSheet('申込情報', _fixtureRows()),
        XSheet('非表示', _fixtureRows(), hidden: true),
      ]));
      final s = selectImportSheet(file, profile);
      expect(s.selected?.name, '申込情報');
      expect(s.candidates, isEmpty);
    });

    test('形式に合うシートが複数あれば、先頭を勝手に使わず候補を返す(管理者が選ぶ)', () {
      final file = parseImportFile('架空.xlsx', _fixtureXlsx(sheets: [
        XSheet('第1回', _fixtureRows()),
        XSheet('第2回', _fixtureRows()),
      ]));
      final s = selectImportSheet(file, profile);
      expect(s.selected, isNull);
      expect(s.candidates.map((c) => c.name), ['第1回', '第2回']);
    });

    test('空のシートだけ → 理由を返す。データのあるシートが1つだけ(形式が違う) → それを選び、不足列は通常の表示で示す', () {
      final empty = parseImportFile('架空.xlsx', buildXlsx([const XSheet('空', [])]));
      expect(empty.sheets.single.isEmpty, isTrue);
      final s1 = selectImportSheet(empty, profile);
      expect(s1.selected, isNull);
      expect(s1.problem, contains('データのある'));
      final other = parseImportFile('架空.xlsx', buildXlsx([const XSheet('空', []), XSheet('別形式', [['名前'], ['架空']])]));
      final s2 = selectImportSheet(other, profile);
      expect(s2.selected?.name, '別形式');
      expect(profile.missingHeaders(s2.selected!.table!.headers), isNotEmpty);
    });

    test('形式に合わないデータのあるシートが複数 → 選べない理由を返す', () {
      final file = parseImportFile('架空.xlsx', buildXlsx([XSheet('A', [['x'], ['1']]), XSheet('B', [['y'], ['2']])]));
      final s = selectImportSheet(file, profile);
      expect(s.selected, isNull);
      expect(s.candidates, isEmpty);
      expect(s.problem, contains('「A」'));
    });

    test('CSVは常にファイル全体を使う', () {
      final file = parseImportFile('架空.csv', Uint8List.fromList(utf8.encode('${fixtureHeaders.join(',')}\n')));
      expect(selectImportSheet(file, profile).selected, same(file.sheets.single));
    });
  });

  group('header mapping(HEBEL属性)', () {
    const profile = currentConfirmedImportProfile;

    test('「&#160;」表記・ノーブレークスペース・全角の揺れがあっても、HEBEL属性の列(実際の列名)を見つける', () {
      for (final header in ['HEBEL&#160;HAUSにお住まいですか', 'HEBEL HAUSにお住まいですか', 'ＨＥＢＥＬ　ＨＡＵＳにお住まいですか', 'HEBEL HAUSにお住まいですか']) {
        expect(profile.resolveHebelResidenceColumn(['氏名', header]), (column: header, ambiguous: false), reason: header);
      }
      expect(profile.resolveHebelResidenceColumn(['氏名', 'HdBdL&#210;HdkSにお住まいですか']).column, isNull);
      expect(
        profile.resolveHebelResidenceColumn(['HEBEL HAUSにお住まいですか', 'HEBEL&#160;HAUSにお住まいですか']),
        (column: null, ambiguous: true),
      );
    });

    test('HEBEL属性の列は必須ではない(列が無いファイルも従来どおり対応する形式)', () {
      expect(profile.requiredHeaders.any((h) => h.contains('HEBEL')), isFalse);
    });

    test('列が無いファイルのmappingは従来と完全に同じ(HEBEL属性の項目を送らない)。列があるときだけ送る', () {
      final legacy = buildMappingFromProfile(profile, _programs);
      expect((legacy.toJson()['participant'] as Map).containsKey('hebelResidenceColumn'), isFalse);
      expect(legacy.mappedColumns().any((c) => c.contains('HEBEL')), isFalse);
      final withHebel = buildMappingFromProfile(profile, _programs, hebelResidenceColumn: 'HEBEL&#160;HAUSにお住まいですか');
      expect((withHebel.toJson()['participant'] as Map)['hebelResidenceColumn'], 'HEBEL&#160;HAUSにお住まいですか');
      expect(withHebel.mappedColumns(), [...legacy.mappedColumns().take(4), 'HEBEL&#160;HAUSにお住まいですか', ...legacy.mappedColumns().skip(4)]);
      expect(withHebel.validate(), isEmpty);
    });
  });

  group('CSVとExcelの共通化', () {
    const profile = currentConfirmedImportProfile;

    String csvOf(List<List<Object?>> rows) => rows
        .take(rows.length - 1) // 末尾の空の行はCSVでは書かない
        .map((r) => List.generate(fixtureHeaders.length, (i) {
              final v = i < r.length ? r[i] : null;
              return switch (v) {
                null => '',
                XPhonetic p => p.text,
                XInline x => x.text,
                _ => '$v',
              };
            }).join(','))
        .join('\n');

    test('同じ内容のCSVとExcelは、同じ表・同じmapping・同じ行(rows/blankRecordNumbers)のリクエストになる', () {
      final xlsxBytes = _fixtureXlsx();
      final csvBytes = Uint8List.fromList(utf8.encode('${csvOf(_fixtureRows())}\n'));
      final xlsx = parseImportFile('架空.xlsx', xlsxBytes).sheets.single.table!;
      final csv = parseImportFile('架空.csv', csvBytes).sheets.single.table!;
      expect(xlsx.headers, csv.headers);
      ImportRequest build(CsvTable t, Uint8List bytes, String name, {String? sheet}) => buildImportRequest(
        eventId: 'evfixture',
        fileName: name,
        fileBytes: bytes,
        table: t,
        mapping: buildMappingFromProfile(profile, _programs, hebelResidenceColumn: profile.resolveHebelResidenceColumn(t.headers).column),
        sheetName: sheet,
      );
      final a = build(xlsx, xlsxBytes, '架空.xlsx', sheet: '申込情報');
      final b = build(csv, csvBytes, '架空.csv');
      for (final key in ['mapping', 'headers', 'rows', 'totalRecords', 'blankRecordNumbers']) {
        expect(jsonEncode(a.json[key]), jsonEncode(b.json[key]), reason: key);
      }
      expect(a.json['blankRecordNumbers'], [5]);
      expect(a.json['totalRecords'], 6);
      expect(a.batchId, isNot(b.batchId)); // ファイルの内容(ハッシュ)が違う
    });

    test('CSVのbatchIdは従来と同じ(シート名を含めない)。Excelは同じファイルでもシートが違えば別の取込', () {
      final mapping = buildMappingFromProfile(profile, _programs).toJson();
      final legacy = deriveBatchId(eventId: 'ev', fileHash: '0' * 64, mappingJson: mapping);
      expect(deriveBatchId(eventId: 'ev', fileHash: '0' * 64, mappingJson: mapping, sheetName: null), legacy);
      final s1 = deriveBatchId(eventId: 'ev', fileHash: '0' * 64, mappingJson: mapping, sheetName: '第1回');
      final s2 = deriveBatchId(eventId: 'ev', fileHash: '0' * 64, mappingJson: mapping, sheetName: '第2回');
      expect({legacy, s1, s2}.length, 3);
    });

    test('検証の応答: HEBEL属性の集計と行ごとの分類を読む(列が無い応答では空)', () {
      final v = ImportValidation.fromJson(_validationJson());
      expect(v.hebelResidenceSummary.map((h) => (h.category, h.count)), [
        ('hebelHaus', 1), ('hebelMaison', 1), ('none', 1), ('unset', 1), ('unknown', 1),
      ]);
      expect(v.rows.firstWhere((r) => r.sourceRowNumber == 7).hebelResidence, 'unknown');
      expect(v.hebelResidenceLabel('none'), '該当なし（いいえ）');
      final legacy = ImportValidation.fromJson({'rows': [{'sourceRowNumber': 2, 'classification': 'ready', 'result': 'ok'}]});
      expect(legacy.hebelResidenceSummary, isEmpty);
      expect(legacy.rows.single.hebelResidence, isNull);
    });
  });

  group('取込画面(Excel)', () {
    testWidgets('Excelを選ぶと形式・シート名・データ行数を表示し、HEBEL属性の列を自動で認識。検証画面に分類別の件数と行ごとの属性を出す', (tester) async {
      final service = _FakeService();
      await _openPage(tester, service, () => (name: '架空申込リスト.xlsx', bytes: _fixtureXlsx()));
      expect(find.text('参加者ファイルを選択'), findsNothing); // 選択済み
      expect(find.text('選択中: 架空申込リスト.xlsx'), findsOneWidget);
      expect(find.text('形式: Excel（.xlsx）'), findsOneWidget);
      expect(find.text('シート: 申込情報'), findsOneWidget);
      expect(find.text('データ行数: 6行(列数: ${fixtureHeaders.length}列)'), findsOneWidget);
      expect(find.textContaining('「HEBEL&#160;HAUSにお住まいですか」列から読み取ります'), findsOneWidget);

      await tester.tap(find.byKey(const Key('run-validate')));
      await tester.pumpAndSettle();
      final request = service.validations.single;
      expect((request.json['mapping']['participant'] as Map)['hebelResidenceColumn'], 'HEBEL&#160;HAUSにお住まいですか');
      expect(request.json['headers'], contains('HEBEL&#160;HAUSにお住まいですか'));

      expect(find.byKey(const Key('hebel-residence-summary')), findsOneWidget);
      for (final (key, label) in [
        ('hebelHaus', hebelHausOption), ('hebelMaison', hebelMaisonOption), ('none', '該当なし（いいえ）'),
        ('unset', '未設定（空欄）'), ('unknown', '未知のHEBEL属性'),
      ]) {
        final row = find.byKey(ValueKey('hebel-residence-count-$key'));
        expect(find.descendant(of: row, matching: find.text(label)), findsOneWidget, reason: key);
        expect(find.descendant(of: row, matching: find.text('1件')), findsOneWidget, reason: key);
      }
      expect(find.byKey(const Key('hebel-residence-unknown-notice')), findsOneWidget);
      // 未知の値の行: 問題の内容に原文を示し、HEBEL属性の列を修正できる
      expect(find.textContaining('HEBEL属性：「架空の未知の回答」は申込フォームの選択肢と一致しません'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('edit-7')));
      await tester.tap(find.byKey(const ValueKey('edit-7')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-7-HEBEL&#160;HAUSにお住まいですか')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cancel-edit-7')));
      await tester.pumpAndSettle();
      // 行ごとのHEBEL属性
      await tester.ensureVisible(find.byKey(const Key('hebel-residence-rows')));
      await tester.tap(find.text('行ごとのHEBEL属性(5件)'));
      await tester.pumpAndSettle();
      expect(find.text('2行目　架空 参加者1　$hebelHausOption'), findsOneWidget);
      expect(find.text('6行目　架空 参加者5　未設定（空欄）'), findsOneWidget);
      expect(find.text('7行目　架空 参加者6　未知のHEBEL属性(原文:「架空の未知の回答」)'), findsOneWidget);
    });

    testWidgets('形式に合うシートが複数あるExcelは、管理者がシートを選ぶまで検証できない。選んだシートで解析する', (tester) async {
      final service = _FakeService();
      final bytes = _fixtureXlsx(sheets: [
        XSheet('第1回', _fixtureRows()),
        XSheet('第2回', [fixtureHeaders, fixtureRow(1, hebel: hebelNoneOption)]),
      ]);
      await _openPage(tester, service, () => (name: '架空.xlsx', bytes: bytes));
      expect(find.byKey(const Key('sheet-chooser')), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsNothing);
      expect(find.byKey(const Key('file-sheet')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('choose-sheet-第2回')));
      await tester.pumpAndSettle();
      expect(find.text('シート: 第2回'), findsOneWidget);
      expect(find.text('データ行数: 1行(列数: ${fixtureHeaders.length}列)'), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsOneWidget);
    });

    testWidgets('不正なxlsxは理由を表示し、検証へ進めない', (tester) async {
      final service = _FakeService();
      await _openPage(tester, service, () => (name: '架空.xlsx', bytes: Uint8List.fromList([1, 2, 3])));
      expect(find.byKey(const Key('file-error')), findsOneWidget);
      expect(find.byKey(const Key('run-validate')), findsNothing);
    });

    testWidgets('HEBEL属性の列が無いCSVは従来どおり(属性は取り込まないと表示し、mappingに含めない)', (tester) async {
      final service = _FakeService();
      final headers = fixtureHeaders.where((h) => !h.contains('HEBEL')).toList();
      final csv = '${headers.join(',')}\n新規申込,1,架空 参加者1,かくう,fixture1@example.invalid,10:30-11:10,2,参加を希望しない,,参加を希望する,1,2026-09-01 10:00:00\n';
      await _openPage(tester, service, () => (name: '架空.csv', bytes: Uint8List.fromList(utf8.encode(csv))));
      expect(find.text('形式: CSV（.csv）'), findsOneWidget);
      expect(find.byKey(const Key('file-sheet')), findsNothing);
      expect(find.textContaining('このファイルには列がありません'), findsOneWidget);
      await tester.tap(find.byKey(const Key('run-validate')));
      await tester.pumpAndSettle();
      expect((service.validations.single.json['mapping']['participant'] as Map).containsKey('hebelResidenceColumn'), isFalse);
      expect(find.byKey(const Key('hebel-residence-summary')), findsNothing);
    });
  });

  group('受付画面のHEBEL属性', () {
    testWidgets('正式staffの受付: participant正本のHEBEL属性を表示する。属性が無い参加者は何も表示しない。受付操作はそのまま', (tester) async {
      Future<void> open(ReceptionView view) async {
        await tester.pumpWidget(MaterialApp(
          home: ConfirmedReceptionPage(
            key: UniqueKey(),
            service: _FakeReception(view),
            eventId: 'evfixture',
            participantId: 'pfixture',
            publicId: 'pub_fixture0123456789012345',
          ),
        ));
        await tester.pumpAndSettle();
      }

      await open(_view(const ReceptionHebelResidence(category: 'hebelMaison', label: hebelMaisonOption)));
      expect(find.text('HEBEL属性：$hebelMaisonOption'), findsOneWidget);
      expect(find.text('受付する'), findsOneWidget);

      await open(_view(const ReceptionHebelResidence(category: 'unknown', label: '未知のHEBEL属性', rawValue: '架空の未知の回答')));
      expect(find.text('HEBEL属性：未知のHEBEL属性（原文：架空の未知の回答）'), findsOneWidget);

      await open(_view(null));
      expect(find.byKey(const Key('reception-hebel-residence')), findsNothing);
      expect(find.textContaining('HEBEL'), findsNothing);
      expect(find.text('受付する'), findsOneWidget);
    });

    testWidgets('アカウント不要の受付(受付キー): サーバーの応答のHEBEL属性を同じ画面に表示する', (tester) async {
      Map<String, dynamic>? hebel;
      final client = MockClient((request) async {
        final name = request.url.pathSegments.last;
        expect(name, 'getConfirmedReceptionViewByStaffKey');
        return http.Response(
          jsonEncode({
            'result': {
              'eventId': 'evfixture',
              'eventName': '架空イベント',
              'participantName': '架空 参加者',
              'hebelResidence': ?hebel,
              'programs': [
                {'programId': 'program-1', 'name': '架空プログラムA', 'plannedCount': 2, 'checkedIn': false},
              ],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = ReceptionStaffKeyService(
        eventId: 'evfixture',
        receptionKey: 'rk_fixture',
        httpClient: client,
        appCheck: FakeAppCheck(),
        baseUrl: 'https://functions.invalid',
      );
      Future<void> open() async {
        await tester.pumpWidget(MaterialApp(
          home: ConfirmedReceptionPage(
            key: UniqueKey(),
            service: service,
            eventId: 'evfixture',
            participantId: 'pfixture',
            publicId: 'pub_fixture0123456789012345',
          ),
        ));
        await tester.pumpAndSettle();
      }

      hebel = {'category': 'hebelHaus', 'label': hebelHausOption};
      await open();
      expect(find.text('HEBEL属性：$hebelHausOption'), findsOneWidget);
      hebel = null;
      await open();
      expect(find.byKey(const Key('reception-hebel-residence')), findsNothing);
    });

    test('受付の応答のHEBEL属性は、形が不正なら表示しない(落とさない)', () {
      expect(ReceptionView.fromJson({'hebelResidence': 'none'}).hebelResidence, isNull);
      expect(ReceptionView.fromJson({'hebelResidence': {'label': 'x'}}).hebelResidence, isNull);
      expect(ReceptionView.fromJson({}).hebelResidence, isNull);
    });
  });

  group('境界の静的検査', () {
    test('HEBEL属性(hebelResidence)は、参加証・QR・メールの画面/サービスのコードに入っていない', () {
      for (final path in [
        'lib/confirmed/pass_page.dart',
        'lib/confirmed/pass_service.dart',
        'lib/confirmed/winner_mail_page.dart',
        'lib/confirmed/winner_mail_service.dart',
        'lib/confirmed/winner_send_page.dart',
        'lib/confirmed/winner_send_service.dart',
        'lib/confirmed/reminder_page.dart',
        'lib/confirmed/reminder_service.dart',
      ]) {
        final source = File(path).readAsStringSync();
        // イベント名の文案(「HEBEL HAUS×sippo」)は対象外。属性のフィールド・表示名だけを見る
        expect(source.contains('hebelResidence') || source.contains('HEBEL属性'), isFalse, reason: path);
      }
    });
  });
}

Map<String, dynamic> _validationJson() => {
  'batchId': 'b1',
  'totalRecords': 6,
  'totalRows': 5,
  'blankRecordCount': 1,
  'okCount': 4,
  'warningCount': 1,
  'errorCount': 0,
  'findingCounts': {'hebel-residence-unknown': 1},
  'nextImportSequence': 1,
  'hebelResidenceSummary': [
    {'category': 'hebelHaus', 'label': hebelHausOption, 'count': 1},
    {'category': 'hebelMaison', 'label': hebelMaisonOption, 'count': 1},
    {'category': 'none', 'label': '該当なし（いいえ）', 'count': 1},
    {'category': 'unset', 'label': '未設定（空欄）', 'count': 1},
    {'category': 'unknown', 'label': '未知のHEBEL属性', 'count': 1},
  ],
  'reviewRows': [7],
  'rows': [
    for (final (n, c) in [(2, 'hebelHaus'), (3, 'hebelMaison'), (4, 'none'), (6, 'unset'), (7, 'unknown')])
      {
        'sourceRowNumber': n,
        'classification': c == 'unknown' ? 'review' : 'ready',
        'result': c == 'unknown' ? 'warning' : 'ok',
        'findings': [
          if (c == 'unknown') {'code': 'hebel-residence-unknown', 'severity': 'warning'},
        ],
        'programIds': ['program-1'],
        'hebelResidence': c,
        if (c == 'unknown') 'approvalKeys': {'review': 'a' * 64},
      },
  ],
};

class _FakeService implements ImportService {
  final List<ImportRequest> validations = [];

  @override
  Future<ImportEventSummary> getEvent(String eventId) async => const ImportEventSummary(
    eventId: 'evfixture',
    eventName: '架空イベント',
    startAt: null,
    venue: '架空ホール',
    programs: _programs,
  );

  @override
  Future<ImportValidation> validate(ImportRequest request) async {
    validations.add(request);
    final hasHebel = (request.json['mapping']['participant'] as Map).containsKey('hebelResidenceColumn');
    final json = _validationJson();
    if (!hasHebel) {
      json.remove('hebelResidenceSummary');
      for (final r in json['rows'] as List) {
        (r as Map).remove('hebelResidence');
      }
    }
    return ImportValidation.fromJson(json);
  }

  @override
  Future<ImportPreview> preview(ImportRequest request) async => throw UnimplementedError();

  @override
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
    ImportValidation? validation,
    bool acknowledgeExistingEmailDuplicates = false,
    bool acknowledgeCsvEmailDuplicates = false,
    List<String> approvalKeys = const [],
  }) async => throw UnimplementedError();
}

Future<void> _openPage(WidgetTester tester, ImportService service, PickedCsv Function() pick) async {
  await tester.binding.setSurfaceSize(const Size(900, 5000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: ConfirmedImportPage(eventId: 'evfixture', service: service, picker: () async => pick()),
  ));
  await tester.pumpAndSettle();
}

ReceptionView _view(ReceptionHebelResidence? hebel) => ReceptionView(
  eventName: '架空イベント',
  participantName: '架空 参加者',
  hebelResidence: hebel,
  programs: const [
    ReceptionProgram(programId: 'program-1', name: '架空プログラムA', plannedCount: 2, checkedIn: false),
  ],
);

class _FakeReception implements ReceptionService {
  _FakeReception(this.view);
  final ReceptionView view;

  @override
  Future<ReceptionView> getView({required String eventId, required String participantId, required String publicId}) async => view;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
