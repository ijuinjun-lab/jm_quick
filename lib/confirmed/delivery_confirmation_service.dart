import 'dart:convert';
import 'package:http/http.dart' as http;
import '../services/app_check.dart';
import 'auth_client.dart';

/// Only allowlisted codes become UI text. Server messages/details are never shown.
class DeliveryConfirmationException implements Exception {
  const DeliveryConfirmationException(this.code);
  final String code;
  String get message => switch (code) {
    'duplicate-address' => '同じメールアドレスが重複しています。確認先を1件にまとめてください。',
    'invalid-address' => 'メールアドレスの形式が正しくありません。入力内容を確認してください。',
    'mail-kind-required' => '対象メール種別を1つ以上選択してください。',
    'permission-denied' => 'この操作を行う権限がありません。確認先の変更・削除はシステム管理者のみ可能です。',
    'unauthenticated' => 'ログイン・アプリ認証を確認して、もう一度お試しください。',
    'policy-changed' => '別の操作で設定が変更されました。「設定・履歴を更新」してからやり直してください。',
    'invalid-recipient' ||
    'invalid-policy' => '確認先の表示名・有効設定・登録件数を確認してください（最大10件）。',
    _ => '処理できませんでした。時間をおいて再度お試しください。',
  };
}

/// Isolated callable transport with safe typed failures; no shared-mail changes.
class DeliveryConfirmationService {
  DeliveryConfirmationService({
    AuthClient? auth,
    AppCheckTokenProvider? appCheck,
    http.Client? client,
  }) : auth = auth ?? FirebaseAuthClient(),
       appCheck = appCheck ?? FirebaseAppCheckTokenProvider(),
       client = client ?? http.Client();
  final AuthClient auth;
  final AppCheckTokenProvider appCheck;
  final http.Client client;
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data,
  ) async {
    try {
      final token = await auth.idToken();
      final check = await appCheck.token();
      if (token == null || check == null) {
        throw const DeliveryConfirmationException('unauthenticated');
      }
      final response = await client.post(
        Uri.parse('https://asia-northeast1-jm-quick.cloudfunctions.net/$name'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          appCheckHeaderName: check,
        },
        body: jsonEncode({'data': data}),
      );
      final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      if (response.statusCode != 200 || decoded['error'] != null) {
        final error = decoded['error'];
        final status = error is Map ? error['status'] : null;
        final details = error is Map ? error['details'] : null;
        final code = switch (status) {
          'PERMISSION_DENIED' => 'permission-denied',
          'UNAUTHENTICATED' => 'unauthenticated',
          'FAILED_PRECONDITION' ||
          'INVALID_ARGUMENT' => details is Map ? details['code'] : null,
          _ => null,
        };
        throw DeliveryConfirmationException(code is String ? code : 'unknown');
      }
      return Map<String, dynamic>.from(
        (decoded['result'] ?? decoded['data']) as Map,
      );
    } on DeliveryConfirmationException {
      rethrow;
    } catch (_) {
      throw const DeliveryConfirmationException('unknown');
    }
  }
}
