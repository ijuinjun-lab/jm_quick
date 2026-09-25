// 新方式(flow=confirmed)の管理機能のロール。
// 権限の正本はサーバー側の accessRoles/{uid}。クライアントはそれを直接読まず(Rulesで全拒否)、
// callable(getMyAccessRole)がサーバー側で確認した結果だけを受け取る。

enum AccessRole {
  admin('admin'),
  staff('staff');

  const AccessRole(this.value);
  final String value;

  /// callableが返した文字列から。'admin'/'staff'以外(未知の値)はnull=権限なし扱い。
  static AccessRole? fromValue(Object? value) {
    for (final role in values) {
      if (role.value == value) return role;
    }
    return null;
  }

  bool get isAdmin => this == admin;
}

enum AccessOutcome {
  /// サーバーがadmin/staffと確認した。
  granted,

  /// ログイン済みだが権限なし(accessRolesなし・active=false・未知のrole)。
  denied,

  /// ログインが無効(トークン切れなど)。ログインし直しが必要。
  unauthenticated,

  /// 通信・サーバーの失敗。権限の有無は不明(再試行できる)。
  error,
}

/// Phase 3: イベント単位の権限(eventAssignments)。正本はサーバーで、クライアントはgetMyAccessRoleの結果を受け取るだけ。
/// 上位は下位を包含する: システム管理者(accessRolesのadmin) > イベント管理者 > スタッフ。
enum EventRole {
  eventManager('event_manager', 'イベント管理者'),
  staff('staff', 'スタッフ');

  const EventRole(this.value, this.label);

  /// サーバーの値(画面には表示しない)。
  final String value;

  /// 画面に表示する名前。
  final String label;

  /// 'event_manager'/'staff'以外(未知の値)はnull=権限として扱わない。
  static EventRole? fromValue(Object? value) {
    for (final role in values) {
      if (role.value == value) return role;
    }
    return null;
  }

  bool get isManager => this == eventManager;
}

/// 画面に表示するシステム管理者の名前(accessRolesのadmin。DBの値は"admin"のまま)。
const String systemAdminLabel = 'システム管理者';

/// 担当イベントとそのrole(getMyAccessRoleのassignments)。
class EventAssignment {
  const EventAssignment({required this.eventId, required this.role});
  final String eventId;
  final EventRole role;
}

class AccessCheck {
  const AccessCheck._(this.outcome, this.role, [this.assignments = const []]);
  const AccessCheck.granted(
    AccessRole role, {
    List<EventAssignment> assignments = const [],
  }) : this._(AccessOutcome.granted, role, assignments);

  /// 全体のroleは無く、イベント単位の権限(担当イベント)だけを持つ(イベント管理者・スタッフ)。
  const AccessCheck.eventScoped(List<EventAssignment> assignments)
    : this._(AccessOutcome.granted, null, assignments);
  const AccessCheck.denied() : this._(AccessOutcome.denied, null);
  const AccessCheck.unauthenticated()
    : this._(AccessOutcome.unauthenticated, null);
  const AccessCheck.error() : this._(AccessOutcome.error, null);

  final AccessOutcome outcome;

  /// 全体のrole(accessRoles)。admin=システム管理者。イベント単位の権限だけのユーザーはnull。
  final AccessRole? role;

  /// 有効な担当イベント(サーバーが確認したものだけ)。
  final List<EventAssignment> assignments;

  bool get isSystemAdmin => role == AccessRole.admin;

  /// イベントごとのrole(無ければnull)。システム管理者はここに含まれない(全イベントを扱える)。
  EventRole? roleFor(String eventId) {
    for (final assignment in assignments) {
      if (assignment.eventId == eventId) return assignment.role;
    }
    return null;
  }
}
