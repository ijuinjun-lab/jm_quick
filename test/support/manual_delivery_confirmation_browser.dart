// Offline UI acceptance fixture: no Firebase initialization or network transport.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:jm_quick/confirmed/manual_delivery_confirmation.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_service.dart';

class ManualNotificationFixture extends DeliveryConfirmationService {
  ManualNotificationFixture({this.mode = 'pending'});
  final String mode;
  final calls = <String>[];
  final requests = <Map<String, dynamic>>[];
  bool sent = false;
  bool retried = false;
  static const emails = [
    'inoue-y6@asahi.com',
    'sippo-support@info-event-jimukyoku.jp',
    'ijuinjun@gmail.com',
    'jm.okubo@gmail.com',
    'hakamatajm@gmail.com',
  ];
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    calls.add(name);
    requests.add(data);
    if (mode == 'denied') {
      throw const DeliveryConfirmationException('permission-denied');
    }
    if (name == 'sendManualDeliveryConfirmation') {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (mode == 'lost') throw const DeliveryConfirmationException('unknown');
      if (data['recipientKey'] != null) {
        retried = true;
      } else {
        sent = true;
      }
    } else if (name != 'previewManualDeliveryConfirmation') {
      throw StateError('Participant endpoints are forbidden');
    }
    return {
      'reportId': 'report',
      'fingerprint': 'preview-fingerprint',
      'subject': '事務局用の送信結果',
      'text': '送信結果の本文。個別参加者の情報は確認用サンプルです。',
      'html': '',
      'counts': {
        'targetCount': 10,
        'sentCount': 8,
        'failedCount': 1,
        'unknownCount': 1,
      },
      'canSend': !sent && mode != 'mixed',
      'deliveries': [
        for (var i = 0; i < emails.length; i++)
          {
            'email': emails[i],
            'recipientKey': 'recipient-$i',
            'attemptCount': 1,
            'allowed': true,
            'status': mode == 'mixed'
                ? (i == 0 && !retried
                      ? 'failed'
                      : i == 1
                      ? 'unknown'
                      : 'sent')
                : sent
                ? 'sent'
                : 'pending',
          },
      ],
    };
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ManualDeliveryConfirmationButton(
            eventId: 'event1',
            jobId: 'winner-local',
            service: ManualNotificationFixture(
              mode: Uri.base.queryParameters['mode'] ?? 'pending',
            ),
          ),
        ),
      ),
    ),
  );
}
