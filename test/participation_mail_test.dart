import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/winner_mail_page.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';
import 'winner_mail_test.dart' show FakeWinnerMailService;

const types = [
  {'value': 'dog', 'label': '① 犬のみ'},
  {'value': 'cat', 'label': '② 猫のみ'},
  {'value': 'dog_cat', 'label': '③ 犬＋猫'},
  {'value': 'talk', 'label': '④ トークショーのみ'},
  {'value': 'dog_talk', 'label': '⑤ 犬＋トークショー'},
  {'value': 'cat_talk', 'label': '⑥ 猫＋トークショー'},
  {'value': 'dog_cat_talk', 'label': '⑦ 犬＋猫＋トークショー'},
];
void main() {
  test('CSVプレビューはサーバーのタイプとゼロを含む7集計を保持する', () {
    final result = ImportPreview.fromJson({
      'participationTypes': [for (final type in types) {...type, 'count': type['value'] == 'cat' ? 1 : 0}],
      'rows': [
        {'sourceRowNumber': 2, 'classification': 'ready', 'participationType': 'cat', 'programIds': ['program-1']},
        {'sourceRowNumber': 3, 'classification': 'review', 'participationType': null},
      ],
    });
    expect(result.participationTypes.length, 7);
    expect(result.participationTypes.first['count'], 0);
    expect(result.rows.first.participationType, 'cat');
    expect(result.rows.last.participationType, isNull);
  });
  testWidgets('タイプと参加者を選び、実在参加者の完成本文をプレビューする', (tester) async {
    final settings = WinnerMailSettings.fromJson({
      'eventId': 'event1', 'event': {'eventName': '架空イベント'},
      'template': {'subject': '保存済件名', 'introBody': '冒頭', 'closingBody': '締め', 'adoptionNotesBody': '譲渡会注意'},
      'ready': true, 'previewParticipantId': 'cat1', 'participationTypes': types,
      'mailSettings': {'talkTimeText': '16:00〜17:00', 'senderName': '架空送信者'},
      'previewParticipants': [
        {'participantId': 'cat1', 'name': '架空猫参加者', 'participationType': 'cat'},
        {'participantId': 'dog1', 'name': '架空犬参加者A', 'participationType': 'dog'},
        {'participantId': 'dog2', 'name': '架空犬参加者B', 'participationType': 'dog'},
      ],
    });
    final service = FakeWinnerMailService(settings: settings,
      previewResult: const WinnerMailPreview(ready: true, problems: [], subject: '完成件名', text: '犬のみの完成本文'));
    await tester.pumpWidget(MaterialApp(home: WinnerMailPage(service: service, initialEventId: 'event1')));
    await tester.pumpAndSettle();
    final filter = find.byKey(const Key('mail-type-filter'));
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('① 犬のみ').last);
    await tester.pumpAndSettle();
    final people = find.byKey(const ValueKey('mail-participant-dog'));
    await tester.ensureVisible(people);
    await tester.tap(people);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. 架空犬参加者B').last);
    await tester.pumpAndSettle();
    final button = find.text('プレビューを表示');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(service.calls.last, 'preview:event1:dog2');
    expect(find.text('犬のみの完成本文'), findsOneWidget);
    await tester.ensureVisible(filter);
    await tester.tap(filter);
    await tester.pumpAndSettle();
    await tester.tap(find.text('④ トークショーのみ').last);
    await tester.pumpAndSettle();
    expect(find.text('このタイプの取込済み参加者はいません。'), findsOneWidget);
    expect(find.text('プレビューを表示'), findsNothing);
    expect(find.text('犬のみの完成本文'), findsNothing);
  });
  testWidgets('新規イベントの既存programからmappingを選択し、重複を拒否して保存', (tester) async {
    final service = FakeWinnerMailService(settings: WinnerMailSettings.fromJson({
      'eventId': 'new-event', 'event': {'eventName': '設定テスト'},
      'template': {'subject': '件名', 'introBody': '冒頭', 'closingBody': '締め'},
      'programs': [for (final id in ['a', 'b', 'c']) {'programId': id, 'name': id}],
      'ready': true,
    }));
    await tester.pumpWidget(MaterialApp(home: WinnerMailPage(service: service, initialEventId: 'new-event')));
    await tester.pumpAndSettle();
    final toggle = find.byType(SwitchListTile);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    Future<void> select(String role, String id) async {
      final field = find.byKey(ValueKey('mapping-$role'));
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.tap(find.text('$id ($id)').last);
      await tester.pumpAndSettle();
    }
    await select('cat', 'a');
    await select('dog', 'a');
    await select('talk', 'c');
    final save = find.widgetWithText(FilledButton, '保存');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(service.savedParticipationMapping, isNull);
    expect(find.text('猫・犬・トークに異なるprogramを選択してください。'), findsOneWidget);
    await select('dog', 'b');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(service.savedParticipationMapping, {'catProgramId': 'a', 'dogProgramId': 'b', 'talkProgramId': 'c'});
  });

}
