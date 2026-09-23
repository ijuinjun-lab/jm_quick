import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'winner_mail_service.dart';

/// 当選メールの設定とプレビュー(adminのみ)。新方式(confirmed)のイベント専用。従来方式の設定画面には触れない。
///
/// 管理者が編集するのは「件名・冒頭本文・締め本文・注意事項」と会場の住所・アクセス(すべてプレーンテキスト)。
/// 宛名・受付QR・Web参加証URL・program名・参加時間・参加人数・開催日時・会場・問い合わせ先は、
/// サーバーが正確なデータから自動生成するため、ここでは編集できない。
///
/// ■ Phase 11D: [initialEventId](イベント管理画面から内部的に渡される)を正本として使う。利用者が
///   イベントIDを見る・入力する・書き換える欄は無い。[initialEventId]が無い状態(直接この画面に来た場合)は、
///   イベントを推測したり最初のイベントを自動選択したりせず、「イベント管理画面から開いてください」という
///   案内だけを表示する。
class WinnerMailPage extends StatefulWidget {
  const WinnerMailPage({super.key, required this.service, this.initialEventId});
  final WinnerMailService service;

  /// イベント管理画面(`/console?eventId=…`)から渡される、対象イベントのID(正本)。
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
  final subject = TextEditingController();
  final intro = TextEditingController();
  final closing = TextEditingController();
  final notes = TextEditingController();
  final address = TextEditingController();
  final access = TextEditingController();
  bool busy = false;
  bool loaded = false;
  String? message;
  String? error;
  WinnerMailSettings? settings;
  WinnerMailPreview? preview;

  String get _eventId => (widget.initialEventId ?? '').trim();
  bool get _hasEventId => _eventId.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasEventId) load();
  }

  @override
  void dispose() {
    for (final c in [
      subject,
      intro,
      closing,
      notes,
      address,
      access,
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
    if (!_hasEventId) return; // 呼び出し元がガードしている
    final result = await widget.service.getSettings(_eventId);
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
      eventId: _eventId,
      subject: subject.text,
      introBody: intro.text,
      closingBody: closing.text,
      notesBody: notes.text,
      address: address.text,
      access: access.text,
    );
    final refreshed = await widget.service.getSettings(_eventId);
    if (!mounted) return;
    setState(() {
      settings = refreshed;
      preview = null;
      message = '保存しました(テンプレートversion $version)。';
    });
  });

  /// プレビュー対象の参加者は、利用者が入力するのではなく、サーバー([WinnerMailSettings.previewParticipantId])
  /// が選んだ「このイベントの有効(active)かつ取込(committed)済み」の参加者から自動的に決まる
  /// (取込回=第1回・第2回…は問わない。0件ならこのメソッドは呼ばれない=ボタン自体を表示しない)。
  Future<void> showPreview() => _run(() async {
    final id = settings?.previewParticipantId;
    if (id == null || id.isEmpty) return; // ボタンを表示していないので通常到達しない
    final result = await widget.service.preview(
      eventId: _eventId,
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
    child: !_hasEventId
        ? missingEventCard(context)
        : Column(
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
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    key: const Key('winner-mail-reload'),
                    onPressed: busy ? null : load,
                    child: const Text('最新の状態に更新'),
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

  /// 実送信と同じ composeWinnerMailFor が生成したQR画像(PNG・base64)をそのまま表示する。
  /// ここで新しくQRを生成することはしない(サーバーが返した画像バイト列をデコードして表示するだけ)。
  /// サーバーの応答が想定外(空・壊れたbase64)でも、例外で画面全体を落とさない。
  Widget _qrPreview(String base64Png) {
    if (base64Png.isEmpty) {
      return const Text(
        'QR画像を取得できませんでした。',
        style: TextStyle(color: Color(0xffb42318)),
      );
    }
    try {
      final bytes = base64Decode(base64Png);
      return Align(
        alignment: Alignment.centerLeft,
        child: Image.memory(bytes, width: 240, height: 240, fit: BoxFit.contain),
      );
    } catch (_) {
      return const Text(
        'QR画像を表示できませんでした。',
        style: TextStyle(color: Color(0xffb42318)),
      );
    }
  }

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
          // 参加者ID・publicId・eventIdなど、内部IDを利用者が入力する欄は置かない。
          // プレビュー対象は、このイベントの取込済み参加者からシステムが自動的に選ぶ。
          if (settings?.previewParticipantId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: busy ? null : showPreview,
                child: const Text('プレビューを表示'),
              ),
            )
          else
            const Text(
              '取込済みの参加者がありません。先にCSV取込を行ってください。',
              style: TextStyle(color: Color(0xff5c6670)),
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
              const SizedBox(height: 20),
              // Phase 11J: HTMLメール自体(preview!.html)はここに埋め込まない。QR画像はメールでは
              // cid:(MIME添付の参照)で埋め込まれておりブラウザでは解決できず、また任意のサーバーHTMLを
              // そのままFlutter側でDOM描画する経路を新設しない(script実行・危険なnavigation対策)。
              // 代わりに、実送信と全く同じ composeWinnerMailFor が生成したQR画像そのもの(preview!.qrPngBase64。
              // ここでQRを作り直してはいない)と、実送信と同じWeb参加証URLを、Flutter widgetとして表示する。
              const Text(
                'HTMLメールプレビュー(受付QR画像を含む完成形)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                '実際のHTMLメールに表示されるのと同じQR画像です(実送信と同じ処理で生成したものをそのまま表示しています)。'
                '宛名・参加program・参加時間・参加人数・開催情報は、上の本文(テキスト版)と同じ内容がHTMLメールにも入ります。',
                style: TextStyle(color: Color(0xff5c6670)),
              ),
              const SizedBox(height: 10),
              _qrPreview(preview!.qrPngBase64),
              const SizedBox(height: 14),
              const Text(
                'Web参加証URL(QRコードが読み取れない場合、メール内にもこのリンクが表示されます)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              SelectableText(preview!.webPassUrl),
            ],
          ],
        ],
      ),
    ),
  );
}
