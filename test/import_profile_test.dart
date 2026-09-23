// Phase 11B-4: 今年度の正式CSVフォーマット(sipposample形式・28列)向けの自動判定profile。
// 利用者はCSVの列を一切選ばない。このテストは、profileがCSVのheaderから正しくImportMappingを
// 自動的に組み立てること、対応していない形式を正しく拒否できることを確認する。データはすべて架空。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_profile.dart';

// 実CSVで確認した28列のうち、主要な20列相当を再現した架空ヘッダー(区分・都道府県・性別・年代・
// 午前相談・午後相談・キャンセル待希望枠・キャンセル待希望人数・rd・備考は取込に使われない列として含める)。
const List<String> _sippoHeaders = [
  '区分',
  'rd',
  '氏名',
  'かな',
  'メールアドレス',
  '都道府県',
  '性別',
  '年代',
  '午前参加時間',
  '午前参加人数',
  '午前相談',
  '午後参加時間',
  '午後参加人数',
  '午後相談',
  'トークショー',
  'トークショー人数',
  'キャンセル待希望枠',
  'キャンセル待希望人数',
  '登録日時',
  '備考',
];

const _eventPrograms = [
  (programId: 'program-1', name: '午前の譲渡会', order: 0),
  (programId: 'program-2', name: '午後の譲渡会', order: 1),
  (programId: 'program-3', name: 'トークショー', order: 2),
];

String _row({
  String kubun = '新規申込',
  String rd = '',
  required String name,
  String kana = 'かくうさんかくしゃ',
  required String email,
  String amTime = '',
  String amCount = '',
  String pmTime = '',
  String pmCount = '',
  String talk = '',
  String talkCount = '',
  String registeredAt = '2026年01月02日 03時04分05秒',
  String memo = '',
}) => [
  kubun,
  rd,
  name,
  kana,
  email,
  '架空県', '未回答', '未回答', // 都道府県・性別・年代(未使用)
  amTime,
  amCount,
  '', // 午前相談(未使用)
  pmTime,
  pmCount,
  '', // 午後相談(未使用)
  talk,
  talkCount,
  '', '', // キャンセル待希望枠・人数(未使用)
  registeredAt,
  memo,
].join(',');

CsvTable _table(List<String> rows) => parseCsvBytes(
  Uint8List.fromList(utf8.encode('${_sippoHeaders.join(',')}\n${rows.join('\n')}\n')),
);

void main() {
  group('ConfirmedImportProfile: header一致の確認', () {
    test('正式フォーマットのheaderがすべて揃っていれば一致(missingHeadersが空)', () {
      expect(
        sipposample2026Profile.missingHeaders(_sippoHeaders),
        isEmpty,
      );
    });

    test('列の順序が変わっても、header名だけで解決できる(列順は問わない)', () {
      final shuffled = [..._sippoHeaders.reversed];
      expect(sipposample2026Profile.missingHeaders(shuffled), isEmpty);
    });

    test('余分な列(この28列の中の未使用列)があっても一致とみなす', () {
      expect(
        sipposample2026Profile.missingHeaders([
          ..._sippoHeaders,
          '未知の自由記述列',
        ]),
        isEmpty,
      );
    });

    test('必要なheaderが1つでも欠けていれば、不足している列名を返す(黙って受理しない)', () {
      final missingEmail = [..._sippoHeaders]..remove('メールアドレス');
      expect(
        sipposample2026Profile.missingHeaders(missingEmail),
        ['メールアドレス'],
      );
      final missingSeveral = [..._sippoHeaders]
        ..remove('午前参加人数')
        ..remove('トークショー');
      expect(
        sipposample2026Profile.missingHeaders(missingSeveral),
        ['トークショー', '午前参加人数'],
      );
    });

    test('全く違う形式のCSV(旧方式など)は、必須列のほとんどが不足として拒否される', () {
      final missing = sipposample2026Profile.missingHeaders(['名前', 'mail']);
      expect(missing, isNotEmpty);
      expect(missing, contains('氏名'));
      expect(missing, contains('メールアドレス'));
    });
  });

  group('missingProfileProgramsInEvent: イベント側のprogram不足', () {
    test('イベントにprogram-1/2/3が揃っていれば一致', () {
      expect(
        missingProfileProgramsInEvent(sipposample2026Profile, _eventPrograms),
        isEmpty,
      );
    });
    test('イベントのprogramIdがprofileと違えば、不足しているprogramIdを返す', () {
      final other = [
        (programId: 'program-a', name: 'A', order: 0),
        (programId: 'program-2', name: '午後の譲渡会', order: 1),
      ];
      expect(
        missingProfileProgramsInEvent(sipposample2026Profile, other),
        ['program-1', 'program-3'],
      );
    });
  });

  group('buildMappingFromProfile: 利用者の操作なしでImportMappingを組み立てる', () {
    test('サーバー契約どおりのJSON(participationColumn等はprogram-1/2/3で自動的に設定される)', () {
      final mapping = buildMappingFromProfile(
        sipposample2026Profile,
        _eventPrograms,
      );
      expect(mapping.validate(), isEmpty);
      expect(mapping.toJson(), {
        'version': 1,
        'participant': {
          'nameColumn': '氏名',
          'kanaColumn': 'かな',
          'emailColumn': 'メールアドレス',
          'registeredAtColumn': '登録日時',
        },
        'programs': [
          {
            'programId': 'program-1',
            'participationColumn': '午前参加時間',
            'notAttendingValues': ['参加を希望しない'],
            'emptyMeans': 'notAttending',
            'slotColumn': '午前参加時間',
            'slotFormat': 'label',
            'countColumn': '午前参加人数',
          },
          {
            'programId': 'program-2',
            'participationColumn': '午後参加時間',
            'notAttendingValues': ['参加を希望しない'],
            'emptyMeans': 'notAttending',
            'slotColumn': '午後参加時間',
            'slotFormat': 'label',
            'countColumn': '午後参加人数',
          },
          {
            'programId': 'program-3',
            'participationColumn': 'トークショー',
            'attendingValues': ['参加を希望する'],
            'notAttendingValues': ['参加を希望しない'],
            'emptyMeans': 'notAttending',
            'countColumn': 'トークショー人数',
          },
        ],
      });
      // event.programsの名前(表示名)がそのままmappingに使われる(programIdを利用者に選ばせない)。
      expect(mapping.programs.map((p) => p.name), ['午前の譲渡会', '午後の譲渡会', 'トークショー']);
    });

    test('mappedColumns()は、サーバー(participationColumn→slotColumn→countColumn)と同じ順序で重複を除く', () {
      final mapping = buildMappingFromProfile(
        sipposample2026Profile,
        _eventPrograms,
      );
      expect(mapping.mappedColumns(), [
        '氏名',
        'かな',
        'メールアドレス',
        '登録日時',
        // program-1: participationColumn(午前参加時間)とslotColumnが同じ列なので1回だけ
        '午前参加時間',
        '午前参加人数',
        '午後参加時間',
        '午後参加人数',
        'トークショー',
        'トークショー人数',
      ]);
    });
  });

  group('自動判定→リクエスト組み立て(mapping操作なしでpreviewできる状態を作れる)', () {
    ImportMapping mappingFor() =>
        buildMappingFromProfile(sipposample2026Profile, _eventPrograms);

    test('90行相当の架空CSVを、列を選ぶ操作なしでリクエストに組み立てられる', () {
      final rows = List.generate(
        90,
        (i) => _row(
          name: '架空参加者${i + 1}',
          email: 'sippo-$i@example.invalid',
          amTime: '10:00-11:00',
          amCount: '1',
        ),
      );
      final table = _table(rows);
      final request = buildImportRequest(
        eventId: 'ev1',
        fileName: 'sipposample1.csv',
        fileBytes: Uint8List.fromList(utf8.encode('x')),
        table: table,
        mapping: mappingFor(),
      );
      expect(request.totalRecords, 90);
      expect((request.json['rows'] as List).length, 90);
    });

    test('午前参加時間・午前参加人数からprogram-1、午後参加時間・午後参加人数からprogram-2、トークショー/トークショー人数からprogram-3のattendanceが作られる(1人が3program参加してもparticipantは1件・attendanceは3件)', () {
      final table = _table([
        _row(
          name: '架空太郎',
          email: 'taro@example.invalid',
          amTime: '10:00-11:00',
          amCount: '2',
          pmTime: '13:00-14:00',
          pmCount: '1',
          talk: '参加を希望する',
          talkCount: '2',
        ),
      ]);
      final request = buildImportRequest(
        eventId: 'ev1',
        fileName: 'a.csv',
        fileBytes: Uint8List.fromList(utf8.encode('x')),
        table: table,
        mapping: mappingFor(),
      );
      final rows = request.json['rows'] as List;
      expect(rows.length, 1, reason: '人数が2でもparticipantは1件');
      final headers = request.json['headers'] as List;
      final values = (rows.single as Map)['values'] as List;
      String cell(String h) => values[headers.indexOf(h)] as String;
      expect(cell('氏名'), '架空太郎');
      expect(cell('午前参加人数'), '2');
      expect(cell('午後参加人数'), '1');
      expect(cell('トークショー人数'), '2');
    });

    test('「参加を希望しない」の行・空欄の行は、そのままサーバーへ送られる(参加しない判定はサーバー側が行う。クライアントは除外しない)', () {
      final table = _table([
        _row(
          name: '架空花子',
          email: 'hanako@example.invalid',
          amTime: '参加を希望しない',
          pmTime: '',
          talk: '参加を希望しない',
        ),
      ]);
      final request = buildImportRequest(
        eventId: 'ev1',
        fileName: 'a.csv',
        fileBytes: Uint8List.fromList(utf8.encode('x')),
        table: table,
        mapping: mappingFor(),
      );
      expect((request.json['rows'] as List).length, 1);
    });

    test('同一メール100行・同一氏名100行は、そのまま100行として送る(重複統合をしない)', () {
      final sameEmail = List.generate(
        100,
        (i) => _row(
          name: '架空同名$i',
          email: 'same@example.invalid',
          amTime: '10:00-11:00',
          amCount: '1',
        ),
      );
      final r1 = buildImportRequest(
        eventId: 'ev1',
        fileName: 'a.csv',
        fileBytes: Uint8List.fromList(utf8.encode('x')),
        table: _table(sameEmail),
        mapping: mappingFor(),
      );
      expect((r1.json['rows'] as List).length, 100);
      expect(r1.totalRecords, 100);

      final sameName = List.generate(
        100,
        (i) => _row(
          name: '架空同姓同名',
          email: 'unique$i@example.invalid',
          amTime: '10:00-11:00',
          amCount: '1',
        ),
      );
      final r2 = buildImportRequest(
        eventId: 'ev1',
        fileName: 'b.csv',
        fileBytes: Uint8List.fromList(utf8.encode('y')),
        table: _table(sameName),
        mapping: mappingFor(),
      );
      expect((r2.json['rows'] as List).length, 100);
    });

    test('rd(参照コード)・備考・区分・都道府県などの未使用列は送らない', () {
      final table = _table([
        _row(
          name: '架空一郎',
          email: 'ichiro@example.invalid',
          rd: 'R-0001',
          amTime: '10:00-11:00',
          amCount: '1',
          memo: 'この値は取り込まれない',
        ),
      ]);
      final request = buildImportRequest(
        eventId: 'ev1',
        fileName: 'a.csv',
        fileBytes: Uint8List.fromList(utf8.encode('x')),
        table: table,
        mapping: mappingFor(),
      );
      final text = jsonEncode(request.json);
      expect(text.contains('R-0001'), isFalse);
      expect(text.contains('この値は取り込まれない'), isFalse);
      expect((request.json['headers'] as List).contains('rd'), isFalse);
      expect((request.json['headers'] as List).contains('備考'), isFalse);
    });
  });

  group('displayCountOf: program別予定の概算表示', () {
    test('半角・全角数字・「名」「人」つきを解釈する。空欄は0、不正な値はnull', () {
      expect(displayCountOf('2'), 2);
      expect(displayCountOf('２'), 2);
      expect(displayCountOf('3名'), 3);
      expect(displayCountOf('4人'), 4);
      expect(displayCountOf(''), 0);
      expect(displayCountOf('  '), 0);
      expect(displayCountOf('-1'), isNull);
      expect(displayCountOf('1.5'), isNull);
      expect(displayCountOf('たくさん'), isNull);
    });
  });
}
