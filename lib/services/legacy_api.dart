import 'dart:convert';

import 'package:http/http.dart' as http;

import '../confirmed/auth_client.dart';
import 'app_check.dart';

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
  bool get isResourceExhausted => status == 'RESOURCE_EXHAUSTED';

  @override
  String toString() => message;
}

/// 従来方式のcallable(Cloud Functions)を呼ぶ窓口。
///  - [authenticated]=true(管理・受付・メール・削除): IDトークンを Authorization ヘッダで送る。
///    送るのはトークンだけで、uid・role・emailは本文に入れない(サーバーは request.auth.uid → accessRoles/{uid} だけで認可する)
///  - [authenticated]=false(参加者本人のcapability API・当日参加登録): IDトークンは送らず、App Checkトークン(X-Firebase-AppCheck)を送る。
///    参加者は participantId+publicId の組で本人確認される。App Checkトークンを取得できないときは、サーバーへ送らずに失敗する(サーバーも拒否する)
class LegacyApiClient {
  LegacyApiClient({
    AuthClient? authClient,
    http.Client? httpClient,
    AppCheckTokenProvider? appCheck,
  }) : _authClient = authClient,
       _httpClient = httpClient ?? http.Client(),
       _appCheck = appCheck;

  static const String _baseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  AuthClient? _authClient;
  final http.Client _httpClient;
  AppCheckTokenProvider? _appCheck;

  /// 公開API(ログイン不要)へ付けるApp Checkトークンの取得口。最初の利用時に作る(テストでは差し替える)。
  AppCheckTokenProvider get appCheck =>
      _appCheck ??= FirebaseAppCheckTokenProvider();

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
    } else {
      String? appCheckToken;
      try {
        appCheckToken = await appCheck.token();
      } catch (_) {
        appCheckToken = null; // 取得失敗はトークン無しと同じ(理由・トークンは外へ出さない)
      }
      if (appCheckToken == null) {
        throw const LegacyApiException(
          'リクエストを確認できませんでした。ページを読み込み直して、もう一度お試しください。',
          status: 'APP_CHECK_UNAVAILABLE',
        );
      }
      headers[appCheckHeaderName] = appCheckToken;
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
