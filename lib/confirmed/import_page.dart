import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_service.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'import_models.dart';
import 'import_service.dart';

/// 選択されたCSV(ファイル名と内容)。
typedef PickedCsv = ({String name, Uint8List bytes});

/// CSVファイルの選択(既定はブラウザのファイル選択。テストでは差し替える)。キャンセルはnull。
typedef CsvPicker = Future<PickedCsv?> Function();

Future<PickedCsv?> pickCsvWithFilePicker() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    withData: true,
  );
  final file = result?.files.single;
  if (file == null || file.bytes == null) return null;
  return (name: file.name, bytes: file.bytes!);
}

/// 新方式イベントへの参加者CSV取込の入口(`/console/import?eventId=…`)。管理者(admin)としてログインした場合だけ表示される。
/// 受付スタッフ・権限なし・未ログインでは表示されない(サーバー側もadmin専用)。
class ConfirmedImportRoute extends StatelessWidget {
  ConfirmedImportRoute({
    super.key,
    this.eventId,
    AuthClient? authClient,
    this.accessService,
    this.service,
    this.picker,
  }) : authClient = authClient ?? FirebaseAuthClient();

  final String? eventId;
  final AuthClient authClient;
  final AccessService? accessService;
  final ImportService? service;
  final CsvPicker? picker;

  @override
  Widget build(BuildContext context) => AuthGate(
    authClient: authClient,
    accessService:
        accessService ?? CallableAccessService(authClient: authClient),
    adminBuilder: (context, signOut) => ConfirmedImportPage(
      eventId: eventId,
      service: service ?? CallableImportService(authClient: authClient),
      picker: picker ?? pickCsvWithFilePicker,
    ),
    staffBuilder: (context, signOut) => PageFrame(
      title: '参加者CSVの取込',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'CSVの取込は管理者のみ利用できます',
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

/// 参加者CSVの取込画面。
///   イベント → CSVファイル選択 → 列の対応(mapping) → プレビュー → 内容確認 → 「取込を確定」→ 完了
/// プレビューを行わないと確定できず、ファイルまたは列の対応を変えるとプレビューは無効になる(再プレビューが必要)。
/// 取込はサーバー(previewConfirmedImport / commitConfirmedImport)が正本で、人物の同一性による統合はしない(1行=1参加者)。
/// 完了してもメールは送信されない(当選メールの送信は、別の画面で管理者が明示的に行う)。
class ConfirmedImportPage extends StatefulWidget {
  const ConfirmedImportPage({
    super.key,
    this.eventId,
    required this.service,
    required this.picker,
    this.onDone,
  });
  final String? eventId;
  final ImportService service;
  final CsvPicker picker;

  /// 完了後の「イベント管理へ戻る」。既定は新方式の管理画面(/console?eventId=…)。
  final void Function(BuildContext context, String eventId)? onDone;

  @override
  State<ConfirmedImportPage> createState() => _ConfirmedImportPageState();
}

class _ConfirmedImportPageState extends State<ConfirmedImportPage> {
  final eventIdController = TextEditingController();
  ImportEventSummary? event;
  String? eventError;
  bool loadingEvent = false;

  PickedCsv? file;
  CsvTable? table;
  String? fileError;
  ImportMapping? mapping;
  // 「許可する値」等の入力欄の状態(モデルのオブジェクトごとに1つ。再描画で入力が消えないようにする)
  final Map<String, TextEditingController> _valueControllers = {};

  bool previewing = false;
  bool committing = false;
  ImportRequest? previewedRequest;
  ImportPreview? preview;
  String? previewError;
  final Set<int> approved = {};

  ImportResult? result;
  String? commitError;
  bool commitAmbiguous = false;

  bool get busy => previewing || committing;
  bool get _eventFixed => (widget.eventId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_eventFixed) {
      eventIdController.text = widget.eventId!;
      _loadEvent();
    }
  }

  @override
  void dispose() {
    eventIdController.dispose();
    for (final c in _valueControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- イベント ----------------------------------------------------------------------------------
  Future<void> _loadEvent() async {
    final id = eventIdController.text.trim();
    if (id.isEmpty) return;
    setState(() {
      loadingEvent = true;
      eventError = null;
      event = null;
      _resetFile();
    });
    try {
      final loaded = await widget.service.getEvent(id);
      if (!mounted) return;
      setState(() => event = loaded);
    } on ImportException catch (e) {
      if (mounted) setState(() => eventError = e.message);
    } catch (_) {
      if (mounted) setState(() => eventError = 'イベントを読み込めませんでした。');
    } finally {
      if (mounted) setState(() => loadingEvent = false);
    }
  }

  // ---- ファイル ----------------------------------------------------------------------------------
  void _resetFile() {
    file = null;
    table = null;
    fileError = null;
    mapping = null;
    for (final c in _valueControllers.values) {
      c.dispose();
    }
    _valueControllers.clear();
    _invalidatePreview();
    result = null;
    commitError = null;
    commitAmbiguous = false;
  }

  // ファイル・列の対応・program選択が変わったら、以前のプレビュー(と承認)は無効。再プレビューが必要
  void _invalidatePreview() {
    previewedRequest = null;
    preview = null;
    previewError = null;
    approved.clear();
  }

  Future<void> _pickFile() async {
    if (busy || event == null) return;
    final PickedCsv? picked;
    try {
      picked = await widget.picker();
    } catch (_) {
      if (mounted) setState(() => fileError = 'CSVファイルを開けませんでした。もう一度お試しください。');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() {
      _resetFile();
      file = picked;
      try {
        table = parseCsvBytes(picked!.bytes);
        mapping = ImportMapping(
          programs: [
            for (final p in event!.programs)
              ProgramMapping(programId: p.programId, name: p.name),
          ],
        );
      } on CsvParseException catch (e) {
        fileError = e.message;
      }
    });
  }

  void _mappingChanged(VoidCallback change) {
    if (busy) return;
    setState(() {
      change();
      _invalidatePreview();
      result = null;
    });
  }

  // ---- プレビュー ---------------------------------------------------------------------------------
  List<String> get _mappingIssues => mapping?.validate() ?? const [];

  Future<void> _runPreview() async {
    if (busy || table == null || mapping == null || event == null) return;
    final issues = _mappingIssues;
    if (issues.isNotEmpty) {
      setState(() => previewError = issues.join('\n'));
      return;
    }
    final ImportRequest request;
    try {
      request = buildImportRequest(
        eventId: event!.eventId,
        fileName: file!.name,
        fileBytes: file!.bytes,
        table: table!,
        mapping: mapping!,
      );
    } on CsvParseException catch (e) {
      setState(() => previewError = e.message);
      return;
    }
    setState(() {
      previewing = true;
      _invalidatePreview();
      result = null;
      commitError = null;
    });
    try {
      final loaded = await widget.service.preview(request);
      if (!mounted) return;
      setState(() {
        // このプレビューに対応するリクエストをそのまま保持し、確定でもこの内容だけを送る
        previewedRequest = request;
        preview = loaded;
      });
    } on ImportException catch (e) {
      if (mounted) setState(() => previewError = e.message);
    } catch (_) {
      if (mounted) setState(() => previewError = 'プレビューできませんでした。');
    } finally {
      if (mounted) setState(() => previewing = false);
    }
  }

  // ---- 確定 --------------------------------------------------------------------------------------
  int get _importCount =>
      (preview?.readyCount ?? 0) + approved.length; // 取込対象(取込対象の行+管理者が承認した確認の行)

  bool get _canCommit =>
      !busy &&
      preview != null &&
      previewedRequest != null &&
      result?.committed != true &&
      _importCount > 0;

  Future<void> _confirmAndCommit() async {
    if (!_canCommit) return;
    final p = preview!;
    final request = previewedRequest!;
    final enabled = mapping!.enabledPrograms;
    setState(() => committing = true); // 確認ダイアログの間も、二重に押せないようにする
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この内容で取り込みます'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _confirmRow('イベント名', event!.eventName),
              _confirmRow('CSVファイル名', request.fileName),
              _confirmRow('CSV総行数', '${p.totalRecords}行'),
              _confirmRow('取込対象件数', '$_importCount件'),
              _confirmRow('エラー件数', '${p.errorCount}件(取り込まれません)'),
              _confirmRow(
                '未承認の確認行',
                '${p.reviewCount - approved.length}件(取り込まれません)',
              ),
              const SizedBox(height: 6),
              const Text(
                'programの対応',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final g in enabled)
                _confirmRow(
                  g.name,
                  '人数: ${g.countColumn}'
                  '${g.participationColumn == null ? '' : ' / 参加: ${g.participationColumn}'}',
                ),
              const SizedBox(height: 10),
              const Text(
                '取り込んでも、メールは送信されません。',
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
            child: const Text('取込を確定'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      if (mounted) setState(() => committing = false);
      return;
    }
    setState(() {
      commitError = null;
      commitAmbiguous = false;
    });
    try {
      final done = await widget.service.commit(
        request,
        approvedReviewRows: approved.toList(),
      );
      if (!mounted) return;
      setState(() => result = done);
    } on ImportException catch (e) {
      if (mounted) {
        setState(() {
          commitError = e.message;
          commitAmbiguous = e.ambiguous;
        });
      }
    } catch (_) {
      if (mounted) setState(() => commitError = '取込に失敗しました。');
    } finally {
      if (mounted) setState(() => committing = false);
    }
  }

  // ---- 表示 --------------------------------------------------------------------------------------
  Widget _confirmRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
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

  Widget _section(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );

  Widget _notice(
    String text, {
    Color color = const Color(0xffffe8e8),
    Key? key,
  }) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 8, bottom: 4),
    padding: const EdgeInsets.all(12),
    color: color,
    child: SelectableText(text),
  );

  Widget _columnDropdown({
    required Key key,
    required String label,
    required String? value,
    required void Function(String?) onChanged,
    bool optional = false,
  }) {
    final headers = <String>{
      ...table!.headers.where((h) => h.isNotEmpty),
    }.toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<String?>(
        key: key,
        isExpanded: true,
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        items: [
          DropdownMenuItem<String?>(
            value: null,
            child: Text(
              optional ? '(使わない)' : '選択してください',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          for (final h in headers)
            DropdownMenuItem<String?>(
              value: h,
              child: Text(h, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: busy ? null : onChanged,
      ),
    );
  }

  List<String> _lines(String text) => [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  // 選んだ列にあるCSVの値(参加・不参加の値を選ぶための参考。先頭の一部だけ)
  String _valuesOf(String column) {
    final index = table!.headers.indexOf(column);
    if (index < 0) return '';
    final seen = <String>[];
    for (final record in table!.records) {
      if (index >= record.length) continue;
      final v = record[index].trim();
      if (v.isNotEmpty && !seen.contains(v)) seen.add(v);
      if (seen.length >= 8) break;
    }
    return seen.join(' / ');
  }

  Widget _valuesField(
    Object owner,
    String field,
    String label,
    List<String> current,
    void Function(List<String>) onChanged, {
    Key? key,
  }) {
    final controller = _valueControllers.putIfAbsent(
      '${identityHashCode(owner)}-$field',
      () => TextEditingController(text: current.join('\n')),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        key: key,
        controller: controller,
        enabled: !busy,
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(labelText: label, hintText: '1行に1つ'),
        onChanged: (text) => _mappingChanged(() => onChanged(_lines(text))),
      ),
    );
  }

  Widget _mappingSection() {
    final m = mapping!;
    return _section('列の対応(CSVのどの列を使うか)', [
      const Text('列は自動では選ばれません。CSVの列を、項目ごとに選んでください。'),
      const SizedBox(height: 10),
      _columnDropdown(
        key: const Key('map-name'),
        label: '氏名の列(必須)',
        value: m.nameColumn,
        onChanged: (v) => _mappingChanged(() => m.nameColumn = v),
      ),
      _columnDropdown(
        key: const Key('map-email'),
        label: 'メールアドレスの列(必須)',
        value: m.emailColumn,
        onChanged: (v) => _mappingChanged(() => m.emailColumn = v),
      ),
      _columnDropdown(
        key: const Key('map-kana'),
        label: 'かなの列',
        value: m.kanaColumn,
        optional: true,
        onChanged: (v) => _mappingChanged(() => m.kanaColumn = v),
      ),
      _columnDropdown(
        key: const Key('map-external'),
        label: '参照コードの列',
        value: m.externalIdColumn,
        optional: true,
        onChanged: (v) => _mappingChanged(() => m.externalIdColumn = v),
      ),
      _columnDropdown(
        key: const Key('map-registered'),
        label: '登録日時の列',
        value: m.registeredAtColumn,
        optional: true,
        onChanged: (v) => _mappingChanged(() => m.registeredAtColumn = v),
      ),
      const Divider(),
      const Text(
        '行の確認(任意。区分などの列が指定した値の行だけを対象にします)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      for (var i = 0; i < m.rowChecks.length; i++)
        Card(
          key: ValueKey('rowcheck-$i'),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _columnDropdown(
                  key: Key('rowcheck-column-$i'),
                  label: '確認する列',
                  value: m.rowChecks[i].column,
                  onChanged: (v) =>
                      _mappingChanged(() => m.rowChecks[i].column = v),
                ),
                if (m.rowChecks[i].column != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      'この列にある値: ${_valuesOf(m.rowChecks[i].column!)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff5c6670),
                      ),
                    ),
                  ),
                _valuesField(
                  m.rowChecks[i],
                  'allowed',
                  '許可する値',
                  m.rowChecks[i].allowedValues,
                  (v) => m.rowChecks[i].allowedValues = v,
                  key: Key('rowcheck-values-$i'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: busy
                        ? null
                        : () => _mappingChanged(() => m.rowChecks.removeAt(i)),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('この確認を削除'),
                  ),
                ),
              ],
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const Key('add-rowcheck'),
          onPressed: busy
              ? null
              : () => _mappingChanged(() => m.rowChecks.add(RowCheck())),
          icon: const Icon(Icons.add),
          label: const Text('行の確認を追加'),
        ),
      ),
      const Divider(),
      const Text(
        'programごとの対応(イベントに定義されたprogram)',
        style: TextStyle(fontWeight: FontWeight.bold),
      ),
      for (var i = 0; i < m.programs.length; i++)
        _programMapping(m.programs[i], i),
    ]);
  }

  Widget _programMapping(ProgramMapping g, int i) => Card(
    key: ValueKey('program-map-$i'),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: Key('program-enabled-$i'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              g.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('ID: ${g.programId}'),
            value: g.enabled,
            onChanged: busy
                ? null
                : (v) => _mappingChanged(() => g.enabled = v),
          ),
          if (g.enabled) ...[
            _columnDropdown(
              key: Key('program-count-$i'),
              label: '人数の列(必須・予定人数になります)',
              value: g.countColumn,
              onChanged: (v) => _mappingChanged(() => g.countColumn = v),
            ),
            _columnDropdown(
              key: Key('program-participation-$i'),
              label: '参加の列(任意)',
              value: g.participationColumn,
              optional: true,
              onChanged: (v) =>
                  _mappingChanged(() => g.participationColumn = v),
            ),
            if (g.participationColumn != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'この列にある値: ${_valuesOf(g.participationColumn!)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff5c6670),
                  ),
                ),
              ),
              _valuesField(
                g,
                'attending',
                '参加とみなす値',
                g.attendingValues,
                (v) => g.attendingValues = v,
                key: Key('program-attending-$i'),
              ),
              _valuesField(
                g,
                'notattending',
                '参加しないとみなす値',
                g.notAttendingValues,
                (v) => g.notAttendingValues = v,
                key: Key('program-notattending-$i'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('参加の列が空の行は「参加しない」とみなす(未チェックなら確認が必要な行になります)'),
                value: g.emptyMeansNotAttending,
                onChanged: busy
                    ? null
                    : (v) => _mappingChanged(
                        () => g.emptyMeansNotAttending = v ?? false,
                      ),
              ),
            ],
            _columnDropdown(
              key: Key('program-slot-$i'),
              label: '時間枠の列(任意)',
              value: g.slotColumn,
              optional: true,
              onChanged: (v) => _mappingChanged(() => g.slotColumn = v),
            ),
            if (g.slotColumn != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<String>(
                  key: Key('program-slotformat-$i'),
                  isExpanded: true,
                  initialValue: g.slotFormat,
                  decoration: const InputDecoration(labelText: '時間枠の形式'),
                  items: const [
                    DropdownMenuItem(value: 'label', child: Text('文字(そのまま表示)')),
                    DropdownMenuItem(
                      value: 'timeRange',
                      child: Text('時刻の範囲(例: 10:00-10:40)'),
                    ),
                  ],
                  onChanged: busy
                      ? null
                      : (v) =>
                            _mappingChanged(() => g.slotFormat = v ?? 'label'),
                ),
              ),
          ],
        ],
      ),
    ),
  );

  String _rowText(PreviewRow r) {
    final issues = r.issueCodes.map(importIssueLabel).join('、');
    final programs = r.programIds.isEmpty
        ? ''
        : ' / program: ${r.programIds.join(', ')}';
    return '${r.classification.label}${issues.isEmpty ? '' : ' — $issues'}$programs';
  }

  Widget _previewSection() {
    final p = preview!;
    final review = p.rows
        .where((r) => r.classification == RowClass.review)
        .toList();
    final errors = p.rows
        .where((r) => r.classification == RowClass.error)
        .toList();
    final ready = p.rows
        .where((r) => r.classification == RowClass.ready)
        .toList();
    return _section('プレビュー結果(まだ取り込まれていません)', [
      if (p.existingStatus == 'committed')
        _notice(
          'この内容(ファイルと列の対応)は、既に取り込み済みです(第${p.existingSequence ?? '?'}回)。もう一度取り込んでも、参加者は増えません。',
          color: const Color(0xffe7f5ec),
          key: const Key('existing-committed'),
        ),
      if (p.existingStatus == 'committing' || p.existingStatus == 'failed')
        _notice(
          '前回の取込が完了していません(${p.existingStatus == 'failed' ? '失敗' : '処理中'})。同じ内容で「取込を確定」すると、続きから安全に完了できます(二重には作られません)。',
          color: const Color(0xfffff1cf),
          key: const Key('existing-incomplete'),
        ),
      if (p.sameFileBatches.isNotEmpty && p.existingStatus == null)
        _notice(
          '参考: 同じファイルが、別の列の対応で取り込まれています(${p.sameFileBatches.map((b) => '第${b.sequence}回').join('、')})。取り込みを止めるものではありません。',
          color: const Color(0xfffff1cf),
        ),
      for (final column in p.warningColumns)
        _notice(
          '注意: 「$column」はキャンセル待ちの列の可能性があります。当選者の取込に使う列か確認してください。',
          color: const Color(0xfffff1cf),
        ),
      InfoRow('CSV総行数', '${p.totalRecords}行'),
      InfoRow('空の行', '${p.blankRecordCount}行'),
      InfoRow('取込対象', '${p.readyCount}件'),
      InfoRow('確認が必要', '${p.reviewCount}件'),
      InfoRow('エラー', '${p.errorCount}件(取り込まれません)'),
      InfoRow('参加者の候補', '${p.participantCandidateCount}件'),
      InfoRow('programの参加の候補', '${p.attendanceCandidateCount}件'),
      if (p.issueCounts.isNotEmpty) ...[
        const SizedBox(height: 6),
        const Text('判定の内訳', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final e in p.issueCounts.entries)
          Text('・${importIssueLabel(e.key)}: ${e.value}件'),
      ],
      if (review.isNotEmpty) ...[
        const Divider(),
        Text(
          '確認が必要な行(${review.length}件)— 取り込む行を承認してください',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: const Key('approve-all'),
              onPressed: busy
                  ? null
                  : () => setState(
                      () => approved
                        ..clear()
                        ..addAll(review.map((r) => r.sourceRowNumber)),
                    ),
              child: const Text('すべて承認'),
            ),
            TextButton(
              onPressed: busy ? null : () => setState(approved.clear),
              child: const Text('すべて解除'),
            ),
          ],
        ),
        for (final r in review)
          CheckboxListTile(
            key: ValueKey('review-${r.sourceRowNumber}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('${r.sourceRowNumber}行目を承認して取り込む'),
            subtitle: Text(_rowText(r)),
            value: approved.contains(r.sourceRowNumber),
            onChanged: busy
                ? null
                : (v) => setState(
                    () => v == true
                        ? approved.add(r.sourceRowNumber)
                        : approved.remove(r.sourceRowNumber),
                  ),
          ),
      ],
      if (errors.isNotEmpty) ...[
        const Divider(),
        Text(
          'エラーの行(${errors.length}件・取り込まれません)',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final r in errors)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('${r.sourceRowNumber}行目: ${_rowText(r)}'),
          ),
      ],
      if (ready.isNotEmpty) ...[
        const Divider(),
        ExpansionTile(
          key: const Key('ready-rows'),
          tilePadding: EdgeInsets.zero,
          title: Text('取込対象の行(${ready.length}件)'),
          children: [
            SizedBox(
              height: 240,
              child: ListView.builder(
                itemCount: ready.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${ready[i].sourceRowNumber}行目: ${_rowText(ready[i])}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      Text(
        '取り込まれる件数: $_importCount件(取込対象+承認した確認の行)',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      FilledButton(
        key: const Key('commit'),
        onPressed: _canCommit ? _confirmAndCommit : null,
        child: Text(committing ? '取込中…' : '内容を確認して取り込む'),
      ),
      if (_importCount == 0)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('取り込める行がありません。CSVまたは列の対応を見直してください。'),
        ),
      if (commitError != null)
        _notice(commitError!, key: const Key('commit-error')),
      if (commitAmbiguous)
        _notice(
          '取込が完了したか不明です。同じ内容でもう一度「内容を確認して取り込む」を押してください(二重には作られず、続きから完了します)。',
          color: const Color(0xfffff1cf),
        ),
    ]);
  }

  Widget _resultSection() {
    final r = result!;
    final id = event!.eventId;
    if (!r.committed) {
      return _section('取込は完了していません', [
        _notice(
          r.status == 'failed'
              ? '取込に失敗しました(状態: 失敗)。同じ内容でもう一度取り込むと、続きから完了できます。'
              : '取込は処理中です(状態: ${r.status})。完了とは限りません。同じ内容でもう一度取り込んで、状態を確認してください。',
          key: const Key('result-incomplete'),
        ),
      ]);
    }
    return _section('取込完了', [
      Container(
        key: const Key('result-committed'),
        padding: const EdgeInsets.all(14),
        color: const Color(0xffe7f5ec),
        child: const Text(
          '取込が完了しました(状態: committed)。メールは送信されていません。',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      InfoRow('イベント', event!.eventName),
      InfoRow('取込', r.label.isEmpty ? '第${r.sequence}回' : r.label),
      SelectableText(
        'batch識別情報: ${r.batchId}',
        style: const TextStyle(fontSize: 12, color: Color(0xff5c6670)),
      ),
      InfoRow('作成した参加者', '${r.createdCount}件'),
      InfoRow('確認待ち(取り込んでいない)', '${r.reviewPendingCount}件'),
      InfoRow('エラー(取り込んでいない)', '${r.errorCount}件'),
      InfoRow('空の行', '${r.blankRecordCount}行'),
      if (r.idempotentReplay)
        _notice(
          'この取込は既に完了していたため、既存の結果を表示しています(参加者は増えていません)。',
          color: const Color(0xfffff1cf),
        ),
      const SizedBox(height: 10),
      OutlinedButton(
        key: const Key('back-to-event'),
        onPressed: () {
          final done = widget.onDone;
          if (done != null) {
            done(context, id);
          } else {
            Navigator.of(context).pushReplacementNamed(
              '/console?eventId=${Uri.encodeQueryComponent(id)}',
            );
          }
        },
        child: const Text('イベント管理へ戻る'),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '参加者CSVの取込',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section('取り込み先のイベント', [
          if (!_eventFixed) ...[
            TextField(
              key: const Key('event-id'),
              controller: eventIdController,
              decoration: const InputDecoration(labelText: 'イベントID'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('load-event'),
              onPressed: loadingEvent || busy ? null : _loadEvent,
              child: const Text('イベントを読み込む'),
            ),
          ],
          if (loadingEvent)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (eventError != null)
            _notice(eventError!, key: const Key('event-error')),
          if (event != null) ...[
            InfoRow('イベント名', event!.eventName),
            InfoRow('開催日時', formatDateTimeMinute(event!.startAt)),
            InfoRow('会場', event!.venue.isEmpty ? '未設定' : event!.venue),
            const Text(
              'program(表示順)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            for (final p in event!.programs)
              Text('・${p.name}(ID: ${p.programId})'),
            const SizedBox(height: 6),
            const Text('参加者は、このイベントへ取り込まれます。取り込むだけでは、メールは送信されません。'),
          ],
        ]),
        if (event != null)
          _section('CSVファイル', [
            const Text('UTF-8(BOMあり・なし)のCSVを選択してください。列名は先頭行から読み取ります。'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('pick-file'),
              onPressed: busy ? null : _pickFile,
              icon: const Icon(Icons.upload_file),
              label: Text(file == null ? 'CSVファイルを選択' : 'ファイルを選び直す'),
            ),
            if (file != null && table != null) ...[
              const SizedBox(height: 8),
              Text('選択中: ${file!.name}'),
              Text('${table!.records.length}行 / ${table!.headers.length}列'),
            ],
            if (fileError != null)
              _notice(fileError!, key: const Key('file-error')),
          ]),
        if (mapping != null && table != null) _mappingSection(),
        if (mapping != null && table != null)
          _section('プレビュー', [
            const Text('プレビューでは何も取り込まれません。内容を確認してから取り込みます。'),
            if (_mappingIssues.isNotEmpty && previewError == null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '未設定の項目: ${_mappingIssues.length}件(プレビュー時に表示します)',
                  style: const TextStyle(color: Color(0xff5c6670)),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('run-preview'),
              onPressed: busy ? null : _runPreview,
              child: Text(previewing ? 'プレビュー中…' : 'プレビューする'),
            ),
            if (previewError != null)
              _notice(previewError!, key: const Key('preview-error')),
          ]),
        if (preview != null && result == null) _previewSection(),
        if (result != null) _resultSection(),
      ],
    ),
  );
}
