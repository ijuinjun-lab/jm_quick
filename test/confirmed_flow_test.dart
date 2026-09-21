import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/models/demo_models.dart';
import 'package:jm_quick/models/program_models.dart';
import 'package:jm_quick/services/demo_repository.dart';
import 'package:jm_quick/services/legacy_api.dart';
import 'package:http/testing.dart';

import 'confirmed_auth_test.dart' show FakeAuthClient;

Map<String, dynamic> _fixture() =>
    jsonDecode(
          File('functions/test/fixtures/program_cases.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

/// fixtureのISO文字列の時刻をDateTimeへ変換する(Node側は文字列のまま検証する)。
Map<String, dynamic> _withDates(Map<String, dynamic> input) => {
  ...input,
  for (final key in ['startAt', 'endAt'])
    if (input[key] is String) key: DateTime.parse(input[key] as String),
};

Participant _participant({String eventId = 'e1'}) => Participant(
  id: 'p1',
  eventId: eventId,
  publicId: 'pub_p1_0123456789abcdef01234567',
  name: '参加者',
  email: 'p1@example.com',
  registeredCount: 1,
  registrationType: 'preRegistered',
  invitationSent: false,
  participationConfirmed: false,
  reconfirmed: false,
  reconfirmationMailSent: false,
);

/// 旧方式で保存された実イベントと同じ形のデータ(flow・programsなし)。
Map<String, dynamic> _legacyEventData() => {
  'eventId': 'e1',
  'eventName': '旧イベント',
  'senderName': '旧送信者',
  'startAt': Timestamp.fromDate(DateTime(2026, 11, 30, 10)),
  'endAt': null,
  'venue': '会場',
  'registrationDeadline': Timestamp.fromDate(DateTime(2026, 11, 20, 23, 59)),
  'confirmationSendAt': Timestamp.fromDate(DateTime(2026, 11, 29, 10)),
  'contact': '問い合わせ',
  'reconfirmEnabled': false,
};

/// Phase 10C: 旧経路はサーバーAPI経由になった。テストでは通信を一切しない(外部通信0)。
/// 送信しようとしたリクエストはここに記録され、常に失敗する。guardで止まる経路ではここが空のままでなければならない。
final List<Uri> _attemptedRequests = [];

DemoRepository _repository(String? flow, {void Function()? onLoad}) =>
    DemoRepository(
      selectedEventId: 'e1',
      api: LegacyApiClient(
        authClient: FakeAuthClient(signedIn: true),
        httpClient: MockClient((request) async {
          _attemptedRequests.add(request.url);
          throw StateError('no network in tests');
        }),
      ),
      eventFlowLoader: (eventId) async {
        onLoad?.call();
        return flow;
      },
    );

void main() {
  group('イベント方式(flow)', () {
    test('flow未設定の既存イベントJSONは従来方式として問題なく読める', () {
      final event = DemoEvent.fromData('e1', _legacyEventData());
      expect(event.flow, isNull);
      expect(event.isLegacyFlow, isTrue);
      expect(event.isConfirmedFlow, isFalse);
      expect(event.programs, isEmpty);
      expect(event.name, '旧イベント');
      expect(event.senderName, '旧送信者');
      expect(event.venue, '会場');
      expect(event.confirmationSendAt, DateTime(2026, 11, 29, 10));
      expect(event.statusAt(DateTime(2026, 11, 25)), isNotNull);
    });

    test('従来のコンストラクタ(flow・programsを渡さない)がそのまま使える', () {
      const event = DemoEvent(
        id: 'e1',
        name: 'x',
        senderName: 'x',
        venue: 'v',
        contact: '',
        reconfirmEnabled: false,
      );
      expect(event.isLegacyFlow, isTrue);
      expect(event.programs, isEmpty);
    });

    test('flow未設定・null・空・legacyはlegacy扱い', () {
      for (final flow in [null, '', 'legacy']) {
        final event = DemoEvent.fromData('e1', {
          ..._legacyEventData(),
          'flow': flow,
        });
        expect(event.isLegacyFlow, isTrue, reason: '$flow');
        expect(event.isConfirmedFlow, isFalse, reason: '$flow');
        expect(isLegacyFlowValue(flow), isTrue);
      }
    });

    test("flow=='confirmed'はconfirmed扱いで、legacyではない", () {
      final event = DemoEvent.fromData('e1', {
        ..._legacyEventData(),
        'flow': 'confirmed',
      });
      expect(event.isConfirmedFlow, isTrue);
      expect(event.isLegacyFlow, isFalse);
    });

    test('未知のflow(タイプミス)はlegacyでもconfirmedでもない(旧機能は拒否される)', () {
      for (final flow in ['confirmd', 'Confirmed', 'v2']) {
        final event = DemoEvent.fromData('e1', {
          ..._legacyEventData(),
          'flow': flow,
        });
        expect(event.isLegacyFlow, isFalse, reason: flow);
        expect(event.isConfirmedFlow, isFalse, reason: flow);
      }
    });
  });

  group('program定義', () {
    test('programs未設定・null・不正な型は空配列', () {
      expect(DemoEvent.fromData('e1', _legacyEventData()).programs, isEmpty);
      for (final raw in [null, 'x', 1, <String, dynamic>{}]) {
        expect(EventProgram.listFromData(raw), isEmpty);
      }
    });

    test('programsを読み、order順に並べ、不正な要素と重複programIdは無視する', () {
      final programs = EventProgram.listFromData([
        {'programId': 'talk', 'name': 'トークセッション', 'order': 2},
        {'programId': 'cat', 'name': '譲渡会（ねこ）', 'order': 0},
        {'programId': 'dog', 'name': '譲渡会（いぬ）', 'order': 1},
        {'programId': 'a/b', 'name': '不正なID'},
        {'programId': 'cat', 'name': '重複'},
        {'programId': 'x', 'name': ''},
        'not-a-map',
      ]);
      expect(programs.map((p) => p.programId), ['cat', 'dog', 'talk']);
      expect(programs.first.name, '譲渡会（ねこ）');
    });

    test('時間・注記つきのprogramを読み書きできる(往復)', () {
      final start = DateTime(2026, 11, 30, 10);
      final program = EventProgram.create(
        programId: 'cat',
        name: '譲渡会（ねこ）',
        order: 1,
        startAt: start,
        endAt: start.add(const Duration(hours: 1)),
        note: '抱っこ体験あり',
      );
      final restored = EventProgram.tryFromMap(program.toMap())!;
      expect(restored.programId, 'cat');
      expect(restored.startAt, start);
      expect(restored.endAt, start.add(const Duration(hours: 1)));
      expect(restored.note, '抱っこ体験あり');
      final event = DemoEvent.fromData('e1', {
        ..._legacyEventData(),
        'flow': 'confirmed',
        'programs': [program.toMap()],
      });
      expect(event.programs.single.name, '譲渡会（ねこ）');
    });

    test('programIdが不正なprogramは作成できない', () {
      for (final id in ['', 'a/b', 'a_b', 'Cat', '-a', 'a b']) {
        expect(
          () => EventProgram.create(programId: id, name: 'x'),
          throwsArgumentError,
          reason: id,
        );
      }
    });

    test('programの検証ケースがNode側(functions/programs.js)と一致する', () {
      for (final c in (_fixture()['programCases'] as List)) {
        final testCase = c as Map<String, dynamic>;
        expect(
          EventProgram.validateData(
            _withDates(testCase['input'] as Map<String, dynamic>),
          ),
          testCase['errors'],
          reason: testCase['name'] as String,
        );
      }
    });
  });

  group('programAttendance', () {
    test('文書IDはparticipantId×programIdから決定的に生成される', () {
      for (final c in (_fixture()['attendanceIds'] as List)) {
        final testCase = c as Map<String, dynamic>;
        final id = programAttendanceId(
          testCase['participantId'] as String,
          testCase['programId'] as String,
        );
        expect(id, testCase['id']);
        expect(
          programAttendanceId(
            testCase['participantId'] as String,
            testCase['programId'] as String,
          ),
          id,
        );
        final parsed = parseProgramAttendanceId(id)!;
        expect(parsed.participantId, testCase['participantId']);
        expect(parsed.programId, testCase['programId']);
      }
    });

    test('異なるparticipant/programの組は異なるIDになる(衝突しない)', () {
      final ids = {
        for (final p in ['p1', 'p2', 'a-b'])
          for (final g in ['cat', 'dog', 'talk', 'b'])
            programAttendanceId(p, g),
      };
      expect(ids.length, 12);
      expect(ids.any((id) => id.contains('/')), isFalse);
    });

    test('不正なprogramId/participantIdはID生成を拒否する(パスを壊す/を含む値など)', () {
      final fixture = _fixture();
      for (final id in (fixture['invalidProgramIds'] as List).cast<String>()) {
        expect(
          () => programAttendanceId('p1', id),
          throwsArgumentError,
          reason: jsonEncode(id),
        );
        expect(isValidProgramId(id), isFalse, reason: jsonEncode(id));
      }
      for (final id in (fixture['validProgramIds'] as List).cast<String>()) {
        expect(isValidProgramId(id), isTrue, reason: id);
      }
      for (final id
          in (fixture['invalidParticipantIds'] as List).cast<String>()) {
        expect(
          () => programAttendanceId(id, 'cat'),
          throwsArgumentError,
          reason: jsonEncode(id),
        );
      }
      for (final id
          in (fixture['validParticipantIds'] as List).cast<String>()) {
        expect(isValidParticipantId(id), isTrue, reason: id);
      }
      expect(parseProgramAttendanceId('p1_cat_x'), isNull);
      expect(parseProgramAttendanceId('p1cat'), isNull);
      expect(parseProgramAttendanceId('p1_a/b'), isNull);
    });

    test('plannedCountは1以上の整数だけ有効(0は参加しない=attendanceを作らない)', () {
      final counts = _fixture()['plannedCounts'] as Map<String, dynamic>;
      for (final n in (counts['valid'] as List)) {
        expect(isValidPlannedCount(n), isTrue, reason: '$n');
      }
      for (final n in (counts['invalid'] as List)) {
        expect(isValidPlannedCount(n), isFalse, reason: '$n');
      }
      expect(
        () => ProgramAttendance.create(
          eventId: 'e1',
          participantId: 'p1',
          programId: 'cat',
          plannedCount: 0,
        ),
        throwsArgumentError,
      );
    });

    test('attendanceの検証ケースがNode側(functions/programs.js)と一致する', () {
      for (final c in (_fixture()['attendanceCases'] as List)) {
        final testCase = c as Map<String, dynamic>;
        expect(
          ProgramAttendance.validateData(
            _withDates(testCase['input'] as Map<String, dynamic>),
          ),
          testCase['errors'],
          reason: testCase['name'] as String,
        );
      }
    });

    test('作成した記録は未受付で、Firestore用Mapへ書き出して読み戻せる', () {
      final attendance = ProgramAttendance.create(
        eventId: 'e1',
        participantId: 'p1',
        programId: 'cat',
        plannedCount: 2,
        slotLabel: '10:00枠',
        startAt: DateTime(2026, 11, 30, 10),
        endAt: DateTime(2026, 11, 30, 10, 30),
      );
      expect(attendance.id, 'p1_cat');
      expect(attendance.checkedIn, isFalse);
      expect(attendance.attendedCount, isNull);
      final map = attendance.toMap(updatedAtValue: 'SERVER_TIMESTAMP');
      expect(map.keys.toSet(), {
        'eventId',
        'participantId',
        'programId',
        'plannedCount',
        'slotLabel',
        'startAt',
        'endAt',
        'checkedIn',
        'checkedInAt',
        'attendedCount',
        'checkedInBy',
        'updatedAt',
      });
      expect(map['updatedAt'], 'SERVER_TIMESTAMP');
      final restored = ProgramAttendance.fromData(map);
      expect(restored.plannedCount, 2);
      expect(restored.slotLabel, '10:00枠');
      expect(restored.startAt, DateTime(2026, 11, 30, 10));
      expect(restored.validate(), isEmpty);
    });

    test('同じ参加者のprogramごとに受付状態を独立して持てる(ねこ受付済み／いぬ・トーク未受付)', () {
      final cat = ProgramAttendance(
        eventId: 'e1',
        participantId: 'p1',
        programId: 'cat',
        plannedCount: 2,
        checkedIn: true,
        checkedInAt: DateTime(2026, 11, 30, 10, 3),
        attendedCount: 2,
        checkedInBy: 'staff-1',
      );
      final dog = ProgramAttendance.create(
        eventId: 'e1',
        participantId: 'p1',
        programId: 'dog',
        plannedCount: 1,
      );
      final talk = ProgramAttendance.create(
        eventId: 'e1',
        participantId: 'p1',
        programId: 'talk',
        plannedCount: 2,
      );
      expect([cat, dog, talk].map((a) => a.id).toSet().length, 3);
      expect([cat, dog, talk].map((a) => a.checkedIn), [true, false, false]);
      expect([cat, dog, talk].map((a) => a.plannedCount), [2, 1, 2]);
      expect(cat.validate(), isEmpty);
    });
  });

  group('新方式Participantの互換フィールド', () {
    test('旧参加者(新フィールドなし)は既定値で読め、active扱いになる', () {
      final p = Participant.fromData('p1', {
        'eventId': 'e1',
        'publicId': 'pub_x',
        'name': '旧参加者',
        'email': 'old@example.com',
        'registeredCount': 3,
        'registrationType': 'preRegistered',
      });
      expect(p.registeredCount, 3);
      expect(p.schemaVersion, 1);
      expect(p.status, participantStatusActive);
      expect(p.isActive, isTrue);
      expect(p.isCancelled, isFalse);
      expect(p.externalId, isNull);
      expect(p.identityKey, isNull);
      expect(p.importBatchId, isNull);
      expect(p.importRow, isNull);
    });

    test('新方式の任意フィールドを読める', () {
      final p = Participant.fromData('p1', {
        'eventId': 'e1',
        'schemaVersion': 2,
        'status': 'cancelled',
        'externalId': 'A-001',
        'identityKey': 'key-1',
        'importBatchId': 'batch-1',
        'importRow': 7,
      });
      expect(p.schemaVersion, 2);
      expect(p.isCancelled, isTrue);
      expect(p.isActive, isFalse);
      expect(p.externalId, 'A-001');
      expect(p.importBatchId, 'batch-1');
      expect(p.importRow, 7);
    });
  });

  group('人数の正本(plannedCount)', () {
    test('新方式のコードは旧参加者ドキュメントの人数フィールド(registeredCount)を参照しない', () {
      // 新方式のファイル: 個別列挙 + lib/confirmed/ と functions/confirmed/ 配下すべて。
      // 新方式のコードを追加したらここに追加する(confirmed/ 配下に置けば自動的に対象)。
      final files = <File>[
        File('lib/models/program_models.dart'),
        File('functions/flow.js'),
        File('functions/programs.js'),
        for (final dir in ['lib/confirmed', 'functions/confirmed'])
          if (Directory(dir).existsSync())
            ...Directory(dir).listSync(recursive: true).whereType<File>(),
      ];
      for (final file in files) {
        expect(file.existsSync(), isTrue, reason: '${file.path}が存在しません');
        expect(
          file.readAsStringSync(),
          isNot(contains('registeredCount')),
          reason:
              '${file.path}がregisteredCountを参照しています。人数の正本はprogramAttendances.plannedCountです',
        );
      }
    });

    test('programAttendanceの書込みMapにregisteredCountは含まれず、人数はplannedCountだけ', () {
      final map = ProgramAttendance.create(
        eventId: 'e1',
        participantId: 'p1',
        programId: 'cat',
        plannedCount: 4,
      ).toMap();
      expect(map.containsKey('registeredCount'), isFalse);
      expect(map['plannedCount'], 4);
    });

    test('旧registeredCountの既存仕様は変わらない(旧Participantは従来どおり読める)', () {
      expect(_participant().registeredCount, 1);
    });
  });

  group('旧経路のguard(DemoRepository)', () {
    final now = DateTime(2026, 11, 30, 10);
    Future<void> updateSettings(DemoRepository repo) =>
        repo.updateEventSettings(
          eventName: 'x',
          senderName: 'x',
          startAt: now,
          venue: 'v',
          registrationDeadline: now,
          confirmationSendTime: const TimeOfDay(hour: 10, minute: 0),
        );
    final blockedOperations = <String, Future<void> Function(DemoRepository)>{
      '旧設定更新': updateSettings,
      '旧参加者作成': (repo) => repo.createParticipant(
        name: 'x',
        email: 'x@example.com',
        registeredCount: 1,
        registrationType: 'preRegistered',
      ),
      '旧正式登録': (repo) => repo.confirmParticipation(_participant()),
      '旧reconfirm回答': (repo) =>
          repo.reconfirm(_participant(), AttendanceResponse.attending),
      '旧受付': (repo) =>
          repo.checkIn(participant: _participant(), attendedCount: 1),
      '旧受付の人数修正': (repo) => repo.updateAttendedCount(_participant(), 1),
    };

    for (final flow in ['confirmed', 'confirmd']) {
      for (final entry in blockedOperations.entries) {
        test('flow=$flow のイベントで${entry.key}はFirestoreに触れる前に拒否される', () async {
          // Firebase未初期化のテスト環境。guardより先にFirestoreへ触れると別の例外になり失敗する。
          _attemptedRequests.clear();
          await expectLater(
            entry.value(_repository(flow)),
            throwsA(isA<ConfirmedFlowException>()),
          );
          expect(_attemptedRequests, isEmpty, reason: 'guardで止まり、サーバーへ送らない');
        });
      }
    }

    for (final flow in [null, '', 'legacy']) {
      test('flow=${flow ?? '未設定'} のイベントはguardを通過する(従来どおり使える)', () async {
        final repo = _repository(flow);
        await repo.assertLegacyEvent('e1', '確認');
        expect(await repo.isLegacyEvent('e1'), isTrue);
        // guardを過ぎるとFirestore(テストでは未初期化)へ進むため、別の例外になる=guardで止まっていない。
        for (final entry in blockedOperations.entries) {
          await expectLater(
            entry.value(_repository(flow)),
            throwsA(isNot(isA<ConfirmedFlowException>())),
            reason: entry.key,
          );
        }
      });
    }

    test('ConfirmedFlowExceptionはStateErrorではない(旧受付の「既に受付済み」表示と混同しない)', () {
      expect(const ConfirmedFlowException('受付'), isNot(isA<StateError>()));
      expect(
        const ConfirmedFlowException('受付').toString(),
        contains('従来方式のイベント専用'),
      );
    });

    test('flowは同一eventIdで1回だけ読み込まれる(CSV取込などで読取が増えない)', () async {
      var loads = 0;
      final repo = _repository('confirmed', onLoad: () => loads++);
      for (var i = 0; i < 5; i++) {
        await expectLater(
          repo.assertLegacyEvent('e1', 'x'),
          throwsA(isA<ConfirmedFlowException>()),
        );
      }
      expect(loads, 1);
    });
  });
}
