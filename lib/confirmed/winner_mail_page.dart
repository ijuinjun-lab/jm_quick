import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'winner_mail_service.dart';

/// 当選メールの設定とプレビュー(adminのみ)。新方式(confirmed)のイベント専用。従来方式の設定画面には触れない。
///
/// 管理者が編集するのは「件名・冒頭本文・締め本文・注意事項」と会場の住所・アクセス(すべてプレーンテキスト)。
/// 宛名・受付QR・Web参加証URL・program名・参加時間・参加人数・開催日時・会場・問い合わせ先は、
/// サーバーが正確なデータから自動生成するため、ここでは編集できない。
class WinnerMailPage extends StatefulWidget {
  const WinnerMailPage({super.key, required this.service, this.initialEventId});
  final WinnerMailService service;
  final String? initialEventId;

  @override
  State<WinnerMailPage> createState() => _WinnerMailPageState();
}

/// サーバーの理由コードを、管理者向けの日本語にする。
String problemLabel(String code) => switch (code) {
  'template-not-configured' => '当選メールのテンプレートが未設定です。件名・冒頭本文・締め本文を保存してください。',
  'template-subject-invalid' => '件名が未設定です。',
  'template-intro-invalid' => '冒頭本文が未設定です。',
  'template-closing-invalid' => '締め本文が未設定です。',
  'template-version-invalid' => 'テンプレートの保存状態が不正です。もう一度保存してください。',
  'event-name-missing' => 'イベント名が未設定です。',
  'event-start-missing' => '開催日時が未設定です。',
  'event-venue-missing' => '会場が未設定です。',
  'no-attendance' => 'この参加者には参加するprogramがありません。',
  'participant-name-missing' => 'この参加者の氏名がありません。',
  _ => 'メールを作成できません($code)。',
};

const _maxSubject = 150;
const _maxBody = 2000;

class _WinnerMailPageState extends State<WinnerMailPage> {
  late final eventId = TextEditingController(text: widget.initialEventId ?? '');
  final subject = TextEditingController();
  final intro = TextEditingController();
  final closing = TextEditingController();
  final notes = TextEditingController();
  final address = TextEditingController();
  final access = TextEditingController();
  final participantId = TextEditingController();
  bool busy = false;
  bool loaded = false;
  String? message;
  String? error;
  WinnerMailSettings? settings;
  WinnerMailPreview? preview;

  @override
  void dispose() {
    for (final c in [
      eventId,
      subject,
      intro,
      closing,
      notes,
      address,
      access,
      participantId,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
    } on WinnerMailException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => _run(() async {
    final id = eventId.text.trim();
    if (id.isEmpty) throw const WinnerMailException('イベントIDを入力してください。');
    final result = await widget.service.getSettings(id);
    if (!mounted) return;
    setState(() {
      settings = result;
      loaded = true;
      preview = null;
      subject.text = result.subject;
      intro.text = result.introBody;
      closing.text = result.closingBody;
      notes.text = result.notesBody;
      address.text = result.address;
      access.text = result.access;
    });
  });

  String? _validate() {
    if (subject.text.trim().isEmpty) return '件名を入力してください。';
    if (subject.text.contains('\n')) return '件名は1行で入力してください。';
    if (subject.text.trim().length > _maxSubject) {
      return '件名は$_maxSubject文字以内で入力してください。';
    }
    if (intro.text.trim().isEmpty) return '冒頭本文を入力してください。';
    if (closing.text.trim().isEmpty) return '締め本文を入力してください。';
    for (final c in [intro, closing, notes]) {
      if (c.text.trim().length > _maxBody) return '本文は$_maxBody文字以内で入力してください。';
    }
    return null;
  }

  Future<void> save() => _run(() async {
    final problem = _validate();
    if (problem != null) throw WinnerMailException(problem);
    final version = await widget.service.updateTemplate(
      eventId: eventId.text.trim(),
      subject: subject.text,
      introBody: intro.text,
      closingBody: closing.text,
      notesBody: notes.text,
      address: address.text,
      access: access.text,
    );
    final refreshed = await widget.service.getSettings(eventId.text.trim());
    if (!mounted) return;
    setState(() {
      settings = refreshed;
      preview = null;
      message = '保存しました(テンプレートversion $version)。';
    });
  });

  Future<void> showPreview() => _run(() async {
    final id = participantId.text.trim();
    if (id.isEmpty) throw const WinnerMailException('プレビューする参加者IDを入力してください。');
    final result = await widget.service.preview(
      eventId: eventId.text.trim(),
      participantId: id,
    );
    if (mounted) setState(() => preview = result);
  });

  Widget _field(
    TextEditingController controller,
    String label, {
    int lines = 1,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      minLines: lines,
      maxLines: lines == 1 ? 1 : lines + 4,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        alignLabelWithHint: true,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '当選メール設定',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '新方式(confirmed)のイベントの当選メール',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: eventId,
                  decoration: const InputDecoration(labelText: 'イベントID'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: busy ? null : load,
                    child: const Text('設定を読み込む'),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: Color(0xffb42318))),
        ],
        if (message != null) ...[
          const SizedBox(height: 12),
          Text(message!, style: const TextStyle(color: Color(0xff067647))),
        ],
        if (loaded && settings != null) ...[
          const SizedBox(height: 16),
          _editor(),
          const SizedBox(height: 16),
          _previewCard(),
        ],
      ],
    ),
  );

  Widget _editor() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${settings!.eventName}(テンプレートversion ${settings!.version})',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (!settings!.ready)
            for (final problem in settings!.problems)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  problemLabel(problem),
                  style: const TextStyle(color: Color(0xffb54708)),
                ),
              ),
          const SizedBox(height: 12),
          const Text(
            '宛名・受付QR・Web参加証URL・programと参加時間・参加人数・開催日時・会場・問い合わせ先は、'
            'システムが正確なデータから自動で挿入します(ここでは編集できません)。',
            style: TextStyle(color: Color(0xff5c6670)),
          ),
          const SizedBox(height: 14),
          _field(subject, '件名', helper: '1行・$_maxSubject文字以内。差し込み機能はありません。'),
          _field(intro, '冒頭本文', lines: 4, helper: 'プレーンテキスト。空行で段落になります。'),
          _field(closing, '締め本文', lines: 4),
          _field(
            notes,
            '注意事項(任意)',
            lines: 3,
            helper: '未入力なら、メールに注意事項の欄は表示されません。',
          ),
          _field(address, '会場の住所(任意)', helper: '未入力なら表示されません。'),
          _field(access, 'アクセス(任意)', lines: 2, helper: '未入力なら表示されません。'),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: busy ? null : save,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _previewCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'プレビュー',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '実際にその参加者へ届くメールの完成形を、サーバーが作成して表示します(送信はしません)。',
            style: TextStyle(color: Color(0xff5c6670)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: participantId,
            decoration: const InputDecoration(
              labelText: '参加者ID',
              helperText: '取込済み(committed)の参加者のID',
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: busy ? null : showPreview,
              child: const Text('プレビューを表示'),
            ),
          ),
          if (preview != null) ...[
            const Divider(height: 28),
            if (!preview!.ready)
              for (final problem in preview!.problems)
                Text(
                  problemLabel(problem),
                  style: const TextStyle(color: Color(0xffb42318)),
                )
            else ...[
              InfoRow('件名', preview!.subject),
              InfoRow('テンプレートversion', '${preview!.templateVersion}'),
              const SizedBox(height: 8),
              const Text(
                '本文(テキスト版)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xfff7f8fa),
                child: SelectableText(preview!.text),
              ),
              const SizedBox(height: 8),
              const Text(
                '実際のメールは、この内容に加えて受付用QRコードの画像が表示されます(HTMLメール)。',
                style: TextStyle(color: Color(0xff5c6670)),
              ),
            ],
          ],
        ],
      ),
    ),
  );
}
