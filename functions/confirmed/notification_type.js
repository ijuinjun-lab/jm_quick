// 取込回(importBatch)の通知種別。純粋関数のみ。
//
// ■ 通知種別は取込回ごとに1つ(1つの取込回に混在させない)。取込回の作成時に1回だけ保存し、変更するAPIは無い。
//   normal            … 通常当選(当選メール = event.winnerMailTemplate)
//   waitlistPromotion … キャンセル待ち繰り上げ当選(当選メール = event.waitlistWinnerMailTemplate)
// ■ 項目の無い既存の取込回(この機能より前の取込)は normal として扱う(移行はしない)。
// ■ 送信ジョブは、取込回の正本の通知種別からテンプレートを決める(クライアントの指定は受け付けない)。

const NOTIFICATION_TYPES = Object.freeze({NORMAL: "normal", WAITLIST_PROMOTION: "waitlistPromotion"});
const NOTIFICATION_TYPE_VALUES = Object.freeze(Object.values(NOTIFICATION_TYPES));
const NOTIFICATION_TYPE_LABELS = Object.freeze({
  [NOTIFICATION_TYPES.NORMAL]: "通常当選",
  [NOTIFICATION_TYPES.WAITLIST_PROMOTION]: "キャンセル待ち繰り上げ当選",
});
const TEMPLATE_FIELDS = Object.freeze({
  [NOTIFICATION_TYPES.NORMAL]: "winnerMailTemplate",
  [NOTIFICATION_TYPES.WAITLIST_PROMOTION]: "waitlistWinnerMailTemplate",
});

// 取込回(またはジョブ・配送記録)の文書 → 通知種別。項目が無い・想定外の値は normal(既存の取込回)。
function notificationTypeOf(doc) {
  return doc && doc.notificationType === NOTIFICATION_TYPES.WAITLIST_PROMOTION ?
    NOTIFICATION_TYPES.WAITLIST_PROMOTION : NOTIFICATION_TYPES.NORMAL;
}

const templateFieldFor = (type) => TEMPLATE_FIELDS[type] || TEMPLATE_FIELDS[NOTIFICATION_TYPES.NORMAL];
const notificationTypeLabel = (type) => NOTIFICATION_TYPE_LABELS[type] || NOTIFICATION_TYPE_LABELS[NOTIFICATION_TYPES.NORMAL];

module.exports = {NOTIFICATION_TYPES, NOTIFICATION_TYPE_VALUES, NOTIFICATION_TYPE_LABELS, TEMPLATE_FIELDS, notificationTypeOf,
  templateFieldFor, notificationTypeLabel};
