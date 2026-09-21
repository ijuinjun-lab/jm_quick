import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'event_create_service.dart';

/// programIDの形式(サーバーの programs.js と同じ規則。固有名は持たない)。
final RegExp _programIdPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$',
);

/// 入力された日本時間の日時("2026-11-30 10:00" / "2026/11/30 10:00")を、オフセット付きISO 8601へ変換する。
/// 存在しない日付・時刻は null。
String? parseJstDateTime(String input) {
  final match = RegExp(
    r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T](\d{1,2}):(\d{2})$',
  ).firstMatch(input.trim());
  if (match == null) return null;
  final y = int.parse(match.group(1)!);
  final mo = int.parse(match.group(2)!);
  final d = int.parse(match.group(3)!);
  final h = int.parse(match.group(4)!);
  final mi = int.parse(match.group(5)!);
  final check = DateTime.utc(y, mo, d, h, mi);
  if (check.year != y ||
      check.month != mo ||
      check.day != d ||
      h > 23 ||
      mi > 59) {
    return null;
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${y.toString().padLeft(4, '0')}-${two(mo)}-${two(d)}T${two(h)}:${two(mi)}:00+09:00';
}

/// 作成要求ID(個人情報を含まない、推測されにくいランダム値)。再試行では同じ値を使い、イベントの二重作成を防ぐ。
String newRequestId([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(18, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

/// 新方式イベントの作成画面の入口(`/console/events/new`)。管理者(admin)としてログインした場合だけフォームが表示される。
/// 受付スタッフ・権限なし・未ログインでは作成できない(サーバー側もadmin専用)。
class ConfirmedEventCreateRoute extends StatelessWidget {
  ConfirmedEventCreateRoute({
    super.key,
    AuthClient? authClient,
    this.accessService,
    this.service,
    this.onCreated,
  }) : authClient = authClient ?? FirebaseAuthClient();

  final AuthClient authClient;
  final AccessService? accessService;
  final EventCreateService? service;
  final void Function(BuildContext context, String eventId)? onCreated;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => ConfirmedEventCreatePage(
      service: service ?? CallableEventCreateService(authClient: authClient),
      onCreated: onCreated,
    ),
    staffBuilder: (context, signOut) => PageFrame(
      title: 'イベントの作成',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'イベントの作成は管理者のみ利用できます',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
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

class _ProgramRow {
  _ProgramRow(String id) : programId = TextEditingController(text: id);
  final TextEditingController programId;
  final TextEditingController name = TextEditingController();
  void dispose() {
    programId.dispose();
    name.dispose();
  }
}

// 確認ダイアログの1行(狭い画面でも長い値が折り返されるよう、ラベルの下に値を置く)
Widget _confirmRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 6),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(color: Color(0xff5c6670), fontSize: 12),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  ),
);

/// 新方式イベントの作成フォーム(イベント基本情報+program)。内容を確認してから作成する。
/// Firestoreは直接使わず、admin専用のサーバーAPIだけを呼ぶ。
class ConfirmedEventCreatePage extends StatefulWidget {
  const ConfirmedEventCreatePage({
    super.key,
    required this.service,
    this.onCreated,
    this.now,
    this.requestIdFactory,
  });
  final EventCreateService service;

  /// 作成成功後の遷移。既定は新方式の管理画面(/console)。
  final void Function(BuildContext context, String eventId)? onCreated;

  /// 現在時刻(テスト用)。開催日時が過去でないかの確認に使う。
  final DateTime Function()? now;
  final String Function()? requestIdFactory;

  @override
  State<ConfirmedEventCreatePage> createState() =>
      _ConfirmedEventCreatePageState();
}

class _ConfirmedEventCreatePageState extends State<ConfirmedEventCreatePage> {
  final eventName = TextEditingController();
  final startAt = TextEditingController();
  final endAt = TextEditingController();
  final venue = TextEditingController();
  final address = TextEditingController();
  final access = TextEditingController();
  final senderName = TextEditingController();
  final contact = TextEditingController();
  final List<_ProgramRow> programs = [];
  late String requestId = _newId();
  bool busy = false;
  String? error;
  List<String> problems = const [];
  int _nextProgramNumber = 1;

  String _newId() => widget.requestIdFactory?.call() ?? newRequestId();

  @override
  void initState() {
    super.initState();
    _addProgram();
  }

  @override
  void dispose() {
    for (final c in [
      eventName,
      startAt,
      endAt,
      venue,
      address,
      access,
      senderName,
      contact,
    ]) {
      c.dispose();
    }
    for (final row in programs) {
      row.dispose();
    }
    super.dispose();
  }

  void _addProgram() {
    programs.add(_ProgramRow('program-${_nextProgramNumber++}'));
  }

  ConfirmedEventDraft? _draft(List<String> issues) {
    final start = parseJstDateTime(startAt.text);
    final endText = endAt.text.trim();
    final end = endText.isEmpty ? null : parseJstDateTime(endText);
    if (eventName.text.trim().isEmpty) issues.add('イベント名を入力してください。');
    if (start == null) {
      issues.add('開催日時を「2026-11-30 10:00」の形式で入力してください(日本時間)。');
    } else if (!DateTime.parse(start).isAfter((widget.now ?? DateTime.now)())) {
      issues.add('開催日時は現在より後の日時にしてください。');
    }
    if (endText.isNotEmpty && end == null) {
      issues.add('終了日時を「2026-11-30 17:00」の形式で入力してください(日本時間)。');
    }
    if (start != null &&
        end != null &&
        !DateTime.parse(end).isAfter(DateTime.parse(start))) {
      issues.add('終了日時は開催日時より後にしてください。');
    }
    if (venue.text.trim().isEmpty) issues.add('会場名を入力してください。');
    if (programs.isEmpty) issues.add('programを1件以上追加してください。');
    final seen = <String>{};
    for (var i = 0; i < programs.length; i++) {
      final id = programs[i].programId.text.trim();
      final label = 'program ${i + 1}';
      if (!_programIdPattern.hasMatch(id)) {
        issues.add('$labelのIDは、英小文字・数字・ハイフンで指定してください(先頭と末尾は英数字)。');
      } else if (!seen.add(id)) {
        issues.add('$labelのIDが重複しています。');
      }
      if (programs[i].name.text.trim().isEmpty) {
        issues.add('$labelの表示名を入力してください。');
      }
    }
    if (issues.isNotEmpty || start == null) return null;
    return ConfirmedEventDraft(
      eventName: eventName.text,
      startAt: start,
      endAt: end,
      venue: venue.text,
      address: address.text,
      access: access.text,
      senderName: senderName.text,
      contact: contact.text,
      programs: [
        for (final row in programs)
          ConfirmedProgramDraft(
            programId: row.programId.text,
            name: row.name.text,
          ),
      ],
    );
  }

  Future<void> _submit() async {
    if (busy) return;
    final issues = <String>[];
    final draft = _draft(issues);
    if (draft == null) {
      setState(() => problems = issues);
      return;
    }
    setState(() {
      problems = const [];
      busy = true; // 確認ダイアログを開いている間も、二重に押せないようにする
    });
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この内容でイベントを作成します'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _confirmRow('イベント名', eventName.text.trim()),
              _confirmRow('開催日時', startAt.text.trim()),
              _confirmRow('会場', venue.text.trim()),
              _confirmRow('program数', '${programs.length}件'),
              for (var i = 0; i < programs.length; i++)
                _confirmRow('program ${i + 1}', programs[i].name.text.trim()),
              const SizedBox(height: 10),
              const Text(
                '作成しただけでは、メールは送信されません。',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('作成する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => busy = false);
      return;
    }
    setState(() => error = null);
    try {
      final created = await widget.service.create(
        requestId: requestId,
        draft: draft,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            created.created ? 'イベントを作成しました。' : 'このイベントは既に作成されています。',
          ),
        ),
      );
      final onCreated = widget.onCreated;
      if (onCreated != null) {
        onCreated(context, created.eventId);
      } else {
        Navigator.of(context).pushReplacementNamed(
          '/console?eventId=${Uri.encodeQueryComponent(created.eventId)}',
        );
      }
    } on EventCreateException catch (e) {
      // 通信の失敗など作成の有無が不明な場合は、同じ作成要求IDで再試行できるようにする(二重作成されない)。
      // サーバーが明確に拒否した場合は、内容を直して新しい作成要求として送る。
      if (!e.ambiguous) requestId = _newId();
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '処理に失敗しました。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: key,
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '新方式のイベントを作成',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('作成しただけでは、メールは送信されません。参加者の取込・メール設定は、作成後の管理画面で行います。'),
            const SizedBox(height: 16),
            _field('イベント名(必須)', eventName, key: const Key('event-name')),
            _field(
              '開催日時(必須・日本時間)',
              startAt,
              hint: '例: 2026-11-30 10:00',
              key: const Key('start-at'),
            ),
            _field(
              '終了日時(日本時間)',
              endAt,
              hint: '例: 2026-11-30 17:00',
              key: const Key('end-at'),
            ),
            _field('会場名(必須)', venue, key: const Key('venue')),
            _field('住所', address, key: const Key('address')),
            _field('アクセス', access, maxLines: 2, key: const Key('access')),
            _field('送信者名(任意)', senderName),
            _field('問い合わせ先(任意)', contact),
            const SizedBox(height: 8),
            const Text(
              'program(1件以上・表示順は上から)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < programs.length; i++)
              Card(
                key: ValueKey('program-card-$i'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _field(
                        'program ${i + 1} のID(英小文字・数字・ハイフン)',
                        programs[i].programId,
                        key: Key('program-id-$i'),
                      ),
                      _field(
                        'program ${i + 1} の表示名',
                        programs[i].name,
                        key: Key('program-name-$i'),
                      ),
                      Wrap(
                        alignment: WrapAlignment.end,
                        children: [
                          IconButton(
                            tooltip: '上へ',
                            onPressed: busy || i == 0
                                ? null
                                : () => setState(() {
                                    final row = programs.removeAt(i);
                                    programs.insert(i - 1, row);
                                  }),
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: '下へ',
                            onPressed: busy || i == programs.length - 1
                                ? null
                                : () => setState(() {
                                    final row = programs.removeAt(i);
                                    programs.insert(i + 1, row);
                                  }),
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          IconButton(
                            key: Key('program-delete-$i'),
                            tooltip: 'このprogramを削除',
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    programs.removeAt(i).dispose();
                                  }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('add-program'),
                onPressed: busy ? null : () => setState(_addProgram),
                icon: const Icon(Icons.add),
                label: const Text('programを追加'),
              ),
            ),
            const SizedBox(height: 16),
            if (problems.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                color: const Color(0xffffe8e8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final p in problems) Text('・$p')],
                ),
              ),
            if (error != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                color: const Color(0xffffe8e8),
                child: Text(error!),
              ),
            FilledButton(
              key: const Key('create-event'),
              onPressed: busy ? null : _submit,
              child: Text(busy ? '処理中…' : '内容を確認して作成'),
            ),
          ],
        ),
      ),
    ),
  );
}
