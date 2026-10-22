import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/reminder_page.dart';
import 'package:jm_quick/confirmed/reminder_service.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;

void main() {
  test(
    'second-round API calls and job adapter always retain round 2',
    () async {
      final calls = <Map<String, dynamic>>[];
      final service = CallableReminderService(
        authClient: FakeAuthClient(signedIn: true, token: 'test-token'),
        round: 2,
        httpClient: MockClient((request) async {
          final data = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['data'] as Map,
          );
          calls.add(data);
          return http.Response(
            jsonEncode({
              'result': {
                'eventId': 'event1',
                'jobId': 'reminder2-event1',
                'job': {'jobId': 'reminder2-event1'},
                'recipients': [],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await service.getSettings('event1');
      await service.updateSchedule('event1', date: '2026-11-27');
      expect(calls.last['plannedTime'], isNull);
      await service.preview(eventId: 'event1', participantId: 'p1');
      await service.startDelivery('event1', dispatch: false);
      await service.recoveryPreview('event1');
      await service.confirmRecovery('event1', {
        'participantId': 'p1',
        'fingerprint': 'f',
      }, '架空確認');
      final adapter = ReminderJobAdapter(service);
      await adapter.getJob('reminder2-event1');
      await adapter.retryFailed('reminder2-event1');
      expect(
        calls.every((c) => c['round'] == 2 && c['eventId'] == 'event1'),
        isTrue,
      );
      expect(
        ReminderJobAdapter.jobIdFor('event1', round: 2),
        'reminder2-event1',
      );
      expect(
        () => adapter.getJob('reminder-event1'),
        throwsA(isA<Exception>()),
      );
    },
  );

  testWidgets(
    'two forms retain independent dates and unsaved text; no time invented or automatic sending',
    (tester) async {
      final calls = <(String, Map<String, dynamic>)>[];
      final saved = <int, Map<String, dynamic>>{
        1: {'plannedDate': '2026-11-20'},
        2: {'plannedDate': '2026-11-27'},
      };
      final service = CallableReminderService(
        authClient: FakeAuthClient(signedIn: true, token: 'test-token'),
        httpClient: MockClient((request) async {
          final data = Map<String, dynamic>.from(
            (jsonDecode(request.body) as Map)['data'] as Map,
          );
          final round = data['round'] as int;
          calls.add((request.url.path, data));
          if (request.url.path.endsWith('updateConfirmedReminderSettings')) {
            saved[round] = {...saved[round]!, ...data};
          }
          return http.Response(
            jsonEncode({
              'result': {
                'eventId': 'event1',
                'eventName': '架空イベント',
                'round': round,
                ...saved[round]!,
                'template': {
                  'version': round,
                  'subject': '第$round回件名',
                  'introBody': 'テスト送信・正式文面ではありません',
                  'closingBody': '架空',
                },
                'targets': {'targetCount': 0},
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ReminderRoundsPage(service: service, initialEventId: 'event1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reminder-date')))
            .controller!
            .text,
        '2026-11-20',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reminder-time')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const Key('reminder-date')),
        '2026-11-21',
      );
      await tester.tap(find.text('第2回'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reminder-date')))
            .controller!
            .text,
        '2026-11-27',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reminder-time')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.ensureVisible(find.text('送信予定を保存'));
      await tester.tap(find.text('送信予定を保存'));
      await tester.pumpAndSettle();
      final update = calls
          .lastWhere((c) => c.$1.endsWith('updateConfirmedReminderSettings'))
          .$2;
      expect(update, {
        'eventId': 'event1',
        'round': 2,
        'plannedDate': '2026-11-27',
        'plannedTime': null,
      });
      final savesBeforeCopy = calls
          .where((c) => c.$1.endsWith('updateConfirmedReminderSettings'))
          .length;
      await tester.ensureVisible(find.text('もう一方の回の文面をコピー'));
      await tester.tap(find.text('もう一方の回の文面をコピー'));
      await tester.pumpAndSettle();
      expect(
        calls
            .where((c) => c.$1.endsWith('updateConfirmedReminderSettings'))
            .length,
        savesBeforeCopy,
      );
      final subjectField = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '件名',
      );
      expect(tester.widget<TextField>(subjectField).controller!.text, '第1回件名');
      await tester.tap(find.text('第1回'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('reminder-date')))
            .controller!
            .text,
        '2026-11-21',
      );
      expect(calls.any((c) => c.$1.contains('startConfirmed')), isFalse);
    },
  );
}
