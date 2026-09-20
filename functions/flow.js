// イベント方式(flow)の判定。Firebase/Firestoreに依存しない純粋関数だけを置く。
//
// - flow未設定 / null / "" / "legacy" → 従来方式(legacy)
// - flow === "confirmed"              → 新方式(当選確定済みイベント)
// - それ以外の値(タイプミス等)         → 「未知」。legacyでもconfirmedでもない。
//
// 旧機能(旧Scheduler・旧一括メール・個別案内メール・当日参加登録)は
// 「legacyと確定できるイベント」だけを対象にする。未知の値は安全側(対象外)に倒す。

const FLOW_CONFIRMED = "confirmed";

function isLegacyFlow(event) {
  const flow = event?.flow;
  return flow === undefined || flow === null || flow === "" || flow === "legacy";
}

function isConfirmedFlow(event) {
  return event?.flow === FLOW_CONFIRMED;
}

// 旧Schedulerが「参加予定確認メール」を送る対象期間内かどうか。
// 従来の判定(confirmationSendAt <= now < startAt)に、legacy限定のguardを加えたもの。
function legacyConfirmationDue(event, now) {
  if (!isLegacyFlow(event)) return false;
  const sendAt = event?.confirmationSendAt?.toDate?.();
  const startAt = event?.startAt?.toDate?.();
  if (!sendAt || !startAt || now < sendAt || now >= startAt) return false;
  return true;
}

module.exports = {
  FLOW_CONFIRMED,
  isLegacyFlow,
  isConfirmedFlow,
  legacyConfirmationDue,
};
