// confirmedイベントの一覧(管理画面→イベント選択の入口)。
//
// ■ 新しいFunctionsは追加していない。既存のadmin専用callable`listLegacyEvents`(functions/legacy/legacy_api.js
//   の listEvents)が、Firestoreの`events`コレクション全件(legacy・confirmedの両方)をDTOで返しており、
//   そのDTOには最初からeventId・eventName・startAt・venue・flowが含まれている。これをFlutter側で
//   flow=="confirmed"だけに絞り込んで使う(サーバー・Rulesは無変更。FirestoreはFlutterから直接読まない)。
// ■ 返るDTOにはparticipant・メールテンプレート・Secret等は含まれない(legacyの参加者一覧はgetEventAdminViewの
//   別APIでしか取得できず、この一覧では要求もしない)。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';

/// 一覧・選択に必要な最小情報だけ(programs等はここでは持たない。選択後にgetConfirmedEventSummary等で取得する)。
class ConfirmedEventListItem {
  const ConfirmedEventListItem({
    required this.eventId,
    required this.eventName,
    required this.startAt,
    required this.venue,
  });

  factory ConfirmedEventListItem.fromJson(Map<String, dynamic> json) =>
      ConfirmedEventListItem(
        eventId: json['eventId'] as String? ?? '',
        eventName: json['eventName'] as String? ?? '',
        startAt: DateTime.tryParse(json['startAt'] as String? ?? '')?.toLocal(),
        venue: json['venue'] as String? ?? '',
      );

  final String eventId;
  final String eventName;
  final DateTime? startAt;
  final String venue;
}

/// イベント一覧の取得で起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class EventListException implements Exception {
  const EventListException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class EventListService {
  /// confirmed方式のイベントだけを返す(legacyイベントはこの一覧に含めない。誤って従来方式の管理画面へ
  /// 入る余地を作らないため)。開催日時の新しい順。
  Future<List<ConfirmedEventListItem>> listConfirmedEvents();
}

class CallableEventListService implements EventListService {
  CallableEventListService({
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
  Future<List<ConfirmedEventListItem>> listConfirmedEvents() async {
    final token = await authClient.idToken();
    if (token == null) throw const EventListException('ログインが必要です。');
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/listLegacyEvents'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'data': const {}}),
      );
    } catch (_) {
      throw const EventListException('通信に失敗しました。もう一度お試しください。');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      final rawEvents = result is Map && result['events'] is List
          ? result['events'] as List
          : const [];
      final items = <ConfirmedEventListItem>[];
      for (final raw in rawEvents) {
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw);
        // flow=="confirmed"だけを選ぶ(legacyイベントはこの一覧に出さない=誤ってconfirmed管理画面へ入れない)。
        if (map['flow'] != 'confirmed') continue;
        items.add(ConfirmedEventListItem.fromJson(map));
      }
      items.sort((a, b) {
        final at = a.startAt;
        final bt = b.startAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at); // 開催日時が新しい順
      });
      return items;
    }
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    switch (error['status']) {
      case 'PERMISSION_DENIED':
        throw const EventListException('この操作を行う権限がありません。');
      case 'UNAUTHENTICATED':
        throw const EventListException('ログインが必要です。');
    }
    throw const EventListException('イベント一覧を取得できませんでした。もう一度お試しください。');
  }
}
