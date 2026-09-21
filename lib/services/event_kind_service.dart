import 'package:cloud_firestore/cloud_firestore.dart';

/// イベントの方式(受付QR `/reception` が、従来の受付画面へ進むか新方式の受付画面へ進むかを決めるための判定)。
enum EventKind {
  /// イベントが存在し、flowが未設定/null/空/'legacy'
  legacy,

  /// flow == 'confirmed'
  confirmed,

  /// イベントが存在しない(孤児のQRなど)
  missing,

  /// 未知のflow・型が不正なflow(タイプミス等)
  unsupported,
}

typedef EventKindLoader = Future<EventKind> Function(String eventId);

/// flowの生の値から方式を決める(fail-closed: legacyと確定できる値だけがlegacy)。
EventKind eventKindFromFlow(Object? flow) {
  if (flow == null || flow == '' || flow == 'legacy') return EventKind.legacy;
  if (flow == 'confirmed') return EventKind.confirmed;
  return EventKind.unsupported;
}

/// eventsを1件読んで方式を判定する。
/// Phase 10C時点で従来方式の画面に残るFirestore直接読み取りは、この1か所(events/{id}のget)だけ。
/// eventsの読み取りはPhase 10Dで閉じる予定のため、それまでに「受付に必要な方式判定」を認証つきのAPIへ移す(引き継ぎ事項)。
/// 読めなかった場合は例外を投げる(従来の「読めなければlegacy扱い」ではなく、呼び出し側が受付を止める)。
class FirestoreEventKindService {
  FirestoreEventKindService({FirebaseFirestore? firestore})
    : _firestore = firestore;
  FirebaseFirestore? _firestore;

  Future<EventKind> kindOf(String eventId) async {
    final db = _firestore ??= FirebaseFirestore.instance;
    final snapshot = await db.collection('events').doc(eventId).get();
    if (!snapshot.exists) return EventKind.missing;
    return eventKindFromFlow((snapshot.data() ?? const {})['flow']);
  }
}
