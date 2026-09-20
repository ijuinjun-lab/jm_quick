import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/demo_models.dart';

class MailSendException implements Exception {
  const MailSendException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DemoRepository {
  DemoRepository({
    this.selectedEventId,
    FirebaseFirestore? firestore,
    http.Client? httpClient,
  }) : db = firestore ?? FirebaseFirestore.instance,
       _httpClient = httpClient ?? http.Client();

  final String? selectedEventId;
  final FirebaseFirestore db;
  final http.Client _httpClient;

  static final Uri _sendParticipantMailUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/sendParticipantMail',
  );
  static final Uri _startBulkInvitationMailUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/startBulkInvitationMail',
  );
  static final Uri _startBulkReconfirmationMailUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/startBulkReconfirmationMail',
  );
  static final Uri _deleteParticipantUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/deleteParticipant',
  );
  static final Uri _deleteEventUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/deleteEvent',
  );
  static final Uri _registerWalkInUri = Uri.parse(
    'https://asia-northeast1-jm-quick.cloudfunctions.net/registerWalkIn',
  );

  String get eventId {
    final value = selectedEventId?.trim() ?? '';
    if (value.isEmpty) throw StateError('eventId-required');
    return value;
  }

  DocumentReference<Map<String, dynamic>> get eventRef =>
      db.collection('events').doc(eventId);
  DocumentReference<Map<String, dynamic>> participantRef(String id) =>
      db.collection('participants').doc(id);
  DocumentReference<Map<String, dynamic>> checkInRef(String id) =>
      db.collection('checkIns').doc(id);

  Stream<List<DemoEvent>> watchEvents() => db
      .collection('events')
      .snapshots()
      .map(
        (snapshot) => snapshot.docs.map(DemoEvent.fromDoc).toList()
          ..sort(
            (a, b) => (a.startAt ?? DateTime(9999)).compareTo(
              b.startAt ?? DateTime(9999),
            ),
          ),
      );

  Stream<DemoEvent?> watchEvent() => watchEventById(eventId);
  Stream<DemoEvent?> watchEventById(String id) => db
      .collection('events')
      .doc(id)
      .snapshots()
      .map((doc) => doc.exists ? DemoEvent.fromDoc(doc) : null);

  Stream<List<Participant>> watchParticipants() => db
      .collection('participants')
      .where('eventId', isEqualTo: eventId)
      .snapshots()
      .map(
        (snapshot) =>
            snapshot.docs.map(Participant.fromDoc).toList()
              ..sort((a, b) => a.name.compareTo(b.name)),
      );

  Stream<List<CheckIn>> watchCheckIns() => db
      .collection('checkIns')
      .where('eventId', isEqualTo: eventId)
      .snapshots()
      .map((snapshot) => snapshot.docs.map(CheckIn.fromDoc).toList());

  Stream<BulkMailJob?> watchBulkMailJob(String type) => db
      .collection('mailJobs')
      .doc('${eventId}_$type')
      .snapshots()
      .map((doc) => doc.exists ? BulkMailJob.fromDoc(doc) : null);

  Stream<Participant?> watchParticipant(String id) => participantRef(
    id,
  ).snapshots().map((doc) => doc.exists ? Participant.fromDoc(doc) : null);
  Stream<CheckIn?> watchCheckIn(String id) => checkInRef(
    id,
  ).snapshots().map((doc) => doc.exists ? CheckIn.fromDoc(doc) : null);

  Future<String> createEvent({
    required String eventName,
    required String senderName,
    required DateTime startAt,
    DateTime? endAt,
    required String venue,
    required DateTime registrationDeadline,
    required TimeOfDay confirmationSendTime,
    required String contact,
  }) async {
    final ref = db.collection('events').doc();
    await ref.set(
      _eventData(
        id: ref.id,
        eventName: eventName,
        senderName: senderName,
        startAt: startAt,
        endAt: endAt,
        venue: venue,
        registrationDeadline: registrationDeadline,
        confirmationSendTime: confirmationSendTime,
        contact: contact,
      ),
    );
    return ref.id;
  }

  Map<String, dynamic> _eventData({
    required String id,
    required String eventName,
    required String senderName,
    required DateTime startAt,
    DateTime? endAt,
    required String venue,
    required DateTime registrationDeadline,
    required TimeOfDay confirmationSendTime,
    required String contact,
  }) {
    final previousDay = DateTime(
      startAt.year,
      startAt.month,
      startAt.day,
    ).subtract(const Duration(days: 1));
    final confirmationSendAt = DateTime(
      previousDay.year,
      previousDay.month,
      previousDay.day,
      confirmationSendTime.hour,
      confirmationSendTime.minute,
    );
    return {
      'eventId': id,
      'eventName': eventName.trim(),
      'senderName': senderName.trim(),
      'startAt': Timestamp.fromDate(startAt),
      'endAt': endAt == null ? null : Timestamp.fromDate(endAt),
      'venue': venue.trim(),
      'registrationDeadline': Timestamp.fromDate(registrationDeadline),
      'confirmationSendAt': Timestamp.fromDate(confirmationSendAt),
      'contact': contact.trim(),
      'reconfirmEnabled': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Future<void> updateEventSettings({
    required String eventName,
    required String senderName,
    required DateTime startAt,
    DateTime? endAt,
    required String venue,
    required DateTime registrationDeadline,
    required TimeOfDay confirmationSendTime,
    String contact = '',
  }) => eventRef.update(
    _eventData(
      id: eventId,
      eventName: eventName,
      senderName: senderName,
      startAt: startAt,
      endAt: endAt,
      venue: venue,
      registrationDeadline: registrationDeadline,
      confirmationSendTime: confirmationSendTime,
      contact: contact,
    )..remove('createdAt'),
  );

  Map<String, dynamic> participantData({
    required String participantId,
    required String publicId,
    required String name,
    required String email,
    required int registeredCount,
    required String registrationType,
    String? furiganaLastName,
    String? furiganaFirstName,
  }) => {
    'participantId': participantId,
    'eventId': eventId,
    'publicId': publicId,
    'name': name.trim(),
    'email': email.trim().toLowerCase(),
    'registeredCount': registeredCount,
    'registrationType': registrationType,
    if (furiganaLastName?.trim().isNotEmpty == true)
      'furiganaLastName': furiganaLastName!.trim(),
    if (furiganaFirstName?.trim().isNotEmpty == true)
      'furiganaFirstName': furiganaFirstName!.trim(),
    'invitationSent': false,
    'invitationSentAt': null,
    'participationConfirmed': registrationType == 'walkIn',
    'participationConfirmedAt': registrationType == 'walkIn'
        ? FieldValue.serverTimestamp()
        : null,
    'reconfirmed': false,
    'reconfirmedAt': null,
    'attendanceResponse': null,
    'reconfirmationMailSent': false,
    'createdAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  Map<String, dynamic> emptyCheckIn(String id) => {
    'participantId': id,
    'eventId': eventId,
    'checkedIn': false,
    'attendedCount': null,
    'checkedInAt': null,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  static String randomPublicId() {
    final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
    return 'pub_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Future<Participant> createParticipant({
    required String name,
    required String email,
    required int registeredCount,
    required String registrationType,
    String? furiganaLastName,
    String? furiganaFirstName,
  }) async {
    if (name.trim().isEmpty || !email.contains('@') || registeredCount < 1) {
      throw ArgumentError('入力内容を確認してください。');
    }
    final ref = db.collection('participants').doc();
    final batch = db.batch();
    batch.set(
      ref,
      participantData(
        participantId: ref.id,
        publicId: randomPublicId(),
        name: name,
        email: email,
        registeredCount: registeredCount,
        registrationType: registrationType,
        furiganaLastName: furiganaLastName,
        furiganaFirstName: furiganaFirstName,
      ),
    );
    batch.set(checkInRef(ref.id), emptyCheckIn(ref.id));
    await batch.commit();
    return Participant.fromDoc(await ref.get());
  }

  Future<({Participant participant, String? mailError})> registerWalkIn({
    required String name,
    required String email,
    required int registeredCount,
  }) async {
    final result = await _callFunction(_registerWalkInUri, {
      'eventId': eventId,
      'name': name.trim(),
      'email': email.trim().toLowerCase(),
      'registeredCount': registeredCount,
    });
    final participantId = result['participantId'];
    final publicId = result['publicId'];
    if (participantId is! String || publicId is! String) {
      throw const MailSendException('登録結果が不正です。受付スタッフへお声がけください。');
    }
    final participant = await resolveParticipant(participantId, publicId);
    if (participant == null) {
      throw const MailSendException('登録情報を確認できません。受付スタッフへお声がけください。');
    }
    return (
      participant: participant,
      mailError: result['mailSent'] == true
          ? null
          : (result['mailError']?.toString() ?? '確認メールを送信できませんでした。'),
    );
  }

  Future<Participant?> resolveParticipant(String? id, String? token) async {
    if (id == null || token == null) return null;
    final doc = await participantRef(id).get();
    if (!doc.exists || doc.data()?['publicId'] != token) return null;
    final participant = Participant.fromDoc(doc);
    if (selectedEventId != null && participant.eventId != eventId) return null;
    return participant;
  }

  Future<void> confirmParticipation(Participant participant) =>
      _updateParticipant(participant, {
        'participationConfirmed': true,
        'participationConfirmedAt': FieldValue.serverTimestamp(),
      });

  Future<void> reconfirm(
    Participant participant,
    AttendanceResponse response,
  ) => _updateParticipant(participant, {
    'reconfirmed': true,
    'reconfirmedAt': FieldValue.serverTimestamp(),
    'attendanceResponse': response.value,
  });

  Future<void> _updateParticipant(
    Participant participant,
    Map<String, dynamic> update,
  ) {
    if (selectedEventId != null && participant.eventId != eventId) {
      throw StateError('event-mismatch');
    }
    return participantRef(
      participant.id,
    ).update({...update, 'updatedAt': FieldValue.serverTimestamp()});
  }

  Future<void> sendMail(Participant participant, String type) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    final response = await _httpClient.post(
      _sendParticipantMailUri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'data': {
          'participantId': participant.id,
          'publicId': participant.publicId,
          'eventId': eventId,
          'type': type,
        },
      }),
    );
    final decoded = _decodeJsonObject(response.body);
    final payload = decoded['result'] ?? decoded['data'];
    final result = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        result['success'] == true &&
        result['messageId'] is String) {
      return;
    }
    final error = decoded['error'];
    final message = error is Map
        ? error['message']?.toString()
        : 'HTTP ${response.statusCode}';
    throw MailSendException(message ?? 'メール送信に失敗しました。');
  }

  Future<void> startBulkInvitationMail({bool failedOnly = false}) async {
    await _callFunction(_startBulkInvitationMailUri, {
      'eventId': eventId,
      'mode': failedOnly ? 'failed' : 'unsent',
    });
  }

  Future<void> startBulkReconfirmationMail() async {
    await _callFunction(_startBulkReconfirmationMailUri, {
      'eventId': eventId,
      'mode': 'unanswered',
    });
  }

  Future<void> deleteParticipant(Participant participant) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    await _callFunction(_deleteParticipantUri, {
      'eventId': eventId,
      'participantId': participant.id,
    });
  }

  Future<void> deleteEvent(DemoEvent event) async {
    await _callFunction(_deleteEventUri, {'eventId': event.id});
  }

  Future<Map<String, dynamic>> _callFunction(
    Uri uri,
    Map<String, dynamic> data,
  ) async {
    final response = await _httpClient.post(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'data': data}),
    );
    final decoded = _decodeJsonObject(response.body);
    final payload = decoded['result'] ?? decoded['data'];
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    final error = decoded['error'];
    final message = error is Map
        ? error['message']?.toString()
        : 'HTTP ${response.statusCode}';
    throw MailSendException(message ?? '処理を開始できませんでした。');
  }

  static Map<String, dynamic> _decodeJsonObject(String source) {
    try {
      final decoded = jsonDecode(source);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<void> checkIn({
    required Participant participant,
    required int attendedCount,
  }) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    if (attendedCount < 0) throw ArgumentError('実参加人数は0以上で入力してください。');
    final ref = checkInRef(participant.id);
    await db.runTransaction((transaction) async {
      final current = await transaction.get(ref);
      final data = current.data();
      if (data?['eventId'] != eventId) throw StateError('event-mismatch');
      if (data?['checkedIn'] == true) throw StateError('already-checked-in');
      transaction.update(ref, {
        'checkedIn': true,
        'registeredCountSnapshot': participant.registeredCount,
        'attendedCount': attendedCount,
        'checkedInAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> updateAttendedCount(
    Participant participant,
    int attendedCount,
  ) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    final snapshot = await checkInRef(participant.id).get();
    if (snapshot.data()?['eventId'] != eventId) {
      throw StateError('event-mismatch');
    }
    await snapshot.reference.update({
      'attendedCount': attendedCount,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
