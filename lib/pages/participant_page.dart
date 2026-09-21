import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/demo_models.dart';
import '../services/demo_repository.dart';
import '../widgets/common.dart';

class ParticipantPage extends StatefulWidget {
  const ParticipantPage({
    super.key,
    required this.participantId,
    required this.publicId,
    this.repository,
  });
  final String? participantId;
  final String? publicId;

  /// テスト用。既定は参加者capability(participantId+publicId)のサーバーAPIを使う。Firestoreは直接読まない。
  final DemoRepository? repository;
  @override
  State<ParticipantPage> createState() => _ParticipantPageState();
}

class _ParticipantPageState extends State<ParticipantPage> {
  late final repository = widget.repository ?? DemoRepository();
  ParticipantPageData? data;
  bool loading = true;
  bool saving = false;
  Object? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // 存在しない・publicId不一致・従来方式でない・不正なURLは、サーバーが同じ応答(=data==null)を返す。
  Future<void> _load() async {
    try {
      data = await repository.loadParticipantPage(
        widget.participantId,
        widget.publicId,
      );
    } catch (e) {
      error = e;
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> action(
    Future<ParticipantPageData> Function() callback,
    String message,
  ) async {
    setState(() => saving = true);
    try {
      final updated = await callback();
      if (mounted) {
        setState(() => data = updated);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存できませんでした：$e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'イベント参加受付',
    child: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? const _ParticipantErrorPanel()
        : data == null
        ? const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('有効なマイページURLではありません。'),
            ),
          )
        : _content(data!),
  );

  // 新方式(flow=confirmed)の参加者は、サーバーが「無効なページ」と同じ応答にする(この画面では扱わない)。
  // 新方式の参加証は /p/{id} の入口(PassRoutePage)が表示する。
  Widget _content(ParticipantPageData p) {
    final participantId = widget.participantId!;
    final publicId = widget.publicId!;
    final receptionUri =
        '/reception?eventId=${Uri.encodeQueryComponent(p.eventId)}&participantId=${Uri.encodeQueryComponent(participantId)}&publicId=${Uri.encodeQueryComponent(publicId)}';
    final qrPayload = Uri.base.resolve(receptionUri).toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              p.eventName,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 18),
            Text(
              '${p.name}様',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            InfoRow('お申し込み人数', '${p.registeredCount}名'),
            InfoRow('開催日時', formatDateTime(p.startAt)),
            InfoRow('会場', p.venue),
            const SizedBox(height: 20),
            if (!p.participationConfirmed)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'イベントへご参加いただくため、まずは正式登録をお願いいたします。\n\n'
                    '開催前日に、参加予定の確認をご案内いたします。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 17, height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: saving
                        ? null
                        : () => action(
                            () => repository.confirmParticipationByKey(
                              participantId,
                              publicId,
                            ),
                            '正式登録が完了しました。',
                          ),
                    child: const Text('正式登録する'),
                  ),
                ],
              ),
            if (p.participationConfirmed)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xffe7f5ec),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Column(
                  children: [
                    Text(
                      '正式登録が完了しました',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '開催前日に、参加予定の確認をご案内いたします。\n\n'
                      'ご案内が届きましたら、マイページからご回答ください。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            if (p.participationConfirmed &&
                p.reconfirmEnabled &&
                p.attendanceResponse == null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'このイベントへの参加予定をお知らせください。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: saving
                            ? null
                            : () => action(
                                () => repository.reconfirmByKey(
                                  participantId,
                                  publicId,
                                  AttendanceResponse.attending,
                                ),
                                '「参加予定」で回答しました。',
                              ),
                        child: const Text('参加予定'),
                      ),
                      OutlinedButton(
                        onPressed: saving
                            ? null
                            : () => action(
                                () => repository.reconfirmByKey(
                                  participantId,
                                  publicId,
                                  AttendanceResponse.notAttending,
                                ),
                                '「不参加予定」で回答しました。',
                              ),
                        child: const Text('不参加予定'),
                      ),
                    ],
                  ),
                ],
              ),
            if (p.attendanceResponse != null)
              Center(
                child: Text(
                  '回答：${p.attendanceResponse!.label}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            if (p.participationConfirmed) const Divider(height: 34),
            if (p.participationConfirmed)
              const Text(
                '受付QR',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            if (p.participationConfirmed)
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: qrPayload, size: 210),
                ),
              ),
            if (p.participationConfirmed) const SizedBox(height: 12),
            if (p.participationConfirmed)
              const Text(
                '当日は、このQRコードを受付でご提示ください。',
                textAlign: TextAlign.center,
              ),
            if (p.participationConfirmed && p.checkedIn)
              Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(14),
                color: const Color(0xffe7f5ec),
                child: Text(
                  '受付済み\n実参加人数 ${p.attendedCount ?? 0}名',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ParticipantErrorPanel extends StatelessWidget {
  const _ParticipantErrorPanel();

  @override
  Widget build(BuildContext context) => const Card(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'ページを読み込めませんでした。時間をおいて、もう一度お試しください。',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
