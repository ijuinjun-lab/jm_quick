import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/delivery_confirmation_service.dart';
import 'package:jm_quick/services/app_check.dart';
import 'app_check_fake.dart';
import 'confirmed_auth_test.dart' show FakeAuthClient;

void main() {
  for (final check in [
    FakeAppCheck(null),
    FakeAppCheck(''),
    FakeAppCheck.throwing(),
  ]) {
    test(
      'missing/failed App Check stops before HTTP and is not an Auth failure: $check',
      () async {
        var calls = 0;
        final service = DeliveryConfirmationService(
          auth: FakeAuthClient(signedIn: true),
          appCheck: check,
          client: MockClient((_) async {
            calls++;
            throw StateError('HTTP forbidden');
          }),
        );
        await expectLater(
          service.call('previewManualDeliveryConfirmation', {
            'eventId': 'event1',
          }),
          throwsA(
            isA<DeliveryConfirmationException>().having(
              (e) => e.code,
              'code',
              'app-check-unavailable',
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  }
  test('missing Auth stops before App Check or HTTP', () async {
    final check = FakeAppCheck();
    final service = DeliveryConfirmationService(
      auth: FakeAuthClient(signedIn: false),
      appCheck: check,
      client: MockClient((_) async => throw StateError('HTTP forbidden')),
    );
    await expectLater(
      service.call('previewManualDeliveryConfirmation', {}),
      throwsA(
        isA<DeliveryConfirmationException>().having(
          (e) => e.code,
          'code',
          'unauthenticated',
        ),
      ),
    );
    expect(check.calls, 0);
  });
  test(
    'valid Auth and App Check are both forwarded; role denial is distinct',
    () async {
      for (final status in [200, 403]) {
        final service = DeliveryConfirmationService(
          auth: FakeAuthClient(signedIn: true),
          appCheck: FakeAppCheck(),
          client: MockClient((req) async {
            expect(req.headers['Authorization'], 'Bearer test-token');
            expect(req.headers[appCheckHeaderName], 'test-app-check-token');
            expect(req.url.path, '/previewManualDeliveryConfirmation');
            return http.Response(
              jsonEncode(
                status == 200
                    ? {
                        'result': {'deliveries': []},
                      }
                    : {
                        'error': {'status': 'PERMISSION_DENIED'},
                      },
              ),
              status,
            );
          }),
        );
        if (status == 200) {
          expect(await service.call('previewManualDeliveryConfirmation', {}), {
            'deliveries': [],
          });
        } else {
          await expectLater(
            service.call('previewManualDeliveryConfirmation', {}),
            throwsA(
              isA<DeliveryConfirmationException>().having(
                (e) => e.code,
                'code',
                'permission-denied',
              ),
            ),
          );
        }
      }
    },
  );
}
