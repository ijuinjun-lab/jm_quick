import 'dart:convert';

import 'package:http/http.dart' as http;

/// 参加証を取得できなかった(通信エラー等)。参加者へ表示できる、内部情報を含まないメッセージ。
class PassException implements Exception {
  const PassException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PassProgram {
  const PassProgram({
    required this.programId,
    required this.name,
    required this.plannedCount,
    required this.checkedIn,
    this.timeText,
  });

  factory PassProgram.fromJson(Map<String, dynamic> json) => PassProgram(
    programId: json['programId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    timeText: json['timeText'] as String?,
    plannedCount: (json['plannedCount'] as num?)?.toInt() ?? 0,
    checkedIn: json['checkedIn'] == true,
  );

  final String programId;
  final String name;
  final String? timeText;
  final int plannedCount;
  final bool checkedIn;
}

/// サーバーが返す参加証。メールアドレス等の個人情報・内部IDは含まれない。
/// qrPayloadはサーバーが生成した受付用QRの文字列(メールのQRと同一)。クライアントは組み立てず、そのまま表示する。
class ConfirmedPass {
  const ConfirmedPass({
    required this.eventName,
    required this.participantName,
    required this.programs,
    required this.qrPayload,
    required this.webPassUrl,
    this.dateTimeText,
    this.venue,
    this.address,
    this.access,
  });

  factory ConfirmedPass.fromJson(Map<String, dynamic> json) {
    final programs = json['programs'];
    return ConfirmedPass(
      eventName: json['eventName'] as String? ?? '',
      dateTimeText: json['dateTimeText'] as String?,
      venue: json['venue'] as String?,
      address: json['address'] as String?,
      access: json['access'] as String?,
      participantName: json['participantName'] as String? ?? '',
      programs: programs is List
          ? programs
                .whereType<Map>()
                .map((p) => PassProgram.fromJson(Map<String, dynamic>.from(p)))
                .toList()
          : const [],
      qrPayload: json['qrPayload'] as String? ?? '',
      webPassUrl: json['webPassUrl'] as String? ?? '',
    );
  }

  final String eventName;
  final String? dateTimeText;
  final String? venue;
  final String? address;
  final String? access;
  final String participantName;
  final List<PassProgram> programs;
  final String qrPayload;
  final String webPassUrl;
}

/// Web参加証の取得(参加者本人・ログインなし・読み取り専用)。
abstract class PassService {
  /// 参加証を返す。確認できない場合(存在しない・publicId不一致・無効な参加者・従来方式など、理由を区別しない)はnull。
  /// 通信エラーなど一時的な失敗は [PassException]。
  Future<ConfirmedPass?> getPass({
    required String participantId,
    required String publicId,
  });
}

class CallablePassService implements PassService {
  CallablePassService({http.Client? httpClient, String? baseUrl})
    : _httpClient = httpClient ?? http.Client(),
      baseUrl = baseUrl ?? defaultBaseUrl;

  static const defaultBaseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  final http.Client _httpClient;
  final String baseUrl;

  @override
  Future<ConfirmedPass?> getPass({
    required String participantId,
    required String publicId,
  }) async {
    http.Response response;
    try {
      // ログイン不要。送るのは参加証のIDとトークンだけ(IDトークン・uid・roleは送らない)。
      response = await _httpClient.post(
        Uri.parse('$baseUrl/getConfirmedParticipantPass'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'data': {'participantId': participantId, 'publicId': publicId},
        }),
      );
    } catch (_) {
      throw const PassException('通信に失敗しました。通信状態を確認して、もう一度お試しください。');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map) {
        return ConfirmedPass.fromJson(Map<String, dynamic>.from(result));
      }
    }
    final status = decoded is Map && decoded['error'] is Map
        ? (decoded['error'] as Map)['status']
        : null;
    // NOT_FOUND = 参加証を確認できない(理由は区別しない)。それ以外は一時的な失敗として扱う。
    if (response.statusCode == 404 || status == 'NOT_FOUND') return null;
    throw const PassException('参加証を読み込めませんでした。時間をおいて、もう一度お試しください。');
  }
}
