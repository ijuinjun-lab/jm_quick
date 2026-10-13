import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';
import 'winner_send_service.dart';

/// イベント設定(基本情報)。サーバー(getConfirmedEventSettings)が返す、保存されている値。日時はUTC。
class EventSettings {
  const EventSettings({
    required this.eventName,
    required this.startAt,
    required this.venue,
    this.endAt,
    this.address,
    this.access,
    this.rawStartAt,
    this.rawEndAt,
  });

  factory EventSettings.fromJson(Map<String, dynamic> json) {
    final start = json['startAt'] as String?;
    final end = json['endAt'] as String?;
    return EventSettings(
      eventName: json['eventName'] as String? ?? '',
      startAt: start == null ? null : DateTime.tryParse(start)?.toUtc(),
      endAt: end == null ? null : DateTime.tryParse(end)?.toUtc(),
      venue: json['venue'] as String? ?? '',
      address: json['address'] as String?,
      access: json['access'] as String?,
      rawStartAt: start,
      rawEndAt: end,
    );
  }

  final String eventName;
  final DateTime? startAt;
  final DateTime? endAt;
  final String venue;
  final String? address;
  final String? access;

  /// サーバーが返したそのままの値(同時更新の照合 expected に使う)。
  final String? rawStartAt;
  final String? rawEndAt;

  /// 同時更新の照合用に、読み込んだ時点の値をサーバーへ返す形にする。
  Object? expectedOf(String field) => switch (field) {
    'eventName' => eventName,
    'startAt' => rawStartAt,
    'endAt' => rawEndAt,
    'venue' => venue,
    'address' => address,
    'access' => access,
    _ => throw ArgumentError(field),
  };
}

/// このイベントの送信済みメールの件数(当選メール・繰り上げ当選メール・前日リマインドの合計)。
class EventSentMail {
  const EventSentMail({this.sentCount = 0, this.unknownCount = 0, this.jobCount = 0});
  factory EventSentMail.fromJson(Object? json) {
    final m = json is Map ? Map<String, dynamic>.from(json) : const <String, dynamic>{};
    return EventSentMail(
      sentCount: (m['sentCount'] as num?)?.toInt() ?? 0,
      unknownCount: (m['unknownCount'] as num?)?.toInt() ?? 0,
      jobCount: (m['jobCount'] as num?)?.toInt() ?? 0,
    );
  }
  final int sentCount;
  final int unknownCount;
  final int jobCount;

  /// 送信済み(または送ったかもしれない)メールがある。
  bool get any => sentCount + unknownCount > 0;
}

class EventSettingsView {
  const EventSettingsView({required this.settings, required this.sentMail});
  final EventSettings settings;
  final EventSentMail sentMail;
}

/// イベント設定の取得・保存(対象イベントのイベント管理者以上。サーバーが必ず認可を検証する)。
abstract class EventSettingsService {
  Future<EventSettingsView> getSettings(String eventId);

  /// [changes]: 変更するフィールドだけ(eventName / startAt / endAt / venue / address / access。日時はISO 8601)。
  /// [expected]: それぞれの、読み込んだ時点の値(同時更新の照合用)。
  Future<EventSettings> update(
    String eventId, {
    required Map<String, Object?> changes,
    required Map<String, Object?> expected,
  });
}

class CallableEventSettingsService implements EventSettingsService {
  CallableEventSettingsService({
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

  @override
  Future<EventSettingsView> getSettings(String eventId) async {
    final result = await _call('getConfirmedEventSettings', {'eventId': eventId});
    return EventSettingsView(
      settings: EventSettings.fromJson(
        Map<String, dynamic>.from(result['settings'] as Map? ?? const {}),
      ),
      sentMail: EventSentMail.fromJson(result['sentMail']),
    );
  }

  @override
  Future<EventSettings> update(
    String eventId, {
    required Map<String, Object?> changes,
    required Map<String, Object?> expected,
  }) async {
    final result = await _call('updateConfirmedEventSettings', {
      'eventId': eventId,
      'changes': changes,
      'expected': expected,
    });
    return EventSettings.fromJson(
      Map<String, dynamic>.from(result['settings'] as Map? ?? const {}),
    );
  }

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final token = await authClient.idToken();
    if (token == null) throw const WinnerSendException('ログインが必要です。');
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/$name'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'data': data}),
      );
    } catch (_) {
      throw const WinnerSendException(
        '通信に失敗しました。通信状態を確認して、もう一度お試しください。',
        code: 'network',
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
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    throw errorFrom(response.statusCode, decoded);
  }

  static const _messages = {
    'event-settings-changed':
        'ほかの操作でイベント設定が変更されています。最新の内容を読み込み直してから、もう一度保存してください。',
    'no-change': '変更がありません。',
    'invalid-time-range': '終了日時は、開始日時より後にしてください。',
    'invalid-date': '日時の形式が正しくありません。',
    'required': '必須の項目が空欄です。',
    'too-long': '入力が長すぎます。',
    'invalid-venue-info': '住所・アクセスの入力が正しくありません。',
  };

  /// サーバーのエラー応答を、表示用の例外にする(共通のものは当選メールの送信管理と同じ)。
  static WinnerSendException errorFrom(int statusCode, Object? decoded) {
    final base = CallableWinnerSendService.errorFrom(statusCode, decoded);
    final message = _messages[base.code];
    return message == null ? base : WinnerSendException(message, code: base.code);
  }
}
