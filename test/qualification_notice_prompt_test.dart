import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'qualification_management_ui_test.dart' show ManagementFake;
import 'qualification_cancel_test.dart'
    show CancelFake, mount, tap, cancelButton;

class PromptFake extends CancelFake {
  bool failSave = false, failMail = false;
  final previews = <Map<String, dynamic>>[];
  @override
  Future<void> changeQualification(Map<String, dynamic> r) async {
    if (failSave) throw Exception('save failed');
    await super.changeQualification(r);
    if (r['targetProgramId'] != null) {
      rows.add({
        'programId': r['targetProgramId'],
        'slotLabel': r['slotLabel'],
        'plannedCount': r['plannedCount'],
        'entitlementStatus': 'active',
        'checkedIn': false,
      });
      history.first['after'] = rows
          .map((q) => Map<String, dynamic>.of(q))
          .toList();
    }
  }

  @override
  Future<Map<String, dynamic>> previewNotice(Map<String, dynamic> r) async {
    previews.add(Map.of(r));
    return super.previewNotice(r);
  }

  @override
  Future<Map<String, dynamic>> sendNotice(Map<String, dynamic> r) async {
    if (failMail) throw Exception('mail failed');
    return super.sendNotice(r);
  }
}

void main() {
  for (final size in [const Size(1280, 900), const Size(390, 500)]) {
    for (final action in ['資格追加', '時間・人数の変更']) {
      testWidgets('$action offers notification $size', (tester) async {
        final service = ManagementFake();
        await mount(tester, service, size);
        Future<void> choose(String label, String value) async {
          await tap(
            tester,
            find.widgetWithText(DropdownButtonFormField<String>, label),
          );
          await tap(tester, find.text(value).last);
        }

        await choose('操作', action);
        await choose('変更・取消する資格', action == '資格追加' ? '犬' : '猫');
        await choose('参加時間', '11:00-12:00');
        final count = find.widgetWithText(TextField, '変更先の予定人数');
        await tester.ensureVisible(count);
        await tester.enterText(count, '4');
        await tap(tester, find.text('確認へ'));
        await tap(tester, find.text('確定'));
        expect(find.text('参加資格の変更が完了しました'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AlertDialog).last,
            matching: find.textContaining('11:00-12:00 4名'),
          ),
          findsOneWidget,
        );
        expect(service.sends, 0);
        await tap(tester, find.text('送信しない'));
        expect(service.history, hasLength(1));
        expect(service.rows.any((q) => q['plannedCount'] == 4), isTrue);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('cat to dog offers saved participation $size', (tester) async {
      final service = PromptFake();
      service.rows.removeWhere((q) => q['programId'] == 'dog');
      await mount(tester, service, size);
      await tap(
        tester,
        find.widgetWithText(DropdownButtonFormField<String>, '変更・取消する資格'),
      );
      await tap(tester, find.text('猫').last);
      await tap(tester, find.byType(CheckboxListTile));
      await tap(tester, find.text('確認へ'));
      await tap(tester, find.text('確定'));
      expect(find.text('参加資格の変更が完了しました'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.textContaining('犬 10:00-11:00 1名'),
        ),
        findsOneWidget,
      );
      expect(service.sends, 0);
      await tap(tester, find.text('メール内容を確認して送信'));
      await tap(tester, find.text('この本人に送信'));
      expect(service.sends, 1);
      expect(tester.takeException(), isNull);
    });
    testWidgets(
      'saved operation opens existing preview, failed mail preserves cancellation $size',
      (tester) async {
        final service = PromptFake()..failMail = true;
        await mount(tester, service, size);
        await tap(tester, cancelButton('all'));
        await tap(tester, find.text('確定'));
        expect(find.text('参加キャンセルが完了しました'), findsOneWidget);
        expect(service.previews, isEmpty);
        expect(service.sends, 0);
        await tap(tester, find.text('メール内容を確認して送信'));
        expect(
          service.previews.single['operationId'],
          service.requests.single['operationId'],
        );
        expect(find.textContaining('宛先：only@example.invalid'), findsOneWidget);
        expect(service.sends, 0);
        await tap(tester, find.text('この本人に送信'));
        expect(
          service.rows.every((q) => q['entitlementStatus'] == 'revoked'),
          isTrue,
        );
        expect(service.history, hasLength(1));
        expect(find.textContaining('通知の内容または結果を確認できません'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('failed save never offers notification $size', (tester) async {
      final service = PromptFake()..failSave = true;
      await mount(tester, service, size);
      await tap(tester, cancelButton('all'));
      await tap(tester, find.text('確定'));
      expect(find.text('本人へ変更内容をメールで通知しますか？'), findsNothing);
      expect(service.history, isEmpty);
      expect(service.previews, isEmpty);
      expect(service.sends, 0);
      expect(
        service.rows.every((q) => q['entitlementStatus'] == 'active'),
        isTrue,
      );
    });
  }
}
