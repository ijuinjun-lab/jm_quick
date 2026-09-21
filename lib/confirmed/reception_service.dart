import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';

/// 受付の表示・実行で起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class ReceptionException implements Exception {
  const ReceptionException(this.message, {this.code, this.notAllowed = false});
  final String message;

  /// サーバーが返した理由コード(受付スタッフ向けの識別用)。
  final String? code;

  /// この参加証は受付できない(参加者・program・状態の不一致)。再試行しても解決しない。
  final bool notAllowed;
  @override
  String toString() => message;
}

class ReceptionProgram {
  const ReceptionProgram({
    required this.programId,
    required this.name,
    required this.plannedCount,
    required this.checkedIn,
    this.timeText,
    this.checkedInAt,
    this.attendedCount,
  });

  factory ReceptionProgram.fromJson(Map<String, dynamic> json) =>
      ReceptionProgram(
        programId: json['programId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        timeText: json['timeText'] as String?,
        plannedCount: (json['plannedCount'] as num?)?.toInt() ?? 0,
        checkedIn: json['checkedIn'] == true,
        checkedInAt: json['checkedInAt'] is String
            ? DateTime.tryParse(json['checkedInAt'] as String)
            : null,
        attendedCount: (json['attendedCount'] as num?)?.toInt(),
      );

  final String programId;
  final String name;
  final String? timeText;

  /// 事前の予定人数(サーバーの値。クライアントは変更しない)。
  final int plannedCount;
  final bool checkedIn;
  final DateTime? checkedInAt;

  /// 実来場人数(受付済みのとき)。予定人数とは別。
  final int? attendedCount;
}

class ReceptionView {
  const ReceptionView({
    required this.eventName,
    required this.participantName,
    required this.programs,
  });

  factory ReceptionView.fromJson(Map<String, dynamic> json) {
    final programs = json['programs'];
    return ReceptionView(
      eventName: json['eventName'] as String? ?? '',
      participantName: json['participantName'] as String? ?? '',
      programs: programs is List
          ? programs
                .whereType<Map>()
                .map(
                  (p) =>
                      ReceptionProgram.fromJson(Map<String, dynamic>.from(p)),
                )
                .toList()
          : const [],
    );
  }

  final String eventName;
  final String participantName;
  final List<ReceptionProgram> programs;
}

class CheckInResult {
  const CheckInResult({required this.alreadyCheckedIn, required this.program});
  final bool alreadyCheckedIn;
  final ReceptionProgram program;
}

/// 受付(staff/adminのみ)。サーバーがログイン・権限・参加者・publicId・programを毎回検証する。
abstract class ReceptionService {
  Future<ReceptionView> getView({
    required String eventId,
    required String participantId,
    required String publicId,
  });

  Future<CheckInResult> checkIn({
    required String eventId,
    required String participantId,
    required String publicId,
    required String programId,
    required int attendedCount,
  });
}

class CallableReceptionService implements ReceptionService {
  CallableReceptionService({
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
  Future<ReceptionView> getView({
    required String eventId,
    required String participantId,
    required String publicId,
  }) async => ReceptionView.fromJson(
    await _call('getConfirmedReceptionView', {
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
    // 送るのは、QRから得たID・受付するprogram・実来場人数だけ(予定人数・uid・role・時刻は送らない)。
    final result = await _call('checkInConfirmedProgram', {
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
    final token = await authClient.idToken();
    if (token == null) throw const ReceptionException('ログインが必要です。');
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

  /// サーバーのエラー応答を、表示用の例外にする。
  static ReceptionException errorFrom(int statusCode, Object? decoded) {
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    switch (error['status']) {
      case 'PERMISSION_DENIED':
        return const ReceptionException('この操作を行う権限がありません。');
      case 'UNAUTHENTICATED':
        return const ReceptionException('ログインが必要です。');
      case 'FAILED_PRECONDITION':
        return ReceptionException(
          'この参加証は受付できません。',
          code: code,
          notAllowed: true,
        );
      case 'INVALID_ARGUMENT':
        return ReceptionException(
          '入力内容を確認してください。',
          code: code,
          notAllowed: code != 'invalid-attended-count',
        );
    }
    return const ReceptionException('処理に失敗しました。もう一度お試しください。');
  }
}
