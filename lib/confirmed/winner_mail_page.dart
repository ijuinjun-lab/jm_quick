import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'winner_mail_service.dart';

/// 当選メールの設定とプレビュー(adminのみ)。新方式(confirmed)のイベント専用。従来方式の設定画面には触れない。
///
/// 共通本文・注意事項・送信者名・問い合わせ先・住所・アクセス・未設定のトーク開催時間を管理する。
/// 宛名・受付QR・Web参加証URL・program名・参加時間・参加人数・開催日時・会場は、
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
  'attendance-time-missing' => '参加時間が未設定です。トークの開催時間はメール設定から設定できます。',
  'participation-type-invalid' => '参加programまたは人数を確認してください。参加タイプを確定できません。',
  'attendance-program-role-unknown' => '犬・猫・トークとの対応が未設定のprogramがあります。',
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
  final adoptionNotes = TextEditingController();
  bool mappingEnabled = false;
  Map<String, String> participationMapping = {};
  final talkTime = TextEditingController();
  final senderName = TextEditingController();
  final contact = TextEditingController();

  // キャンセル待ち繰り上げ当選メール(通常当選メールとは別のテンプレート)
  final wSubject = TextEditingController();
  final wIntro = TextEditingController();
  final wClosing = TextEditingController();
  final wNotes = TextEditingController();
  final wAdoptionNotes = TextEditingController();
  WinnerMailPreview? waitlistPreview;
  String? selectedType;
  String? selectedParticipant;
  List<Map<String, dynamic>> get availableParticipants => settings!.previewParticipants
      .where((p) => selectedType == null || p['participationType'] == selectedType).toList();
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
      access, adoptionNotes, talkTime, senderName, contact,
      wSubject, wIntro, wClosing, wNotes, wAdoptionNotes,
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
      participationMapping = Map.of(result.participationMapping);
      mappingEnabled = participationMapping.isNotEmpty;
      loaded = true;
      preview = null;
      subject.text = result.subject;
      intro.text = result.introBody;
      closing.text = result.closingBody;
      notes.text = result.notesBody;
      address.text = result.address;
      access.text = result.access;
      adoptionNotes.text = result.adoptionNotesBody;
      talkTime.text = result.mailSettings['talkTimeText'] as String? ?? '';
      senderName.text = result.mailSettings['senderName'] as String? ?? '';
      contact.text = result.mailSettings['contact'] as String? ?? '';
      selectedType = null;
      selectedParticipant = null;
      _fillWaitlist(result.waitlistTemplate ?? const {});
      waitlistPreview = null;
    });
  });

  void _fillWaitlist(Map<String, dynamic> template) {
    wSubject.text = template['subject'] as String? ?? '';
    wIntro.text = template['introBody'] as String? ?? '';
    wClosing.text = template['closingBody'] as String? ?? '';
    wNotes.text = template['notesBody'] as String? ?? '';
    wAdoptionNotes.text = template['adoptionNotesBody'] as String? ?? '';
  }

  String? _validateWaitlist() {
    if (wSubject.text.trim().isEmpty) return '繰り上げ当選メールの件名を入力してください。';
    if (wSubject.text.contains('\n')) return '件名は1行で入力してください。';
    if (wSubject.text.trim().length > _maxSubject) return '件名は$_maxSubject文字以内で入力してください。';
    if (wIntro.text.trim().isEmpty) return '繰り上げ当選メールの冒頭本文を入力してください。';
    if (wClosing.text.trim().isEmpty) return '繰り上げ当選メールの締め本文を入力してください。';
    for (final c in [wIntro, wClosing, wNotes, wAdoptionNotes]) {
      if (c.text.trim().length > _maxBody) return '本文は$_maxBody文字以内で入力してください。';
    }
    return null;
  }

  Future<void> saveWaitlist() => _run(() async {
    final problem = _validateWaitlist();
    if (problem != null) throw WinnerMailException(problem);
    final version = await widget.service.updateWaitlistTemplate(
      eventId: _eventId,
      subject: wSubject.text,
      introBody: wIntro.text,
      closingBody: wClosing.text,
      notesBody: wNotes.text,
      adoptionNotesBody: wAdoptionNotes.text,
    );
    final refreshed = await widget.service.getSettings(_eventId);
    if (!mounted) return;
    setState(() {
      settings = refreshed;
      waitlistPreview = null;
      message = '繰り上げ当選メールを保存しました(テンプレートversion $version)。';
    });
  });

  Future<void> showWaitlistPreview() => _run(() async {
    final id = settings?.previewParticipantId;
    if (id == null || id.isEmpty) return;
    final result = await widget.service.previewWaitlist(eventId: _eventId, participantId: id);
    if (mounted) setState(() => waitlistPreview = result);
  });

  String? _validate() {
    if (mappingEnabled && (participationMapping.length != 3 || participationMapping.values.toSet().length != 3)) return '猫・犬・トークに異なるprogramを選択してください。';
    if (subject.text.trim().isEmpty) return '件名を入力してください。';
    if (subject.text.contains('\n')) return '件名は1行で入力してください。';
    if (subject.text.trim().length > _maxSubject) {
      return '件名は$_maxSubject文字以内で入力してください。';
    }
    if (intro.text.trim().isEmpty) return '冒頭本文を入力してください。';
    if (closing.text.trim().isEmpty) return '締め本文を入力してください。';
    for (final c in [intro, closing, notes, adoptionNotes]) {
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
      adoptionNotesBody: adoptionNotes.text,
      participationMapping: mappingEnabled ? participationMapping : {},
      mailSettings: {'senderName': senderName.text, 'contact': contact.text, 'talkTimeText': talkTime.text},
    );
    final refreshed = await widget.service.getSettings(_eventId);
    if (!mounted) return;
    setState(() {
      settings = refreshed;
      preview = null;
      message = '保存しました(テンプレートversion $version)。';
    });
  });

  /// 対象イベントではタイプで絞って参加者を選ぶ。他イベントは既存の代表参加者を使う。
  /// 本文・QRはどちらも実送信と同じサーバー処理で生成する。
  Future<void> showPreview() => _run(() async {
    final id = settings!.participationTypes.isNotEmpty
        ? selectedParticipant ?? (availableParticipants.firstOrNull?['participantId'] as String?)
        : settings?.previewParticipantId;
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
    // 縦の余白は画面全体で統一する: 前の項目(説明文・補足文)との間に上8、次の項目との間に下16。
    padding: const EdgeInsets.only(top: 8, bottom: 16),
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

  /// フォームの中の説明文(項目の間に置く1文)。前後の入力欄と重ならないよう、上4・下12の余白を付ける。
  Widget _note(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 12),
    child: Text(text, key: key),
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
          const SizedBox(height: 16),
          _waitlistCard(),
        ],
      ],
    ),
  );

  /// キャンセル待ち繰り上げ当選メール。繰り上げ当選の取込回へ送るときに、サーバーが自動でこのメールを使う(送信画面では選ばない)。
  Widget _waitlistCard() {
    final w = settings!.waitlistTemplate;
    final preset = settings!.suggestedWaitlistTemplate;
    final p = waitlistPreview;
    return Card(
      key: const Key('waitlist-mail-card'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'キャンセル待ち繰り上げ当選メール',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              '取込時に「キャンセル待ち繰り上げ当選」を選んだ取込回へ送るメールです。通常当選メールとは別に保存されます。'
              '会場・送信者・問い合わせ先・QRは通常当選メールと同じ設定を使います。',
              style: TextStyle(color: Color(0xff5c6670)),
            ),
            const SizedBox(height: 6),
            Text(
              w == null
                  ? '未設定(このままでは繰り上げ当選の取込回へ送信できません)'
                  : '保存済み：テンプレートversion ${w['version']}${settings!.waitlistReady ? '' : '(不足があります)'}',
              key: const Key('waitlist-template-status'),
            ),
            const SizedBox(height: 10),
            if (preset.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const Key('load-waitlist-preset'),
                  onPressed: busy ? null : () => setState(() => _fillWaitlist(preset)),
                  child: const Text('繰り上げ当選の文案を入力'),
                ),
              ),
            const SizedBox(height: 10),
            _field(wSubject, '繰り上げ当選メールの件名'),
            _field(wIntro, '繰り上げ当選メールの冒頭本文', lines: 6),
            _field(wAdoptionNotes, '繰り上げ当選メールの譲渡会の注意事項(任意)', lines: 3),
            _field(wNotes, '繰り上げ当選メールの注意事項(任意)', lines: 3),
            _field(wClosing, '繰り上げ当選メールの締め本文', lines: 2),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: const Key('save-waitlist-template'),
                  onPressed: busy ? null : saveWaitlist,
                  child: const Text('繰り上げ当選メールを保存'),
                ),
                if (settings!.previewParticipantId != null)
                  OutlinedButton(
                    key: const Key('preview-waitlist'),
                    onPressed: busy || w == null ? null : showWaitlistPreview,
                    child: const Text('繰り上げ当選メールのプレビュー'),
                  ),
              ],
            ),
            if (p != null) ...[
              const Divider(height: 28),
              if (!p.ready)
                for (final problem in p.problems)
                  Text(problemLabel(problem), style: const TextStyle(color: Color(0xffb42318)))
              else ...[
                InfoRow('件名', p.subject),
                InfoRow('テンプレートversion', '${p.templateVersion}'),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xfff7f8fa),
                  child: SelectableText(p.text, key: const Key('waitlist-preview-text')),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

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
            '宛名・受付QR・Web参加証URL・programと参加時間・参加人数・開催日時・会場は、'
            'システムが正確なデータから自動で挿入します(ここでは編集できません)。',
            style: TextStyle(color: Color(0xff5c6670)),
          ),
          const SizedBox(height: 14),
          if (mappingEnabled && settings!.suggestedTemplate.isNotEmpty)
            OutlinedButton(
              onPressed: busy ? null : () => setState(() {
                final preset = settings!.suggestedTemplate;
                subject.text = preset['subject'] as String;
                intro.text = preset['introBody'] as String;
                closing.text = preset['closingBody'] as String;
                notes.text = preset['notesBody'] as String;
                adoptionNotes.text = preset['adoptionNotesBody'] as String;
                senderName.text = preset['senderName'] as String;
                contact.text = preset['contact'] as String;
                preview = null;
                message = '基準文案を入力しました。内容を確認し、保存すると反映されます。';
              }),
              child: const Text('HEBEL HAUS×sippo 基準文案を入力'),
            ),
          SwitchListTile(
            title: const Text('犬・猫・トークの7タイプ機能を有効にする'),
            value: mappingEnabled,
            onChanged: busy ? null : (value) => setState(() { mappingEnabled = value; }),
          ),
          if (mappingEnabled) ...[
            // 項目ごとに「ラベル(上) → プルダウン(下)」の独立した行にする(ラベルと前後のプルダウンを重ねない。狭い幅でも同じ)。
            for (final role in const {'cat': '猫', 'dog': '犬', 'talk': 'トーク'}.entries)
              Padding(
                key: ValueKey('mapping-row-${role.key}'),
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${role.value}に対応するprogram',
                      key: ValueKey('mapping-label-${role.key}'),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      key: ValueKey('mapping-${role.key}'),
                      initialValue: participationMapping['${role.key}ProgramId'],
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                      items: [for (final program in settings!.programs)
                        DropdownMenuItem(
                          value: program['programId'] as String,
                          child: Text('${program['name']} (${program['programId']})', overflow: TextOverflow.ellipsis),
                        )],
                      onChanged: busy ? null : (value) => setState(() { if (value != null) participationMapping['${role.key}ProgramId'] = value; }),
                    ),
                  ],
                ),
              ),
            _note('下の「保存」で本文と一緒に保存します。参加者ファイル取込前に設定してください。', key: const Key('mapping-save-note')),
          ],
          _field(senderName, '送信者名'),
          _note('送信元メールアドレスは既存メール配信基盤の設定を使用します。', key: const Key('sender-address-note')),
          _field(contact, 'お問い合わせ先', lines: 3),
          if (mappingEnabled) ...[
            _field(talkTime, 'トーク開催時間', helper: 'programに開催時間がある場合はそちらを優先します。未設定の時だけ使用します。'),
            _field(adoptionNotes, '譲渡会参加者向け注意事項', lines: 3, helper: '犬または猫の譲渡会に参加する方だけに表示します。'),
          ],
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
          // 内部IDの手入力ではなく、サーバーが返す有効・取込済み参加者を氏名で選ぶ。
          _note('プレビューには保存済みの設定が使われます。編集後は保存してください。', key: const Key('preview-saved-note')),
          if (settings!.participationTypes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: DropdownButtonFormField<String>(
                key: const Key('mail-type-filter'),
                initialValue: selectedType ?? '',
                decoration: const InputDecoration(labelText: '参加タイプ'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('全タイプ')),
                  for (final type in settings!.participationTypes)
                    DropdownMenuItem(value: type['value'] as String, child: Text(type['label'] as String)),
                ],
                onChanged: busy ? null : (value) => setState(() {
                  selectedType = value == '' ? null : value;
                  selectedParticipant = null;
                  preview = null;
                }),
              ),
            ),
            if (availableParticipants.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                child: DropdownButtonFormField<String>(
                  key: ValueKey('mail-participant-${selectedType ?? 'all'}'),
                  initialValue: selectedParticipant ?? availableParticipants.first['participantId'] as String,
                  decoration: const InputDecoration(labelText: 'プレビューする参加者'),
                  items: [for (var i = 0; i < availableParticipants.length; i++)
                    DropdownMenuItem(value: availableParticipants[i]['participantId'] as String,
                      child: Text('${i + 1}. ${availableParticipants[i]['name']}'))],
                  onChanged: busy ? null : (value) => setState(() { selectedParticipant = value; preview = null; }),
                ),
              )
            else
              _note('このタイプの取込済み参加者はいません。'),
          ],
          if (settings!.participationTypes.isNotEmpty ? availableParticipants.isNotEmpty : settings?.previewParticipantId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: busy ? null : showPreview,
                child: const Text('プレビューを表示'),
              ),
            )
          else if (settings?.previewParticipantId == null)
            const Text(
              '取込済みの参加者がありません。先に参加者ファイル取込を行ってください。',
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
