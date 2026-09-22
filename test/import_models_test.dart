// Phase 11B: confirmed CSV取込のクライアント側モデル(CSV読込・列の対応・リクエスト組み立て)。
// 共有fixture(functions/test/fixtures/import_ui_case.json。完全な架空データ)で、サーバーAPIが受け付ける形と一致することを確認する
// (同じfixtureをサーバー側のEmulatorテストが previewConfirmedImport / commitConfirmedImport へ実際に送る)。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/import_models.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'functions/test/fixtures/import_ui_case.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

ImportMapping _mapping() {
  final m = ImportMapping(
    programs: [
      ProgramMapping(programId: 'program-a', name: 'A'),
      ProgramMapping(programId: 'program-b', name: 'B'),
      ProgramMapping(programId: 'custom-zeta-9', name: 'Z'),
    ],
  );
  m.externalIdColumn = 'rd';
  m.nameColumn = '氏名';
  m.kanaColumn = 'かな';
  m.emailColumn = 'メールアドレス';
  m.registeredAtColumn = '登録日時';
  m.rowChecks.add(RowCheck(column: '区分', allowedValues: ['新規申込']));
  final a = m.programs[0]
    ..slotColumn = '午前参加時間'
    ..slotFormat = 'timeRange'
    ..countColumn = '午前参加人数';
  final b = m.programs[1]
    ..slotColumn = '午後参加時間'
    ..slotFormat = 'timeRange'
    ..countColumn = '午後参加人数';
  final z = m.programs[2]..countColumn = 'トークショー人数';
  expect([a, b, z].length, 3);
  return m;
}

void main() {
  final csvText = _fixture['csvText'] as String;
  final eventId = _fixture['eventId'] as String;

  group('CSV読込', () {
    test('引用符・カンマ・セル内改行・CRLF・末尾の改行を正しく読む。全項目が空の行はレコードとして数える', () {
      final table = parseCsvBytes(_bytes(csvText));
      expect(table.headers.length, 15);
      expect(table.records.length, 5, reason: '末尾の改行は行ではない。空の行(3件目)はレコード');
      expect(table.records[1][2], '架空テスト,002 "引用"');
      expect(table.records[1][13], contains('\n'));
      expect(table.records[2].every((c) => c.isEmpty), isTrue);
    });
    test('UTF-8のBOMありでも同じ内容として読める(ファイルのハッシュは別)', () {
      final plain = _bytes(csvText);
      final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...plain]);
      expect(parseCsvBytes(withBom).headers, parseCsvBytes(plain).headers);
      expect(sha256Hex(withBom), isNot(sha256Hex(plain)));
    });
    test('UTF-8以外(Shift_JIS等)・空ファイル・行数超過は、対応形式を示して拒否する', () {
      expect(
        () => parseCsvBytes(
          Uint8List.fromList([0x82, 0xA0, 0x82, 0xA2, 0x0A, 0x82, 0xA0]),
        ),
        throwsA(
          isA<CsvParseException>().having(
            (e) => e.message,
            'm',
            contains('UTF-8'),
          ),
        ),
      );
      expect(
        () => parseCsvBytes(_bytes('')),
        throwsA(isA<CsvParseException>()),
      );
      expect(
        () => parseCsvBytes(_bytes('  \n')),
        throwsA(isA<CsvParseException>()),
      );
      final many = 'a\n${List.filled(importMaxRows + 1, 'x').join('\n')}';
      expect(
        () => parseCsvBytes(_bytes(many)),
        throwsA(
          isA<CsvParseException>().having(
            (e) => e.message,
            'm',
            contains('5000'),
          ),
        ),
      );
      expect(
        parseCsvBytes(
          _bytes('a\n${List.filled(importMaxRows, 'x').join('\n')}'),
        ).records.length,
        importMaxRows,
      );
    });
  });

  group('列の対応(mapping)とリクエスト', () {
    test('mappingのJSONは、サーバーの契約どおりの共有fixtureと一致する。mappingが読む列はサーバーと同じ順序', () {
      final mapping = _mapping();
      expect(mapping.validate(), isEmpty);
      expect(mapping.toJson(), equals(_fixture['mapping']));
      expect(
        mapping.mappedColumns(),
        equals((_fixture['expectedRequest'] as Map)['headers']),
      );
    });

    test(
      '組み立てたリクエストは、サーバーAPIに実際に受理される共有fixtureのリクエストと完全に一致する(未マップの列は送らない・空の行はblank・行番号は2から)',
      () {
        final bytes = _bytes(csvText);
        final request = buildImportRequest(
          eventId: eventId,
          fileName: _fixture['fileName'] as String,
          fileBytes: bytes,
          table: parseCsvBytes(bytes),
          mapping: _mapping(),
        );
        expect(request.json, equals(_fixture['expectedRequest']));
        expect(request.batchId, _fixture['batchId']);
        expect(request.json['fileHash'], _fixture['fileHash']);
        expect(request.totalRecords, 5);
        expect(request.json['blankRecordNumbers'], [4]);
        final rows = request.json['rows'] as List;
        expect(rows.map((r) => (r as Map)['rowNumber']).toList(), [2, 3, 5, 6]);
        expect(request.json.containsKey('label'), isFalse);
        // 取り込まない列(かな以外の自由記述・都道府県・キャンセル待)の値は送らない
        expect(jsonEncode(request.json).contains('未取込の自由記述'), isFalse);
        expect(jsonEncode(request.json).contains('キャンセル待'), isFalse);
        // publicId・approvedReviewRows等はpreview・commit共通の本体に含めない(クライアントで生成しない)
        for (final key in [
          'publicId',
          'approvedReviewRows',
          'excludedRows',
          'participantId',
        ]) {
          expect(request.json.containsKey(key), isFalse, reason: key);
        }
      },
    );

    test(
      'batchIdは内容から決まる: 同じ内容なら同じ(再送・再選択でも二重にならない)。ファイル名は影響しない。ファイル・列の対応が変われば別',
      () {
        final bytes = _bytes(csvText);
        final table = parseCsvBytes(bytes);
        ImportRequest build({
          String name = 'a.csv',
          Uint8List? data,
          ImportMapping? mapping,
        }) => buildImportRequest(
          eventId: eventId,
          fileName: name,
          fileBytes: data ?? bytes,
          table: table,
          mapping: mapping ?? _mapping(),
        );
        expect(
          build().batchId,
          build(name: '別の名前.csv').batchId,
          reason: 'ファイル名は含めない',
        );
        expect(build().batchId, build().batchId);
        expect(
          build(data: _bytes('$csvText ')).batchId,
          isNot(build().batchId),
        );
        final changed = _mapping()..programs[2].enabled = false;
        expect(build(mapping: changed).batchId, isNot(build().batchId));
        final other = buildImportRequest(
          eventId: 'evother',
          fileName: 'a.csv',
          fileBytes: bytes,
          table: table,
          mapping: _mapping(),
        );
        expect(other.batchId, isNot(build().batchId));
        expect(
          RegExp(r'^[A-Za-z0-9]{1,40}$').hasMatch(build().batchId),
          isTrue,
        );
      },
    );

    test(
      'CSVに無い列・同名の列が複数ある列・長すぎる値は、送信前に拒否する。値の個数が足りない行は途中までの値を送る(サーバーが確認対象にする)',
      () {
        final table = parseCsvBytes(_bytes(csvText));
        final missing = _mapping()..nameColumn = 'ない列';
        expect(
          () => buildImportRequest(
            eventId: eventId,
            fileName: 'a.csv',
            fileBytes: _bytes(csvText),
            table: table,
            mapping: missing,
          ),
          throwsA(
            isA<CsvParseException>().having(
              (e) => e.message,
              'm',
              contains('ない列'),
            ),
          ),
        );
        final dup = parseCsvBytes(_bytes('氏名,氏名,メール,人数\nA,B,c,1\n'));
        final m =
            ImportMapping(
                programs: [ProgramMapping(programId: 'p1', name: 'P')],
              )
              ..nameColumn = '氏名'
              ..emailColumn = 'メール'
              ..programs[0].countColumn = '人数';
        expect(
          () => buildImportRequest(
            eventId: eventId,
            fileName: 'a.csv',
            fileBytes: _bytes('x'),
            table: dup,
            mapping: m,
          ),
          throwsA(
            isA<CsvParseException>().having(
              (e) => e.message,
              'm',
              contains('複数'),
            ),
          ),
        );
        final longTable = parseCsvBytes(
          _bytes('氏名,メール,人数\n${'あ' * (importMaxValueLength + 1)},x,1\n'),
        );
        expect(
          () => buildImportRequest(
            eventId: eventId,
            fileName: 'a.csv',
            fileBytes: _bytes('x'),
            table: longTable,
            mapping: m,
          ),
          throwsA(
            isA<CsvParseException>().having(
              (e) => e.message,
              'm',
              contains('2行目'),
            ),
          ),
        );
        final ragged = parseCsvBytes(
          _bytes('氏名,メール,人数\nA,a@example.invalid\n'),
        );
        final request = buildImportRequest(
          eventId: eventId,
          fileName: 'a.csv',
          fileBytes: _bytes('x'),
          table: ragged,
          mapping: m,
        );
        expect((request.json['rows'] as List).single['values'], [
          'A',
          'a@example.invalid',
        ]);
      },
    );

    test('同一メール・同一氏名の行も、そのまま別の行として送る(人物単位の統合をしない)。100行は100行', () {
      final rows = List.generate(
        100,
        (i) => 'テスト同名,same@example.invalid,${i + 1}',
      ).join('\n');
      final table = parseCsvBytes(_bytes('氏名,メール,人数\n$rows\n'));
      final m =
          ImportMapping(
              programs: [ProgramMapping(programId: 'p1', name: 'P')],
            )
            ..nameColumn = '氏名'
            ..emailColumn = 'メール'
            ..programs[0].countColumn = '人数';
      final request = buildImportRequest(
        eventId: eventId,
        fileName: 'a.csv',
        fileBytes: _bytes('x'),
        table: table,
        mapping: m,
      );
      expect((request.json['rows'] as List).length, 100);
      expect(request.totalRecords, 100);
      expect(
        (request.json['rows'] as List)
            .map((r) => (r as Map)['rowNumber'])
            .toSet()
            .length,
        100,
      );
    });

    test(
      'mappingの確認: 氏名・メール・programの人数の列が必須。参加者の項目に同じ列の重複は不可。列名の推測はしない(初期値は未選択)',
      () {
        final empty = ImportMapping(
          programs: [ProgramMapping(programId: 'p1', name: 'P')],
        );
        expect(empty.nameColumn, isNull);
        expect(empty.programs.single.countColumn, isNull);
        final issues = empty.validate();
        expect(issues.length, 3);
        final m =
            ImportMapping(
                programs: [ProgramMapping(programId: 'p1', name: 'P')],
              )
              ..nameColumn = '氏名'
              ..emailColumn = '氏名';
        final text = m.validate().join('\n');
        expect(text, contains('重複'));
        expect(text, contains('人数の列を選択'));
        final none =
            ImportMapping(
                programs: [ProgramMapping(programId: 'p1', name: 'P')],
              )
              ..nameColumn = 'a'
              ..emailColumn = 'b'
              ..programs[0].enabled = false;
        expect(none.validate().join(), contains('1つ以上'));
      },
    );
  });

  group('サーバーの応答', () {
    test('previewの応答モデルは、サーバーが返す項目だけを読む(人数・氏名・メール・publicIdは無い)', () {
      final preview = ImportPreview.fromJson({
        'batchId': 'b1',
        'totalRecords': 5,
        'totalRows': 4,
        'readyCount': 2,
        'reviewCount': 1,
        'errorCount': 1,
        'blankRecordCount': 1,
        'participantCandidateCount': 3,
        'attendanceCandidateCount': 5,
        'issueCounts': {'row-check-failed': 1},
        'sameFileBatches': [
          {'batchId': 'x', 'sequence': 2, 'status': 'committed'},
        ],
        'existingBatch': {'status': 'committing', 'sequence': 3},
        'mappingWarnings': [
          {'code': 'waitlist-column', 'column': 'キャンセル待希望人数'},
        ],
        'rows': [
          {
            'sourceRowNumber': 2,
            'importRecordId': 'b1-000002',
            'classification': 'ready',
            'issueCodes': [],
            'programIds': ['program-a'],
          },
        ],
      });
      expect(
        (preview.readyCount, preview.reviewCount, preview.errorCount),
        (2, 1, 1),
      );
      expect(preview.existingStatus, 'committing');
      expect(preview.sameFileBatches.single.sequence, 2);
      expect(preview.warningColumns, ['キャンセル待希望人数']);
      expect(preview.rows.single.classification, RowClass.ready);
      expect(preview.rows.single.programIds, ['program-a']);
    });
    test('commitの応答: committedだけを完了とみなす。committing・failedは完了ではない', () {
      final ok = ImportResult.fromJson({
        'batchId': 'b1',
        'status': 'committed',
        'sequence': 1,
        'label': '第1回',
        'createdCount': 3,
        'totalRows': 3,
      });
      expect(ok.committed, isTrue);
      expect(
        ImportResult.fromJson({'status': 'committing'}).committed,
        isFalse,
      );
      expect(ImportResult.fromJson({'status': 'failed'}).committed, isFalse);
    });
    test('判定コードの表示名: 既知は日本語、未知はそのまま(内部情報を作らない)', () {
      expect(importIssueLabel('row-check-failed'), contains('行の確認'));
      expect(importIssueLabel('brand-new-code'), 'brand-new-code');
    });
  });
}
