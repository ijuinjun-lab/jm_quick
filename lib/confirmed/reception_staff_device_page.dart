// 受付端末の入口(`/reception/staff?eventId=…&key=…`。PCの「受付スタッフ用QR」を読み取ったスマートフォンが開く)。
//
// ■ JM Quickのアカウント・ログインは不要(AuthGateを通さない。メールアドレス・パスワードの入力欄は出さない)。
//   QRのURLに含まれる受付キーを、サーバーが毎回検証する(対象イベントの受付だけ。管理機能・他イベント・訂正取消は不可)。
// ■ 順序: 受付キーの確認(getReceptionStaffSessionByStaffKey)→ そのイベントに固定した既存のQRカメラスキャナー
//   ([ConfirmedScanReceptionFlow]) → 既存の受付画面([ConfirmedReceptionPage]。受付キーのサービスを渡す)→
//   「次のQRを読み取る」でカメラへ戻る。受付ロジック・QRの検証・カメラは既存のものをそのまま使い、複製しない。
// ■ 受付キーは、この画面のURL(再読み込みしても同じ)とメモリ上にだけ保持する(端末のストレージへは保存しない)。
//   有効期限(発行から24時間)はサーバーが判定し、切れたら「もう一度QRを読み取ってください」と案内する。
// ■ 受付キーはログ・debugPrintへ出さない。

import 'package:flutter/material.dart';

import 'qr_scanner_page.dart';
import 'reception_page.dart';
import 'reception_service.dart';
import 'reception_staff_key_service.dart';

/// 受付キーのサービスを作る口(テストでは通信を差し替える)。
typedef ReceptionStaffKeyServiceFactory =
    ReceptionStaffKeyService Function(String eventId, String receptionKey);

class ReceptionStaffDeviceRoute extends StatefulWidget {
  const ReceptionStaffDeviceRoute({
    super.key,
    required this.eventId,
    required this.receptionKey,
    this.serviceFactory,
    this.surfaceBuilder,
    this.expectedHost,
  });

  final String? eventId;
  final String? receptionKey;
  final ReceptionStaffKeyServiceFactory? serviceFactory;

  /// カメラ部分の差し替え口(テスト用。既定は実カメラ)。
  final QrSurfaceBuilder? surfaceBuilder;

  /// 参加者QRのホスト検証に使う値(テスト用。既定は実行時の配信元)。
  final String? expectedHost;

  @override
  State<ReceptionStaffDeviceRoute> createState() =>
      _ReceptionStaffDeviceRouteState();
}

class _ReceptionStaffDeviceRouteState extends State<ReceptionStaffDeviceRoute> {
  late final String _eventId = (widget.eventId ?? '').trim();
  late final String _key = (widget.receptionKey ?? '').trim();
  late final ReceptionStaffKeyService? _service =
      _eventId.isEmpty || _key.isEmpty
      ? null
      : (widget.serviceFactory ??
            ((eventId, key) => ReceptionStaffKeyService(
              eventId: eventId,
              receptionKey: key,
            )))(_eventId, _key);
  late Future<ReceptionStaffSession>? _session = _service?.getSession();

  void _retry() => setState(() {
    _session = _service!.getSession();
  });

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (service == null) {
      return const _DeviceMessage(message: receptionStaffKeyInvalidMessage);
    }
    return FutureBuilder<ReceptionStaffSession>(
      future: _session,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) {
          final error = snapshot.error;
          final known = error is ReceptionException ? error : null;
          return _DeviceMessage(
            message: known?.message ?? '受付を開始できませんでした。もう一度お試しください。',
            // 受付キーが無効・期限切れなら、再試行しても変わらない(QRの読み直しを案内する)。
            onRetry: known?.code == 'reception-key-invalid' ? null : _retry,
          );
        }
        // 受付キーを確認できたら、ログイン画面・メニューを挟まず、このイベントに固定したカメラへ直接進む。
        return ConfirmedScanReceptionFlow(
          initialEventId: _eventId,
          expectedHost: widget.expectedHost,
          surfaceBuilder: widget.surfaceBuilder,
          receptionBuilder:
              ({
                required eventId,
                required participantId,
                required publicId,
                required onScanNext,
              }) => ConfirmedReceptionPage(
                // 訂正・取消(adminService)は渡さない。受付端末は初回受付だけ。
                service: service,
                eventId: eventId,
                participantId: participantId,
                publicId: publicId,
                onScanNext: onScanNext,
              ),
        );
      },
    );
  }
}

class _DeviceMessage extends StatelessWidget {
  const _DeviceMessage({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('受付')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              key: const Key('reception-staff-device-message'),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('再試行')),
            ],
          ],
        ),
      ),
    ),
  );
}
