import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';

/// 管理者に見せる機能(いずれも後続Phaseで実装。この画面は入口とロール別の境界だけ)。
const List<String> adminFeatureLabels = [
  'イベント設定',
  'CSV取込',
  '当選メール送信',
  'リマインド',
  '参加者管理',
  '受付',
  '受付訂正',
  'スタッフ管理',
];

/// 受付スタッフに見せる機能(受付系だけ)。
const List<String> staffFeatureLabels = ['当日の受付', '参加者検索'];

/// 新方式(flow=confirmed)の管理・受付の入口(/console)。従来方式の画面はこのゲートで包まない。
class ConfirmedConsolePage extends StatelessWidget {
  ConfirmedConsolePage({
    super.key,
    AuthClient? authClient,
    AccessService? accessService,
  }) : authClient = authClient ?? FirebaseAuthClient(),
       _accessService = accessService;

  final AuthClient authClient;
  final AccessService? _accessService;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        _accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => _RoleHome(
      title: '管理機能',
      roleLabel: '管理者',
      features: adminFeatureLabels,
      signOut: signOut,
    ),
    staffBuilder: (context, signOut) => _RoleHome(
      title: '受付',
      roleLabel: '受付スタッフ',
      features: staffFeatureLabels,
      signOut: signOut,
    ),
  );
}

class _RoleHome extends StatelessWidget {
  const _RoleHome({
    required this.title,
    required this.roleLabel,
    required this.features,
    required this.signOut,
  });
  final String title;
  final String roleLabel;
  final List<String> features;
  final Future<void> Function() signOut;

  @override
  Widget build(BuildContext context) => PageFrame(
    title: title,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'ログイン中：$roleLabel',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            for (final feature in features)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(feature),
                subtitle: const Text('準備中'),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: signOut,
                child: const Text('ログアウト'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
