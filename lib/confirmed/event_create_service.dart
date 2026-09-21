import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';

/// 新方式イベントの作成で起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class EventCreateException implements Exception {
  const EventCreateException(this.message, {this.code, this.ambiguous = false});
  final String message;

  /// サーバーが返した理由コード(例: start-in-past)。
  final String? code;

  /// 通信の失敗など、サーバーで作成が行われたかどうか分からない場合。
  /// 再試行では同じ作成要求ID(requestId)を使うことで、イベントが二重に作られない。
  final bool ambiguous;
  @override
  String toString() => message;
}

/// 作成するprogram(表示順は一覧の並び順=order)。
class ConfirmedProgramDraft {
  const ConfirmedProgramDraft({required this.programId, required this.name});
  final String programId;
  final String name;
}

/// 作成するイベントの入力。日時は日本時間のオフセット付きISO 8601文字列(例: 2026-11-30T10:00:00+09:00)。
class ConfirmedEventDraft {
  const ConfirmedEventDraft({
    required this.eventName,
    required this.startAt,
    this.endAt,
    required this.venue,
    this.address = '',
    this.access = '',
    this.senderName = '',
    this.contact = '',
    required this.programs,
  });
  final String eventName;
  final String startAt;
  final String? endAt;
  final String venue;
  final String address;
  final String access;
  final String senderName;
  final String contact;
  final List<ConfirmedProgramDraft> programs;

  /// サーバーへ送る内容。flow・eventId・createdBy等は含めない(サーバーが決める)。空の任意項目は送らない。
  Map<String, dynamic> toJson(String requestId) => {
    'requestId': requestId,
    'eventName': eventName.trim(),
    'startAt': startAt,
    'endAt': ?endAt,
    'venue': venue.trim(),
    if (address.trim().isNotEmpty) 'address': address.trim(),
    if (access.trim().isNotEmpty) 'access': access.trim(),
    if (senderName.trim().isNotEmpty) 'senderName': senderName.trim(),
    if (contact.trim().isNotEmpty) 'contact': contact.trim(),
    'programs': [
      for (var i = 0; i < programs.length; i++)
        {
          'programId': programs[i].programId.trim(),
          'name': programs[i].name.trim(),
          'order': i,
        },
    ],
  };
}

class CreatedConfirmedEvent {
  const CreatedConfirmedEvent({
    required this.eventId,
    required this.eventName,
    required this.created,
  });
  final String eventId;
  final String eventName;

  /// false=同じ作成要求の再試行で、既に作られていたイベントが返った。
  final bool created;
}

/// 新方式イベントの作成(admin専用のサーバーAPI)。画面はこの抽象にだけ依存する(テストでは差し替える)。
abstract class EventCreateService {
  Future<CreatedConfirmedEvent> create({
    required String requestId,
    required ConfirmedEventDraft draft,
  });
}

class CallableEventCreateService implements EventCreateService {
  CallableEventCreateService({
    required this.authClient,
    http.Client? httpClient,
    String? baseUrl,
  }) : _httpClient = httpClient ?? http.Client(),
       baseUrl = baseUrl ?? defaultBaseUrl;

  static const defaultBaseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  final AuthClient authClient;
  final http.Client _httpClient;
  final String baseUrl;

  static const _messages = {
    'required': '必須項目が入力されていません。',
    'too-long': '入力が長すぎる項目があります。',
    'invalid-date': '日時の形式が正しくありません。',
    'start-in-past': '開催日時は現在より後の日時にしてください。',
    'invalid-time-range': '終了日時は開催日時より後にしてください。',
    'programs-required': 'programを1件以上追加してください。',
    'too-many-programs': 'programが多すぎます。',
    'invalid-program-id': 'programIDは、英小文字・数字・ハイフンで指定してください。',
    'duplicate-program-id': 'programIDが重複しています。',
    'duplicate-order': 'programの表示順が重複しています。',
    'request-id-conflict': '前回の作成要求が既に処理された可能性があります。この画面を開き直して、内容を確認してください。',
  };

  @override
  Future<CreatedConfirmedEvent> create({
    required String requestId,
    required ConfirmedEventDraft draft,
  }) async {
    final token = await authClient.idToken();
    if (token == null) throw const EventCreateException('ログインが必要です。');
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/createConfirmedEvent'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'data': draft.toJson(requestId)}),
      );
    } catch (_) {
      throw const EventCreateException(
        '通信に失敗しました。イベントが作成されたかどうか分かりません。もう一度「作成する」を押しても、イベントが二重に作られることはありません。',
        ambiguous: true,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map && result['eventId'] is String) {
        return CreatedConfirmedEvent(
          eventId: result['eventId'] as String,
          eventName: result['eventName'] as String? ?? '',
          created: result['created'] != false,
        );
      }
    }
    throw errorFrom(response.statusCode, decoded);
  }

  static EventCreateException errorFrom(int statusCode, Object? decoded) {
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    switch (error['status']) {
      case 'PERMISSION_DENIED':
        return EventCreateException('この操作を行う権限がありません。', code: code);
      case 'UNAUTHENTICATED':
        return EventCreateException('ログインが必要です。', code: code);
    }
    final known = _messages[code];
    if (known != null) return EventCreateException(known, code: code);
    // 5xx等はサーバーで作成が済んだか分からない
    return EventCreateException(
      statusCode >= 500
          ? '処理に失敗しました。イベントが作成されたかどうか分かりません。もう一度「作成する」を押しても、イベントが二重に作られることはありません。'
          : '入力内容を確認してください。',
      code: code,
      ambiguous: statusCode >= 500,
    );
  }
}
