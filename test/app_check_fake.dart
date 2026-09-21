import 'package:jm_quick/services/app_check.dart';

/// テスト専用のApp Checkトークン取得口。実際のApp Checkサービス(Firebase)には接続しない。
///   FakeAppCheck('token')      → そのトークンを返す
///   FakeAppCheck(null)         → 取得できない(未設定・失敗相当)
///   FakeAppCheck.throwing()    → 取得時に例外
class FakeAppCheck implements AppCheckTokenProvider {
  FakeAppCheck([this.value = 'test-app-check-token']) : throws = false;
  FakeAppCheck.throwing() : value = null, throws = true;

  final String? value;
  final bool throws;
  int calls = 0;

  @override
  Future<String?> token() async {
    calls++;
    if (throws) throw StateError('app check failure');
    return value;
  }
}
