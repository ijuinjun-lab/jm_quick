import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jm_quick/confirmed/auth_client.dart';
import 'package:jm_quick/confirmed/invitation_service.dart';
import 'package:jm_quick/services/app_check.dart';

import 'confirmed_auth_test.dart' show FakeAuthClient;

class _Credential implements UserCredential {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AuthSdk implements FirebaseAuth {
  final calls = <(String, String)>[];
  String? failure;
  @override
  Future<UserCredential> createUserWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    calls.add((email, password));
    if (failure != null) throw FirebaseAuthException(code: failure!);
    return _Credential();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AppCheck implements AppCheckTokenProvider {
  @override
  Future<String?> token() async => 'fixture-app-check';
}

void main() {
  test('本人登録はFirebase Auth SDKにだけemail/passwordを渡す', () async {
    final sdk = _AuthSdk();
    await FirebaseAuthClient(
      auth: sdk,
    ).register('invited@example.invalid', 'fixture-password');
    expect(sdk.calls, [('invited@example.invalid', 'fixture-password')]);
  });

  test('既存Firebase password policyの拒否と登録競合を安全な文言で返す', () async {
    final sdk = _AuthSdk();
    for (final code in [
      'weak-password',
      'password-does-not-meet-requirements',
      'email-already-in-use',
    ]) {
      sdk.failure = code;
      await expectLater(
        FirebaseAuthClient(
          auth: sdk,
        ).register('invited@example.invalid', 'fixture-password'),
        throwsA(
          isA<AuthFailure>()
              .having((e) => e.code, 'code', code)
              .having(
                (e) => e.message.contains('fixture-password'),
                'passwordを返さない',
                false,
              ),
        ),
      );
    }
  });

  test('招待Functionsへの通信はtokenだけ。Auth ID tokenとApp Checkを用途別に付与', () async {
    final requests = <http.Request>[];
    final service = CallableInvitationService(
      authClient: FakeAuthClient(signedIn: true),
      appCheck: _AppCheck(),
      baseUrl: 'https://functions.invalid',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'result': request.url.path.endsWith('getEventInvitation')
                ? {
                    'status': 'pending',
                    'email': 'invited@example.invalid',
                    'role': 'staff',
                  }
                : {'eventName': 'Fixture', 'role': 'staff'},
          }),
          200,
        );
      }),
    );
    await service.getInvitation('fixture-token');
    await service.accept('fixture-token');
    for (final request in requests) {
      expect(jsonDecode(request.body), {
        'data': {'token': 'fixture-token'},
      });
      expect(request.body.contains('password'), isFalse);
    }
    expect(requests[0].headers['Authorization'], isNull);
    expect(requests[0].headers[appCheckHeaderName], 'fixture-app-check');
    expect(requests[1].headers['Authorization'], 'Bearer test-token');
  });
}
