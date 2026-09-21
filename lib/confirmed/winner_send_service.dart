import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';

/// 送信管理の呼び出しで起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class WinnerSendException implements Exception {
  const WinnerSendException(this.message, {this.code});
  final String message;

  /// サーバーが返した理由コード(例: template-version-changed)。
  final String? code;
  @override
  String toString() => message;
}

/// 配送状態(サーバーの mailDeliveries / items の状態名と同じ)。
enum DeliveryState {
  pending('pending', '未送信'),
  sending('sending', '送信中'),
  sent('sent', '送信済み'),
  failed('failed', '失敗'),
  // 「送信された可能性があるが、結果を確定できない」。失敗とは別の状態。
  unknown('unknown', '結果確認が必要');

  const DeliveryState(this.value, this.label);
  final String value;
  final String label;

  static DeliveryState? fromValue(Object? value) {
    for (final state in values) {
      if (state.value == value) return state;
    }
    return null;
  }
}

/// ジョブの状態(サーバーの状態名。新しい状態名は作らない)。
/// preparing=準備中 / ready=送信可能(未処理・処理中を含む) / completed=処理完了 / failed=準備に失敗
enum JobState {
  preparing('preparing', '準備中'),
  ready('ready', '送信処理中'),
  completed('completed', '処理完了'),
  failed('failed', '準備に失敗');

  const JobState(this.value, this.label);
  final String value;
  final String label;

  static JobState? fromValue(Object? value) {
    for (final state in values) {
      if (state.value == value) return state;
    }
    return null;
  }
}

class DeliveryCounts {
  const DeliveryCounts({
    required this.pending,
    required this.sending,
    required this.sent,
    required this.failed,
    required this.unknown,
  });

  factory DeliveryCounts.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    int n(String key) => (map[key] as num?)?.toInt() ?? 0;
    return DeliveryCounts(
      pending: n('pending'),
      sending: n('sending'),
      sent: n('sent'),
      failed: n('failed'),
      unknown: n('unknown'),
    );
  }

  /// create / process / retry の応答(pendingCount 等のフラットな形)。
  factory DeliveryCounts.fromFlat(Map<String, dynamic> json) {
    int n(String key) => (json[key] as num?)?.toInt() ?? 0;
    return DeliveryCounts(
      pending: n('pendingCount'),
      sending: n('sendingCount'),
      sent: n('sentCount'),
      failed: n('failedCount'),
      unknown: n('unknownCount'),
    );
  }

  final int pending;
  final int sending;
  final int sent;
  final int failed;
  final int unknown;

  int get total => pending + sending + sent + failed + unknown;
  int of(DeliveryState state) => switch (state) {
    DeliveryState.pending => pending,
    DeliveryState.sending => sending,
    DeliveryState.sent => sent,
    DeliveryState.failed => failed,
    DeliveryState.unknown => unknown,
  };
}

/// 送信ジョブ(batch単位)の状態。件数はサーバーの mailDeliveries 由来。
class SendJob {
  const SendJob({
    required this.jobId,
    required this.batchId,
    required this.state,
    required this.templateVersion,
    required this.targetCount,
    required this.counts,
    this.batchLabel = '',
    this.excludedInactiveCount = 0,
    this.createdAt,
    this.completedAt,
    this.serverConsistent = true,
    this.serverCompletedConsistent = true,
  });

  factory SendJob.fromView(Map<String, dynamic> json) {
    final conservation = json['conservation'] is Map
        ? json['conservation'] as Map
        : const {};
    return SendJob(
      jobId: json['jobId'] as String? ?? '',
      batchId: json['batchId'] as String? ?? '',
      batchLabel: json['batchLabel'] as String? ?? '',
      state: JobState.fromValue(json['status']),
      templateVersion: (json['templateVersion'] as num?)?.toInt() ?? 0,
      targetCount: (json['targetCount'] as num?)?.toInt() ?? 0,
      excludedInactiveCount:
          (json['excludedInactiveCount'] as num?)?.toInt() ?? 0,
      counts: DeliveryCounts.fromJson(json['counts']),
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
      completedAt: json['completedAt'] is String
          ? DateTime.tryParse(json['completedAt'] as String)
          : null,
      serverConsistent: conservation['consistent'] == true,
      serverCompletedConsistent: conservation['completedConsistent'] == true,
    );
  }

  /// create / process / retry の応答。
  factory SendJob.fromFlat(Map<String, dynamic> json) => SendJob(
    jobId: json['jobId'] as String? ?? '',
    batchId: json['batchId'] as String? ?? '',
    state: JobState.fromValue(json['status']),
    templateVersion: (json['templateVersion'] as num?)?.toInt() ?? 0,
    targetCount: (json['targetCount'] as num?)?.toInt() ?? 0,
    excludedInactiveCount:
        (json['excludedInactiveCount'] as num?)?.toInt() ?? 0,
    counts: DeliveryCounts.fromFlat(json),
  );

  final String jobId;
  final String batchId;
  final String batchLabel;

  /// 未知の状態名はnull(「状態を確認できません」として扱う)。
  final JobState? state;
  final int templateVersion;
  final int targetCount;
  final int excludedInactiveCount;
  final DeliveryCounts counts;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final bool serverConsistent;
  final bool serverCompletedConsistent;

  /// 件数の保存則: 未送信+送信中+送信済み+失敗+結果確認 == 対象件数(サーバーの判定とクライアントの再計算の両方)。
  bool get countsConsistent => serverConsistent && counts.total == targetCount;

  /// completedなら、未送信・送信中が残っておらず sent + failed + unknown == 対象件数。
  bool get completedConsistent {
    if (state != JobState.completed) return serverCompletedConsistent;
    return serverCompletedConsistent &&
        counts.pending == 0 &&
        counts.sending == 0 &&
        counts.sent + counts.failed + counts.unknown == targetCount;
  }

  /// 状態を信頼して表示・操作してよいか。合わなければ「状態を確認できません」とし、完了扱いにも操作にも使わない。
  bool get trustworthy =>
      state != null &&
      targetCount > 0 &&
      countsConsistent &&
      completedConsistent;

  bool get isTerminal =>
      state == JobState.completed || state == JobState.failed;

  /// process / retry の応答(件数と状態だけを持つ)を、既に画面にある表示情報(取込回名・作成日時など)へ反映する。
  SendJob withProgress(SendJob progress) => SendJob(
    jobId: jobId,
    batchId: batchId,
    batchLabel: batchLabel,
    state: progress.state,
    templateVersion: templateVersion,
    targetCount: progress.targetCount,
    counts: progress.counts,
    excludedInactiveCount: excludedInactiveCount,
    createdAt: createdAt,
    completedAt: completedAt,
  );
}

class SendBatch {
  const SendBatch({
    required this.batchId,
    required this.sequence,
    required this.label,
    required this.status,
    required this.canCreateJob,
    required this.blockedReasons,
    this.importedCount,
    this.targetCount,
    this.excludedInactiveCount,
    this.consistent,
    this.previewParticipantId,
    this.job,
  });

  factory SendBatch.fromJson(Map<String, dynamic> json) => SendBatch(
    batchId: json['batchId'] as String? ?? '',
    sequence: (json['sequence'] as num?)?.toInt() ?? 0,
    label: json['label'] as String? ?? '',
    status: json['status'] as String? ?? '',
    importedCount: (json['importedCount'] as num?)?.toInt(),
    targetCount: (json['targetCount'] as num?)?.toInt(),
    excludedInactiveCount: (json['excludedInactiveCount'] as num?)?.toInt(),
    consistent: json['consistent'] as bool?,
    previewParticipantId: json['previewParticipantId'] as String?,
    canCreateJob: json['canCreateJob'] == true,
    blockedReasons: json['blockedReasons'] is List
        ? (json['blockedReasons'] as List).whereType<String>().toList()
        : const [],
    job: json['job'] is Map
        ? SendJob.fromView(Map<String, dynamic>.from(json['job'] as Map))
        : null,
  );

  final String batchId;
  final int sequence;
  final String label;

  /// 取込の状態(committed / committing / failed)。committed以外は送信開始できない。
  final String status;
  final int? importedCount;
  final int? targetCount;
  final int? excludedInactiveCount;
  final bool? consistent;
  final String? previewParticipantId;
  final bool canCreateJob;
  final List<String> blockedReasons;
  final SendJob? job;
}

class SendBatchList {
  const SendBatchList({
    required this.eventId,
    required this.eventName,
    required this.templateVersion,
    required this.templateReady,
    required this.templateProblems,
    required this.batches,
  });

  factory SendBatchList.fromJson(Map<String, dynamic> json) {
    final template = json['template'] is Map
        ? json['template'] as Map
        : const {};
    return SendBatchList(
      eventId: json['eventId'] as String? ?? '',
      eventName: json['eventName'] as String? ?? '',
      templateVersion: (template['version'] as num?)?.toInt(),
      templateReady: template['ready'] == true,
      templateProblems: template['problems'] is List
          ? (template['problems'] as List).whereType<String>().toList()
          : const [],
      batches: json['batches'] is List
          ? (json['batches'] as List)
                .whereType<Map>()
                .map((b) => SendBatch.fromJson(Map<String, dynamic>.from(b)))
                .toList()
          : const [],
    );
  }

  final String eventId;
  final String eventName;
  final int? templateVersion;
  final bool templateReady;
  final List<String> templateProblems;
  final List<SendBatch> batches;
}

class SendItem {
  const SendItem({
    required this.participantId,
    required this.name,
    required this.state,
    this.attemptCount = 0,
    this.lastErrorCode,
    this.leaseActive,
  });

  factory SendItem.fromJson(Map<String, dynamic> json) => SendItem(
    participantId: json['participantId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    state: DeliveryState.fromValue(json['status']),
    attemptCount: (json['attemptCount'] as num?)?.toInt() ?? 0,
    lastErrorCode: json['lastErrorCode'] as String?,
    leaseActive: json['leaseActive'] as bool?,
  );

  final String participantId;
  final String name;
  final DeliveryState? state;
  final int attemptCount;
  final String? lastErrorCode;
  final bool? leaseActive;
}

class SendJobDetail {
  const SendJobDetail({
    required this.job,
    required this.items,
    required this.nextAfter,
  });

  factory SendJobDetail.fromJson(Map<String, dynamic> json) => SendJobDetail(
    job: SendJob.fromView(Map<String, dynamic>.from(json['job'] as Map)),
    items: json['items'] is List
        ? (json['items'] as List)
              .whereType<Map>()
              .map((i) => SendItem.fromJson(Map<String, dynamic>.from(i)))
              .toList()
        : const [],
    nextAfter: json['nextAfter'] as String?,
  );

  final SendJob job;
  final List<SendItem> items;
  final String? nextAfter;
}

/// process の応答(1回の処理後のジョブの状態)。
class ProcessResult {
  const ProcessResult({
    required this.job,
    required this.processed,
    required this.skipped,
  });
  final SendJob job;
  final int processed;
  final int skipped;
}

/// 当選メール送信管理(admin専用)。状態はすべてサーバーから取得する(Firestoreを直接読まない)。
/// 対象者の計算・件数・状態の判定はサーバーが行い、クライアントはそれを表示する。
abstract class WinnerSendService {
  Future<SendBatchList> listBatches(String eventId);

  Future<SendJobDetail> getJob(
    String jobId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  });

  /// 送信ジョブを作成する(メールは1通も送らない。同じbatchなら既存のジョブが返る=冪等)。
  /// expectedTemplateVersion: 画面で確認したテンプレートversion。違えばサーバーが作成しない。
  Future<SendJob> createJob({
    required String eventId,
    required String batchId,
    required int expectedTemplateVersion,
  });

  /// 未送信の項目を最大limit件処理する(実際にメールを送る操作)。
  Future<ProcessResult> processJob(String jobId, {int limit = 50});

  /// failedの項目だけを未送信に戻す(sent・unknownは対象外)。送信は processJob で行う。
  Future<SendJob> retryFailed(String jobId);
}

class CallableWinnerSendService implements WinnerSendService {
  CallableWinnerSendService({
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
  Future<SendBatchList> listBatches(String eventId) async =>
      SendBatchList.fromJson(
        await _call('listConfirmedWinnerMailBatches', {'eventId': eventId}),
      );

  @override
  Future<SendJobDetail> getJob(
    String jobId, {
    DeliveryState? itemStatus,
    String? after,
    int limit = 100,
  }) async => SendJobDetail.fromJson(
    await _call('getConfirmedWinnerMailJob', {
      'jobId': jobId,
      'limit': limit,
      if (itemStatus != null) 'itemStatus': itemStatus.value,
      if (after != null) 'after': after,
    }),
  );

  @override
  Future<SendJob> createJob({
    required String eventId,
    required String batchId,
    required int expectedTemplateVersion,
  }) async => SendJob.fromFlat(
    await _call('createConfirmedWinnerMailJob', {
      'eventId': eventId,
      'batchId': batchId,
      'expectedTemplateVersion': expectedTemplateVersion,
    }),
  );

  @override
  Future<ProcessResult> processJob(String jobId, {int limit = 50}) async {
    final result = await _call('processConfirmedWinnerMailJob', {
      'jobId': jobId,
      'limit': limit,
    });
    return ProcessResult(
      job: SendJob.fromFlat(result),
      processed: (result['processed'] as num?)?.toInt() ?? 0,
      skipped: (result['skipped'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<SendJob> retryFailed(String jobId) async => SendJob.fromFlat(
    await _call('retryFailedConfirmedWinnerMails', {'jobId': jobId}),
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
      // 応答を受け取れなかった場合、サーバーで処理が行われた可能性がある。画面の再読込で、サーバーの状態を再取得して確認する。
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

  static const _codeMessages = {
    'batch-not-committed': '取込が完了(committed)していない取込回には送信できません。',
    'template-version-changed':
        '確認したテンプレートのバージョンが変更されています。画面を更新して、もう一度確認してください。',
    'mail-not-ready': '当選メールの設定が完了していません。「当選メール設定」を確認してください。',
    'mail-api-incapable': 'メール送信サービスがQR付きメールに対応していることを確認できません。送信を中止しました。',
    'participants-mismatch': '取込回の参加者数が取込結果と一致しません。送信できません。',
    'no-targets': '送信対象の参加者がいません。',
    'job-not-ready': 'ジョブの準備が完了していないため、操作できません。',
    'job-items-mismatch': '送信対象の件数とジョブ項目の件数が一致しません。ジョブを作成しませんでした。',
    'delivery-count-mismatch': '配送結果の合計が対象数と一致しません。状態を確認してください。',
    'delivery-exists': 'この参加者には既に配送記録があるため、ジョブを作成できません。',
  };

  /// サーバーのエラー応答を、表示用の例外にする。
  static WinnerSendException errorFrom(int statusCode, Object? decoded) {
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    switch (error['status']) {
      case 'PERMISSION_DENIED':
        return WinnerSendException('この操作を行う権限がありません。', code: code);
      case 'UNAUTHENTICATED':
        return WinnerSendException('ログインが必要です。', code: code);
      case 'NOT_FOUND':
        return WinnerSendException('対象が見つかりません。', code: code);
    }
    final known = _codeMessages[code];
    if (known != null) return WinnerSendException(known, code: code);
    return WinnerSendException('処理に失敗しました。画面を更新して、現在の状態を確認してください。', code: code);
  }
}
