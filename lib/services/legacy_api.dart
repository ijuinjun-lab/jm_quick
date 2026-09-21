import 'dart:convert';

import 'package:http/http.dart' as http;

import '../confirmed/auth_client.dart';

/// 従来方式(legacy)のサーバーAPI呼び出しの失敗。[message]は画面へそのまま表示できる文(内部情報を含まない)。
class LegacyApiException implements Exception {
  const LegacyApiException(this.message, {this.status});
  final String message;

  /// サーバーの状態コード(UNAUTHENTICATED / PERMISSION_DENIED / FAILED_PRECONDITION / NOT_FOUND など)。
  final String? status;

  bool get isUnauthenticated => status == 'UNAUTHENTICATED';
  bool get isPermissionDenied => status == 'PERMISSION_DENIED';
  bool get isNotFound => status == 'NOT_FOUND';
  bool get isFailedPrecondition => status == 'FAILED_PRECONDITION';

  @override
  String toString() => message;
}

/// 従来方式のcallable(Cloud Functions)を呼ぶ窓口。
///  - [authenticated]=true(管理・受付・メール・削除): IDトークンを Authorization ヘッダで送る。
///    送るのはトークンだけで、uid・role・emailは本文に入れない(サーバーは request.auth.uid → accessRoles/{uid} だけで認可する)
///  - [authenticated]=false(参加者本人のcapability API・当日参加登録): トークンを送らない。
///    参加者は participantId+publicId の組で本人確認される
class LegacyApiClient {
  LegacyApiClient({AuthClient? authClient, http.Client? httpClient})
    : _authClient = authClient,
      _httpClient = httpClient ?? http.Client();

  static const String _baseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  AuthClient? _authClient;
  final http.Client _httpClient;

  /// Firebase初期化後の最初の利用時に作る(テストでは差し替える)。
  AuthClient get authClient => _authClient ??= FirebaseAuthClient();

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> data, {
    bool authenticated = true,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (authenticated) {
      final String? token;
      try {
        token = await authClient.idToken();
      } catch (_) {
        throw const LegacyApiException(
          'ログイン状態を確認できませんでした。',
          status: 'UNAUTHENTICATED',
        );
      }
      if (token == null) {
        throw const LegacyApiException('ログインが必要です。', status: 'UNAUTHENTICATED');
      }
      headers['Authorization'] = 'Bearer $token';
    }
    final http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$_baseUrl/$name'),
        headers: headers,
        body: jsonEncode({'data': data}),
      );
    } catch (_) {
      throw const LegacyApiException('通信に失敗しました。通信状態を確認して、もう一度お試しください。');
    }
    final decoded = _decodeObject(response.body);
    final payload = decoded['result'] ?? decoded['data'];
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    final error = decoded['error'];
    final message = error is Map ? error['message']?.toString() : null;
    final status = error is Map ? error['status']?.toString() : null;
    throw LegacyApiException(
      message ?? '処理できませんでした(HTTP ${response.statusCode})。',
      status: status,
    );
  }

  static Map<String, dynamic> _decodeObject(String source) {
    try {
      final decoded = jsonDecode(source);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}
