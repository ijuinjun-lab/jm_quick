import 'dart:convert';

import 'package:http/http.dart' as http;

import 'access_role.dart';
import 'auth_client.dart';

/// 自分のロールをサーバーに確認する。判定はすべてサーバー側
/// (ログイン + accessRoles/{uid}.active == true + role)で行われる。
abstract class AccessService {
  Future<AccessCheck> fetchMyAccess();
}

/// getMyAccessRole callableを呼ぶ実装。
/// 送るのはIDトークン(Authorizationヘッダ)だけで、uid・role・emailを本文に入れない
/// (入れてもサーバーは信用しない)。Firestoreの accessRoles は直接読まない。
class CallableAccessService implements AccessService {
  CallableAccessService({
    required this.authClient,
    http.Client? httpClient,
    Uri? uri,
  }) : _httpClient = httpClient ?? http.Client(),
       uri = uri ?? defaultUri;

  static final Uri defaultUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/getMyAccessRole',
  );

  final AuthClient authClient;
  final http.Client _httpClient;
  final Uri uri;

  @override
  Future<AccessCheck> fetchMyAccess() async {
    try {
      final token = await authClient.idToken();
      if (token == null) return const AccessCheck.unauthenticated();
      final response = await _httpClient.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'data': <String, dynamic>{}}),
      );
      return interpret(response.statusCode, response.body);
    } catch (_) {
      return const AccessCheck.error();
    }
  }

  /// サーバーの応答を判定結果へ変換する(テストしやすいよう分離)。
  static AccessCheck interpret(int statusCode, String body) {
    if (statusCode == 401) return const AccessCheck.unauthenticated();
    if (statusCode == 403) return const AccessCheck.denied();
    if (statusCode != 200) return const AccessCheck.error();
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const AccessCheck.error();
    }
    final result = decoded is Map
        ? (decoded['result'] ?? decoded['data'])
        : null;
    if (result is! Map || result['authenticated'] != true) {
      return const AccessCheck.error();
    }
    final role = AccessRole.fromValue(result['role']);
    // Phase 3: 有効な担当イベント(イベント管理者・スタッフ)。未知のroleや不正な項目は無視する。
    final assignments = <EventAssignment>[];
    final rawAssignments = result['assignments'];
    if (rawAssignments is List) {
      for (final raw in rawAssignments) {
        if (raw is! Map) continue;
        final eventId = raw['eventId'];
        final eventRole = EventRole.fromValue(raw['role']);
        if (eventId is! String || eventId.isEmpty || eventRole == null) {
          continue;
        }
        assignments.add(EventAssignment(eventId: eventId, role: eventRole));
      }
    }
    // 200でも、admin/staff以外の値で担当イベントも無ければ権限なしとして扱う(未知の値を許可しない)。
    // systemAdminはroleがadminのときだけ(systemAdmin=trueの主張だけでは管理機能を出さない)。
    if (role != null) {
      return AccessCheck.granted(role, assignments: assignments);
    }
    return assignments.isEmpty
        ? const AccessCheck.denied()
        : AccessCheck.eventScoped(assignments);
  }
}
