// confirmed受付QRスキャナーのカメラ表示Widget。実装はWeb専用(dart:js_interop・package:webを使う
// web_qr_camera_web.dart)で、VM実行時(flutter test / flutter analyze)は web_qr_camera_stub.dart が使われる
// (conditional import。dart.library.js_interopは、dart2js/dartdevc/dart2wasmなどのWebターゲットでのみtrue)。
//
// 責務: [WebCameraGateway]を使ってカメラを開始・終了し、検出した文字列をそのまま[onDetected]へ渡すだけ。
// QRの検証・別event判定・重複scan防止・受付画面への接続は、呼び出し側(qr_scanner_page.dart)の責務。

import 'dart:async';

import 'package:flutter/material.dart';

import 'qr_scanner.dart' show QrCameraProblem;
import 'web_qr_camera_gateway.dart';
import 'web_qr_camera_stub.dart'
    if (dart.library.js_interop) 'web_qr_camera_web.dart'
    as impl;

export 'web_qr_camera_gateway.dart' show WebCameraException, WebCameraGateway;

typedef WebCameraGatewayFactory = WebCameraGateway Function();

/// カメラを起動し、検出した文字列をそのまま[onDetected]へ渡す。起動できない場合は[onProblem]を呼ぶ
/// (UI表示は呼び出し側。ここでは判定・表示を行わない)。
class WebQrCameraView extends StatefulWidget {
  const WebQrCameraView({
    super.key,
    required this.onDetected,
    required this.onProblem,
    WebCameraGatewayFactory? gatewayFactory,
  }) : _gatewayFactory = gatewayFactory;

  final void Function(String rawValue) onDetected;
  final void Function(QrCameraProblem problem) onProblem;

  /// テスト用。既定は実カメラ(Web)、非Web(VM)では常にunsupportedを返すgateway。
  final WebCameraGatewayFactory? _gatewayFactory;

  @override
  State<WebQrCameraView> createState() => _WebQrCameraViewState();
}

class _WebQrCameraViewState extends State<WebQrCameraView> {
  late final WebCameraGateway _gateway =
      (widget._gatewayFactory ?? impl.createWebCameraGateway)();
  bool _ready = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _gateway.open(
        onDetect: (rawValue) {
          if (!_disposed) widget.onDetected(rawValue);
        },
      );
      if (!_disposed && mounted) setState(() => _ready = true);
    } on WebCameraException catch (e) {
      if (!_disposed) widget.onProblem(e.problem);
    } on Object {
      if (!_disposed) widget.onProblem(QrCameraProblem.generic);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // カメラを終了する(MediaStreamTrackの解放)。完了を待たずにdisposeを終える(disposeは同期的であるべきため)。
    unawaited(_gateway.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ready ? _gateway.buildPreview() : const SizedBox.shrink();
}
