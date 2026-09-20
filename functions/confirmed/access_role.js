// getMyAccessRole: ログイン中のユーザー自身のロールを返す、新方式最初の認証callableのハンドラ。
// 認可(ログイン済み + accessRoles/{uid}.active === true + roleがadmin/staff)は confirmedCallable が済ませており、
// このハンドラに届くidentityはサーバー側で確定した値。副作用はない(読み取りのみ)。
// 返すのは「ログイン済みか」と「ロール」だけ。uid・メールアドレスなど不要な情報は返さない。
function getMyAccessRoleHandler({identity}) {
  return {authenticated: true, role: identity.role};
}

module.exports = {getMyAccessRoleHandler};
