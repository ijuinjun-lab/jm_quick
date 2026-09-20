import 'package:cloud_firestore/cloud_firestore.dart';

import 'event_status.dart';
import 'program_models.dart';

DateTime? dateFrom(dynamic value) => value is Timestamp
    ? value.toDate()
    : value is DateTime
    ? value
    : null;

/// イベント方式(flow)の値。未設定(null/空/'legacy')は従来方式、'confirmed'は新方式。
const String eventFlowLegacy = 'legacy';
const String eventFlowConfirmed = 'confirmed';

/// participant.statusの値。未設定(旧参加者)はactive相当。
const String participantStatusActive = 'active';
const String participantStatusCancelled = 'cancelled';

/// flowの値が従来方式を表すか。未設定(null)・空・'legacy'だけがtrue。
/// 'confirmed'や未知の値(タイプミス等)はfalse(従来方式専用の機能を安全側に倒して拒否する)。
bool isLegacyFlowValue(String? flow) =>
    flow == null || flow.isEmpty || flow == eventFlowLegacy;

/// 従来方式専用の操作(旧設定・旧正式登録・旧reconfirm・旧受付・旧参加者作成)を、
/// 新方式(flow=confirmed)などlegacyでないイベントに対して行おうとしたときの例外。
/// StateErrorではない(旧受付画面の「既に受付済み」表示と取り違えないため)。
class ConfirmedFlowException implements Exception {
  const ConfirmedFlowException(this.operation);
  final String operation;

  String get message =>
      'この操作（$operation）は従来方式のイベント専用です。'
      '新方式のイベントでは、専用の機能が提供されるまで使用できません。';

  @override
  String toString() => message;
}

enum AttendanceResponse {
  attending('attending', '参加予定'),
  notAttending('notAttending', '不参加予定');

  const AttendanceResponse(this.value, this.label);
  final String value;
  final String label;

  static AttendanceResponse? fromValue(dynamic value) {
    for (final response in values) {
      if (response.value == value) return response;
    }
    return null;
  }
}

class DemoEvent {
  const DemoEvent({
    required this.id,
    required this.name,
    required this.senderName,
    required this.venue,
    required this.contact,
    this.startAt,
    this.endAt,
    this.registrationDeadline,
    this.confirmationSendAt,
    required this.reconfirmEnabled,
    this.flow,
    this.programs = const [],
  });
  final String id;
  final String name;
  final String senderName;
  final String venue;
  final String contact;
  final DateTime? startAt;
  final DateTime? endAt;
  final DateTime? registrationDeadline;
  final DateTime? confirmationSendAt;
  final bool reconfirmEnabled;

  /// イベント方式。未設定(null)は従来方式。既存のFirestoreイベントにはflowが無く、
  /// migrationなしでそのまま従来方式として動く。既存イベントを自動でconfirmedに変換しない。
  final String? flow;

  /// 新方式のprogram定義(order順)。旧イベントは未設定=空。
  final List<EventProgram> programs;

  /// 従来方式(flow未設定/null/空/'legacy')。
  bool get isLegacyFlow => isLegacyFlowValue(flow);

  /// 新方式(flow == 'confirmed')。方式の判定は文字列比較を散在させず、このgetterを使う。
  bool get isConfirmedFlow => flow == eventFlowConfirmed;

  factory DemoEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      DemoEvent.fromData(doc.id, doc.data() ?? {});

  factory DemoEvent.fromData(String id, Map<String, dynamic> data) {
    final name = data['eventName'] as String? ?? 'イベント参加受付';
    return DemoEvent(
      id: id,
      name: name,
      senderName: (data['senderName'] as String?)?.trim().isNotEmpty == true
          ? (data['senderName'] as String).trim()
          : name,
      venue: data['venue'] as String? ?? '主催者からのご案内をご確認ください',
      contact: data['contact'] as String? ?? '',
      startAt: dateFrom(data['startAt']),
      endAt: dateFrom(data['endAt']),
      registrationDeadline: dateFrom(data['registrationDeadline']),
      confirmationSendAt: dateFrom(data['confirmationSendAt']),
      reconfirmEnabled: data['reconfirmEnabled'] as bool? ?? false,
      flow: data['flow'] as String?,
      programs: EventProgram.listFromData(data['programs']),
    );
  }

  EventStatus? statusAt(DateTime now) {
    if (startAt == null ||
        registrationDeadline == null ||
        confirmationSendAt == null) {
      return null;
    }
    return calculateEventStatus(
      now: now,
      startAt: startAt!,
      endAt: endAt,
      registrationDeadline: registrationDeadline!,
      confirmationSendAt: confirmationSendAt!,
    );
  }
}

class Participant {
  const Participant({
    required this.id,
    required this.eventId,
    required this.publicId,
    required this.name,
    required this.email,
    this.furiganaLastName,
    this.furiganaFirstName,
    required this.registeredCount,
    required this.registrationType,
    required this.invitationSent,
    this.invitationMailStatus,
    this.invitationSentAt,
    this.invitationMessageId,
    required this.participationConfirmed,
    this.participationConfirmedAt,
    required this.reconfirmed,
    this.attendanceResponse,
    required this.reconfirmationMailSent,
    this.reconfirmedAt,
    this.schemaVersion = 1,
    this.status = participantStatusActive,
    this.externalId,
    this.identityKey,
    this.importBatchId,
    this.importRow,
  });
  final String id;
  final String eventId;
  final String publicId;
  final String name;
  final String email;
  final String? furiganaLastName;
  final String? furiganaFirstName;
  final int registeredCount;
  final String registrationType;
  final bool invitationSent;
  final String? invitationMailStatus;
  final DateTime? invitationSentAt;
  final String? invitationMessageId;
  final bool participationConfirmed;
  final DateTime? participationConfirmedAt;
  final bool reconfirmed;
  final AttendanceResponse? attendanceResponse;
  final bool reconfirmationMailSent;
  final DateTime? reconfirmedAt;

  // --- 新方式(flow=confirmed)用の任意フィールド。旧参加者には存在せず、既定値で読める ---
  /// 未設定(旧参加者)は1。
  final int schemaVersion;

  /// 未設定(旧参加者)はactive。
  final String status;
  final String? externalId;
  final String? identityKey;
  final String? importBatchId;
  final int? importRow;

  bool get isWalkIn => registrationType == 'walkIn';
  bool get isActive => status == participantStatusActive;
  bool get isCancelled => status == participantStatusCancelled;

  factory Participant.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Participant.fromData(doc.id, doc.data() ?? {});

  factory Participant.fromData(String id, Map<String, dynamic> data) {
    return Participant(
      id: id,
      eventId: data['eventId'] as String? ?? '',
      publicId: data['publicId'] as String? ?? '',
      name: data['name'] as String? ?? '',
      email: data['email'] as String? ?? '',
      furiganaLastName: data['furiganaLastName'] as String?,
      furiganaFirstName: data['furiganaFirstName'] as String?,
      registeredCount: (data['registeredCount'] as num?)?.toInt() ?? 0,
      registrationType: data['registrationType'] as String? ?? 'preRegistered',
      invitationSent: data['invitationSent'] as bool? ?? false,
      invitationMailStatus: data['invitationMailStatus'] as String?,
      invitationSentAt: dateFrom(data['invitationSentAt']),
      invitationMessageId: data['invitationMessageId'] as String?,
      participationConfirmed: data['participationConfirmed'] as bool? ?? false,
      participationConfirmedAt: dateFrom(data['participationConfirmedAt']),
      reconfirmed: data['reconfirmed'] as bool? ?? false,
      attendanceResponse: AttendanceResponse.fromValue(
        data['attendanceResponse'],
      ),
      reconfirmationMailSent: data['reconfirmationMailSent'] as bool? ?? false,
      reconfirmedAt: dateFrom(data['reconfirmedAt']),
      schemaVersion: (data['schemaVersion'] as num?)?.toInt() ?? 1,
      status: (data['status'] as String?)?.isNotEmpty == true
          ? data['status'] as String
          : participantStatusActive,
      externalId: data['externalId'] as String?,
      identityKey: data['identityKey'] as String?,
      importBatchId: data['importBatchId'] as String?,
      importRow: (data['importRow'] as num?)?.toInt(),
    );
  }
}

class BulkMailJob {
  const BulkMailJob({
    required this.id,
    required this.eventId,
    required this.type,
    required this.status,
    required this.totalCount,
    required this.sentCount,
    required this.failedCount,
    required this.skippedCount,
  });

  final String id;
  final String eventId;
  final String type;
  final String status;
  final int totalCount;
  final int sentCount;
  final int failedCount;
  final int skippedCount;

  bool get isRunning =>
      const {'preparing', 'queued', 'running'}.contains(status);

  factory BulkMailJob.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    int number(String key) => (data[key] as num?)?.toInt() ?? 0;
    return BulkMailJob(
      id: doc.id,
      eventId: data['eventId'] as String? ?? '',
      type: data['type'] as String? ?? '',
      status: data['status'] as String? ?? '',
      totalCount: number('totalCount'),
      sentCount: number('sentCount'),
      failedCount: number('failedCount'),
      skippedCount: number('skippedCount'),
    );
  }
}

class CheckIn {
  const CheckIn({
    required this.participantId,
    required this.eventId,
    required this.checkedIn,
    this.attendedCount,
    this.checkedInAt,
    this.updatedAt,
  });
  final String participantId;
  final String eventId;
  final bool checkedIn;
  final int? attendedCount;
  final DateTime? checkedInAt;
  final DateTime? updatedAt;

  factory CheckIn.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return CheckIn(
      participantId: data['participantId'] as String? ?? doc.id,
      eventId: data['eventId'] as String? ?? '',
      checkedIn: data['checkedIn'] as bool? ?? false,
      attendedCount: (data['attendedCount'] as num?)?.toInt(),
      checkedInAt: dateFrom(data['checkedInAt']),
      updatedAt: dateFrom(data['updatedAt']),
    );
  }
}
