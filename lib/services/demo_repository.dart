import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../models/demo_models.dart';
import 'legacy_api.dart';
import 'polling_source.dart';

class MailSendException implements Exception {
  const MailSendException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// イベントのflow値を読む関数(未設定はnull)。テストで差し替えられる。
typedef EventFlowLoader = Future<String?> Function(String eventId);

/// 受付画面に表示する内容(サーバーの受付表示APIの結果。メールアドレス・publicIdは含まない)。
class ReceptionView {
  const ReceptionView({
    required this.eventName,
    required this.participantName,
    required this.registeredCount,
    required this.reconfirmed,
    required this.checkedIn,
    this.attendedCount,
    this.checkedInAt,
  });
  final String eventName;
  final String participantName;
  final int registeredCount;
  final bool reconfirmed;
  final bool checkedIn;
  final int? attendedCount;
  final DateTime? checkedInAt;

  factory ReceptionView.fromData(Map<String, dynamic> data) => ReceptionView(
    eventName: data['eventName'] as String? ?? '',
    participantName: data['participantName'] as String? ?? '',
    registeredCount: (data['registeredCount'] as num?)?.toInt() ?? 0,
    reconfirmed: data['reconfirmed'] as bool? ?? false,
    checkedIn: data['checkedIn'] as bool? ?? false,
    attendedCount: (data['attendedCount'] as num?)?.toInt(),
    checkedInAt: dateFrom(data['checkedInAt']),
  );
}

/// 参加者本人のマイページに表示する内容(サーバーのcapability APIの結果。メールアドレス等は含まない)。
class ParticipantPageData {
  const ParticipantPageData({
    required this.eventId,
    required this.eventName,
    required this.startAt,
    required this.venue,
    required this.reconfirmEnabled,
    required this.name,
    required this.registeredCount,
    required this.participationConfirmed,
    required this.attendanceResponse,
    required this.checkedIn,
    required this.attendedCount,
  });
  final String eventId;
  final String eventName;
  final DateTime? startAt;
  final String venue;
  final bool reconfirmEnabled;
  final String name;
  final int registeredCount;
  final bool participationConfirmed;
  final AttendanceResponse? attendanceResponse;
  final bool checkedIn;
  final int? attendedCount;

  factory ParticipantPageData.fromData(Map<String, dynamic> data) {
    Map<String, dynamic> section(String key) => data[key] is Map
        ? Map<String, dynamic>.from(data[key] as Map)
        : const <String, dynamic>{};
    final event = section('event');
    final participant = section('participant');
    final checkIn = section('checkIn');
    return ParticipantPageData(
      eventId: event['eventId'] as String? ?? '',
      eventName: event['eventName'] as String? ?? 'イベント参加受付',
      startAt: dateFrom(event['startAt']),
      venue: event['venue'] as String? ?? '主催者からのご案内をご確認ください',
      reconfirmEnabled: event['reconfirmEnabled'] as bool? ?? false,
      name: participant['name'] as String? ?? '',
      registeredCount: (participant['registeredCount'] as num?)?.toInt() ?? 0,
      participationConfirmed:
          participant['participationConfirmed'] as bool? ?? false,
      attendanceResponse: AttendanceResponse.fromValue(
        participant['attendanceResponse'],
      ),
      checkedIn: checkIn['checkedIn'] as bool? ?? false,
      attendedCount: (checkIn['attendedCount'] as num?)?.toInt(),
    );
  }
}

/// 管理画面のイベント詳細(サーバーの管理者向けAPIの結果)。
class EventAdminView {
  const EventAdminView({
    required this.event,
    required this.legacy,
    required this.participants,
    required this.checkIns,
    required this.invitationJob,
    required this.reconfirmationJob,
  });
  final DemoEvent event;
  final bool legacy;
  final List<Participant> participants;
  final List<CheckIn> checkIns;
  final BulkMailJob? invitationJob;
  final BulkMailJob? reconfirmationJob;

  factory EventAdminView.fromData(Map<String, dynamic> data) {
    List<Map<String, dynamic>> list(String key) => data[key] is List
        ? (data[key] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
        : const [];
    final eventData = data['event'] is Map
        ? Map<String, dynamic>.from(data['event'] as Map)
        : const <String, dynamic>{};
    final jobs = data['jobs'] is Map
        ? Map<String, dynamic>.from(data['jobs'] as Map)
        : const <String, dynamic>{};
    BulkMailJob? job(String key) => jobs[key] is Map
        ? BulkMailJob.fromData(
            (jobs[key] as Map)['jobId'] as String? ?? '',
            Map<String, dynamic>.from(jobs[key] as Map),
          )
        : null;
    return EventAdminView(
      event: DemoEvent.fromData(
        eventData['eventId'] as String? ?? '',
        eventData,
      ),
      legacy: data['legacy'] == true,
      participants: list('participants')
          .map(
            (p) => Participant.fromData(p['participantId'] as String? ?? '', p),
          )
          .toList(),
      checkIns: list('checkIns')
          .map((c) => CheckIn.fromData(c['participantId'] as String? ?? '', c))
          .toList(),
      invitationJob: job('invitation'),
      reconfirmationJob: job('reconfirmation'),
    );
  }
}

/// 従来方式(legacy)のイベント・参加者・受付を扱う窓口。
///
/// Phase 10C: Firestoreを直接読み書きしない。すべて認証つき(管理者/受付スタッフ)または参加者capability(participantId+publicId)の
/// サーバーAPI([LegacyApiClient])経由。旧画面が使っていた`watch*`(Firestoreの購読)は、同じ形のStreamを返すポーリング
/// ([PollingSource])に置き換えた(購読されている間だけ取得し、操作の直後に取り直す)。
class DemoRepository {
  DemoRepository({
    this.selectedEventId,
    LegacyApiClient? api,
    EventFlowLoader? eventFlowLoader,
    this.pollInterval = const Duration(seconds: 8),
  }) : _api = api,
       _eventFlowLoader = eventFlowLoader;

  final String? selectedEventId;
  final Duration pollInterval;
  LegacyApiClient? _api;
  final EventFlowLoader? _eventFlowLoader;
  final Map<String, String?> _flowCache = {};

  LegacyApiClient get api => _api ??= LegacyApiClient();

  /// 従来方式のイベントか。新方式・未知のflowならfalse。画面が「従来機能は使えない」と案内するために使う。
  Future<bool> isLegacyEvent(String eventId) async =>
      isLegacyFlowValue(await _flowOf(eventId));

  /// 従来方式専用の書込み経路の入口guard。legacyでない(新方式・未知のflow)イベントなら
  /// 通信の前に ConfirmedFlowException を投げる。サーバー側でも同じ条件を必ず再検証している(こちらは操作性のための事前確認)。
  Future<void> assertLegacyEvent(String eventId, String operation) async {
    if (!isLegacyFlowValue(await _flowOf(eventId))) {
      throw ConfirmedFlowException(operation);
    }
  }

  Future<String?> _flowOf(String eventId) async {
    if (_flowCache.containsKey(eventId)) return _flowCache[eventId];
    final loader = _eventFlowLoader ?? _loadEventFlow;
    final flow = await loader(eventId);
    _flowCache[eventId] = flow;
    return flow;
  }

  // 既定の判定は、管理画面が取得済み(または取得する)イベント詳細のflow。取得できなければ例外(fail-closed)。
  Future<String?> _loadEventFlow(String eventId) async {
    if (eventId != selectedEventId) {
      throw StateError('event-mismatch');
    }
    return (await _adminView.current()).event.flow;
  }

  String get eventId {
    final value = selectedEventId?.trim() ?? '';
    if (value.isEmpty) throw StateError('eventId-required');
    return value;
  }

  // ---- 管理者向けの読み取り(ポーリング) ----------------------------------------------------------
  late final PollingSource<EventAdminView> _adminView = PollingSource(() async {
    final data = await api.call('getLegacyEventAdminView', {
      'eventId': eventId,
    });
    return EventAdminView.fromData(data);
  }, interval: pollInterval);

  late final PollingSource<List<DemoEvent>> _events = PollingSource(() async {
    final data = await api.call('listLegacyEvents', const {});
    final events = <DemoEvent>[];
    for (final raw
        in data['events'] is List ? data['events'] as List : const []) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      events.add(
        DemoEvent.fromData(
          map['eventId'] as String? ?? '',
          map,
          summary: map['summary'] is Map
              ? EventSummary.fromData(
                  Map<String, dynamic>.from(map['summary'] as Map),
                )
              : null,
        ),
      );
    }
    return events..sort(
      (a, b) =>
          (a.startAt ?? DateTime(9999)).compareTo(b.startAt ?? DateTime(9999)),
    );
  }, interval: pollInterval);

  // StreamBuilderが再構築のたびに購読し直さないよう、導出したStreamは1つだけ作って使い回す。
  late final Stream<List<DemoEvent>> _eventsStream = _events.stream;
  late final Stream<DemoEvent?> _eventStream = _adminView.stream.map(
    (v) => v.event,
  );
  late final Stream<List<Participant>> _participantsStream = _adminView.stream
      .map(
        (v) => [...v.participants]..sort((a, b) => a.name.compareTo(b.name)),
      );
  late final Stream<List<CheckIn>> _checkInsStream = _adminView.stream.map(
    (v) => v.checkIns,
  );
  late final Stream<BulkMailJob?> _invitationJobStream = _adminView.stream.map(
    (v) => v.invitationJob,
  );
  late final Stream<BulkMailJob?> _reconfirmationJobStream = _adminView.stream
      .map((v) => v.reconfirmationJob);

  Stream<List<DemoEvent>> watchEvents() => _eventsStream;
  Stream<DemoEvent?> watchEvent() => _eventStream;
  Stream<List<Participant>> watchParticipants() => _participantsStream;
  Stream<List<CheckIn>> watchCheckIns() => _checkInsStream;
  Stream<BulkMailJob?> watchBulkMailJob(String type) => switch (type) {
    'invitation' => _invitationJobStream,
    'reconfirmation' => _reconfirmationJobStream,
    _ => throw ArgumentError('unknown job type'),
  };

  /// 操作の直後に、管理画面の表示を取り直す(失敗しても操作の結果には影響しない)。
  Future<void> _refreshViews() async {
    try {
      await _adminView.refresh();
    } catch (_) {}
    try {
      await _events.refresh();
    } catch (_) {}
  }

  // ---- イベント・参加者の操作(admin専用API) ------------------------------------------------------
  Map<String, dynamic> _settingsPayload({
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
      'eventName': eventName.trim(),
      'senderName': senderName.trim(),
      'startAt': startAt.toUtc().toIso8601String(),
      if (endAt != null) 'endAt': endAt.toUtc().toIso8601String(),
      'venue': venue.trim(),
      'registrationDeadline': registrationDeadline.toUtc().toIso8601String(),
      'confirmationSendAt': confirmationSendAt.toUtc().toIso8601String(),
      'contact': contact.trim(),
    };
  }

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
    final result = await api.call(
      'createLegacyEvent',
      _settingsPayload(
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
    final id = result['eventId'];
    if (id is! String) throw const LegacyApiException('イベントを作成できませんでした。');
    await _refreshEvents();
    return id;
  }

  Future<void> _refreshEvents() async {
    try {
      await _events.refresh();
    } catch (_) {}
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
  }) async {
    // 旧設定更新は confirmationSendAt の再計算と reconfirmEnabled=false の書込みを伴うため、
    // 新方式イベントには使わせない(新方式の設定更新は別経路で提供する)。
    await assertLegacyEvent(eventId, 'イベント設定の更新');
    await api.call('updateLegacyEventSettings', {
      'eventId': eventId,
      ..._settingsPayload(
        eventName: eventName,
        senderName: senderName,
        startAt: startAt,
        endAt: endAt,
        venue: venue,
        registrationDeadline: registrationDeadline,
        confirmationSendTime: confirmationSendTime,
        contact: contact,
      ),
    });
    await _refreshViews();
  }

  /// 参加者を手動登録する(管理者)。participantId・publicIdはサーバーが生成する。
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
    await assertLegacyEvent(eventId, '参加者の追加');
    final result = await api.call('createLegacyParticipant', {
      'eventId': eventId,
      'name': name.trim(),
      'email': email.trim().toLowerCase(),
      'registeredCount': registeredCount,
      'registrationType': registrationType,
      if (furiganaLastName?.trim().isNotEmpty == true)
        'furiganaLastName': furiganaLastName!.trim(),
      if (furiganaFirstName?.trim().isNotEmpty == true)
        'furiganaFirstName': furiganaFirstName!.trim(),
    });
    final data = result['participant'];
    if (data is! Map) throw const LegacyApiException('参加者を登録できませんでした。');
    final map = Map<String, dynamic>.from(data);
    await _refreshViews();
    return Participant.fromData(map['participantId'] as String? ?? '', map);
  }

  /// 当日参加登録(公開API。ログイン不要)。サーバーが登録・確認メールの送信まで行う。
  Future<({String participantId, String publicId, String? mailError})>
  registerWalkIn({
    required String name,
    required String email,
    required int registeredCount,
  }) async {
    final result = await _call('registerWalkIn', {
      'eventId': eventId,
      'name': name.trim(),
      'email': email.trim().toLowerCase(),
      'registeredCount': registeredCount,
    }, authenticated: false);
    final participantId = result['participantId'];
    final publicId = result['publicId'];
    if (participantId is! String || publicId is! String) {
      throw const MailSendException('登録結果が不正です。受付スタッフへお声がけください。');
    }
    return (
      participantId: participantId,
      publicId: publicId,
      mailError: result['mailSent'] == true
          ? null
          : (result['mailError']?.toString() ?? '確認メールを送信できませんでした。'),
    );
  }

  // ---- 参加者本人(participantId+publicId) -------------------------------------------------------
  Map<String, dynamic> _capability(String participantId, String publicId) => {
    'participantId': participantId,
    'publicId': publicId,
  };

  /// マイページの内容を取得する。無効な組(存在しない・publicId不一致・従来方式でない等)は、すべて同じ失敗(null)。
  Future<ParticipantPageData?> loadParticipantPage(
    String? participantId,
    String? publicId,
  ) async {
    if (participantId == null || publicId == null) return null;
    try {
      return ParticipantPageData.fromData(
        await api.call(
          'getLegacyParticipantPage',
          _capability(participantId, publicId),
          authenticated: false,
        ),
      );
    } on LegacyApiException catch (error) {
      if (error.isNotFound) return null;
      rethrow;
    }
  }

  /// 正式登録(本人)。従来方式専用の判定は、サーバーがpublicIdとイベントで必ず再検証する。
  Future<ParticipantPageData> confirmParticipationByKey(
    String participantId,
    String publicId,
  ) async => ParticipantPageData.fromData(
    await api.call(
      'confirmLegacyParticipation',
      _capability(participantId, publicId),
      authenticated: false,
    ),
  );

  Future<ParticipantPageData> reconfirmByKey(
    String participantId,
    String publicId,
    AttendanceResponse response,
  ) async => ParticipantPageData.fromData(
    await api.call('answerLegacyReconfirmation', {
      ..._capability(participantId, publicId),
      'response': response.value,
    }, authenticated: false),
  );

  Future<void> _guardParticipant(
    Participant participant,
    String operation,
  ) async {
    if (selectedEventId != null && participant.eventId != eventId) {
      throw StateError('event-mismatch');
    }
    // 正式登録・参加予定確認(reconfirm)・旧受付は従来方式専用。新方式では使わせない。
    await assertLegacyEvent(participant.eventId, operation);
  }

  Future<void> confirmParticipation(Participant participant) async {
    await _guardParticipant(participant, '正式登録');
    await confirmParticipationByKey(participant.id, participant.publicId);
  }

  Future<void> reconfirm(
    Participant participant,
    AttendanceResponse response,
  ) async {
    await _guardParticipant(participant, '参加予定の回答');
    await reconfirmByKey(participant.id, participant.publicId, response);
  }

  // ---- メール・削除(admin専用API) ------------------------------------------------------------------
  Future<void> sendMail(Participant participant, String type) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    final result = await _call('sendParticipantMail', {
      'participantId': participant.id,
      'publicId': participant.publicId,
      'eventId': eventId,
      'type': type,
    });
    if (result['success'] == true && result['messageId'] is String) {
      await _refreshViews();
      return;
    }
    throw const MailSendException('メール送信に失敗しました。');
  }

  Future<void> startBulkInvitationMail({bool failedOnly = false}) async {
    await _call('startBulkInvitationMail', {
      'eventId': eventId,
      'mode': failedOnly ? 'failed' : 'unsent',
    });
    await _refreshViews();
  }

  Future<void> startBulkReconfirmationMail() async {
    await _call('startBulkReconfirmationMail', {
      'eventId': eventId,
      'mode': 'unanswered',
    });
    await _refreshViews();
  }

  Future<void> deleteParticipant(Participant participant) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    await _call('deleteParticipant', {
      'eventId': eventId,
      'participantId': participant.id,
    });
    await _refreshViews();
  }

  Future<void> deleteEvent(DemoEvent event) async {
    await _call('deleteEvent', {'eventId': event.id});
    await _refreshEvents();
  }

  /// 従来から、これらの操作の失敗は MailSendException として画面へ伝えていた(画面の表示文言を変えない)。
  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data, {
    bool authenticated = true,
  }) async {
    try {
      return await api.call(name, data, authenticated: authenticated);
    } on LegacyApiException catch (error) {
      throw MailSendException(error.message);
    }
  }

  // ---- 受付(staff / admin) ------------------------------------------------------------------------
  Map<String, dynamic> _receptionKey(String participantId, String publicId) => {
    'eventId': eventId,
    'participantId': participantId,
    'publicId': publicId,
  };

  /// 受付画面の表示内容。QRのeventId・participantId・publicIdはサーバーが毎回再検証する。
  Future<ReceptionView> receptionView(
    String participantId,
    String publicId,
  ) async => ReceptionView.fromData(
    await api.call(
      'getLegacyReceptionView',
      _receptionKey(participantId, publicId),
    ),
  );

  /// 受付する(QRの内容から)。既に受付済みのときは StateError('already-checked-in')。
  /// 従来方式かどうかは、サーバーがQRのeventId・participantId・publicIdとともに再検証する。
  Future<void> checkInByKey({
    required String participantId,
    required String publicId,
    required int attendedCount,
  }) async {
    if (attendedCount < 0) throw ArgumentError('実参加人数は0以上で入力してください。');
    final result = await api.call('checkInLegacyParticipant', {
      ..._receptionKey(participantId, publicId),
      'attendedCount': attendedCount,
    });
    if (result['alreadyCheckedIn'] == true) {
      throw StateError('already-checked-in');
    }
  }

  Future<void> updateAttendedCountByKey({
    required String participantId,
    required String publicId,
    required int attendedCount,
  }) async {
    await api.call('updateLegacyAttendedCount', {
      ..._receptionKey(participantId, publicId),
      'attendedCount': attendedCount,
    });
  }

  Future<void> checkIn({
    required Participant participant,
    required int attendedCount,
  }) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    if (attendedCount < 0) throw ArgumentError('実参加人数は0以上で入力してください。');
    // participant単位の旧受付。新方式の受付の正本はprogram別(participant×program)のため使わせない。
    await assertLegacyEvent(participant.eventId, '受付');
    await checkInByKey(
      participantId: participant.id,
      publicId: participant.publicId,
      attendedCount: attendedCount,
    );
  }

  Future<void> updateAttendedCount(
    Participant participant,
    int attendedCount,
  ) async {
    if (participant.eventId != eventId) throw StateError('event-mismatch');
    await assertLegacyEvent(participant.eventId, '実参加人数の修正');
    await updateAttendedCountByKey(
      participantId: participant.id,
      publicId: participant.publicId,
      attendedCount: attendedCount,
    );
  }

  /// (Phase 10C以降、参加者のpublicIdはサーバーが生成する。この関数は形式の検証用に残している)
  static String randomPublicId() {
    final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
    return 'pub_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}
