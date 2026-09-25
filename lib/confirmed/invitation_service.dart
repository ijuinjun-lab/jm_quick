// Phase 4: 招待リンク(`/invite?token=…`)を開いた本人向けの通信。
//   getEventInvitation: ログイン不要(App Check・rate limit。tokenを確認できた場合だけ最小限の情報)
//   acceptEventInvitation: ログインした本人(メールアドレスの一致はサーバーがAuthの正本で確認する)
// tokenはログ・画面に出さない。パスワードはFunctionsへ送らず、Firebase Auth SDKで本人が設定する。

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/app_check.dart';
import 'access_role.dart';
import 'auth_client.dart';

enum InvitationStatus { pending, accepted, expired, revoked, invalid }

class InvitationInfo {
  const InvitationInfo({
    required this.status,
    this.eventName = '',
    this.role,
    this.emailHint = '',
    this.email = '',
    this.expiresAt,
    this.accountExists = false,
  });

  final InvitationStatus status;
  final String eventName;
  final EventRole? role;

  /// 招待先のメールアドレスの一部(例: ta***@example.com)。
  final String emailHint;
  final String email;
  final DateTime? expiresAt;

  /// 招待先のメールアドレスで、既にAuthアカウントがある(受諾の完了とは独立)。
  final bool accountExists;

  static InvitationInfo fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'pending' => InvitationStatus.pending,
      'accepted' => InvitationStatus.accepted,
      'expired' => InvitationStatus.expired,
      'revoked' => InvitationStatus.revoked,
      _ => InvitationStatus.invalid,
    };
    if (status != InvitationStatus.pending) {
      return InvitationInfo(status: status);
    }
    final role = EventRole.fromValue(json['role']);
    if (role == null) {
      return const InvitationInfo(status: InvitationStatus.invalid);
    }
    return InvitationInfo(
      status: status,
      eventName: json['eventName'] as String? ?? '',
      role: role,
      emailHint: json['emailHint'] as String? ?? '',
      email: json['email'] as String? ?? '',
      expiresAt: DateTime.tryParse(
        json['expiresAt'] as String? ?? '',
      )?.toLocal(),
      accountExists: json['accountExists'] == true,
    );
  }
}

class InvitationAcceptResult {
  const InvitationAcceptResult({required this.eventName, required this.role});
  final String eventName;
  final EventRole role;
}

class InvitationException implements Exception {
  const InvitationException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

abstract class InvitationService {
  Future<InvitationInfo> getInvitation(String token);
  Future<InvitationAcceptResult> accept(String token);
}

String invitationErrorMessage(String? status, String? code) {
  switch (code) {
    case 'invitation-expired':
      return 'この招待の有効期限が切れています。招待した方に、もう一度招待を依頼してください。';
    case 'invitation-revoked':
      return 'この招待は取り消されています。';
    case 'invitation-accepted':
      return 'この招待は受諾済みです。JM Quickへログインしてください。';
    case 'invitation-invalid':
    case 'invitation-changed':
    case 'invitation-inviter-inactive':
    case 'event-not-confirmed':
    case 'event-not-found':
      return 'この招待は利用できません。招待した方に確認してください。';
    case 'invitation-email-mismatch':
      return '招待されたメールアドレスでログインしてください。';
    case 'target-is-system-admin':
      return 'システム管理者のアカウントでは、この招待を受ける必要はありません。';
  }
  switch (status) {
    case 'UNAUTHENTICATED':
      return 'ログインが必要です。';
    case 'PERMISSION_DENIED':
      return 'この操作を行う権限がありません。';
    case 'RESOURCE_EXHAUSTED':
      return '操作が集中しています。しばらくしてから、もう一度お試しください。';
  }
  return '処理に失敗しました。もう一度お試しください。';
}

class CallableInvitationService implements InvitationService {
  CallableInvitationService({
    required this.authClient,
    http.Client? httpClient,
    String? baseUrl,
    AppCheckTokenProvider? appCheck,
  }) : _httpClient = httpClient ?? http.Client(),
       _appCheck = appCheck ?? FirebaseAppCheckTokenProvider(),
       baseUrl = baseUrl ?? defaultBaseUrl;

  static const defaultBaseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  final AuthClient authClient;
  final http.Client _httpClient;
  final AppCheckTokenProvider _appCheck;
  final String baseUrl;

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data, {
    required bool signedIn,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (signedIn) {
      final token = await authClient.idToken();
      if (token == null) throw const InvitationException('ログインが必要です。');
      headers['Authorization'] = 'Bearer $token';
    } else {
      String? appCheckToken;
      try {
        appCheckToken = await _appCheck.token();
      } catch (_) {
        appCheckToken = null;
      }
      if (appCheckToken == null) {
        throw const InvitationException(
          'リクエストを確認できませんでした。ページを読み込み直して、もう一度お試しください。',
        );
      }
      headers[appCheckHeaderName] = appCheckToken;
    }
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/$name'),
        headers: headers,
        body: jsonEncode({'data': data}),
      );
    } catch (_) {
      throw const InvitationException('通信に失敗しました。通信状態を確認して、もう一度お試しください。');
    }
    return interpret(response.statusCode, utf8.decode(response.bodyBytes));
  }

  static Map<String, dynamic> interpret(int statusCode, String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    throw InvitationException(
      invitationErrorMessage(error['status'] as String?, code),
      code: code,
    );
  }

  @override
  Future<InvitationInfo> getInvitation(String token) async =>
      InvitationInfo.fromJson(
        await _call('getEventInvitation', {'token': token}, signedIn: false),
      );

  @override
  Future<InvitationAcceptResult> accept(String token) async {
    final result = await _call('acceptEventInvitation', {
      'token': token,
    }, signedIn: true);
    return InvitationAcceptResult(
      eventName: result['eventName'] as String? ?? '',
      role: EventRole.fromValue(result['role']) ?? EventRole.staff,
    );
  }
}
