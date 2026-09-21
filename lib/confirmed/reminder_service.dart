import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';
import 'winner_mail_service.dart';
import 'winner_send_service.dart';

/// 前日リマインドの設定・対象・ジョブの状態(すべてサーバーの値。個人情報は含まない)。
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
  Future<SendJob> startDelivery(
    String eventId, {
    int? expectedTemplateVersion,
    int? expectedTargetCount,
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

class CallableReminderService implements ReminderService {
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
    bool dispatch = true,
  }) async => SendJob.fromFlat(
    await _call('startConfirmedReminderDelivery', {
      'eventId': eventId,
      'expectedTemplateVersion': ?expectedTemplateVersion,
      'expectedTargetCount': ?expectedTargetCount,
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
    'send-at-in-past': '送信予定日時が過去です。有効にすると直ちに送信されます。',
    'send-at-required': '自動送信を有効にするには、送信予定日時を設定してください。',
    'event-ended': 'イベントが終了しているため、実行できません。',
    'target-count-changed': '確認した対象人数と現在の対象人数が異なります。画面を更新して、もう一度確認してください。',
    'participant-not-target': 'この参加者は前日リマインドの対象ではありません。',
    'no-targets': '送信対象の参加者がいません。',
    'mail-not-ready': '前日リマインドの文面またはイベント情報が不足しています。',
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
