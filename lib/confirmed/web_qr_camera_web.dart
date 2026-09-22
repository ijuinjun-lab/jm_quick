// confirmed受付QRスキャナーの実カメラアダプタ(Web専用。dart:js_interop・package:webに依存する)。
//
// ■ 背景(iPhone Safariで映像が真っ黒になる不具合の回避):
//   package:mobile_scanner 7.4.2 のWeb実装は、生成する<video>要素に playsInline / muted を設定していない。
//   WebKit(iPhone上の全ブラウザに共通のエンジン)は、playsinlineの無い<video>の再生を「インライン表示」と
//   みなさずネイティブのフルスクリーン再生へ切り替えようとするため、getUserMedia自体は成功していても
//   画面には何も描画されない(既知の未修正issue。juliansteenbakker/mobile_scanner#1785)。
//   このアダプタはJM Quickが<video>要素を自前で生成し、
//     playsInline = true
//     muted = true
//     autoplay = true
//   を必ず明示したうえでgetUserMediaのstreamを直接アタッチすることで、この不具合を回避する。
//
// ■ QRのdecodeは標準のBarcodeDetector(Shape Detection API。Safari 17+ / Chrome 83+ / Edge 83+)を使う。
//   利用できないブラウザ(主にFirefox・古いSafari)では QrCameraProblem.unsupported として報告し、
//   既存のOS標準カメラ→/receptionの経路(このアプリの他の場所は無変更)へ委ねる。
//   mobile_scannerが内部で使うzxing-wasmのような追加ライブラリのfallbackは、今回は追加しない
//   (対象ブラウザ〈iPhone Safari・Chrome・Edge〉はBarcodeDetectorで足りるため、不要な実装を増やさない)。
//
// ■ カメラの終了(dispose・「次のQR」での作り直し・エラー)では、必ずMediaStreamTrackをstopする。

import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'qr_scanner.dart' show QrCameraProblem;
import 'web_qr_camera_gateway.dart';

WebCameraGateway createWebCameraGateway() => _BrowserCameraGateway();

int _viewCounter = 0;

class _BrowserCameraGateway implements WebCameraGateway {
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  Timer? _pollTimer;
  _NativeBarcodeDetector? _detector;
  bool _detecting = false;
  bool _closed = false;
  String? _viewType;

  @override
  Future<void> open({required void Function(String rawValue) onDetect}) async {
    if (!await _isBarcodeDetectorSupported()) {
      throw const WebCameraException(QrCameraProblem.unsupported);
    }

    web.MediaStream stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: {
                'facingMode': {'ideal': 'environment'},
              }.jsify()!,
            ),
          )
          .toDart;
    } on Object catch (error) {
      throw WebCameraException(_mapGetUserMediaError(error));
    }
    _stream = stream;

    try {
      _detector = _NativeBarcodeDetector.withOptions(
        _BarcodeDetectorInit(formats: ['qr_code'.toJS].toJS),
      );

      final video = web.HTMLVideoElement()
        ..autoplay = true
        ..muted = true
        ..playsInline = true
        ..controls = false
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover';
      video.srcObject = stream;
      await video.play().toDart;
      _video = video;

      final div = web.HTMLDivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..append(video);

      _viewCounter += 1;
      final viewType = 'confirmed-web-qr-camera-$_viewCounter';
      _viewType = viewType;
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) => div);

      _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
        unawaited(_detectOnce(onDetect));
      });
    } on Object catch (error) {
      // ここまでで取得済みのstreamは、他の失敗経路と同じくcloseで確実に解放する。
      await close();
      throw WebCameraException(_mapGetUserMediaError(error));
    }
  }

  Future<void> _detectOnce(void Function(String rawValue) onDetect) async {
    // 前回のdetect()がまだ完了していなければ、今回のtickは行わない(連続decodeの重複抑止)。
    if (_detecting || _closed) return;
    final detector = _detector;
    final video = _video;
    if (detector == null || video == null) return;
    _detecting = true;
    try {
      final results = await detector.detect(video).toDart;
      for (final barcode in results.toDart) {
        final value = barcode.rawValue;
        if (value != null && value.isNotEmpty) {
          onDetect(value);
          break; // 1回のdetectで複数見つかっても、最初の1件だけを扱う。
        }
      }
    } on Object {
      // 1フレームのdecode失敗(ピンボケ・映像未準備等)は無視して、次のtickで再試行する。
    } finally {
      _detecting = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _detector = null;
    // カメラの使用中表示が残らないよう、MediaStreamTrackを必ずstopする。
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
    }
    final video = _video;
    _video = null;
    video?.srcObject = null;
  }

  @override
  Widget buildPreview() {
    final viewType = _viewType;
    if (viewType == null) return const SizedBox.shrink();
    return HtmlElementView(viewType: viewType);
  }
}

// mobile_scannerの実装(lib/src/web/mobile_scanner_web.dart)と同じ、安全で実績のある方式:
// エラーをObjectとして受け取りtoString()の内容(DOMExceptionのname)を調べる(型キャストに依存しない)。
QrCameraProblem _mapGetUserMediaError(Object error) {
  final message = error.toString();
  if (message.contains('NotAllowedError') ||
      message.contains('SecurityError')) {
    return QrCameraProblem.permissionDenied;
  }
  if (message.contains('NotFoundError') ||
      message.contains('NotSupportedError') ||
      message.contains('OverconstrainedError')) {
    return QrCameraProblem.unsupported;
  }
  return QrCameraProblem.generic;
}

Future<bool> _isBarcodeDetectorSupported() async {
  try {
    final formats = await _NativeBarcodeDetector.getSupportedFormats().toDart;
    return formats.toDart.isNotEmpty;
  } on Object {
    return false;
  }
}

/// JSの`BarcodeDetector`(Shape Detection API)への最小限のバインディング。
/// https://developer.mozilla.org/en-US/docs/Web/API/BarcodeDetector
@JS('BarcodeDetector')
extension type _NativeBarcodeDetector._(JSObject _) implements JSObject {
  external factory _NativeBarcodeDetector.withOptions(
    _BarcodeDetectorInit options,
  );

  external static JSPromise<JSArray<JSString>> getSupportedFormats();

  external JSPromise<JSArray<_DetectedBarcode>> detect(
    web.HTMLVideoElement videoElement,
  );
}

@JS()
extension type _BarcodeDetectorInit._(JSObject _) implements JSObject {
  external factory _BarcodeDetectorInit({required JSArray<JSString> formats});
}

@JS()
extension type _DetectedBarcode(JSObject _) implements JSObject {
  external String? get rawValue;
}
