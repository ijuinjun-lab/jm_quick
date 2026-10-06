import 'package:jm_quick/confirmed/reception_service.dart';
import 'package:jm_quick/confirmed/reception_staff_key_service.dart';

/// テスト専用: 受付スタッフ用QRの受付キーの取得口(サーバーへは接続しない)。
class FakeReceptionStaffKeyIssuer implements ReceptionStaffKeyIssuer {
  FakeReceptionStaffKeyIssuer({this.key = fakeReceptionKey, this.error});

  final String key;
  ReceptionException? error;
  final List<String> calls = [];

  @override
  Future<ReceptionStaffKey> issue(String eventId) async {
    calls.add(eventId);
    final failure = error;
    if (failure != null) throw failure;
    return ReceptionStaffKey(
      eventId: eventId,
      key: key,
      expiresAt: DateTime.utc(2026, 11, 30, 15),
    );
  }
}

/// 43文字(32バイトのbase64url)の架空の受付キー。
const String fakeReceptionKey = 'FAKEreceptionKey0123456789abcdefghijklmnopq';
