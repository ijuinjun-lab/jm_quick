import 'package:flutter/material.dart';

import '../services/demo_repository.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'reception_page.dart';
import 'reception_service.dart';

/// 受付イベントが従来方式(legacy/flow未設定)か。従来方式ならtrue。
typedef LegacyEventCheck = Future<bool> Function(String eventId);

/// `/reception?eventId&participantId&publicId`(受付用QRのURL)の入口。QRの形式は従来と同じ。
///   イベントが従来方式(flow未設定/legacy)           → 従来の受付画面([legacyBuilder]。ログイン要求などの変更なし)
///   新方式(confirmed)・未知のflow                    → ログイン(staff/admin)が必要な、program別の受付画面
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
  }) : _authClient = authClient,
       _accessService = accessService,
       _receptionService = receptionService,
       _isLegacyEvent = isLegacyEvent;

  final String? eventId;
  final String? participantId;
  final String? publicId;
  final WidgetBuilder legacyBuilder;
  final AuthClient? _authClient;
  final AccessService? _accessService;
  final ReceptionService? _receptionService;
  final LegacyEventCheck? _isLegacyEvent;

  @override
  State<ReceptionRoutePage> createState() => _ReceptionRoutePageState();
}

class _ReceptionRoutePageState extends State<ReceptionRoutePage> {
  late final Future<bool> legacy = _resolve();
  late final AuthClient authClient = widget._authClient ?? FirebaseAuthClient();

  bool get _hasAllParams =>
      (widget.eventId ?? '').isNotEmpty &&
      (widget.participantId ?? '').isNotEmpty &&
      (widget.publicId ?? '').isNotEmpty;

  Future<bool> _resolve() async {
    if (!_hasAllParams) return true; // 従来の受付画面が「有効なQRから開いてください」と案内する
    try {
      final check =
          widget._isLegacyEvent ??
          (String id) => DemoRepository(selectedEventId: id).isLegacyEvent(id);
      return await check(widget.eventId!);
    } catch (_) {
      return true; // 判定できないときは従来どおりの画面(従来のエラー表示)
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: legacy,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.data!) return widget.legacyBuilder(context);
      final service =
          widget._receptionService ??
          CallableReceptionService(authClient: authClient);
      // 受付後の訂正・取消は、adminとして確認できた場合だけ画面に出す(staffには渡さない。サーバーもadmin専用)。
      Widget page(
        BuildContext context,
        Future<void> Function() signOut, {
        required bool isAdmin,
      }) => ConfirmedReceptionPage(
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
