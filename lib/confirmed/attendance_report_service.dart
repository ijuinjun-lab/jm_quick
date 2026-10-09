import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';
import 'winner_send_service.dart';

/// 最終実績(getConfirmedAttendanceReport)の応答。サーバーがFirestoreの正本(participants・programAttendances・
/// importBatches)から作る。クライアントはFirestoreを直接読まない。
class AttendanceReport {
  const AttendanceReport({
    required this.eventId,
    required this.eventName,
    required this.programs,
    required this.participants,
  });

  factory AttendanceReport.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> maps(Object? value) => value is List
        ? [
            for (final v in value)
              if (v is Map) Map<String, dynamic>.from(v),
          ]
        : const [];
    return AttendanceReport(
      eventId: json['eventId'] as String? ?? '',
      eventName: json['eventName'] as String? ?? '',
      programs: [
        for (final p in maps(json['programs']))
          if (p['programId'] is String)
            AttendanceReportProgram(
              programId: p['programId'] as String,
              name: p['name'] as String? ?? p['programId'] as String,
              inEvent: p['inEvent'] != false,
            ),
      ],
      participants: [
        for (final p in maps(json['participants']))
          AttendanceReportParticipant.fromJson(p),
      ],
    );
  }

  final String eventId;
  final String eventName;

  /// 列にするprogram(イベントの表示順。イベント設定に無いprogramの受付記録があれば末尾に[inEvent]=falseで並ぶ)。
  final List<AttendanceReportProgram> programs;

  /// 参加者全員(取込回→行番号の順)。同じメールアドレスでも別participantは別の行。
  final List<AttendanceReportParticipant> participants;
}

class AttendanceReportProgram {
  const AttendanceReportProgram({
    required this.programId,
    required this.name,
    this.inEvent = true,
  });
  final String programId;
  final String name;
  final bool inEvent;
}

class AttendanceReportParticipant {
  const AttendanceReportParticipant({
    required this.participantId,
    required this.name,
    required this.kana,
    required this.email,
    required this.status,
    required this.programs,
    this.importSequence,
    this.batchCommitted,
    this.hebelCategory,
    this.hebelLabel,
    this.hebelRawValue,
  });

  factory AttendanceReportParticipant.fromJson(Map<String, dynamic> json) {
    final hebel = json['hebelResidence'] is Map
        ? Map<String, dynamic>.from(json['hebelResidence'] as Map)
        : null;
    final programs = json['programs'];
    return AttendanceReportParticipant(
      participantId: json['participantId'] as String? ?? '',
      importSequence: (json['importSequence'] as num?)?.toInt(),
      batchCommitted: json['batchCommitted'] as bool?,
      name: json['name'] as String? ?? '',
      kana: json['kana'] as String? ?? '',
      email: json['email'] as String? ?? '',
      status: json['status'] as String? ?? '',
      hebelCategory: hebel?['category'] as String?,
      hebelLabel: hebel?['label'] as String?,
      hebelRawValue: hebel?['rawValue'] as String?,
      programs: programs is List
          ? [
              for (final p in programs)
                if (p is Map && p['programId'] is String)
                  AttendanceReportEntry.fromJson(Map<String, dynamic>.from(p)),
            ]
          : const [],
    );
  }

  final String participantId;

  /// 取込回(第n回のn)。取込回の無い参加者はnull。
  final int? importSequence;

  /// 取込回が確定(committed)しているか。取込回の無い参加者はnull。
  final bool? batchCommitted;
  final String name;
  final String kana;
  final String email;

  /// participant.status(現在は "active" のみ)。
  final String status;

  /// HEBEL属性(受付画面と同じ表示名)。属性フィールドの無い参加者はnull。
  final String? hebelCategory;
  final String? hebelLabel;

  /// 未知のHEBEL属性のときだけの原文。
  final String? hebelRawValue;

  /// 申込んだprogram(programAttendances)。
  final List<AttendanceReportEntry> programs;
}

class AttendanceReportEntry {
  const AttendanceReportEntry({
    required this.programId,
    required this.checkedIn,
    this.plannedCount,
    this.timeText,
    this.attendedCount,
    this.checkedInAt,
  });

  factory AttendanceReportEntry.fromJson(Map<String, dynamic> json) =>
      AttendanceReportEntry(
        programId: json['programId'] as String,
        plannedCount: (json['plannedCount'] as num?)?.toInt(),
        timeText: json['timeText'] as String?,
        checkedIn: json['checkedIn'] == true,
        attendedCount: (json['attendedCount'] as num?)?.toInt(),
        checkedInAt: json['checkedInAt'] is String
            ? DateTime.tryParse(json['checkedInAt'] as String)?.toUtc()
            : null,
      );

  final String programId;
  final int? plannedCount;
  final String? timeText;

  /// 受付済み(取消済みはfalse)。
  final bool checkedIn;

  /// 実来場人数(受付済みのときだけ。訂正後の最新の値)。
  final int? attendedCount;

  /// 受付時刻(UTC。受付済みのときだけ)。
  final DateTime? checkedInAt;
}

abstract class AttendanceReportService {
  Future<AttendanceReport> getReport(String eventId);
}

class CallableAttendanceReportService implements AttendanceReportService {
  CallableAttendanceReportService({
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
  Future<AttendanceReport> getReport(String eventId) async =>
      AttendanceReport.fromJson(
        await _call('getConfirmedAttendanceReport', {'eventId': eventId}),
      );

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

  /// サーバーのエラー応答を、表示用の例外にする(共通のものは当選メールの送信管理と同じ)。
  static WinnerSendException errorFrom(int statusCode, Object? decoded) {
    final base = CallableWinnerSendService.errorFrom(statusCode, decoded);
    if (base.code == 'report-too-large') {
      return WinnerSendException(
        '参加者が多すぎるため、最終実績を出力できません。管理者へ連絡してください。',
        code: base.code,
      );
    }
    return base;
  }
}
