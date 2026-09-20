// メール生成テスト用の完全な架空データ(実在の氏名・メール・会場は一切含まない)。
const {receptionQrPayload} = require("../pass_urls");

const APP_BASE_URL = "https://app.invalid";
const PUBLIC_ID = "pub_0123456789abcdef0123456789abcdef";

// event(Firestoreの文書と同じ形)。programsは意図的にorder順と異なる並びにしてある。
function makeEvent(overrides = {}) {
  return {
    eventId: "event1", eventName: "架空イベント", senderName: "架空事務局", flow: "confirmed",
    startAt: new Date("2026-11-30T01:00:00Z"), endAt: new Date("2026-11-30T07:00:00Z"),
    venue: "架空会場ホール", contact: "架空事務局 support@example.invalid",
    venueInfo: {address: "〒000-0000 架空県架空市1-2-3", access: "架空駅から徒歩5分"},
    programs: [
      {programId: "talk", name: "トークセッション", order: 2, startAt: new Date("2026-11-30T04:00:00Z"), endAt: new Date("2026-11-30T05:00:00Z")},
      {programId: "alpha", name: "プログラムA", order: 0},
      {programId: "beta", name: "プログラムB", order: 1},
    ],
    winnerMailTemplate: {subject: "【ご参加確定】架空イベント", introBody: "このたびは当選おめでとうございます。", closingBody: "当日お会いできるのを楽しみにしています。",
      notesBody: "駐車場はありません。", version: 1},
    ...overrides,
  };
}

const participant = (overrides = {}) => ({participantId: "batchA-000002", eventId: "event1", name: "架空 太郎", publicId: PUBLIC_ID, email: "p1@example.invalid", status: "active", ...overrides});
const attendance = (programId, plannedCount, extra = {}) => ({eventId: "event1", participantId: "batchA-000002", programId, plannedCount, slotLabel: null, startAt: null, endAt: null, ...extra});
const attendances = () => [attendance("talk", 2), attendance("alpha", 1, {slotLabel: "10:00〜10:40"}), attendance("beta", 3, {startAt: new Date("2026-11-30T02:00:00Z"), endAt: new Date("2026-11-30T02:40:00Z")})];

// テスト用のQR PNG生成(内容の検証は別のテスト。ここでは payload に依存する決定的なバイト列を返す)
const fakeQrPng = async (payload) => Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.from(`FAKE:${payload}`)]);

const payloadFor = (p = participant()) => receptionQrPayload({appBaseUrl: APP_BASE_URL, eventId: p.eventId, participantId: p.participantId, publicId: p.publicId});

module.exports = {APP_BASE_URL, PUBLIC_ID, makeEvent, participant, attendance, attendances, fakeQrPng, payloadFor};
