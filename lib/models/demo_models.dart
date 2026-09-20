import 'package:cloud_firestore/cloud_firestore.dart';

import 'event_status.dart';

DateTime? dateFrom(dynamic value) => value is Timestamp
    ? value.toDate()
    : value is DateTime
    ? value
    : null;

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

  factory DemoEvent.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final name = data['eventName'] as String? ?? 'イベント参加受付';
    return DemoEvent(
      id: doc.id,
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

  bool get isWalkIn => registrationType == 'walkIn';

  factory Participant.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return Participant(
      id: doc.id,
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
