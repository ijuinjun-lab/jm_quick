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

class AccessCheck {
  const AccessCheck._(this.outcome, this.role);
  const AccessCheck.granted(AccessRole role)
    : this._(AccessOutcome.granted, role);
  const AccessCheck.denied() : this._(AccessOutcome.denied, null);
  const AccessCheck.unauthenticated()
    : this._(AccessOutcome.unauthenticated, null);
  const AccessCheck.error() : this._(AccessOutcome.error, null);

  final AccessOutcome outcome;
  final AccessRole? role;
}
