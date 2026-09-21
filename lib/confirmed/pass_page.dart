import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/common.dart';
import 'pass_service.dart';
import 'robots_meta.dart';

/// `/p/{participantId}?publicId=…` の入口。
/// まずconfirmedの参加証を取得し、確認できればWeb参加証を表示する。確認できなければ従来のマイページ([legacyBuilder])へ進む
/// (従来方式の参加者のページは、これまでと同じ動作)。
/// 参加証は読み取り専用。participantId+publicIdは閲覧用のトークンで、受付・変更の権限ではない。
class PassRoutePage extends StatefulWidget {
  const PassRoutePage({
    super.key,
    required this.participantId,
    required this.publicId,
    required this.service,
    required this.legacyBuilder,
  });
  final String? participantId;
  final String? publicId;
  final PassService service;
  final WidgetBuilder legacyBuilder;

  @override
  State<PassRoutePage> createState() => _PassRoutePageState();
}

enum _Phase { loading, pass, legacy, failed }

class _PassRoutePageState extends State<PassRoutePage> {
  _Phase phase = _Phase.loading;
  ConfirmedPass? pass;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    setNoIndex(false);
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.participantId;
    final token = widget.publicId;
    if (id == null || id.isEmpty || token == null || token.isEmpty) {
      setState(() => phase = _Phase.legacy);
      return;
    }
    setState(() => phase = _Phase.loading);
    try {
      final result = await widget.service.getPass(
        participantId: id,
        publicId: token,
      );
      if (!mounted) return;
      if (result == null) {
        setState(() => phase = _Phase.legacy);
      } else {
        setNoIndex(true); // 個人の参加証は検索エンジンに載せない
        setState(() {
          pass = result;
          phase = _Phase.pass;
        });
      }
    } catch (_) {
      if (mounted) setState(() => phase = _Phase.failed);
    }
  }

  @override
  Widget build(BuildContext context) => switch (phase) {
    _Phase.legacy => widget.legacyBuilder(context),
    _Phase.pass => ConfirmedPassPage(pass: pass!),
    _Phase.failed => PageFrame(
      title: '参加証',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '参加証を確認できませんでした。時間をおいて、もう一度お試しください。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('再読み込み')),
            ],
          ),
        ),
      ),
    ),
    _Phase.loading => const PageFrame(
      title: '参加証',
      child: Center(child: CircularProgressIndicator()),
    ),
  };
}

/// 参加証(読み取り専用)。メールでQRが表示できない場合のバックアップ。
/// 受付・人数変更・取消などの操作は一切ない(受付はスタッフが受付用QRを読み取って行う)。
class ConfirmedPassPage extends StatelessWidget {
  const ConfirmedPassPage({super.key, required this.pass});
  final ConfirmedPass pass;

  static String? _present(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  @override
  Widget build(BuildContext context) {
    final venue = _present(pass.venue);
    final address = _present(pass.address);
    final access = _present(pass.access);
    final dateTime = _present(pass.dateTimeText);
    return PageFrame(
      title: '参加証',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                pass.eventName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (dateTime != null) ...[
                const SizedBox(height: 4),
                Text(dateTime, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 16),
              Text(
                '${pass.participantName} 様',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              for (final program in pass.programs)
                _ProgramRow(program: program),
              const SizedBox(height: 12),
              const Text(
                '受付では、こちらのQRコードをスタッフにご提示ください。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Center(
                child: QrImageView(
                  // keyにも同じ文字列を持たせる(テストが、表示中のQRがサーバーの文字列そのものであることを確認する)
                  key: ValueKey('pass-qr:${pass.qrPayload}'),
                  data: pass.qrPayload,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              if (venue != null || address != null || access != null) ...[
                const Divider(height: 32),
                if (venue != null) InfoRow('会場', venue),
                if (address != null) InfoRow('住所', address),
                if (access != null) InfoRow('アクセス', access),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgramRow extends StatelessWidget {
  const _ProgramRow({required this.program});
  final PassProgram program;

  @override
  Widget build(BuildContext context) {
    final time = ConfirmedPassPage._present(program.timeText);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffdfe3e8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            program.name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          if (time != null) Text(time),
          Text('予定人数 ${program.plannedCount}名'),
          if (program.checkedIn)
            const Text('受付済み', style: TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
