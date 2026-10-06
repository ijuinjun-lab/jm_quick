// 「受付」の入口(PC・イベント管理画面から開く)。
//
// ■ 目的はこの画面だけ: PCブラウザのカメラは絶対に起動しない(getUserMediaを一切呼ばない。カメラ関連の
//   widget(WebQrCameraView・ConfirmedQrScannerView等)をこのファイルは一切importしない)。
//   表示するのは「受付スタッフ用QR」の画像と案内文だけ。
// ■ 「受付スタッフ用QR」は、受付スタッフのスマートフォンを、このイベント専用の受付端末にするURL
//   (`/reception/staff?eventId=…&key=…`。ReceptionStaffDeviceRoute)。受付スタッフはJM Quickのアカウント・
//   ログインが不要で、QRを読んだ端末は「このイベントの受付」だけを行える(管理機能・他イベントは不可)。
//   keyはサーバー(issueReceptionStaffKey。この画面を開いた人の正式ログインと、対象イベントのstaff以上を検証)が
//   発行した、このイベント専用の受付キー(有効期限24時間)。ログイン中の人のIDトークン・セッション・パスワードは含めない。
//   同じイベントでは、有効期限内は同じQRになる(何台のスマートフォンで読み取っても同じ。1回で失効しない)。
//   参加者の受付QR(functions/confirmed/pass_urls.js の receptionQrPayload)とは別物で、参加者を特定する値は一切含めない。
// ■ QR画像の生成は、参加証(pass_page.dart)が既に使っているqr_flutter(既存のpub依存)をそのまま
//   クライアント側で再利用する。新しい依存もサーバー側のQR生成(generateQrPng)も使わない。

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/common.dart';
import 'auth_client.dart';
import 'reception_service.dart';
import 'reception_staff_key_service.dart';

/// 受付スタッフ用QRが指す、受付端末の入口のパス。
const String receptionStaffDevicePath = '/reception/staff';

/// 受付スタッフ用QRのURL(配信元 + 受付端末の入口 + eventId + 受付キー)。
String receptionStaffDeviceUrl(Uri base, String eventId, String key) => Uri(
  scheme: base.scheme,
  host: base.host,
  port: base.hasPort ? base.port : null,
  path: receptionStaffDevicePath,
  queryParameters: {'eventId': eventId, 'key': key},
).toString();

class ConfirmedReceptionStaffQrPage extends StatefulWidget {
  ConfirmedReceptionStaffQrPage({
    super.key,
    required this.eventId,
    required this.eventName,
    ReceptionStaffKeyIssuer? issuer,
    this.baseUri,
  }) : issuer =
           issuer ??
           CallableReceptionStaffKeyIssuer(authClient: FirebaseAuthClient());

  final String eventId;
  final String eventName;

  /// 受付キーの取得(既定はサーバーのissueReceptionStaffKey。テストでは差し替える)。
  final ReceptionStaffKeyIssuer issuer;

  /// テスト用の差し替え口(省略時は実行時の`Uri.base`=実際の配信元を使う)。
  final Uri? baseUri;

  @override
  State<ConfirmedReceptionStaffQrPage> createState() =>
      _ConfirmedReceptionStaffQrPageState();
}

class _ConfirmedReceptionStaffQrPageState
    extends State<ConfirmedReceptionStaffQrPage> {
  late Future<ReceptionStaffKey> _key = widget.issuer.issue(widget.eventId);

  void _retry() => setState(() {
    _key = widget.issuer.issue(widget.eventId);
  });

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
              widget.eventName,
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
            FutureBuilder<ReceptionStaffKey>(
              future: _key,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 260,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final key = snapshot.data;
                if (key == null) {
                  final error = snapshot.error;
                  return Column(
                    children: [
                      Text(
                        error is ReceptionException
                            ? error.message
                            : '受付スタッフ用QRを表示できませんでした。もう一度お試しください。',
                        key: const Key('reception-staff-qr-error'),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _retry, child: const Text('再試行')),
                    ],
                  );
                }
                final url = receptionStaffDeviceUrl(
                  widget.baseUri ?? Uri.base,
                  widget.eventId,
                  key.key,
                );
                return Column(
                  children: [
                    Center(
                      child: QrImageView(
                        // keyにも同じURLを持たせる(テストが、表示中のQRの中身をそのまま確認できるようにする)。
                        key: ValueKey('reception-staff-qr:$url'),
                        data: url,
                        size: 260,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '有効期限: ${_formatExpiry(key.expiresAt)} まで',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xff5c6670)),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            const Text(
              'スマートフォン側では、ログインは不要です。このイベント専用の受付カメラがすぐに起動し、'
              '参加者から提示された受付QRを続けて読み取れます。同じQRを複数のスマートフォンで読み取れます。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xff5c6670)),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 有効期限の表示(JST・M/d HH:mm)。
String _formatExpiry(DateTime at) {
  final jst = at.toUtc().add(const Duration(hours: 9));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${jst.month}/${jst.day} ${two(jst.hour)}:${two(jst.minute)}';
}
