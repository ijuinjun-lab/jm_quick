// Local Chrome acceptance fixture. Build with --target pointing to this file and
// an output directory outside build/web. Every callable is mocked; no Firebase
// initialization, real credentials, mail transport or production writes exist.
import 'package:flutter/material.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_page.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_service.dart';

class BrowserConfirmationService extends DeliveryConfirmationService {
  final rows = <Map<String, dynamic>>[
    for (final name in ['office', 'organizer'])
      {
        'email': '$name@example.invalid',
        'name': name,
        'enabled': true,
        'kinds': ['normal', 'waitlistPromotion', 'broadcast'],
      },
  ];
  bool enabled = false;
  int version = 0;
  @override
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final manager = Uri.base.queryParameters['role'] == 'manager';
    if (name == 'getDeliveryConfirmationSettings') {
      final start = data['after'] == null
          ? 0
          : int.parse(data['after'] as String);
      return {
        'canManage': !manager,
        'policy': {'enabled': enabled, 'version': version, 'recipients': rows},
        'reports': [
          for (var i = start; i < start + 20 && i < 45; i++)
            {
              'reportId': '$i',
              'kind': 'normal',
              'status': 'ready',
              'subject': '確認履歴 ${45 - i}',
              'completedAt': DateTime.utc(
                2026,
                10,
                31,
              ).subtract(Duration(hours: i)).toIso8601String(),
            },
        ],
        'nextAfter': start + 20 < 45 ? '${start + 20}' : null,
      };
    }
    if (name == 'updateDeliveryConfirmationPolicy') {
      if (manager || Uri.base.queryParameters['error'] == 'permission') {
        throw const DeliveryConfirmationException('permission-denied');
      }
      if (Uri.base.queryParameters['error'] == 'internal') {
        throw StateError('sensitive internal information');
      }
      final next = (data['recipients'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final emails = <String>{};
      for (final r in next) {
        final email = (r['email'] as String).trim().toLowerCase();
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
          throw const DeliveryConfirmationException('invalid-address');
        }
        if ((r['kinds'] as List).isEmpty) {
          throw const DeliveryConfirmationException('mail-kind-required');
        }
        if (!emails.add(email)) {
          throw const DeliveryConfirmationException('duplicate-address');
        }
      }
      rows
        ..clear()
        ..addAll(next);
      enabled = data['enabled'] as bool;
      version++;
      return {'saved': true};
    }
    if (name == 'getDeliveryConfirmationReport') {
      return {
        'reportId': data['reportId'],
        'sourceJobId': 'winner-local-fixture',
        'html': '',
        'text': '過去の確認メール送信履歴（個別参加者の情報は確認用サンプルです）',
        'deliveries': [
          {
            'name': 'office',
            'email': 'office@example.invalid',
            'status': 'sent',
            'attemptCount': 1,
            'sentAt': '2026-10-31T00:00:00Z',
          },
        ],
      };
    }
    throw StateError('Unexpected local test operation');
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep semantics enabled for real Chrome/CDP mouse and text-input interactions.
  WidgetsBinding.instance.ensureSemantics();
  runApp(
    MaterialApp(
      home: DeliveryConfirmationPage(
        eventId: 'local-fixture',
        service: BrowserConfirmationService(),
      ),
    ),
  );
}
