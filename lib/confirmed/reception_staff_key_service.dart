// 受付スタッフ用QRの「受付キー」の通信(functions/confirmed/reception_key_api.js)。
//
// ■ PC(正式ログインした対象イベントのstaff以上): issueReceptionStaffKey で、QRに載せる受付キーを取得する。
// ■ 受付端末(アカウントなし・ログインなし): QRのURLに含まれる受付キーとApp Checkだけで、対象イベントの
//   受付(受付画面の表示・初回受付)を行う。Firebase ID token・uid・roleは送らない。
//   訂正・取消・管理機能は提供しない(このサービスはReceptionAdminServiceを実装しない。サーバーも受付キーでは許可しない)。
// ■ 受付キーはログ・debugPrintへ出さない。

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/app_check.dart';
import 'auth_client.dart';
import 'reception_service.dart';

/// 受付キーが無効・期限切れ・別イベントのもののとき(サーバーは理由を区別しない)。
const String receptionStaffKeyInvalidMessage =
    'この受付スタッフ用QRは無効か、有効期限が切れています。'
    'PCに表示されている受付スタッフ用QRを、もう一度読み取ってください。';

/// PCに表示する受付スタッフ用QRの受付キー。
class ReceptionStaffKey {
  const ReceptionStaffKey({
    required this.eventId,
    required this.key,
    required this.expiresAt,
  });
  final String eventId;
  final String key;
  final DateTime expiresAt;
}

/// 受付端末がQRを読んだ直後に確認する、受付キーの内容(イベント名と有効期限だけ)。
class ReceptionStaffSession {
  const ReceptionStaffSession({
    required this.eventId,
    required this.eventName,
    required this.expiresAt,
  });
  final String eventId;
  final String eventName;
  final DateTime? expiresAt;
}

/// PC側: 受付キーの取得(対象イベントのstaff以上。サーバーがログイン・権限を毎回検証する)。
abstract class ReceptionStaffKeyIssuer {
  Future<ReceptionStaffKey> issue(String eventId);
}

class CallableReceptionStaffKeyIssuer implements ReceptionStaffKeyIssuer {
  CallableReceptionStaffKeyIssuer({
    required this.authClient,
    http.Client? httpClient,
    String? baseUrl,
  }) : _httpClient = httpClient ?? http.Client(),
       baseUrl = baseUrl ?? CallableReceptionService.defaultBaseUrl;

  final AuthClient authClient;
  final http.Client _httpClient;
  final String baseUrl;

  @override
  Future<ReceptionStaffKey> issue(String eventId) async {
    final token = await authClient.idToken();
    if (token == null) throw const ReceptionException('ログインが必要です。');
    final result = await _post(
      _httpClient,
      Uri.parse('$baseUrl/issueReceptionStaffKey'),
      {'Authorization': 'Bearer $token'},
      {'eventId': eventId},
      CallableReceptionService.errorFrom,
    );
    final key = result['key'];
    final expiresAt = result['expiresAt'];
    if (key is! String || key.isEmpty || expiresAt is! num) {
      throw const ReceptionException('受付スタッフ用QRを作成できませんでした。もう一度お試しください。');
    }
    return ReceptionStaffKey(
      eventId: eventId,
      key: key,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt()),
    );
  }
}

/// 受付端末側: 受付キーで対象イベントの受付を行う。eventIdはQRのURL由来で、サーバーが受付キーと照合する。
class ReceptionStaffKeyService implements ReceptionService {
  ReceptionStaffKeyService({
    required this.eventId,
    required this.receptionKey,
    http.Client? httpClient,
    String? baseUrl,
    AppCheckTokenProvider? appCheck,
  }) : _httpClient = httpClient ?? http.Client(),
       _appCheck = appCheck ?? FirebaseAppCheckTokenProvider(),
       baseUrl = baseUrl ?? CallableReceptionService.defaultBaseUrl;

  final String eventId;
  final String receptionKey;
  final http.Client _httpClient;
  final AppCheckTokenProvider _appCheck;
  final String baseUrl;

  /// QRを読んだ直後の確認(受付キーが有効か・どのイベントか)。
  Future<ReceptionStaffSession> getSession() async {
    final result = await _call('getReceptionStaffSessionByStaffKey', {
      'eventId': eventId,
    });
    final expiresAt = result['expiresAt'];
    return ReceptionStaffSession(
      eventId: eventId,
      eventName: result['eventName'] as String? ?? '',
      expiresAt: expiresAt is num
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt())
          : null,
    );
  }

  @override
  Future<ReceptionView> getView({
    required String eventId,
    required String participantId,
    required String publicId,
  }) async => ReceptionView.fromJson(
    await _call('getConfirmedReceptionViewByStaffKey', {
      'eventId': eventId,
      'participantId': participantId,
      'publicId': publicId,
    }),
  );

  @override
  Future<CheckInResult> checkIn({
    required String eventId,
    required String participantId,
    required String publicId,
    required String programId,
    required int attendedCount,
  }) async {
    final result = await _call('checkInConfirmedProgramByStaffKey', {
      'eventId': eventId,
      'participantId': participantId,
      'publicId': publicId,
      'programId': programId,
      'attendedCount': attendedCount,
    });
    final program = result['program'];
    if (program is! Map) {
      throw const ReceptionException('受付結果を確認できませんでした。受付状況を確認してください。');
    }
    return CheckInResult(
      alreadyCheckedIn: result['alreadyCheckedIn'] == true,
      program: ReceptionProgram.fromJson(Map<String, dynamic>.from(program)),
    );
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    String? appCheckToken;
    try {
      appCheckToken = await _appCheck.token();
    } catch (_) {
      appCheckToken = null;
    }
    if (appCheckToken == null) {
      throw const ReceptionException(
        'リクエストを確認できませんでした。ページを読み込み直して、もう一度お試しください。',
      );
    }
    // ログインなし。送るのは受付の入力・受付キー・App Checkトークンだけ(IDトークン・uid・roleは送らない)。
    return _post(
      _httpClient,
      Uri.parse('$baseUrl/$name'),
      {appCheckHeaderName: appCheckToken},
      {...data, 'receptionKey': receptionKey},
      receptionStaffKeyErrorFrom,
    );
  }
}

Future<Map<String, dynamic>> _post(
  http.Client client,
  Uri url,
  Map<String, String> headers,
  Map<String, dynamic> data,
  ReceptionException Function(int statusCode, Object? decoded) errorFrom,
) async {
  http.Response response;
  try {
    response = await client.post(
      url,
      headers: {'Content-Type': 'application/json', ...headers},
      body: jsonEncode({'data': data}),
    );
  } catch (_) {
    throw const ReceptionException('通信に失敗しました。通信状態を確認して、もう一度お試しください。');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    decoded = null;
  }
  if (response.statusCode == 200 && decoded is Map) {
    final result = decoded['result'] ?? decoded['data'];
    if (result is Map) return Map<String, dynamic>.from(result);
  }
  throw errorFrom(response.statusCode, decoded);
}

/// 受付端末向け: サーバーのエラー応答を表示用の例外にする。受付キーの拒否とApp Checkの拒否(端末はログインしないため
/// UNAUTHENTICATEDは「ログインが必要」ではない)だけを専用の案内にし、それ以外は既存の受付と同じ。
ReceptionException receptionStaffKeyErrorFrom(int statusCode, Object? decoded) {
  final error = decoded is Map && decoded['error'] is Map
      ? Map<String, dynamic>.from(decoded['error'] as Map)
      : const <String, dynamic>{};
  final details = error['details'] is Map
      ? Map<String, dynamic>.from(error['details'] as Map)
      : const <String, dynamic>{};
  if (details['code'] == 'reception-key-invalid') {
    return const ReceptionException(
      receptionStaffKeyInvalidMessage,
      code: 'reception-key-invalid',
      notAllowed: true,
    );
  }
  if (error['status'] == 'UNAUTHENTICATED') {
    return const ReceptionException(
      'リクエストを確認できませんでした。ページを読み込み直して、もう一度お試しください。',
    );
  }
  return CallableReceptionService.errorFrom(statusCode, decoded);
}
