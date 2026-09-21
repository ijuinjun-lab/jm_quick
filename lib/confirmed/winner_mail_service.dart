import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';

/// 当選メール設定・プレビューのサーバー呼び出しで起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class WinnerMailException implements Exception {
  const WinnerMailException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 保存済みの設定(サーバーが返す値)。個人情報は含まない。
class WinnerMailSettings {
  const WinnerMailSettings({
    required this.eventId,
    required this.eventName,
    required this.subject,
    required this.introBody,
    required this.closingBody,
    required this.notesBody,
    required this.address,
    required this.access,
    required this.version,
    required this.ready,
    required this.problems,
    required this.missingOptional,
  });

  factory WinnerMailSettings.fromJson(Map<String, dynamic> json) {
    final template = json['template'] is Map
        ? Map<String, dynamic>.from(json['template'] as Map)
        : const <String, dynamic>{};
    final venue = json['venueInfo'] is Map
        ? Map<String, dynamic>.from(json['venueInfo'] as Map)
        : const <String, dynamic>{};
    final event = json['event'] is Map
        ? Map<String, dynamic>.from(json['event'] as Map)
        : const <String, dynamic>{};
    List<String> strings(Object? value) =>
        value is List ? value.whereType<String>().toList() : const [];
    return WinnerMailSettings(
      eventId: json['eventId'] as String? ?? '',
      eventName: event['eventName'] as String? ?? '',
      subject: template['subject'] as String? ?? '',
      introBody: template['introBody'] as String? ?? '',
      closingBody: template['closingBody'] as String? ?? '',
      notesBody: template['notesBody'] as String? ?? '',
      address: venue['address'] as String? ?? '',
      access: venue['access'] as String? ?? '',
      version: (template['version'] as num?)?.toInt() ?? 0,
      ready: json['ready'] == true,
      problems: strings(json['problems']),
      missingOptional: strings(json['missingOptional']),
    );
  }

  final String eventId;
  final String eventName;
  final String subject;
  final String introBody;
  final String closingBody;
  final String notesBody;
  final String address;
  final String access;
  final int version;
  final bool ready;
  final List<String> problems;
  final List<String> missingOptional;
}

/// プレビュー結果。ready=falseのときはproblems(理由コード)だけ。
class WinnerMailPreview {
  const WinnerMailPreview({
    required this.ready,
    required this.problems,
    this.subject = '',
    this.text = '',
    this.webPassUrl = '',
    this.templateVersion = 0,
    this.qrPayload = '',
    this.qrPngBase64 = '',
  });

  factory WinnerMailPreview.fromJson(Map<String, dynamic> json) =>
      WinnerMailPreview(
        ready: json['ready'] == true,
        problems: json['problems'] is List
            ? (json['problems'] as List).whereType<String>().toList()
            : const [],
        subject: json['subject'] as String? ?? '',
        text: json['text'] as String? ?? '',
        webPassUrl: json['webPassUrl'] as String? ?? '',
        templateVersion: (json['templateVersion'] as num?)?.toInt() ?? 0,
        qrPayload: json['qrPayload'] as String? ?? '',
        qrPngBase64: json['qrPngBase64'] as String? ?? '',
      );

  final bool ready;
  final List<String> problems;
  final String subject;
  final String text;
  final String webPassUrl;
  final int templateVersion;

  /// 受付用QRの文字列と、メールに添付されるQR画像(PNG・base64)。サーバーが実送信と同じレンダラーで作ったもの。
  final String qrPayload;
  final String qrPngBase64;
}

/// 当選メールの設定・プレビュー。判定・生成はすべてサーバー(admin専用callable)で行う。
/// クライアントが送るのは、eventId・参加者ID・管理者が編集する文章だけ。
abstract class WinnerMailService {
  Future<WinnerMailSettings> getSettings(String eventId);

  /// 保存して、新しいテンプレートversionを返す。
  Future<int> updateTemplate({
    required String eventId,
    required String subject,
    required String introBody,
    required String closingBody,
    required String notesBody,
    required String address,
    required String access,
  });

  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  });
}

/// callableを呼ぶ実装。IDトークンをAuthorizationヘッダで送る(uid・roleは送らない)。
class CallableWinnerMailService implements WinnerMailService {
  CallableWinnerMailService({
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
  Future<WinnerMailSettings> getSettings(String eventId) async =>
      WinnerMailSettings.fromJson(
        await _call('getConfirmedWinnerMailSettings', {'eventId': eventId}),
      );

  @override
  Future<int> updateTemplate({
    required String eventId,
    required String subject,
    required String introBody,
    required String closingBody,
    required String notesBody,
    required String address,
    required String access,
  }) async {
    final result = await _call('updateConfirmedWinnerMailTemplate', {
      'eventId': eventId,
      'template': {
        'subject': subject,
        'introBody': introBody,
        'closingBody': closingBody,
        'notesBody': notesBody,
      },
      'venueInfo': {'address': address, 'access': access},
    });
    return (result['version'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  }) async => WinnerMailPreview.fromJson(
    await _call('previewConfirmedWinnerMail', {
      'eventId': eventId,
      'participantId': participantId,
    }),
  );

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final token = await authClient.idToken();
    if (token == null) throw const WinnerMailException('ログインが必要です。');
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
      throw const WinnerMailException('通信に失敗しました。通信状態を確認して、もう一度お試しください。');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    throw WinnerMailException(errorMessage(response.statusCode, decoded));
  }

  static const _fieldLabels = {
    'subject': '件名',
    'introBody': '冒頭本文',
    'closingBody': '締め本文',
    'notesBody': '注意事項',
    'address': '住所',
    'access': 'アクセス',
  };
  static const _errorLabels = {
    'required': '入力してください',
    'too-long': '長すぎます',
    'multiline-not-allowed': '1行で入力してください',
    'invalid-character': '使用できない文字が含まれています',
    'unknown-key': '利用できない項目です',
    'invalid-type': '形式が正しくありません',
  };

  /// サーバーのエラー応答から、表示用の日本語メッセージを作る。
  static String errorMessage(int statusCode, Object? decoded) {
    if (statusCode == 401) return 'ログインが必要です。';
    if (statusCode == 403) return 'この操作を行う権限がありません。';
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final errors = details['errors'];
    if (errors is List && errors.isNotEmpty) {
      return errors
          .whereType<Map>()
          .map((e) {
            final path = '${e['path']}'.split('.').last;
            return '${_fieldLabels[path] ?? path}: ${_errorLabels['${e['code']}'] ?? '${e['code']}'}';
          })
          .join('、');
    }
    // callableのHTTPエラー: 400は invalid-argument / failed-precondition の両方なので、statusの文字列で見分ける。
    final serverMessage = error['message'];
    return switch (error['status']) {
      'PERMISSION_DENIED' => 'この操作を行う権限がありません。',
      'UNAUTHENTICATED' => 'ログインが必要です。',
      // サーバーのメッセージは日本語で、個人情報を含まない(参加者ID・氏名・メールは入らない)。
      'NOT_FOUND' ||
      'FAILED_PRECONDITION' when serverMessage is String => serverMessage,
      'INVALID_ARGUMENT' => '入力内容を確認してください。',
      _ => '処理に失敗しました。もう一度お試しください。',
    };
  }
}
