import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../confirmed/access_service.dart';
import '../confirmed/auth_client.dart';
import '../confirmed/auth_gate.dart';
import '../services/legacy_api.dart';
import '../widgets/common.dart';

typedef LegacyAdminBuilder =
    Widget Function(BuildContext context, LegacyApiClient api);

/// 従来方式(legacy)の管理画面(`/admin`・`/demo-admin`・`/admin/events/{id}`)の入口。Phase 10C。
///   未ログイン → ログイン画面 / 権限なし → 権限なし / staff → 「管理者のみ」 / admin → [builder]
/// 画面(builder)は、ログイン後にだけ作られる。それまでサーバーへのデータ取得(購読・API呼び出し)は一切しない。
/// 権限はクライアントで判断せず、必ずサーバー(getMyAccessRole)の確認結果に従う。
class LegacyAdminGate extends StatefulWidget {
  const LegacyAdminGate({
    super.key,
    required this.builder,
    this.authClient,
    this.accessService,
    this.httpClient,
  });

  final LegacyAdminBuilder builder;
  final AuthClient? authClient;
  final AccessService? accessService;

  /// テスト用(既定は実通信)。
  final http.Client? httpClient;

  @override
  State<LegacyAdminGate> createState() => _LegacyAdminGateState();
}

class _LegacyAdminGateState extends State<LegacyAdminGate> {
  late final AuthClient authClient = widget.authClient ?? FirebaseAuthClient();
  late final LegacyApiClient api = LegacyApiClient(
    authClient: authClient,
    httpClient: widget.httpClient,
  );

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        widget.accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => widget.builder(context, api),
    staffBuilder: (context, signOut) => PageFrame(
      title: 'JM Quick',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '管理者のみ利用できます',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'この画面は管理者(admin)専用です。受付スタッフは、受付用のQRから受付画面を開いてください。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              Center(
                child: FilledButton(
                  onPressed: signOut,
                  child: const Text('ログアウト'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
