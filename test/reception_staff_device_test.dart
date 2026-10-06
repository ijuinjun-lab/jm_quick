// 受付スタッフ用QRを読み取った受付端末(`/reception/staff?eventId=…&key=…`)。
// アカウントを持たない受付スタッフのスマートフォンが、ログイン(メールアドレス・パスワード)なしで、
// このイベントの受付カメラへ直接進み、参加者QRを続けて受付できることを確認する。
// 通信はhttpのMockClient(架空のサーバー)、カメラは差し替え(実カメラ・実Firebase・外部通信は使わない)。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/qr_scanner.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_page.dart';
import 'package:jm_quick/confirmed/reception_staff_device_page.dart';
import 'package:jm_quick/confirmed/reception_staff_key_service.dart';
import 'package:jm_quick/main.dart' show resolveRoute;

import 'app_check_fake.dart';
import 'reception_staff_key_fake.dart';

const _host = 'jm-quick.example.invalid';
const _event = 'event1';

String _participantQr(String eventId, String participantId) =>
    'https://$_host/reception?eventId=$eventId&participantId=$participantId'
    '&publicId=pub_${participantId}0123456789012345678';

/// 架空のサーバー(Functionsの受付キーcallableと同じ入出力)。受付キー・eventIdをサーバー側で照合する。
class FakeKeyServer {
  FakeKeyServer({this.validKey = fakeReceptionKey});
  final String validKey;
  final List<
    ({String name, Map<String, dynamic> data, Map<String, String> headers})
  >
  requests = [];
  final Map<String, int> checkedIn =
      {}; // participantId_programId → attendedCount

  http.Client client() => MockClient((request) async {
    final name = request.url.pathSegments.last;
    final data = Map<String, dynamic>.from(
      (jsonDecode(request.body) as Map)['data'] as Map,
    );
    requests.add((name: name, data: data, headers: request.headers));
    http.Response json(int status, Object body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    if (data['receptionKey'] != validKey || data['eventId'] != _event) {
      return json(403, {
        'error': {
          'status': 'PERMISSION_DENIED',
          'message': '受付スタッフ用QRが無効か、有効期限が切れています。',
          'details': {'code': 'reception-key-invalid'},
        },
      });
    }
    switch (name) {
      case 'getReceptionStaffSessionByStaffKey':
        return json(200, {
          'result': {
            'eventId': _event,
            'eventName': '架空イベント',
            'expiresAt': 1796050800000,
          },
        });
      case 'getConfirmedReceptionViewByStaffKey':
        final pid = data['participantId'];
        return json(200, {
          'result': {
            'eventId': _event,
            'eventName': '架空イベント',
            'participantName': '架空 参加者$pid',
            'programs': [
              {
                'programId': 'alpha',
                'name': '譲渡会(ねこ)',
                'plannedCount': 2,
                'checkedIn': checkedIn.containsKey('${pid}_alpha'),
              },
            ],
          },
        });
      case 'checkInConfirmedProgramByStaffKey':
        final id = '${data['participantId']}_${data['programId']}';
        final already = checkedIn.containsKey(id);
        checkedIn.putIfAbsent(id, () => data['attendedCount'] as int);
        return json(200, {
          'result': {
            'alreadyCheckedIn': already,
            'program': {
              'programId': data['programId'],
              'plannedCount': 2,
              'checkedIn': true,
              'checkedInAt': '2026-11-30T01:23:00.000Z',
              'attendedCount': checkedIn[id],
            },
          },
        });
    }
    return json(404, {
      'error': {'status': 'NOT_FOUND'},
    });
  });
}

/// 1台の受付端末(カメラは差し替え。onRawで「QRを写した」ことを再現する)。
class _Device {
  _Device(this.server, {this.eventId = _event, this.key = fakeReceptionKey});
  final FakeKeyServer server;
  final String? eventId;
  final String? key;
  void Function(String raw)? scan;

  Widget app() => MaterialApp(
    home: ReceptionStaffDeviceRoute(
      eventId: eventId,
      receptionKey: key,
      expectedHost: _host,
      serviceFactory: (eventId, key) => ReceptionStaffKeyService(
        eventId: eventId,
        receptionKey: key,
        httpClient: server.client(),
        baseUrl: 'https://functions.example.invalid',
        appCheck: FakeAppCheck(),
      ),
      surfaceBuilder: (context, {required onRaw}) {
        scan = onRaw;
        return const SizedBox(key: Key('fake-camera'));
      },
    ),
  );
}

Future<void> _checkInShown(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '受付する').first);
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '受付する').last); // 確認ダイアログ
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('URL `/reception/staff?eventId=…&key=…` は受付端末の画面(ログイン画面ではない)', (
    tester,
  ) async {
    final page = resolveRoute(
      Uri.parse(
        'https://$_host/reception/staff?eventId=$_event&key=$fakeReceptionKey',
      ),
    );
    expect(page, isA<ReceptionStaffDeviceRoute>());
    final route = page as ReceptionStaffDeviceRoute;
    expect(route.eventId, _event);
    expect(route.receptionKey, fakeReceptionKey);
  });

  testWidgets('未ログインの端末でも、メールアドレス・パスワード入力なしで、このイベントの受付カメラへ直接進む', (
    tester,
  ) async {
    final server = FakeKeyServer();
    final device = _Device(server);
    await tester.pumpWidget(device.app());
    await tester.pumpAndSettle();
    expect(find.text('メールアドレス'), findsNothing);
    expect(find.text('パスワード'), findsNothing);
    expect(find.byType(ConfirmedQrScannerView), findsOneWidget);
    expect(find.byKey(const Key('fake-camera')), findsOneWidget);
    // そのイベントに固定されている
    expect(
      tester
          .widget<ConfirmedScanReceptionFlow>(
            find.byType(ConfirmedScanReceptionFlow),
          )
          .initialEventId,
      _event,
    );
    // 送ったのは受付キーとApp Checkだけ(Firebase IDトークンは送らない)
    final first = server.requests.single;
    expect(first.name, 'getReceptionStaffSessionByStaffKey');
    expect(first.data, {'eventId': _event, 'receptionKey': fakeReceptionKey});
    expect(
      first.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(first.headers['X-Firebase-AppCheck'], 'test-app-check-token');
  });

  testWidgets('参加者QRを受付 → 「次のQRを読み取る」でカメラへ戻り、続けて次の参加者を受付できる(QRの再読取不要)', (
    tester,
  ) async {
    final server = FakeKeyServer();
    final device = _Device(server);
    await tester.pumpWidget(device.app());
    await tester.pumpAndSettle();

    device.scan!(_participantQr(_event, 'p1'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmedReceptionPage), findsOneWidget);
    expect(find.textContaining('架空 参加者p1'), findsOneWidget);
    // 受付端末には訂正・取消(管理者向けの操作)を出さない
    expect(find.text('人数を訂正'), findsNothing);
    expect(find.text('受付を取り消す'), findsNothing);
    await _checkInShown(tester);
    expect(server.checkedIn, {'p1_alpha': 2});

    await tester.tap(find.text('次のQRを読み取る'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmedQrScannerView), findsOneWidget);

    device.scan!(_participantQr(_event, 'p2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('架空 参加者p2'), findsOneWidget);
    await _checkInShown(tester);
    expect(server.checkedIn, {'p1_alpha': 2, 'p2_alpha': 2});
    // 受付のたびに受付キーを送っている(セッションは端末のメモリ上に保持。受付スタッフ用QRの再読取は無い)
    final checkIns = server.requests.where(
      (r) => r.name == 'checkInConfirmedProgramByStaffKey',
    );
    expect(checkIns.length, 2);
    expect(
      checkIns.every(
        (r) =>
            r.data['receptionKey'] == fakeReceptionKey &&
            r.data['eventId'] == _event,
      ),
      isTrue,
    );
    expect(
      server.requests
          .where((r) => r.name == 'getReceptionStaffSessionByStaffKey')
          .length,
      1,
    );
  });

  testWidgets('同じ受付スタッフ用QRを端末A・B・Cで読み取り、それぞれ受付できる(1台で失効しない)', (tester) async {
    final server = FakeKeyServer();
    for (final (i, participant) in ['pa', 'pb', 'pc'].indexed) {
      final device = _Device(server);
      await tester.pumpWidget(Container(key: ValueKey(i), child: device.app()));
      await tester.pumpAndSettle();
      expect(
        find.byType(ConfirmedQrScannerView),
        findsOneWidget,
        reason: '端末${'ABC'[i]}',
      );
      device.scan!(_participantQr(_event, participant));
      await tester.pumpAndSettle();
      await _checkInShown(tester);
    }
    expect(server.checkedIn.keys.toSet(), {'pa_alpha', 'pb_alpha', 'pc_alpha'});
  });

  testWidgets('他イベントの参加者QRは受付画面へ進まない(このイベントに固定)', (tester) async {
    final server = FakeKeyServer();
    final device = _Device(server);
    await tester.pumpWidget(device.app());
    await tester.pumpAndSettle();
    device.scan!(_participantQr('event2', 'q1'));
    await tester.pumpAndSettle();
    expect(find.byType(ConfirmedReceptionPage), findsNothing);
    expect(find.text(qrDifferentEventMessage), findsOneWidget);
    expect(
      server.requests.where(
        (r) => r.name != 'getReceptionStaffSessionByStaffKey',
      ),
      isEmpty,
    );
  });

  testWidgets('無効・期限切れ・改ざんされた受付スタッフ用QRは、カメラもログイン画面も出さず、読み直しを案内する', (
    tester,
  ) async {
    final server = FakeKeyServer();
    final device = _Device(server, key: '${fakeReceptionKey.substring(1)}X');
    await tester.pumpWidget(device.app());
    await tester.pumpAndSettle();
    expect(find.text(receptionStaffKeyInvalidMessage), findsOneWidget);
    expect(find.byType(ConfirmedQrScannerView), findsNothing);
    expect(find.text('メールアドレス'), findsNothing);
    expect(find.text('再試行'), findsNothing);
  });

  testWidgets('eventIdを書き換えたURL(別イベント + このキー)は、サーバーが拒否する', (tester) async {
    final server = FakeKeyServer();
    final device = _Device(server, eventId: 'event2');
    await tester.pumpWidget(device.app());
    await tester.pumpAndSettle();
    expect(find.text(receptionStaffKeyInvalidMessage), findsOneWidget);
    expect(find.byType(ConfirmedQrScannerView), findsNothing);
  });

  testWidgets('受付キー・eventIdが無いURLは、通信せずに案内だけ', (tester) async {
    for (final (eventId, key) in [
      (null, fakeReceptionKey),
      (_event, null),
      ('', ''),
      (_event, '  '),
    ]) {
      final server = FakeKeyServer();
      await tester.pumpWidget(
        Container(
          key: UniqueKey(),
          child: _Device(server, eventId: eventId, key: key).app(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(receptionStaffKeyInvalidMessage), findsOneWidget);
      expect(server.requests, isEmpty);
    }
  });

  testWidgets('受付キーの拒否は受付画面でも「QRを読み直す」案内になる(期限切れの途中でも理由が分かる)', (tester) async {
    final error = receptionStaffKeyErrorFrom(403, {
      'error': {
        'status': 'PERMISSION_DENIED',
        'details': {'code': 'reception-key-invalid'},
      },
    });
    expect(error.message, receptionStaffKeyInvalidMessage);
    expect(error.notAllowed, isTrue);
    // App Checkの拒否は「ログインが必要」ではない(端末はログインしない)
    final appCheck = receptionStaffKeyErrorFrom(401, {
      'error': {'status': 'UNAUTHENTICATED'},
    });
    expect(appCheck.message.contains('ログイン'), isFalse);
  });
}
