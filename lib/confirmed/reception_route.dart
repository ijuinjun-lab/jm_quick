import 'package:flutter/material.dart';

import '../services/event_kind_service.dart';
import '../services/legacy_api.dart';
import 'access_service.dart';
import 'assignment_pages.dart';
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
///   順序: ログイン → staff/adminの確認 → 方式の判定(サーバーAPI getEventKind。Firestoreは直接読まない) → 受付画面
///   従来方式(flow未設定/legacy)   → 従来の受付画面([legacyBuilder])
///   新方式(confirmed)              → program別の受付画面
///   未知のflow・存在しないイベント・方式を確認できない → どの受付画面も出さず、「イベントを確認できませんでした」だけ(再試行可)。fail-closed
/// 参加者本人がこのURLを開いても、ログインしていなければログイン画面が出るだけで、方式の問い合わせも受付操作もできない
/// (受付はFirebase Auth + accessRolesのstaff/adminをサーバーが毎回検証する)。
class ReceptionRoutePage extends StatefulWidget {
  const ReceptionRoutePage({
    super.key,
    required this.eventId,
    required this.participantId,
    required this.publicId,
    required this.legacyBuilder,
    this.onScanNext,
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

  /// QRカメラスキャナー(Phase 11C)から開かれた場合だけ渡される。「次のQRを読み取る」の導線を
  /// confirmedの受付画面([ConfirmedReceptionPage])に追加で表示する。/reception への直接アクセス(通常のQR・OS標準カメラ経路)
  /// ではnullのままで、画面は従来どおり変わらない。legacyの受付画面には渡さない(legacyは変更しない)。
  final VoidCallback? onScanNext;
  final AuthClient? _authClient;
  final AccessService? _accessService;
  final ReceptionService? _receptionService;
  final LegacyEventCheck? _isLegacyEvent;
  final EventKindCheck? _eventKind;

  @override
  State<ReceptionRoutePage> createState() => _ReceptionRoutePageState();
}

class _ReceptionRoutePageState extends State<ReceptionRoutePage> {
  late final AuthClient authClient = widget._authClient ?? FirebaseAuthClient();

  bool get _hasAllParams =>
      (widget.eventId ?? '').isNotEmpty &&
      (widget.participantId ?? '').isNotEmpty &&
      (widget.publicId ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // 必要なパラメータが欠けたURLは、従来どおり案内だけ(ログイン・通信なし)
    if (!_hasAllParams) return widget.legacyBuilder(context);
    // 順序: ログイン → staff/adminの確認 → 方式(legacy/confirmed)の判定 → 受付画面。
    // 未ログインのまま方式を問い合わせない(受付できるのは認証済みのstaff/adminだけ)。
    return AuthGate(
      authClient: authClient,
      accessService:
          widget._accessService ??
          CallableAccessService(authClient: authClient),
      // 未ログインでこのQRを開いた人(参加者本人を含む)には、受付スタッフ用ログイン画面はそのまま出すが
      // (受付スタッフがこのURLから直接ログインし直す場合にも変わらず使える)、その上に「これは受付スタッフへ
      // 提示するもの」という案内と、自分の参加証(/p/…読み取り専用・ログイン不要)への導線を追加する。
      // 受付操作UI(来場人数入力・受付するボタン)は、この案内の有無にかかわらず未ログインでは元々出ない
      // (AuthGateの構造上、adminBuilder/staffBuilderは権限確認後にしか呼ばれない)。
      signedOutBanner: _ParticipantGuidanceBanner(
        participantId: widget.participantId!,
        publicId: widget.publicId!,
      ),
      adminBuilder: (context, signOut) => _KindResolver(
        route: widget,
        authClient: authClient,
        signOut: signOut,
        isAdmin: true,
      ),
      staffBuilder: (context, signOut) => _KindResolver(
        route: widget,
        authClient: authClient,
        signOut: signOut,
        isAdmin: false,
      ),
      // Phase 3: 担当イベントのイベント管理者・スタッフ。受付・人数訂正・受付取消ができる(サーバーも対象イベントの
      // スタッフ以上に許可する)。担当外のイベントのQRは受付画面を出さない(サーバーも拒否する)。
      eventScopedBuilder: (context, signOut, assignments) {
        if (!assignments.any((a) => a.eventId == widget.eventId)) {
          return EventScopeDenied(
            title: '受付',
            message: 'このイベントの受付を行う権限がありません。',
            signOut: signOut,
          );
        }
        return _KindResolver(
          route: widget,
          authClient: authClient,
          signOut: signOut,
          isAdmin: true,
        );
      },
    );
  }
}

/// 認証済み(staff/admin)のあとに、イベントの方式をサーバー(getEventKind)で確認し、受付画面へ振り分ける。
/// 方式を確認できないとき(未知のflow・存在しない・通信失敗)は、legacyやconfirmedと仮定せず、どの受付画面も出さない。
class _KindResolver extends StatefulWidget {
  const _KindResolver({
    required this.route,
    required this.authClient,
    required this.signOut,
    required this.isAdmin,
  });
  final ReceptionRoutePage route;
  final AuthClient authClient;
  final Future<void> Function() signOut;
  final bool isAdmin;

  @override
  State<_KindResolver> createState() => _KindResolverState();
}

class _KindResolverState extends State<_KindResolver> {
  late Future<EventKind?> kind = _resolve();

  // 判定できなかった(通信・認証の失敗)ときはnull。unsupportedはサーバーが「確認できない」と答えた場合。
  Future<EventKind?> _resolve() async {
    final route = widget.route;
    try {
      final legacyCheck = route._isLegacyEvent;
      if (legacyCheck != null) {
        return await legacyCheck(route.eventId!)
            ? EventKind.legacy
            : EventKind.confirmed;
      }
      final kindCheck =
          route._eventKind ??
          ApiEventKindService(
            api: LegacyApiClient(authClient: widget.authClient),
          ).kindOf;
      return await kindCheck(route.eventId!);
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
          message: 'イベントを確認できませんでした。通信状態を確認して、もう一度お試しください。',
          onRetry: () => setState(() {
            kind = _resolve();
          }),
        );
      }
      if (resolved != EventKind.legacy && resolved != EventKind.confirmed) {
        return const _Unavailable(
          message: 'イベントを確認できませんでした。この受付用QRコードでは受付できません。受付スタッフへお声がけください。',
        );
      }
      final route = widget.route;
      if (resolved == EventKind.legacy) {
        // 従来方式の受付画面も、staff/adminとして確認できたあとにだけ作られる
        return route.legacyBuilder(context);
      }
      final service =
          route._receptionService ??
          CallableReceptionService(authClient: widget.authClient);
      // 受付後の訂正・取消は、システム管理者、または担当イベントのイベント管理者・スタッフとして確認できた場合だけ画面に出す
      // (isAdmin=訂正・取消を表示する。従来の全体staffには渡さない。サーバーも対象イベントのスタッフ以上に限る)。
      return ConfirmedReceptionPage(
        service: service,
        eventId: route.eventId!,
        participantId: route.participantId!,
        publicId: route.publicId!,
        signOut: widget.signOut,
        onScanNext: route.onScanNext,
        adminService: widget.isAdmin
            ? (service is ReceptionAdminService
                  ? service as ReceptionAdminService
                  : null)
            : null,
      );
    },
  );
}

/// 未ログインで受付用QRの/receptionを開いた人(参加者本人を含む)向けの案内。ログイン画面(参加者は使わない)の
/// 上に表示するだけで、受付操作(来場人数入力・「受付する」)は含まない。
/// 「参加証を確認する」は、既存の読み取り専用ページ(/p/{participantId}?publicId=…。ログイン不要・
/// getConfirmedParticipantPassを使う既存の仕組み)への遷移だけで、ここで新しく参加証データを取得・
/// 組み立てることはしない。
class _ParticipantGuidanceBanner extends StatelessWidget {
  const _ParticipantGuidanceBanner({
    required this.participantId,
    required this.publicId,
  });
  final String participantId;
  final String publicId;

  @override
  Widget build(BuildContext context) => Card(
    color: const Color(0xfff7f8fa),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'このQRコードは、受付スタッフへご提示ください。',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'ご参加者ご本人がこの画面から受付を行うことはできません。'
            '参加内容を確認したい場合は、下記から参加証をご覧いただけます(ログイン不要)。',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: const Key('reception-open-pass'),
              onPressed: () => Navigator.of(context).pushReplacementNamed(
                '/p/$participantId?publicId=${Uri.encodeQueryComponent(publicId)}',
              ),
              child: const Text('参加証を確認する'),
            ),
          ),
        ],
      ),
    ),
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
