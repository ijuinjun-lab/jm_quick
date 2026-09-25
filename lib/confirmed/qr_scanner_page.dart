// confirmed受付用のQRカメラスキャナー(staff/admin専用)。
//
// ■ 責務はここまで: カメラ → QR文字列取得 → URL検証([qr_scanner.dart]) → 既存の[ReceptionRoutePage]へ渡す。
//   受付・program別受付・二重受付防止・plannedCount等のロジックは一切複製しない(既存Functions・既存画面が正本)。
// ■ QR仕様(payloadの形式)はここでは変更しない。参加者側の参加証・QR生成にもカメラ機能は追加しない(スタッフ専用)。
// ■ カメラ本体は[WebQrCameraView](web_qr_camera.dart。JM Quickが<video>要素を自前で所有し、playsInline/muted/
//   autoplayを明示してiPhone Safariの黒画面不具合〈package:mobile_scannerの既知issue〉を回避する)を使う。
//   実カメラ部分は単体では自動テストできない(実ブラウザが無い環境のため)。検出後の遷移・拒否判定・エラー表示の
//   内容は、カメラに依存しない形でテストできるように分離してある([ConfirmedScanReceptionFlow]は[surfaceBuilder]で、
//   [_WebCameraSurface]は[WebQrCameraView]のgatewayFactoryで、それぞれカメラ部分を差し替えられる)。
// ■ QR全文・eventId・participantId・publicIdは、ここでもログ・debugPrintへ出さない。

import 'package:flutter/material.dart';

import '../pages/reception_page.dart' as legacy;
import 'access_service.dart';
import 'assignment_pages.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'qr_scanner.dart';
import 'reception_route.dart';
import 'web_qr_camera.dart';

/// `/console/scan`: staff/adminが受付用QRをスマートフォンのカメラで読み取る入口。
/// 未認証・受付権限のない利用者は使用できない(既存の[AuthGate]と同じ境界)。
///
/// [eventId]は任意(イベント選択後の管理画面「受付」から `?eventId=…` で渡される。内部的な引き継ぎのみで、
/// 利用者が入力・コピーする欄は無い)。指定があれば、最初のQRを読み取る前からそのイベントへscannerを固定する
/// (詳細は[ConfirmedScanReceptionFlow]参照)。指定が無ければ従来どおり、最初に読み取ったQRのイベントへ固定する
/// (`/console/scan`への直リンク・ブックマーク等)。
class ConfirmedScanReceptionRoute extends StatelessWidget {
  ConfirmedScanReceptionRoute({
    super.key,
    this.eventId,
    AuthClient? authClient,
    this.accessService,
  }) : authClient = authClient ?? FirebaseAuthClient();

  final String? eventId;
  final AuthClient authClient;
  final AccessService? accessService;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        accessService ?? CallableAccessService(authClient: authClient),
    // staff/adminのどちらも使用可能(初回受付はstaffOrAdmin。訂正・取消はConfirmedReceptionPage側でadminのみ描画される)。
    adminBuilder: (context, signOut) =>
        ConfirmedScanReceptionFlow(initialEventId: eventId),
    staffBuilder: (context, signOut) =>
        ConfirmedScanReceptionFlow(initialEventId: eventId),
    // Phase 3: イベント管理者・スタッフは担当イベントの受付だけ(サーバーも担当外を拒否する)。
    // eventIdが無く担当が1件なら、そのイベントへ固定する(担当が複数なら従来どおり最初に読み取ったQRのイベントへ固定)。
    eventScopedBuilder: (context, signOut, assignments) {
      final id = (eventId ?? '').trim();
      if (id.isNotEmpty && !assignments.any((a) => a.eventId == id)) {
        return EventScopeDenied(
          title: '受付',
          message: 'このイベントの受付を行う権限がありません。',
          signOut: signOut,
        );
      }
      final fixed = id.isNotEmpty
          ? id
          : (assignments.length == 1 ? assignments.single.eventId : null);
      return ConfirmedScanReceptionFlow(initialEventId: fixed);
    },
  );
}

/// scanner ↔ 受付画面 の往復を管理する。1回の有効なQRごとに既存の[ReceptionRoutePage]を1つ表示し、
/// 「次のQRを読み取る」でscanner側へ戻る(トップ画面まで戻らない)。
///
/// 同一セッション中は、eventIdへ「固定」する。[initialEventId]が指定されていれば、最初のQRを読み取る前
/// からそのイベントへ固定する(イベント選択後の管理画面「受付」から渡される。利用者の入力・コピーは無い)。
/// 指定が無ければ、従来どおり最初に読み取ったQRのeventIdへ固定する。異なるイベントのQRは
/// [qrDifferentEventMessage] を表示して拒否し、誤って別イベントへ進まないようにする。
class ConfirmedScanReceptionFlow extends StatefulWidget {
  const ConfirmedScanReceptionFlow({
    super.key,
    this.expectedHost,
    this.initialEventId,
    QrSurfaceBuilder? surfaceBuilder,
    ReceptionScreenBuilder? receptionBuilder,
  }) : _surfaceBuilder = surfaceBuilder,
       _receptionBuilder = receptionBuilder;

  /// QRのホスト検証に使う値。省略時は実行時の[Uri.base]のホストを使う(テストでは明示的に渡す)。
  final String? expectedHost;

  /// 指定があれば、最初のQRを読み取る前からこのeventIdへscannerを固定する(任意)。
  final String? initialEventId;
  final QrSurfaceBuilder? _surfaceBuilder;
  final ReceptionScreenBuilder? _receptionBuilder;

  @override
  State<ConfirmedScanReceptionFlow> createState() =>
      _ConfirmedScanReceptionFlowState();
}

/// [ConfirmedScanReceptionFlow]が、有効なQRを受理した後に受付画面を作るための差し替え口(テスト用)。
/// 既定は実際の[ReceptionRoutePage](= /reception と同じ画面遷移。受付ロジックの複製はしない)。
typedef ReceptionScreenBuilder =
    Widget Function({
      required String eventId,
      required String participantId,
      required String publicId,
      required VoidCallback onScanNext,
    });

enum _Phase { scanning, reception }

class _ConfirmedScanReceptionFlowState
    extends State<ConfirmedScanReceptionFlow> {
  _Phase _phase = _Phase.scanning;
  // イベント選択後の管理画面から開いた場合は、最初からそのeventIdへ固定する(未指定なら最初のQRで決まる)。
  late String? _lockedEventId = (widget.initialEventId ?? '').trim().isEmpty
      ? null
      : widget.initialEventId!.trim();
  ScannedReceptionQr? _scanned;
  String? _message;
  bool _accepted = false; // 有効なQRを受理して遷移するまで、以降の検出をすべて無視する(重複scan防止)。
  int _scannerGeneration = 0; // scannerを作り直す(カメラを再起動する)ためのkey。

  String? get _host {
    final override = widget.expectedHost;
    if (override != null) return override;
    final host = Uri.base.host;
    return host.isEmpty ? null : host;
  }

  void _onRaw(String raw) {
    if (_accepted) return; // 遷移が確定するまで、同じ/別のQRを何度検出しても処理は1回だけ。
    final result = parseReceptionQrPayload(raw, expectedHost: _host);
    if (!result.isValid) {
      _showMessage(qrRejectMessage(result.reason!));
      return;
    }
    final parsed = result.value!;
    final locked = _lockedEventId;
    if (locked != null && parsed.eventId != locked) {
      _showMessage(qrDifferentEventMessage);
      return;
    }
    _accepted = true;
    _lockedEventId ??= parsed.eventId;
    setState(() {
      _message = null;
      _scanned = parsed;
      _phase = _Phase.reception;
    });
  }

  void _showMessage(String text) {
    if (_message == text) return; // 同じ理由を毎フレーム再描画しない。
    setState(() => _message = text);
  }

  void _resumeScanning() {
    setState(() {
      _accepted = false;
      _message = null;
      _scanned = null;
      _phase = _Phase.scanning;
      _scannerGeneration += 1; // 新しいscanner(新しいカメラ)を作り直す。
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.reception) {
      final scanned = _scanned!;
      final builder = widget._receptionBuilder ?? _defaultReceptionBuilder;
      return builder(
        eventId: scanned.eventId,
        participantId: scanned.participantId,
        publicId: scanned.publicId,
        onScanNext: _resumeScanning,
      );
    }
    return ConfirmedQrScannerView(
      key: ValueKey(_scannerGeneration),
      message: _message,
      onRaw: _onRaw,
      surfaceBuilder: widget._surfaceBuilder,
    );
  }

  Widget _defaultReceptionBuilder({
    required String eventId,
    required String participantId,
    required String publicId,
    required VoidCallback onScanNext,
  }) => ReceptionRoutePage(
    eventId: eventId,
    participantId: participantId,
    publicId: publicId,
    onScanNext: onScanNext,
    // 従来方式(legacy)のQRを読んだ場合は、/reception と同じ従来の受付画面へ(scanner独自の分岐は作らない)。
    legacyBuilder: (_) => legacy.ReceptionPage(
      eventId: eventId,
      participantId: participantId,
      publicId: publicId,
    ),
  );
}

/// カメラ部分(_WebCameraSurface)を差し替えるための型。既定は実カメラ、テストでは差し替える。
typedef QrSurfaceBuilder =
    Widget Function(
      BuildContext context, {
      required void Function(String rawValue) onRaw,
    });

/// カメラ映像 + 読み取り範囲の枠 + 案内文 + 閉じるボタンを表示する画面。
/// 検出したQRの検証・遷移判断は行わない([ConfirmedScanReceptionFlow]の責務)。
class ConfirmedQrScannerView extends StatelessWidget {
  const ConfirmedQrScannerView({
    super.key,
    required this.onRaw,
    this.message,
    this.surfaceBuilder,
  });

  final void Function(String rawValue) onRaw;

  /// 直前の検出に対する案内(拒否理由等)。nullなら既定のヒントを表示する。
  final String? message;
  final QrSurfaceBuilder? surfaceBuilder;

  @override
  Widget build(BuildContext context) {
    final surface = (surfaceBuilder ?? _defaultSurfaceBuilder)(
      context,
      onRaw: onRaw,
    );
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('受付QRを読み取る'),
        leading: IconButton(
          key: const Key('scanner-close'),
          icon: const Icon(Icons.close),
          tooltip: '閉じる',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          surface,
          const _ScanFrameOverlay(),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  key: message != null
                      ? const Key('scanner-message')
                      : const Key('scanner-hint'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    message ?? '枠の中に、参加者の受付QR(参加証)を写してください。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: message != null
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _defaultSurfaceBuilder(
    BuildContext context, {
    required void Function(String) onRaw,
  }) => _WebCameraSurface(onRaw: onRaw);
}

/// 読み取り範囲が分かるよう、中央に枠を表示するだけの装飾(検出ロジックには関与しない)。
class _ScanFrameOverlay extends StatelessWidget {
  const _ScanFrameOverlay();
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: Container(
        width: 240,
        height: 240,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white, width: 3),
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
  );
}

/// カメラ権限拒否・カメラ利用不可時の案内。特定のカメラ実装に依存しない単体の表示部品(単体テストできる)。
/// [QrCameraProblem]自体は[qr_scanner.dart]で定義(web_qr_camera_*.dartからも参照するため)。
class QrCameraErrorView extends StatelessWidget {
  const QrCameraErrorView({super.key, required this.problem, this.onRetry});
  final QrCameraProblem problem;
  final VoidCallback? onRetry;

  String get _message => switch (problem) {
    QrCameraProblem.permissionDenied => 'カメラを利用できません。ブラウザのカメラ権限を確認してください。',
    QrCameraProblem.unsupported =>
      'この端末・ブラウザではQRカメラを利用できません。受付用QRのリンク(またはお使いのカメラアプリでの読み取り)から直接開いてご利用ください。',
    QrCameraProblem.generic => 'カメラを起動できませんでした。もう一度お試しください。',
  };

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam_off, color: Colors.white70, size: 40),
          const SizedBox(height: 16),
          Text(
            _message,
            key: const Key('scanner-camera-error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('scanner-camera-retry'),
              onPressed: onRetry,
              child: const Text('再試行'),
            ),
          ],
        ],
      ),
    ),
  );
}

/// 実カメラ([WebQrCameraView]。JM Quickが<video>要素を自前で所有するWeb実装)を使う本番用のスキャナー面。
/// 実カメラ部分は単体では自動テストしない(実ブラウザが無い環境のため。テストは[gatewayFactory]で差し替える)。
/// エラー時は[QrCameraErrorView]を表示し、「再試行」は[WebQrCameraView]を作り直す(新しいkeyでgetUserMediaを再実行)。
class _WebCameraSurface extends StatefulWidget {
  const _WebCameraSurface({required this.onRaw});
  final void Function(String rawValue) onRaw;

  @override
  State<_WebCameraSurface> createState() => _WebCameraSurfaceState();
}

class _WebCameraSurfaceState extends State<_WebCameraSurface> {
  int _generation = 0; // 「再試行」のたびに新しいWebQrCameraViewを作り、カメラの取得からやり直す。
  QrCameraProblem? _problem;

  void _handleProblem(QrCameraProblem problem) {
    if (mounted) setState(() => _problem = problem);
  }

  void _retry() {
    setState(() {
      _problem = null;
      _generation += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    if (problem != null) {
      // カメラ非対応(unsupported)は再試行しても変わらないため、再試行ボタンは出さない。
      return QrCameraErrorView(
        problem: problem,
        onRetry: problem == QrCameraProblem.unsupported ? null : _retry,
      );
    }
    return WebQrCameraView(
      key: ValueKey(_generation),
      onDetected: widget.onRaw,
      onProblem: _handleProblem,
    );
  }
}
