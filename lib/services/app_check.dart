import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// 公開API(ログイン不要の5本)へ付ける App Check トークンの取得口。
/// 画面・サービスはこの抽象にだけ依存する(テストでは差し替える。実際のApp Checkサービスへは接続しない)。
/// App Check は「正規のJM Quick Webアプリからのリクエストである」ことの補強で、参加者本人の権限(participantId+publicId)の代わりではない。
abstract class AppCheckTokenProvider {
  /// トークン。取得できなければnull(未設定・取得失敗)。トークンをログに出さない。
  Future<String?> token();
}

/// サーバーが検証するヘッダ名(Firebase Functions の callable が読む標準のヘッダ)。
const String appCheckHeaderName = 'X-Firebase-AppCheck';

/// 本番用のreCAPTCHA Enterpriseのサイトキー。コードに埋め込まず、ビルド時に `--dart-define` で渡す:
///   flutter build web --dart-define=APP_CHECK_RECAPTCHA_ENTERPRISE_SITE_KEY=(Firebase ConsoleのApp Checkで登録したキー)
/// 未指定なら App Check は有効化されず、公開APIの呼び出しはクライアント側で止まる(サーバーも拒否する。fail-closed)。
const String appCheckSiteKey = String.fromEnvironment(
  'APP_CHECK_RECAPTCHA_ENTERPRISE_SITE_KEY',
);

/// Firebase初期化後に1回だけ呼ぶ。設定が無ければ何もせずfalse(公開APIは使えない状態のまま)。
Future<bool> activateAppCheck() async {
  if (appCheckSiteKey.isEmpty) {
    debugPrint('app-check: site key not configured (public APIs disabled)');
    return false;
  }
  try {
    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaEnterpriseProvider(appCheckSiteKey),
    );
    return true;
  } catch (_) {
    debugPrint('app-check: activation failed');
    return false;
  }
}

/// Firebase App Check SDK から実際にトークンを取得する。
class FirebaseAppCheckTokenProvider implements AppCheckTokenProvider {
  @override
  Future<String?> token() async {
    try {
      final value = await FirebaseAppCheck.instance.getToken();
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }
}
