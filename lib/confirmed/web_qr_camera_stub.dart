// web_qr_camera.dartのconditional importで、Web以外(このアプリでは実質flutter test/flutter analyzeのVM実行時)
// にだけ使われる代替。実カメラには一切接続しない(dart:js_interop・package:webを読み込まない)。

import 'package:flutter/widgets.dart';

import 'qr_scanner.dart' show QrCameraProblem;
import 'web_qr_camera_gateway.dart';

WebCameraGateway createWebCameraGateway() => const _UnsupportedCameraGateway();

class _UnsupportedCameraGateway implements WebCameraGateway {
  const _UnsupportedCameraGateway();

  @override
  Future<void> open({required void Function(String rawValue) onDetect}) async {
    throw const WebCameraException(QrCameraProblem.unsupported);
  }

  @override
  Future<void> close() async {}

  @override
  Widget buildPreview() => const SizedBox.shrink();
}
