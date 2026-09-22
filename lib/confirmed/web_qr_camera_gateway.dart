// confirmed受付QRスキャナーの、カメラ実装を差し替え可能にするための抽象(プラットフォームに依存しない)。
// 実装(Web専用の実カメラ)は web_qr_camera_web.dart、テスト・非Web環境向けの代替は web_qr_camera_stub.dart。
// このファイル自体はdart:js_interop等のWeb専用APIに依存しないため、flutter test(VM)でも安全に読み込める。

import 'package:flutter/widgets.dart';

import 'qr_scanner.dart' show QrCameraProblem;

/// 1回分のカメラ利用(open〜close)を表す。[WebQrCameraView]から使われる。
abstract class WebCameraGateway {
  /// カメラを起動し、QRを検出するたびに[onDetect]を呼ぶ(検証・重複scan防止は呼び出し側の責務。ここでは生の文字列を渡すだけ)。
  /// 起動できない場合は[WebCameraException]を投げる。
  Future<void> open({required void Function(String rawValue) onDetect});

  /// カメラを終了する。MediaStreamTrack等を必ず解放する(呼び出し側はdispose時に必ず呼ぶ)。
  /// 何度呼んでも安全(open前・close後の再呼び出しでも例外を投げない)。
  Future<void> close();

  /// カメラ映像の表示に使うWidget([open]が成功した後にだけ呼ばれる想定)。
  Widget buildPreview();
}

/// [WebCameraGateway.open]が失敗したときの例外。[problem]はUI表示用に分類済み。
class WebCameraException implements Exception {
  const WebCameraException(this.problem);
  final QrCameraProblem problem;

  @override
  String toString() => 'WebCameraException(${problem.name})';
}
