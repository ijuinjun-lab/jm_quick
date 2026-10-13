import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'event_settings_service.dart';
import 'winner_send_service.dart';

/// イベント設定(基本情報の確認・修正。`/console?eventId=…` のイベント管理画面から開く)。
/// システム管理者・このイベントのイベント管理者だけ(サーバー getConfirmedEventSettings / updateConfirmedEventSettings も同じ権限で拒否する)。
///
/// ■ 編集できるのは イベント名・開催日・開始時刻・終了時刻・会場名・住所・アクセス だけ(programs・参加者・受付・メールの設定は対象外)。
/// ■ 日時は日本時間で表示・入力し、UTC(ISO 8601)でサーバーへ送る。終了日時は開催日の時刻として入力する
///   (保存済みの終了日時が開始と別の日付なら、その日数の差を保つ)。終了日時は追加・変更できるが消せない。
/// ■ 変更したフィールドだけを、読み込んだ時点の値(同時更新の照合用)とあわせて送る。保存の前に変更前→変更後を確認する。
/// ■ 送信済みのメールがあれば警告する(送信済みメールの内容は変わらない。再送・変更通知はしない)。
class EventSettingsPage extends StatefulWidget {
  const EventSettingsPage({
    super.key,
    required this.eventId,
    required this.service,
  });

  final String eventId;
  final EventSettingsService service;

  @override
  State<EventSettingsPage> createState() => _EventSettingsPageState();
}

const Duration _jst = Duration(hours: 9);
String _two(int v) => v.toString().padLeft(2, '0');

/// UTC → 日本時間の「YYYY/MM/DD」「HH:mm」。
String jstDateText(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${t.year}/${_two(t.month)}/${_two(t.day)}';
}

String jstTimeText(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// 日本時間の日付・時刻の入力 → UTC。暦として成立しない値(2月30日・25時等)・形式違いはnull。
DateTime? jstInputToUtc(String date, String time) {
  final d = RegExp(r'^\s*(\d{4})[/-](\d{1,2})[/-](\d{1,2})\s*$').firstMatch(date);
  final t = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*$').firstMatch(time);
  if (d == null || t == null) return null;
  final [y, mo, da] = [for (var i = 1; i <= 3; i++) int.parse(d.group(i)!)];
  final [h, mi] = [int.parse(t.group(1)!), int.parse(t.group(2)!)];
  if (h > 23 || mi > 59) return null;
  final wall = DateTime.utc(y, mo, da, h, mi);
  if (wall.year != y || wall.month != mo || wall.day != da) return null;
  return wall.subtract(_jst);
}

/// 入力欄の内容。
typedef EventSettingsInput = ({
  String eventName,
  String date,
  String startTime,
  String endTime,
  String venue,
  String address,
  String access,
});

/// 変更点の計算(純粋関数)。changes は送る値(日時はUTCのISO)、diffは確認表示用の変更前→変更後(日本時間)。
/// 入力が不正なら error に理由を入れ、changes は空。
({Map<String, Object?> changes, List<(String, String, String)> diff, String? error})
computeEventSettingsChanges(EventSettings loaded, EventSettingsInput input) {
  const none = <String, Object?>{};
  String? error;
  final changes = <String, Object?>{};
  final diff = <(String, String, String)>[];
  String show(String? v) => v == null || v.isEmpty ? '(未設定)' : v;
  String showAt(DateTime? at) => at == null ? '(未設定)' : '${jstDateText(at)} ${jstTimeText(at)}';

  final name = input.eventName.trim();
  if (name.isEmpty) return (changes: none, diff: const [], error: 'イベント名を入力してください。');
  if (name != loaded.eventName.trim()) {
    changes['eventName'] = name;
    diff.add(('イベント名', show(loaded.eventName), name));
  }

  final start = jstInputToUtc(input.date, input.startTime);
  if (start == null) {
    return (changes: none, diff: const [], error: '開催日は「2026/11/30」、開始時刻は「10:00」の形式(日本時間)で入力してください。');
  }
  // 入力は分単位なので、分単位で比べる(秒のある保存値を、触っていないのに「変更あり」としない)
  DateTime minuteOf(DateTime t) {
    final u = t.toUtc();
    return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute);
  }

  bool sameMinute(DateTime a, DateTime? b) => b != null && minuteOf(a) == minuteOf(b);
  if (!sameMinute(start, loaded.startAt)) {
    changes['startAt'] = start.toIso8601String();
    diff.add(('開始日時', showAt(loaded.startAt), showAt(start)));
  }

  DateTime? end;
  if (input.endTime.trim().isEmpty) {
    if (loaded.endAt != null) {
      return (changes: none, diff: const [], error: '終了時刻は削除できません。正しい終了時刻を入力してください。');
    }
  } else {
    final sameDay = jstInputToUtc(input.date, input.endTime);
    if (sameDay == null) {
      return (changes: none, diff: const [], error: '終了時刻は「17:00」の形式(日本時間)で入力してください。');
    }
    // 保存済みの終了日時が開始と別の日付なら、その日数の差を保つ
    var days = 0;
    if (loaded.startAt != null && loaded.endAt != null) {
      final s = loaded.startAt!.toUtc().add(_jst);
      final e = loaded.endAt!.toUtc().add(_jst);
      days = DateTime.utc(e.year, e.month, e.day).difference(DateTime.utc(s.year, s.month, s.day)).inDays;
    }
    end = sameDay.add(Duration(days: days));
    if (!end.isAfter(start)) {
      return (changes: none, diff: const [], error: '終了時刻は、開始時刻より後にしてください。');
    }
    if (!sameMinute(end, loaded.endAt)) {
      changes['endAt'] = end.toIso8601String();
      diff.add(('終了日時', showAt(loaded.endAt), showAt(end)));
    }
  }

  final venue = input.venue.trim();
  if (venue.isEmpty) return (changes: none, diff: const [], error: '会場名を入力してください。');
  if (venue != loaded.venue.trim()) {
    changes['venue'] = venue;
    diff.add(('会場名', show(loaded.venue), venue));
  }
  for (final (field, label, value, current) in [
    ('address', '住所', input.address.trim(), loaded.address?.trim() ?? ''),
    ('access', 'アクセス', input.access.trim(), loaded.access?.trim() ?? ''),
  ]) {
    if (value != current) {
      changes[field] = value.isEmpty ? null : value;
      diff.add((label, show(current), show(value)));
    }
  }
  return (changes: changes, diff: diff, error: error);
}

class _EventSettingsPageState extends State<EventSettingsPage> {
  EventSettingsView? view;
  bool loading = true;
  bool saving = false;
  String? loadError;
  String? saveError;
  String? saved;

  final name = TextEditingController();
  final date = TextEditingController();
  final start = TextEditingController();
  final end = TextEditingController();
  final venue = TextEditingController();
  final address = TextEditingController();
  final access = TextEditingController();

  List<TextEditingController> get _all => [name, date, start, end, venue, address, access];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({String? savedMessage}) async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final loaded = await widget.service.getSettings(widget.eventId);
      if (!mounted) return;
      final s = loaded.settings;
      name.text = s.eventName;
      date.text = s.startAt == null ? '' : jstDateText(s.startAt!);
      start.text = s.startAt == null ? '' : jstTimeText(s.startAt!);
      end.text = s.endAt == null ? '' : jstTimeText(s.endAt!);
      venue.text = s.venue;
      address.text = s.address ?? '';
      access.text = s.access ?? '';
      setState(() {
        view = loaded;
        saveError = null;
        saved = savedMessage;
      });
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => loadError = e.message);
    } catch (_) {
      if (mounted) setState(() => loadError = 'イベント設定を読み込めませんでした。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  EventSettingsInput get _input => (
    eventName: name.text,
    date: date.text,
    startTime: start.text,
    endTime: end.text,
    venue: venue.text,
    address: address.text,
    access: access.text,
  );

  Future<void> _save() async {
    final v = view;
    if (v == null || saving) return;
    final computed = computeEventSettingsChanges(v.settings, _input);
    if (computed.error != null || computed.changes.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('イベント設定を変更します'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (label, before, after) in computed.diff)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('変更前：$before'),
                      Text('変更後：$after', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (v.sentMail.any) _mailWarning(v.sentMail, key: const Key('event-settings-confirm-mail-warning')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('やめる')),
          FilledButton(
            key: const Key('event-settings-confirm-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('変更を保存する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      saving = true;
      saveError = null;
      saved = null;
    });
    try {
      await widget.service.update(
        widget.eventId,
        changes: computed.changes,
        expected: {for (final f in computed.changes.keys) f: v.settings.expectedOf(f)},
      );
      if (!mounted) return;
      await _load(savedMessage: '保存しました(${computed.diff.map((d) => d.$1).join('・')})。');
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => saveError = e.message);
    } catch (_) {
      if (mounted) setState(() => saveError = '保存できませんでした。最新の内容を読み込み直して、もう一度お試しください。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget _mailWarning(EventSentMail mail, {Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.all(12),
    margin: const EdgeInsets.only(bottom: 12),
    color: const Color(0xfffff1cf),
    child: Text(
      'このイベントでは、すでにメールを送信しています(送信済み${mail.sentCount}件'
      '${mail.unknownCount > 0 ? '・結果不明${mail.unknownCount}件' : ''})。'
      '保存しても、送信済みのメールの内容は変わりません。メールの再送や変更のお知らせは送られません。'
      '必要な場合は、参加者へ別途ご案内ください。',
    ),
  );

  Widget _field(TextEditingController c, String label, Key key, {String? hint, int maxLines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: key,
      controller: c,
      maxLines: maxLines,
      onChanged: (_) => setState(() => saved = null),
      decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final v = view;
    final computed = v == null ? null : computeEventSettingsChanges(v.settings, _input);
    final canSave = !saving && computed != null && computed.error == null && computed.changes.isNotEmpty;
    return PageFrame(
      title: 'イベント設定',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'イベントの基本情報を確認・修正します。日時は日本時間です。'
                'プログラム・参加者・受付・メールの文面は、この画面では変わりません。',
                style: TextStyle(color: Color(0xff5c6670)),
              ),
              const SizedBox(height: 12),
              if (loading && v == null) const Center(child: CircularProgressIndicator()),
              if (loadError != null)
                Container(
                  key: const Key('event-settings-load-error'),
                  padding: const EdgeInsets.all(12),
                  color: const Color(0xffffe8e8),
                  child: Text(loadError!),
                ),
              if (v != null) ...[
                if (v.sentMail.any) _mailWarning(v.sentMail, key: const Key('event-settings-mail-warning')),
                _field(name, 'イベント名', const Key('event-settings-name')),
                _field(date, '開催日(日本時間)', const Key('event-settings-date'), hint: '2026/11/30'),
                Row(
                  children: [
                    Expanded(child: _field(start, '開始時刻', const Key('event-settings-start'), hint: '10:00')),
                    const SizedBox(width: 12),
                    Expanded(child: _field(end, '終了時刻', const Key('event-settings-end'), hint: '17:00')),
                  ],
                ),
                if (v.settings.endAt == null)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      '終了時刻が未設定です。設定すると、受付状況一覧・最終実績Excelで、時間帯の無いプログラムの欠席を判定できます。',
                      key: Key('event-settings-end-missing'),
                      style: TextStyle(color: Color(0xffb54708), fontSize: 12),
                    ),
                  ),
                _field(venue, '会場名', const Key('event-settings-venue')),
                _field(address, '住所', const Key('event-settings-address'), maxLines: 2),
                _field(access, 'アクセス', const Key('event-settings-access'), maxLines: 3),
                if (computed?.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      computed!.error!,
                      key: const Key('event-settings-input-error'),
                      style: const TextStyle(color: Color(0xffb42318)),
                    ),
                  ),
                if (computed != null && computed.error == null && computed.changes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('変更はありません。', key: Key('event-settings-no-change'), style: TextStyle(color: Color(0xff5c6670))),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('event-settings-save'),
                      onPressed: canSave ? _save : null,
                      icon: saving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save_outlined),
                      label: const Text('変更内容を確認して保存'),
                    ),
                    OutlinedButton(
                      key: const Key('event-settings-reload'),
                      onPressed: loading || saving ? null : _load,
                      child: const Text('最新の内容を読み込む'),
                    ),
                  ],
                ),
                if (saveError != null)
                  Container(
                    key: const Key('event-settings-save-error'),
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xffffe8e8),
                    child: Text(saveError!),
                  ),
                if (saved != null)
                  Container(
                    key: const Key('event-settings-saved'),
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xffeef3f8),
                    child: Text(saved!),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
