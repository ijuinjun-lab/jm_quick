import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/qualification_change_dialog.dart';
import 'package:jm_quick/confirmed/qualification_change_service.dart';

class ManagementFake
    implements QualificationChangeService, QualificationNoticeService {
  final requests = <Map<String, dynamic>>[];
  int sends = 0, reviews = 0;
  final rows = <Map<String, dynamic>>[
    {
      'programId': 'cat',
      'slotLabel': '10:00-11:00',
      'plannedCount': 2,
      'entitlementStatus': 'active',
      'checkedIn': false,
    },
  ];
  final history = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> getQualifications(
    String eventId,
    String participantId,
  ) async => {
    'name': '架空参加者',
    'email': 'only@example.invalid',
    'fingerprint': '${requests.length}'.padLeft(64, 'a'),
    'busy': false,
    'programs': [
      {'programId': 'cat', 'name': '猫'},
      {'programId': 'dog', 'name': '犬'},
      {'programId': 'talk', 'name': 'トーク'},
    ],
    'mapping': {
      'catProgramId': 'cat',
      'dogProgramId': 'dog',
      'talkProgramId': 'talk',
    },
    'slots': {
      for (final id in ['cat', 'dog', 'talk'])
        id: ['10:00-11:00', '11:00-12:00'],
    },
    'qualifications': rows,
    'history': history,
    'deliveries': [
      if (sends > 0)
        {
          'id': 'notice',
          'kind': 'qualificationNotices',
          'status': 'unknown',
          'recoverable': true,
          'reviewed': reviews > 0,
        },
    ],
  };
  @override
  Future<void> changeQualification(Map<String, dynamic> r) async {
    requests.add(Map.of(r));
    final before = rows.map((r) => Map<String, dynamic>.of(r)).toList();
    rows.removeWhere((q) => q['programId'] == r['programId']);
    rows.add({
      'programId': r['programId'],
      'slotLabel': r['slotLabel'],
      'plannedCount': r['plannedCount'],
      'entitlementStatus': 'active',
      'checkedIn': false,
    });
    history.insert(0, {
      'operationId': r['operationId'],
      'changedAt': '2026-10-24',
      'changedBy': 'manager',
      'reason': r['reason'],
      'before': before,
      'after': rows.map((r) => Map<String, dynamic>.of(r)).toList(),
    });
  }

  @override
  Future<Map<String, dynamic>> previewNotice(
    Map<String, dynamic> request,
  ) async => {
    'to': 'only@example.invalid',
    'subject': '参加変更',
    'text': '変更前 猫2名 → 変更後 猫4名\n既存のQR・Web参加証',
    'fingerprint': 'f' * 64,
  };
  @override
  Future<Map<String, dynamic>> sendNotice(Map<String, dynamic> request) async {
    sends++;
    return {'status': 'unknown'};
  }

  @override
  Future<void> reviewDelivery(Map<String, dynamic> request) async {
    expect(request['reason'], '配送終了を確認');
    reviews++;
  }
}

void main() {
  testWidgets('管理画面: 現在値、人数・時間変更、資格追加、履歴、本人通知確認、結果不明復旧', (tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = ManagementFake();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QualificationChangeDialog(
            service: service,
            eventId: 'event',
            participantId: 'person',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> choose(String label, String value) async {
      await tester.tap(
        find.widgetWithText(DropdownButtonFormField<String>, label),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(value).last);
      await tester.pumpAndSettle();
    }

    Future<void> save() async {
      await tester.enterText(
        find.widgetWithText(TextField, '変更理由（必須）'),
        '本人希望',
      );
      await tester.tap(find.text('確認へ'));
      await tester.pumpAndSettle();
      expect(find.textContaining('変更前：'), findsOneWidget);
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
    }

    await choose('操作', '時間・人数の変更');
    await choose('変更・取消する資格', '猫');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '変更先の予定人数'))
          .controller!
          .text,
      '2',
    );
    expect(
      find.widgetWithText(DropdownButtonFormField<String>, '10:00-11:00'),
      findsOneWidget,
    );
    await tester.enterText(find.widgetWithText(TextField, '変更先の予定人数'), '4');
    await save();
    expect(service.requests.last['plannedCount'], 4);
    expect(service.requests.last['slotLabel'], '10:00-11:00');
    expect(service.sends, 0);
    await choose('変更・取消する資格', '猫');
    await choose('参加時間', '11:00-12:00');
    await save();
    expect(service.requests.last['plannedCount'], 4);
    expect(service.requests.last['slotLabel'], '11:00-12:00');
    await choose('操作', '資格追加');
    await choose('変更・取消する資格', 'トーク');
    await save();
    expect(service.requests.last['action'], 'add');
    expect(service.requests.last['programId'], 'talk');
    expect(service.sends, 0);
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('変更後\n'), findsOneWidget);
    final notify = find.text('変更通知を確認・手動送信').first;
    await tester.ensureVisible(notify);
    await tester.tap(notify);
    await tester.pumpAndSettle();
    expect(find.textContaining('宛先：only@example.invalid'), findsOneWidget);
    expect(service.sends, 0);
    await tester.tap(find.text('この本人に送信'));
    await tester.pumpAndSettle();
    expect(service.sends, 1);
    expect(find.text('配送：結果不明（再送禁止）'), findsOneWidget);
    final recovery = find.text('状態確認・復旧');
    await tester.ensureVisible(recovery);
    await tester.tap(recovery);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '配送終了を確認');
    await tester.tap(find.text('確認を記録'));
    await tester.pumpAndSettle();
    expect(service.reviews, 1);
    expect(service.sends, 1);
  });
}
