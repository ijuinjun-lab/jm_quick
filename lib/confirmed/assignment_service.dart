// Phase 3: イベント単位の任命(イベント管理者・スタッフ)と、担当イベントの取得。
// Functions(Phase 2)の assignEventRole / removeEventRole / listEventAssignments / listMyEvents を呼ぶだけで、
// 権限の判断はすべてサーバーが行う(クライアントはFirestoreを直接読まない)。
// ■ 利用者にはuid・assignmentId・eventIdを表示しない。assignmentIdは解除処理の内部値としてだけ保持する。
// ■ 対象ユーザーはメールアドレスで指定する(Firebase Authに登録済みのユーザーだけ。ユーザーは作らない)。

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'access_role.dart';
import 'auth_client.dart';

/// 本人が管理・受付できるイベント(listMyEvents)。
class MyEvent {
  const MyEvent({
    required this.eventId,
    required this.eventName,
    required this.startAt,
    required this.venue,
    required this.eventRole,
  });

  final String eventId;
  final String eventName;
  final DateTime? startAt;
  final String venue;

  /// このイベントでのrole。システム管理者(全イベント)ではnull。
  final EventRole? eventRole;

  bool get isSystemAdmin => eventRole == null;

  /// 画面に表示するroleの名前。
  String get roleLabel => eventRole?.label ?? systemAdminLabel;

  /// イベント管理機能(CSV取込・メール・スタッフ管理等)を使えるか(システム管理者・イベント管理者)。
  bool get canManage => eventRole == null || eventRole!.isManager;

  static MyEvent? fromJson(Map<String, dynamic> json) {
    final eventId = json['eventId'];
    if (eventId is! String || eventId.isEmpty) return null;
    final rawRole = json['role'];
    final EventRole? role;
    if (rawRole == 'system_admin') {
      role = null;
    } else {
      role = EventRole.fromValue(rawRole);
      if (role == null) return null; // 未知のroleは表示しない
    }
    return MyEvent(
      eventId: eventId,
      eventName: json['eventName'] as String? ?? '',
      startAt: DateTime.tryParse(json['startAt'] as String? ?? '')?.toLocal(),
      venue: json['venue'] as String? ?? '',
      eventRole: role,
    );
  }
}

/// 対象イベントの任命(listEventAssignments)。assignmentIdは解除の内部値(表示しない)。
class EventAssignmentEntry {
  const EventAssignmentEntry({
    required this.assignmentId,
    required this.role,
    required this.email,
    required this.isSelf,
  });

  final String assignmentId;
  final EventRole role;
  final String email;
  final bool isSelf;
}

/// 招待中(未登録の人への招待。listEventAssignmentsのinvitations)。invitationIdは取消の内部値(表示しない)。
class EventInvitationEntry {
  const EventInvitationEntry({
    required this.invitationId,
    required this.role,
    required this.email,
    required this.expiresAt,
    required this.expired,
    required this.mailFailed,
  });

  final String invitationId;
  final EventRole role;
  final String email;
  final DateTime? expiresAt;
  final bool expired;

  /// 招待メールを送れなかった(再度招待すれば送り直す)。
  final bool mailFailed;

  /// 画面に表示する状態。
  String get statusLabel => expired ? '期限切れ' : (mailFailed ? '送信失敗' : '招待中');
}

/// 招待の結果。未登録なら招待メールを送った(invited)、登録済みなら即任命した(assigned)。
enum InviteResult { invited, assigned }

/// 画面へそのまま表示できるエラー(内部情報を含まない)。
class AssignmentException implements Exception {
  const AssignmentException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

abstract class AssignmentService {
  Future<List<MyEvent>> listMyEvents();
  Future<List<EventAssignmentEntry>> listAssignments(String eventId);

  /// 任命(既に同じ任命があれば何もしない)。変更があればtrue。
  Future<bool> assign({
    required String eventId,
    required String email,
    required EventRole role,
  });
  Future<void> remove({required String eventId, required String assignmentId});

  /// Phase 4: 招待中の一覧(招待中・期限切れ)。
  Future<List<EventInvitationEntry>> listInvitations(String eventId);

  /// Phase 4: 招待(未登録なら招待メール、登録済みならサーバーが即任命する)。
  Future<InviteResult> invite({
    required String eventId,
    required String email,
    required EventRole role,
  });

  /// Phase 4: 招待の取消。
  Future<void> revokeInvitation({
    required String eventId,
    required String invitationId,
  });
}

/// サーバーの理由コード → 画面の文言。
String assignmentErrorMessage(String? status, String? code) {
  switch (code) {
    case 'user-not-found':
      return 'このメールアドレスの利用者が登録されていません。先にJM Quickのアカウントを登録してください。';
    case 'user-disabled':
      return 'この利用者のアカウントは無効になっています。';
    case 'target-is-system-admin':
      return 'この利用者はシステム管理者のため、イベントごとの設定は不要です。';
    case 'self-assignment':
      return '自分自身の権限は変更できません。';
    case 'invalid-email':
      return 'メールアドレスの形式を確認してください。';
    case 'event-not-found':
    case 'event-not-confirmed':
      return 'このイベントでは設定できません。';
    case 'assignment-not-found':
    case 'invitation-not-found':
      return '対象が見つかりません。画面を更新してください。';
    case 'invitation-mail-failed':
      return '招待メールを送信できませんでした。時間をおいて、もう一度招待してください。';
  }
  switch (status) {
    case 'PERMISSION_DENIED':
      return 'この操作を行う権限がありません。';
    case 'UNAUTHENTICATED':
      return 'ログインが必要です。';
  }
  return '処理に失敗しました。もう一度お試しください。';
}

class CallableAssignmentService implements AssignmentService {
  CallableAssignmentService({
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

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final token = await authClient.idToken();
    if (token == null) throw const AssignmentException('ログインが必要です。');
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
      throw const AssignmentException('通信に失敗しました。もう一度お試しください。');
    }
    return interpret(response.statusCode, utf8.decode(response.bodyBytes));
  }

  /// 応答の解釈(テストから直接検証できるよう公開)。成功ならresult、失敗なら表示用の例外。
  static Map<String, dynamic> interpret(int statusCode, String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      decoded = null;
    }
    if (statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    throw AssignmentException(
      assignmentErrorMessage(error['status'] as String?, code),
      code: code,
    );
  }

  @override
  Future<List<MyEvent>> listMyEvents() async {
    final result = await _call('listMyEvents', const {});
    final raw = result['events'] is List ? result['events'] as List : const [];
    return [
      for (final item in raw)
        if (item is Map) MyEvent.fromJson(Map<String, dynamic>.from(item)),
    ].whereType<MyEvent>().toList();
  }

  @override
  Future<List<EventAssignmentEntry>> listAssignments(String eventId) async {
    final result = await _call('listEventAssignments', {'eventId': eventId});
    final raw = result['assignments'] is List
        ? result['assignments'] as List
        : const [];
    final entries = <EventAssignmentEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final role = EventRole.fromValue(item['role']);
      final assignmentId = item['assignmentId'];
      if (role == null || assignmentId is! String) continue;
      entries.add(
        EventAssignmentEntry(
          assignmentId: assignmentId,
          role: role,
          email: item['email'] as String? ?? '',
          isSelf: item['isSelf'] == true,
        ),
      );
    }
    return entries;
  }

  @override
  Future<bool> assign({
    required String eventId,
    required String email,
    required EventRole role,
  }) async {
    final result = await _call('assignEventRole', {
      'eventId': eventId,
      'email': email.trim(),
      'role': role.value,
    });
    return result['changed'] == true;
  }

  @override
  Future<void> remove({
    required String eventId,
    required String assignmentId,
  }) async {
    await _call('removeEventRole', {
      'eventId': eventId,
      'assignmentId': assignmentId,
    });
  }

  @override
  Future<List<EventInvitationEntry>> listInvitations(String eventId) async {
    final result = await _call('listEventAssignments', {'eventId': eventId});
    final raw = result['invitations'] is List
        ? result['invitations'] as List
        : const [];
    final entries = <EventInvitationEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final role = EventRole.fromValue(item['role']);
      final invitationId = item['invitationId'];
      if (role == null || invitationId is! String) continue;
      entries.add(
        EventInvitationEntry(
          invitationId: invitationId,
          role: role,
          email: item['email'] as String? ?? '',
          expiresAt: DateTime.tryParse(
            item['expiresAt'] as String? ?? '',
          )?.toLocal(),
          expired: item['status'] == 'expired',
          mailFailed:
              item['mailStatus'] == 'failed' || item['mailStatus'] == 'unknown',
        ),
      );
    }
    return entries;
  }

  @override
  Future<InviteResult> invite({
    required String eventId,
    required String email,
    required EventRole role,
  }) async {
    final result = await _call('inviteEventRole', {
      'eventId': eventId,
      'email': email.trim(),
      'role': role.value,
    });
    return result['result'] == 'assigned'
        ? InviteResult.assigned
        : InviteResult.invited;
  }

  @override
  Future<void> revokeInvitation({
    required String eventId,
    required String invitationId,
  }) async {
    await _call('revokeEventInvitation', {
      'eventId': eventId,
      'invitationId': invitationId,
    });
  }
}
