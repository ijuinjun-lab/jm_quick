import 'legacy_api.dart';

/// イベントの方式(受付QR `/reception` が、従来の受付画面へ進むか新方式の受付画面へ進むかを決めるための判定)。
enum EventKind {
  /// イベントが存在し、flowが未設定/null/空/'legacy'
  legacy,

  /// flow == 'confirmed'
  confirmed,

  /// 存在しない・未知のflow・型が不正なflow(サーバーは区別せず、同じ「確認できない」応答を返す)
  unsupported,

  /// (予約値。サーバーAPIは返さない。テストで使う)
  missing,
}

typedef EventKindLoader = Future<EventKind> Function(String eventId);

/// flowの生の値から方式を決める(fail-closed: legacyと確定できる値だけがlegacy)。
EventKind eventKindFromFlow(Object? flow) {
  if (flow == null || flow == '' || flow == 'legacy') return EventKind.legacy;
  if (flow == 'confirmed') return EventKind.confirmed;
  return EventKind.unsupported;
}

/// 方式の判定を、staff/admin認証つきのサーバーAPI(getEventKind)で行う。Phase 10D。
/// Flutterからeventsを直接読むことはない(Firestoreの直接アクセス0件)。サーバーが返すのは kind('legacy' / 'confirmed')だけで、
/// イベントの内容は返らない。判定できないとき(未知のflow・存在しない・不正)は [EventKind.unsupported]、
/// 通信・認証の失敗は例外(呼び出し側が受付画面を出さずに再試行を案内する)。
/// 呼び出しは、ログイン+staff/admin確認のあと(AuthGateの内側)でなければならない。
class ApiEventKindService {
  ApiEventKindService({required this.api});
  final LegacyApiClient api;

  Future<EventKind> kindOf(String eventId) async {
    try {
      final result = await api.call('getEventKind', {'eventId': eventId});
      return switch (result['kind']) {
        'legacy' => EventKind.legacy,
        'confirmed' => EventKind.confirmed,
        _ => EventKind.unsupported,
      };
    } on LegacyApiException catch (error) {
      if (error.isFailedPrecondition) return EventKind.unsupported;
      rethrow;
    }
  }
}
