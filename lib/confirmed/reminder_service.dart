import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';
import 'winner_mail_service.dart';
import 'winner_send_service.dart';

/// 前日リマインドの設定・対象・ジョブの状態(すべてサーバーの値。個人情報は含まない)。
/// 前日リマインドの宛先(送信前の確認用。サーバーの getConfirmedReminderSettings が返す。対象外も含む)。
class ReminderRecipient {
  const ReminderRecipient({
    required this.participantId,
    required this.name,
    required this.email,
    required this.notificationType,
    required this.programs,
    required this.winnerStatus,
    required this.target,
    this.excludedReason,
    this.duplicate = 'none',
    this.duplicateGroupSize = 1,
    this.additionUnresolved = false,
  });

  factory ReminderRecipient.fromJson(Map<String, dynamic> json) => ReminderRecipient(
    participantId: json['participantId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    email: json['email'] as String? ?? '',
    notificationType: json['notificationType'] as String? ?? 'normal',
    programs: [
      for (final p in (json['programs'] is List ? json['programs'] as List : const []))
        if (p is Map)
          (
            name: p['name'] as String? ?? '',
            timeText: p['timeText'] as String?,
            plannedCount: (p['plannedCount'] as num?)?.toInt(),
          ),
    ],
    winnerStatus: json['winnerStatus'] as String? ?? 'none',
    target: json['target'] == true,
    excludedReason: json['excludedReason'] as String?,
    duplicate: json['duplicate'] as String? ?? 'none',
    duplicateGroupSize: (json['duplicateGroupSize'] as num?)?.toInt() ?? 1,
    additionUnresolved: json['additionUnresolved'] == true,
  );

  final String participantId;
  final String name;
  final String email;

  /// normal / waitlistPromotion
  final String notificationType;
  final List<({String name, String? timeText, int? plannedCount})> programs;

  /// 当選メールの配送状態: sent / unknown / pending / sending / failed / none(配送記録なし)
  final String winnerStatus;

  /// 送信対象(当選メールが送信済み)
  final bool target;
  final String? excludedReason;

  /// メールアドレスの重複: none / shared-address / different-programs / undetermined / suspected-duplicate
  final String duplicate;
  final int duplicateGroupSize;
  final bool additionUnresolved;

  String get notificationTypeLabel => notificationType == 'waitlistPromotion' ? '繰り上げ当選' : '通常当選';

  String get winnerStatusLabel => switch (winnerStatus) {
    'sent' => '送信済み',
    'unknown' => '結果不明(要確認)',
    'pending' => '未送信',
    'sending' => '送信中',
    'failed' => '送信失敗',
    _ => '未送信(記録なし)',
  };

  String get duplicateLabel => switch (duplicate) {
    'shared-address' => '同じアドレス(別の氏名・共有)',
    'different-programs' => '同じアドレス・同じ氏名(別のプログラム)',
    'undetermined' => '同じアドレス(判定できません・要確認)',
    'suspected-duplicate' => '重複登録の疑い',
    _ => '',
  };
}

class ReminderSettings {
  const ReminderSettings({
    required this.eventId,
    required this.eventName,
    required this.enabled,
    required this.ready,
    required this.problems,
    required this.targetCount,
    required this.excludedCount,
    this.sendAt,
    this.eventEnded = false,
    this.templateVersion,
    this.subject = '',
    this.introBody = '',
    this.closingBody = '',
    this.notesBody = '',
    this.previewParticipantId,
    this.job,
    this.changedSinceJob = false,
    this.currentTargetCount,
    this.recipients = const [],
    this.targetsFingerprint,
    this.normalCount = 0,
    this.waitlistCount = 0,
    this.unknownWinnerMail = 0,
    this.suspectedDuplicates = 0,
  });

  factory ReminderSettings.fromJson(Map<String, dynamic> json) {
    final template = json['template'] is Map ? json['template'] as Map : null;
    final targets = json['targets'] is Map ? json['targets'] as Map : const {};
    final changed = json['changedSinceJob'] is Map
        ? json['changedSinceJob'] as Map
        : null;
    return ReminderSettings(
      eventId: json['eventId'] as String? ?? '',
      eventName: json['eventName'] as String? ?? '',
      enabled: json['enabled'] == true,
      sendAt: json['sendAt'] is String
          ? DateTime.tryParse(json['sendAt'] as String)
          : null,
      eventEnded: json['eventEnded'] == true,
      ready: json['ready'] == true,
      problems: json['problems'] is List
          ? (json['problems'] as List).whereType<String>().toList()
          : const [],
      templateVersion: template == null
          ? null
          : (template['version'] as num?)?.toInt(),
      subject: template?['subject'] as String? ?? '',
      introBody: template?['introBody'] as String? ?? '',
      closingBody: template?['closingBody'] as String? ?? '',
      notesBody: template?['notesBody'] as String? ?? '',
      targetCount: (targets['targetCount'] as num?)?.toInt() ?? 0,
      excludedCount: (targets['excludedCount'] as num?)?.toInt() ?? 0,
      previewParticipantId: json['previewParticipantId'] as String?,
      job: json['job'] is Map
          ? SendJob.fromView(Map<String, dynamic>.from(json['job'] as Map))
          : null,
      changedSinceJob: changed?['changed'] == true,
      recipients: [
        for (final r in (json['recipients'] is List ? json['recipients'] as List : const []))
          if (r is Map) ReminderRecipient.fromJson(Map<String, dynamic>.from(r)),
      ],
      targetsFingerprint: targets['fingerprint'] as String?,
      normalCount: ((targets['countsByNotificationType'] as Map?)?['normal'] as num?)?.toInt() ?? 0,
      waitlistCount: ((targets['countsByNotificationType'] as Map?)?['waitlistPromotion'] as num?)?.toInt() ?? 0,
      unknownWinnerMail: ((targets['blocked'] as Map?)?['unknownWinnerMail'] as num?)?.toInt() ?? 0,
      suspectedDuplicates: ((targets['blocked'] as Map?)?['suspectedDuplicates'] as num?)?.toInt() ?? 0,
      currentTargetCount: (changed?['currentTargetCount'] as num?)?.toInt(),
    );
  }

  final String eventId;
  final String eventName;

  /// 自動送信の有効/無効(既定は無効)。
  final bool enabled;

  /// 送信予定日時(絶対時刻)。
  final DateTime? sendAt;
  final bool eventEnded;
  final bool ready;
  final List<String> problems;
  final int? templateVersion;
  final String subject;
  final String introBody;
  final String closingBody;
  final String notesBody;

  /// リマインド対象(イベント全体の全active participant。サーバーの計算結果)と、対象外の件数。
  final int targetCount;
  final int excludedCount;
  final String? previewParticipantId;

  /// 作成済みのリマインドジョブ(なければnull)。
  final SendJob? job;

  /// ジョブ作成後に参加者が追加・変更されている(既存ジョブへは自動で追加しない)。
  final bool changedSinceJob;
  final int? currentTargetCount;

  /// 送信前の宛先一覧(対象・対象外)。
  final List<ReminderRecipient> recipients;

  /// 宛先一覧の照合値(手動開始で送る。確認後に宛先・送信内容が変わっていれば、サーバーが作成を拒否する)。
  final String? targetsFingerprint;

  /// 送信対象のうち通常当選・繰り上げ当選の件数。
  final int normalCount;
  final int waitlistCount;

  /// 当選メールの結果不明・重複登録の疑い(1件でもあれば、サーバーはリマインドを作らない)。
  final int unknownWinnerMail;
  final int suspectedDuplicates;

  bool get blocked => unknownWinnerMail > 0 || suspectedDuplicates > 0;
}

/// 前日リマインド(admin専用)。状態・対象・設定はすべてサーバーから取得し、Firestoreを直接読まない。
abstract class ReminderService {
  Future<ReminderSettings> getSettings(String eventId);

  /// 設定の保存(保存だけではメールは送られない)。sendAtはnull以外なら絶対時刻。
  Future<void> updateSettings({
    required String eventId,
    bool? enabled,
    DateTime? sendAt,
    ({String subject, String introBody, String closingBody, String notesBody})?
    template,
    bool acknowledgePast = false,
  });

  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  });

  /// 手動開始(自動開始と同じジョブへ到達。既存があればその状態を返す=別便ではない)。
  /// expected*: 画面で確認した値(ジョブを新規作成する場合だけサーバーが照合する)。
  /// [expectedTargetsFingerprint]: 確認した宛先一覧の照合値(ジョブを新しく作るときはサーバーが必須とする)。
  Future<SendJob> startDelivery(
    String eventId, {
    int? expectedTemplateVersion,
    int? expectedTargetCount,
    String? expectedTargetsFingerprint,
    bool dispatch = true,
  });

  Future<SendJobDetail> getJob(
    String eventId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  });

  /// failedだけを未送信へ戻す(sent・unknownは対象外)。送信はサーバーの継続処理が行う。
  Future<SendJob> retryFailed(String eventId);
}

/// リマインドのジョブ(reminder-{eventId})を、送信状況画面(WinnerSendJobPage)で表示・操作するための変換。
/// 画面は当選メールと共通(状態の区別・unknownの警告・失敗分だけ再送・pollingなど)。呼び先だけがリマインド用のcallableになる。
class ReminderJobAdapter implements WinnerSendService {
  ReminderJobAdapter(this.service);
  final ReminderService service;

  static const prefix = 'reminder-';
  static String jobIdFor(String eventId) => '$prefix$eventId';
  String _eventOf(String jobId) => jobId.startsWith(prefix)
      ? jobId.substring(prefix.length)
      : throw const WinnerSendException('対象が見つかりません。');

  @override
  Future<SendBatchList> listBatches(String eventId) =>
      throw UnsupportedError('前日リマインドは取込回ごとの一覧を持たない');

  @override
  Future<SendJobDetail> getJob(
    String jobId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  }) async => service.getJob(
    _eventOf(jobId),
    itemStatus: itemStatus,
    after: after,
    limit: limit,
  );

  // 送信状況画面の「準備を完了する」用(準備が途中のジョブを完了させる。配送は始めない)。
  @override
  Future<SendJob> createJob({
    required String eventId,
    required String batchId,
    required int expectedTemplateVersion,
  }) => service.startDelivery(eventId, dispatch: false);

  @override
  Future<SendJob> startDelivery(String jobId) async =>
      service.startDelivery(_eventOf(jobId));

  @override
  Future<SendJob> retryFailed(String jobId) async =>
      service.retryFailed(_eventOf(jobId));
}

abstract class ReminderRecoveryService {
  Future<List<Map<String, dynamic>>> recoveryPreview(String eventId);
  Future<void> confirmRecovery(String eventId, Map<String, dynamic> recipient, String reason);
}

class CallableReminderService implements ReminderService, ReminderRecoveryService {
  @override
  Future<List<Map<String, dynamic>>> recoveryPreview(String eventId) async {
    final result = await _call('getConfirmedReminderRecovery', {'eventId': eventId});
    return [for (final r in result['recipients'] as List? ?? []) Map<String, dynamic>.from(r as Map)];
  }

  @override
  Future<void> confirmRecovery(String eventId, Map<String, dynamic> recipient, String reason) async {
    await _call('confirmConfirmedReminderRecovery', {'eventId': eventId, 'participantId': recipient['participantId'],
      'expectedFingerprint': recipient['fingerprint'], 'reason': reason});
  }

  CallableReminderService({
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
  Future<ReminderSettings> getSettings(String eventId) async =>
      ReminderSettings.fromJson(
        await _call('getConfirmedReminderSettings', {'eventId': eventId}),
      );

  @override
  Future<void> updateSettings({
    required String eventId,
    bool? enabled,
    DateTime? sendAt,
    ({String subject, String introBody, String closingBody, String notesBody})?
    template,
    bool acknowledgePast = false,
  }) async {
    await _call('updateConfirmedReminderSettings', {
      'eventId': eventId,
      'reminderEnabled': ?enabled,
      if (sendAt != null) 'reminderSendAt': sendAt.toUtc().toIso8601String(),
      if (template != null)
        'template': {
          'subject': template.subject,
          'introBody': template.introBody,
          'closingBody': template.closingBody,
          'notesBody': template.notesBody,
        },
      if (acknowledgePast) 'acknowledgePast': true,
    });
  }

  @override
  Future<WinnerMailPreview> preview({
    required String eventId,
    required String participantId,
  }) async => WinnerMailPreview.fromJson(
    await _call('previewConfirmedReminderMail', {
      'eventId': eventId,
      'participantId': participantId,
    }),
  );

  @override
  Future<SendJob> startDelivery(
    String eventId, {
    int? expectedTemplateVersion,
    int? expectedTargetCount,
    String? expectedTargetsFingerprint,
    bool dispatch = true,
  }) async => SendJob.fromFlat(
    await _call('startConfirmedReminderDelivery', {
      'eventId': eventId,
      'expectedTemplateVersion': ?expectedTemplateVersion,
      'expectedTargetCount': ?expectedTargetCount,
      'expectedTargetsFingerprint': ?expectedTargetsFingerprint,
      if (!dispatch) 'dispatch': false,
    }),
  );

  @override
  Future<SendJobDetail> getJob(
    String eventId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  }) async => SendJobDetail.fromJson(
    await _call('getConfirmedReminderJob', {
      'eventId': eventId,
      'limit': limit,
      if (itemStatus != null) 'itemStatus': itemStatus.value,
      'after': ?after,
    }),
  );

  @override
  Future<SendJob> retryFailed(String eventId) async => SendJob.fromFlat(
    await _call('retryFailedConfirmedReminderMails', {'eventId': eventId}),
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
        '通信に失敗しました。サーバーでは処理が行われている可能性があります。画面を更新して、現在の状態を確認してください。',
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
    'recovery-delivery-active': '配送処理中は復旧できません。処理が止まってから状態を更新して確認してください。',
    'recovery-not-failed': 'この宛先は確実な未送信失敗ではないため、復旧できません。送信済み・結果不明は再送しません。',
    'recovery-state-changed': '再確認の後に宛先・参加資格・配送状態が変わりました。復旧画面を開き直して確認してください。',
    'send-at-in-past': '送信予定日時が過去です。有効にすると直ちに送信されます。',
    'send-at-required': '自動送信を有効にするには、送信予定日時を設定してください。',
    'event-ended': 'イベントが終了しているため、実行できません。',
    'target-count-changed': '確認した対象人数と現在の対象人数が異なります。画面を更新して、もう一度確認してください。',
    'participant-not-target': 'この参加者は前日リマインドの対象ではありません。',
    'no-targets': '送信対象の参加者がいません。',
    'mail-not-ready': '前日リマインドの文面またはイベント情報が不足しています。',
    'targets-changed':
        '確認した後に、送信対象または送信内容(宛先・参加内容・当選メールの状態)が変わりました。画面を更新して、宛先一覧をもう一度確認してください。',
    'reminder-targets-unresolved':
        '当選メールの結果が不明な参加者、または重複登録の疑いがある参加者がいるため、前日リマインドを作成できません。宛先一覧で確認してください。',
    'targets-fingerprint-required': '宛先一覧を確認してから開始してください。画面を更新して、もう一度確認してください。',
  };

  /// サーバーのエラー応答を、表示用の例外にする(共通のものは当選メールの送信管理と同じ)。
  static WinnerSendException errorFrom(int statusCode, Object? decoded) {
    final base = CallableWinnerSendService.errorFrom(statusCode, decoded);
    final message = _messages[base.code];
    return message == null
        ? base
        : WinnerSendException(message, code: base.code);
  }
}
