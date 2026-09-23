// 「受付」の入口(PC・イベント管理画面から開く)。
//
// ■ 目的はこの画面だけ: PCブラウザのカメラは絶対に起動しない(getUserMediaを一切呼ばない。カメラ関連の
//   widget(WebQrCameraView・ConfirmedQrScannerView等)をこのファイルは一切importしない)。
//   表示するのは「受付スタッフ用QR」の画像と案内文だけ。
// ■ 「受付スタッフ用QR」は、受付スタッフのスマートフォンを、このイベントに固定された既存のスマホ受付スキャナ
//   (`/console/scan?eventId=…`。既存のConfirmedScanReceptionRoute・AuthGate・staffOrAdmin認可はそのまま)
//   へ導くだけのURLで、参加者の受付QR(functions/confirmed/pass_urls.js の receptionQrPayload。
//   {base}/reception?eventId=…&participantId=…&publicId=…)とは別物。
//   participantId・publicIdは一切含めない(このQRは「参加者」を特定するものではない)。
// ■ QR画像の生成は、参加証(pass_page.dart)が既に使っているqr_flutter(既存のpub依存)をそのまま
//   クライアント側で再利用する。新しい依存もサーバー側のQR生成(generateQrPng)も使わない
//   (URLはeventIdと現在の配信元だけから決まる、個人情報を含まない文字列のため)。

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/common.dart';

class ConfirmedReceptionStaffQrPage extends StatelessWidget {
  const ConfirmedReceptionStaffQrPage({
    super.key,
    required this.eventId,
    required this.eventName,
    this.baseUri,
  });

  final String eventId;
  final String eventName;

  /// テスト用の差し替え口(省略時は実行時の`Uri.base`=実際の配信元を使う)。
  final Uri? baseUri;

  /// 受付スタッフのスマートフォンを導く先。既存のスマホ受付スキャナのURLをそのまま再利用する
  /// (新しい受付方式・新しいルートは作らない)。
  String get _staffScanUrl => (baseUri ?? Uri.base)
      .replace(path: '/console/scan', queryParameters: {'eventId': eventId})
      .toString();

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '受付',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              eventName,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text(
              '受付スタッフ用QRコード',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              '受付スタッフのスマートフォンで、このQRを読み取ってください。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            const Text(
              'このPCではカメラを使用しません。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xff5c6670)),
            ),
            const SizedBox(height: 24),
            Center(
              child: QrImageView(
                // keyにも同じURLを持たせる(テストが、表示中のQRの中身をそのまま確認できるようにする)。
                key: ValueKey('reception-staff-qr:$_staffScanUrl'),
                data: _staffScanUrl,
                size: 260,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'スマートフォン側では、ログイン(受付スタッフ・管理者)のあと、このイベント専用のカメラが起動し、'
              '参加者から提示された受付QRを読み取れます。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xff5c6670)),
            ),
          ],
        ),
      ),
    ),
  );
}
