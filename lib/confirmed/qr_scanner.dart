// 受付用QRカメラスキャナー: QR文字列(URL)の検証だけを行う純粋関数。カメラ・Firestore・callableには依存しない。
//
// ■ QRの形式はPhase 6のreceptionQrPayload(functions/confirmed/pass_urls.js)が唯一の正本で、ここでは一切変更しない:
//     {appBaseUrl}/reception?eventId={eventId}&participantId={participantId}&publicId={publicId}
// ■ ここでの検証はUX目的(他サイトのQR・無関係なQRを弾いて案内する)であって、セキュリティの正本ではない。
//   本人確認・受付権限・改ざん検知は、既存のサーバーAPI(getConfirmedReceptionView・checkInConfirmedProgram等)が必ず行う。
//   クライアント側の検証だけで「本人確認済み」として扱ってはならない。
// ■ 読み取ったQR文字列(rawValue)・eventId・participantId・publicIdは、ここでも呼び出し側でもログ・console・debugPrintへ出さない。

/// 受付QRから取り出した3つの識別子。値の妥当性(存在確認・改ざん検知)はサーバーが判定する。
class ScannedReceptionQr {
  const ScannedReceptionQr({
    required this.eventId,
    required this.participantId,
    required this.publicId,
  });
  final String eventId;
  final String participantId;
  final String publicId;

  @override
  bool operator ==(Object other) =>
      other is ScannedReceptionQr &&
      other.eventId == eventId &&
      other.participantId == participantId &&
      other.publicId == publicId;

  @override
  int get hashCode => Object.hash(eventId, participantId, publicId);
}

/// QRを受付用として受け付けられない理由。
enum QrRejectReason {
  /// URLとして解析できない、または JM Quick の受付URL(/reception)ではない(他サイト・無関係なQR)。
  notReceptionUrl,
  eventIdMissing,
  participantIdMissing,
  publicIdMissing,
}

/// [parseReceptionQrPayload] の結果。[isValid] が true のときだけ [value] が入る。
class QrParseResult {
  const QrParseResult._(this.value, this.reason);
  const QrParseResult.valid(ScannedReceptionQr value) : this._(value, null);
  const QrParseResult.rejected(QrRejectReason reason) : this._(null, reason);
  final ScannedReceptionQr? value;
  final QrRejectReason? reason;
  bool get isValid => value != null;
}

/// カメラが読み取った文字列(rawValue)を、受付用QRとして検証する。
/// [expectedHost] を渡すと、そのホスト(JM Quickの配信元)と一致しないURLも拒否する(大文字小文字は無視)。
/// 省略時はホストを検証しない(ホストが分からない環境向け。パス・パラメータの検証は必ず行う)。
QrParseResult parseReceptionQrPayload(String raw, {String? expectedHost}) {
  final uri = Uri.tryParse(raw.trim());
  final looksLikeReceptionUrl =
      uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.path == '/reception' &&
      (expectedHost == null || uri.host.toLowerCase() == expectedHost.toLowerCase());
  if (!looksLikeReceptionUrl) {
    return const QrParseResult.rejected(QrRejectReason.notReceptionUrl);
  }
  final eventId = uri.queryParameters['eventId'];
  if (eventId == null || eventId.isEmpty) {
    return const QrParseResult.rejected(QrRejectReason.eventIdMissing);
  }
  final participantId = uri.queryParameters['participantId'];
  if (participantId == null || participantId.isEmpty) {
    return const QrParseResult.rejected(QrRejectReason.participantIdMissing);
  }
  final publicId = uri.queryParameters['publicId'];
  if (publicId == null || publicId.isEmpty) {
    return const QrParseResult.rejected(QrRejectReason.publicIdMissing);
  }
  return QrParseResult.valid(
    ScannedReceptionQr(eventId: eventId, participantId: participantId, publicId: publicId),
  );
}

/// スタッフ向けに表示する、拒否理由ごとの案内文(内部コード・QR全文・IDは出さない)。
String qrRejectMessage(QrRejectReason reason) => switch (reason) {
  QrRejectReason.notReceptionUrl =>
    'このQRはJM Quickの受付用ではありません。参加者の受付QR(参加証)を読み取ってください。',
  QrRejectReason.eventIdMissing ||
  QrRejectReason.participantIdMissing ||
  QrRejectReason.publicIdMissing =>
    'このQRは受付に必要な情報が不足しています。参加証のQRを読み取ってください。',
};

/// 現在受付中のイベントと異なるイベントのQRを読んだときの案内。
const String qrDifferentEventMessage =
    '別のイベントの参加証です。現在受付中のイベントとは異なるため、この画面では受付できません。';
