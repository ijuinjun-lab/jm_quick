import 'package:flutter/material.dart';

import '../services/event_kind_service.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'reception_page.dart';
import 'reception_service.dart';

/// 受付イベントが従来方式(legacy/flow未設定)か。従来方式ならtrue、新方式(confirmed)ならfalse。
/// (テスト用の簡易な差し替え口。未知のflow・存在しないイベントを区別したい場合は [EventKindCheck] を使う)
typedef LegacyEventCheck = Future<bool> Function(String eventId);

/// 受付イベントの方式(legacy/confirmed/未知/存在しない)。読み取りに失敗したときは例外を投げる。
typedef EventKindCheck = Future<EventKind> Function(String eventId);

/// `/reception?eventId&participantId&publicId`(受付用QRのURL)の入口。QRの形式は従来と同じ。
///   従来方式(flow未設定/legacy)   → ログイン(staff/admin)が必要な、従来の受付画面([legacyBuilder])  ※Phase 10Cで認証必須になった
///   新方式(confirmed)              → ログイン(staff/admin)が必要な、program別の受付画面
///   未知のflow・存在しないイベント・イベントを読めない → どの受付画面も出さず、案内(再試行)だけ。fail-closed
/// 参加者本人がこのURLを開いても、ログインしていなければログイン画面が出るだけで、受付操作はできない
/// (受付はFirebase Auth + accessRolesのstaff/adminをサーバーが毎回検証する)。
class ReceptionRoutePage extends StatefulWidget {
  const ReceptionRoutePage({
    super.key,
    required this.eventId,
    required this.participantId,
    required this.publicId,
    required this.legacyBuilder,
    AuthClient? authClient,
    AccessService? accessService,
    ReceptionService? receptionService,
    LegacyEventCheck? isLegacyEvent,
    EventKindCheck? eventKind,
  }) : _authClient = authClient,
       _accessService = accessService,
       _receptionService = receptionService,
       _isLegacyEvent = isLegacyEvent,
       _eventKind = eventKind;

  final String? eventId;
  final String? participantId;
  final String? publicId;
  final WidgetBuilder legacyBuilder;
  final AuthClient? _authClient;
  final AccessService? _accessService;
  final ReceptionService? _receptionService;
  final LegacyEventCheck? _isLegacyEvent;
  final EventKindCheck? _eventKind;

  @override
  State<ReceptionRoutePage> createState() => _ReceptionRoutePageState();
}

class _ReceptionRoutePageState extends State<ReceptionRoutePage> {
  late Future<EventKind?> kind = _resolve();
  late final AuthClient authClient = widget._authClient ?? FirebaseAuthClient();

  bool get _hasAllParams =>
      (widget.eventId ?? '').isNotEmpty &&
      (widget.participantId ?? '').isNotEmpty &&
      (widget.publicId ?? '').isNotEmpty;

  // 方式を判定できなかった(読み取りの失敗)ときはnullを返し、受付画面を出さない(以前は「読めなければ従来の画面」だった)
  Future<EventKind?> _resolve() async {
    // 従来の受付画面が「有効なQRから開いてください」と案内する(通信しない)
    if (!_hasAllParams) return EventKind.legacy;
    try {
      final legacyCheck = widget._isLegacyEvent;
      if (legacyCheck != null) {
        return await legacyCheck(widget.eventId!)
            ? EventKind.legacy
            : EventKind.confirmed;
      }
      final kindCheck =
          widget._eventKind ??
          (String id) => FirestoreEventKindService().kindOf(id);
      return await kindCheck(widget.eventId!);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<EventKind?>(
    future: kind,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final resolved = snapshot.data;
      if (resolved == null) {
        return _Unavailable(
          message: 'イベントの情報を確認できませんでした。通信状態を確認して、もう一度お試しください。',
          onRetry: () => setState(() => kind = _resolve()),
        );
      }
      if (resolved == EventKind.missing || resolved == EventKind.unsupported) {
        return const _Unavailable(
          message: 'この受付用QRコードでは受付できません。受付スタッフへお声がけください。',
        );
      }
      // 必要なパラメータが欠けたURLは、従来どおり案内だけ(ログイン・通信なし)
      if (!_hasAllParams) return widget.legacyBuilder(context);
      final isLegacy = resolved == EventKind.legacy;
      final service =
          widget._receptionService ??
          CallableReceptionService(authClient: authClient);
      // 受付後の訂正・取消は、adminとして確認できた場合だけ画面に出す(staffには渡さない。サーバーもadmin専用)。
      Widget page(
        BuildContext context,
        Future<void> Function() signOut, {
        required bool isAdmin,
      }) => isLegacy
          // 従来方式の受付画面も、staff/adminとして確認できたあとにだけ作られる(Phase 10C)
          ? widget.legacyBuilder(context)
          : ConfirmedReceptionPage(
              service: service,
              eventId: widget.eventId!,
              participantId: widget.participantId!,
              publicId: widget.publicId!,
              signOut: signOut,
              adminService: isAdmin
                  ? (service is ReceptionAdminService
                        ? service as ReceptionAdminService
                        : null)
                  : null,
            );
      return AuthGate(
        authClient: authClient,
        accessService:
            widget._accessService ??
            CallableAccessService(authClient: authClient),
        adminBuilder: (context, signOut) =>
            page(context, signOut, isAdmin: true),
        staffBuilder: (context, signOut) =>
            page(context, signOut, isAdmin: false),
      );
    },
  );
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('受付画面')),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('再試行')),
            ],
          ],
        ),
      ),
    ),
  );
}
