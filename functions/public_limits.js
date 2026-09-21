// 公開callable(ログイン不要の5本)の濫用防止の上限値を、ここ1か所に集約する(Phase 10D)。数値を他のファイルへ散在させない。
// 用途が違うため、同じ上限にしていない:
//   view    : 参加証・マイページの閲覧(読み取り専用)
//   update  : 参加者本人の状態更新(正式登録・参加予定の回答。冪等だが書込みを伴う)
//   walkIn  : 当日参加登録(新規データ作成+外部メール送信を伴う。最も厳しい)
// scope: "ip"(接続元。HMAC化して保存)/ "target"(参加者ID・メールアドレス等の対象。HMAC化して保存)
// onError: rate limitの保存先(Firestore)に障害があったときの方針
//   "open"   = 制限なしで処理を続ける(読み取り専用の閲覧。publicIdの照合は別に必須のため、可用性を優先)
//   "closed" = 拒否する(書込み・メール送信を伴うもの。判定できないなら実行しない)
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const RATE_LIMIT_POLICIES = Object.freeze({
  viewIp: Object.freeze({name: "viewIp", scope: "ip", windowMs: MINUTE, limit: 30, onError: "open"}),
  viewTarget: Object.freeze({name: "viewTarget", scope: "target", windowMs: MINUTE, limit: 10, onError: "open"}),
  updateIp: Object.freeze({name: "updateIp", scope: "ip", windowMs: MINUTE, limit: 10, onError: "closed"}),
  updateTarget: Object.freeze({name: "updateTarget", scope: "target", windowMs: MINUTE, limit: 5, onError: "closed"}),
  walkInIp: Object.freeze({name: "walkInIp", scope: "ip", windowMs: HOUR, limit: 5, onError: "closed"}),
  walkInTarget: Object.freeze({name: "walkInTarget", scope: "target", windowMs: DAY, limit: 3, onError: "closed"}),
});

// 1つのイベントに対する、当日参加登録(walk-in)として作れる件数の上限(通常の事前登録の参加者は数えない)
const WALK_IN_EVENT_LIMIT = 500;

// rate limitの記録(rateLimits collection)の保持期間。TTLポリシー(expiresAt)を本番で設定するまでは、期限切れの文書が残る
const RATE_LIMIT_RETENTION_MS = 2 * DAY;

module.exports = {RATE_LIMIT_POLICIES, WALK_IN_EVENT_LIMIT, RATE_LIMIT_RETENTION_MS, MINUTE, HOUR, DAY};
