// confirmed受付QRスキャナーの実カメラアダプタ(Web専用。dart:js_interop・package:webに依存する)。
//
// ■ 背景1(iPhone Safariで映像が真っ黒になる不具合の回避。Phase 11C-2):
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
// ■ 背景2(iPhone実機でBarcodeDetectorが使えなかった不具合の回避。Phase 11C-3):
//   MDNのbrowser-compat-data(api/BarcodeDetector.json)によると、SafariのBarcodeDetector(17+)は
//   「Shape Detection API」という実験的機能フラグの背後にあり、既定では無効(iOS Safariも同じ扱いでmirror)。
//   実際のiPhone Safari(既定設定)では BarcodeDetector.getSupportedFormats() が空配列を返し、
//   このアダプタは正しく「利用不可」と判定していた(feature detectionのバグではない)。
//   このためBarcodeDetectorが無い場合は、QR専用の軽量な純JSライブラリ jsQR(Apache-2.0)へfallbackする
//   (同一originの web/vendor/jsqr.min.js から配信。外部CDNには依存しない。BarcodeDetectorが使えるときは
//   ロードすらしない=軽量)。カメラの取得(getUserMedia)・<video>の生成・表示・MediaStreamTrackの解放は、
//   decoderの種類に関わらずこのファイルが唯一の場所で行う(decoderはvideoフレームを受け取って文字列を返すだけ)。
//
// ■ カメラの終了(dispose・「次のQR」での作り直し・エラー)では、必ずMediaStreamTrackをstopする。
// ■ BarcodeDetectorが無いことだけではcamera全体をunsupportedにしない(jsQRへfallbackする)。
//   getUserMedia自体が使えない場合だけcamera unsupported/permissionDenied/genericとして扱う。
//   decoder(BarcodeDetector・jsQRのどちらも)が用意できない場合だけ、明確なエラー(generic)にする。

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
  _FrameDecoder? _decoder;
  bool _detecting = false;
  bool _closed = false;
  String? _viewType;

  @override
  Future<void> open({required void Function(String rawValue) onDetect}) async {
    // 1. カメラ(getUserMedia)を取得する。ここが唯一のcamera unsupported/permissionDenied判定点
    //    (BarcodeDetectorの有無はここでは判定しない)。
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
      // 2. decoderを決める(BarcodeDetector → 無ければjsQR fallback)。カメラの取得とは独立した判断。
      _decoder = await _resolveFrameDecoder();

      // 3. <video>を自前で生成し、playsInline/muted/autoplayを明示してstreamをアタッチする。
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
    } on WebCameraException {
      await close();
      rethrow;
    } on Object catch (error) {
      // ここまでで取得済みのstreamは、他の失敗経路と同じくcloseで確実に解放する。
      await close();
      throw WebCameraException(_mapGetUserMediaError(error));
    }
  }

  Future<void> _detectOnce(void Function(String rawValue) onDetect) async {
    // 前回のdetect()がまだ完了していなければ、今回のtickは行わない(連続decodeの重複抑止)。
    if (_detecting || _closed) return;
    final decoder = _decoder;
    final video = _video;
    if (decoder == null || video == null) return;
    _detecting = true;
    try {
      final value = await decoder.decodeFrame(video);
      if (value != null && value.isNotEmpty) onDetect(value);
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
    _decoder = null;
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

// ---- decoder(1フレームからQR文字列を取り出すだけ。カメラの取得・表示・解放には関与しない) --------------

abstract class _FrameDecoder {
  /// 1フレームをdecodeする。見つからなければnull。
  Future<String?> decodeFrame(web.HTMLVideoElement video);
}

/// BarcodeDetectorが使えればそれを使い、使えなければjsQR(同一origin配信・外部CDN不要)へfallbackする。
/// どちらも用意できない場合だけ、明確なエラー(generic)として報告する。
Future<_FrameDecoder> _resolveFrameDecoder() async {
  if (await _isBarcodeDetectorSupported()) {
    return _BarcodeDetectorFrameDecoder();
  }
  try {
    await _ensureJsQrLoaded();
    return _JsQrFrameDecoder();
  } on Object {
    throw const WebCameraException(QrCameraProblem.generic);
  }
}

/// 標準BarcodeDetector(Shape Detection API)によるdecoder。
/// iPhone Safari 17+でも、既定では「Shape Detection API」の実験的フラグが無効なため使えないことが多い
/// (MDNのbrowser-compat-data参照。既定で有効なブラウザでは、こちらが優先して使われる)。
class _BarcodeDetectorFrameDecoder implements _FrameDecoder {
  final _NativeBarcodeDetector _detector = _NativeBarcodeDetector.withOptions(
    _BarcodeDetectorInit(formats: ['qr_code'.toJS].toJS),
  );

  @override
  Future<String?> decodeFrame(web.HTMLVideoElement video) async {
    final results = await _detector.detect(video).toDart;
    for (final barcode in results.toDart) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
}

/// jsQR(https://github.com/cozmo/jsQR。Apache-2.0)によるfallback decoder。
/// videoフレームを自前のcanvasへ描き、そのImageDataをjsQRへ渡すだけ(カメラの所有権はこのクラスには無い)。
class _JsQrFrameDecoder implements _FrameDecoder {
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _context;

  @override
  Future<String?> decodeFrame(web.HTMLVideoElement video) async {
    final width = video.videoWidth;
    final height = video.videoHeight;
    if (width <= 0 || height <= 0) return null; // 映像がまだ準備できていない
    var canvas = _canvas;
    web.CanvasRenderingContext2D context;
    if (canvas == null || canvas.width != width || canvas.height != height) {
      canvas = web.HTMLCanvasElement()
        ..width = width
        ..height = height;
      context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      _canvas = canvas;
      _context = context;
    } else {
      context = _context!;
    }
    context.drawImage(video, 0, 0);
    final imageData = context.getImageData(0, 0, width, height);
    final result = _callJsQr(imageData.data, width, height);
    return result?.data;
  }
}

Future<bool> _isBarcodeDetectorSupported() async {
  try {
    final formats = await _NativeBarcodeDetector.getSupportedFormats().toDart;
    return formats.toDart.isNotEmpty;
  } on Object {
    return false;
  }
}

// ---- jsQRの読み込み(同一origin配信。BarcodeDetectorが使えるブラウザではロードすらしない) --------------

bool _jsQrLoaded = false;
Completer<void>? _jsQrLoading;

/// web/vendor/jsqr.min.js(このアプリのHostingと同一origin。外部CDNは使わない)を、必要になった時だけ読み込む。
/// 読み込み済みなら即座に戻る(ページ内で1回だけ読み込む)。
Future<void> _ensureJsQrLoaded() {
  if (_jsQrLoaded) return Future<void>.value();
  final pending = _jsQrLoading;
  if (pending != null) return pending.future;

  final completer = Completer<void>();
  _jsQrLoading = completer;
  final script = web.HTMLScriptElement()
    ..src = '${web.window.location.origin}/vendor/jsqr.min.js';
  script.onload = ((JSAny _) {
    _jsQrLoaded = true;
    completer.complete();
  }).toJS;
  script.onerror = ((JSAny _) {
    completer.completeError(StateError('jsqr.min.jsを読み込めませんでした。'));
  }).toJS;
  web.document.head!.append(script);
  return completer.future;
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

/// jsQR(web/vendor/jsqr.min.js)への最小限のバインディング。読み込み前に呼ぶと実行時エラーになる
/// (必ず[_ensureJsQrLoaded]を先に完了させる)。
@JS('jsQR')
external _JsQrResult? _callJsQr(
  JSUint8ClampedArray data,
  int width,
  int height,
);

@JS()
extension type _JsQrResult._(JSObject _) implements JSObject {
  external String? get data;
}
