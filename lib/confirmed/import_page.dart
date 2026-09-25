import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_role.dart';
import 'access_service.dart';
import 'assignment_pages.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'import_models.dart';
import 'import_profile.dart';
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

/// 新方式イベントへの参加者CSV取込の入口(`/console/import?eventId=…`)。システム管理者、または
/// Phase 3からそのイベントのイベント管理者としてログインした場合だけ表示される。
/// スタッフ・担当外・権限なし・未ログインでは表示されない(サーバー側も対象イベントのイベント管理者以上に限る)。
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
    eventScopedBuilder: (context, signOut, assignments) {
      final id = (eventId ?? '').trim();
      final isManager = assignments.any(
        (a) => a.eventId == id && a.role == EventRole.eventManager,
      );
      if (!isManager) {
        return EventScopeDenied(
          title: '参加者CSVの取込',
          message: 'このイベントのCSV取込を行う権限がありません。',
          signOut: signOut,
        );
      }
      return ConfirmedImportPage(
        eventId: id,
        service: service ?? CallableImportService(authClient: authClient),
        picker: picker ?? pickCsvWithFilePicker,
      );
    },
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
///   イベント → CSVファイル選択 → 自動解析 → プレビュー → 内容確認 → 「取込を確定」→ 完了
/// Phase 11B-4から、通常運用ではCSVの列を利用者に選ばせない。[ConfirmedImportProfile](import_profile.dart)が
/// 今年度の正式フォーマット(header名)からmappingを自動的に組み立てる。CSVのheaderがそのフォーマットと
/// 一致しない場合は、プレビュー(サーバーへの問い合わせ)を試みる前に、対応していない形式として拒否する。
/// プレビューを行わないと確定できず、ファイルを選び直すとプレビューは無効になる(再プレビューが必要)。
/// 取込はサーバー(previewConfirmedImport / commitConfirmedImport)が正本で、人物の同一性による統合はしない(1行=1参加者)。
/// 完了してもメールは送信されない(当選メールの送信は、別の画面で管理者が明示的に行う)。
class ConfirmedImportPage extends StatefulWidget {
  const ConfirmedImportPage({
    super.key,
    this.eventId,
    required this.service,
    required this.picker,
    this.onDone,
    this.profile = currentConfirmedImportProfile,
  });
  final String? eventId;
  final ImportService service;
  final CsvPicker picker;

  /// 完了後の「イベント管理へ戻る」。既定は新方式の管理画面(/console?eventId=…)。
  final void Function(BuildContext context, String eventId)? onDone;

  /// 今年度の正式CSVフォーマット向けprofile(テストでは差し替える。既定は[currentConfirmedImportProfile])。
  final ConfirmedImportProfile profile;

  @override
  State<ConfirmedImportPage> createState() => _ConfirmedImportPageState();
}

class _ConfirmedImportPageState extends State<ConfirmedImportPage> {
  ImportEventSummary? event;
  String? eventError;
  bool loadingEvent = false;
  List<String> eventProgramMismatch = [];

  PickedCsv? file;
  CsvTable? table;
  String? fileError;
  String? formatError;
  List<String> missingHeadersList = [];
  ImportMapping? mapping;

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
    if (_eventFixed) _loadEvent();
  }

  // ---- イベント ----------------------------------------------------------------------------------
  // eventIdは常にNavigator経由(/console/import?eventId=…)で引き継ぐ。利用者に入力・選択させない。
  Future<void> _loadEvent() async {
    final id = (widget.eventId ?? '').trim();
    if (id.isEmpty) return;
    setState(() {
      loadingEvent = true;
      eventError = null;
      event = null;
      eventProgramMismatch = [];
      _resetFile();
    });
    try {
      final loaded = await widget.service.getEvent(id);
      if (!mounted) return;
      final mismatch = missingProfileProgramsInEvent(
        widget.profile,
        loaded.programs,
      );
      setState(() {
        event = loaded;
        eventProgramMismatch = mismatch;
      });
      // イベントとprogramが確認できたら、そのままファイル選択を開く(操作を1手減らす)。
      // キャンセルされても、下の「CSVファイルを選択」から改めて選べる。
      if (mismatch.isEmpty) await _pickFile();
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
    formatError = null;
    missingHeadersList = [];
    mapping = null;
    _invalidatePreview();
    result = null;
    commitError = null;
    commitAmbiguous = false;
  }

  // ファイルが変わったら、以前のプレビュー(と承認)は無効。再プレビューが必要
  void _invalidatePreview() {
    previewedRequest = null;
    preview = null;
    previewError = null;
    approved.clear();
  }

  Future<void> _pickFile() async {
    if (busy || event == null || eventProgramMismatch.isNotEmpty) return;
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
        final parsed = parseCsvBytes(picked!.bytes);
        table = parsed;
        // 通常運用ではCSVの列を利用者に選ばせない。CSVのheaderが今年度の正式フォーマットと一致しない場合は、
        // プレビュー(サーバーへの問い合わせ)を試みる前に、ここで明確に拒否する。
        final missing = widget.profile.missingHeaders(parsed.headers);
        if (missing.isNotEmpty) {
          formatError = 'このCSVは対応している参加者リストの形式ではありません。';
          missingHeadersList = missing;
          return;
        }
        mapping = buildMappingFromProfile(widget.profile, event!.programs);
      } on CsvParseException catch (e) {
        fileError = e.message;
      }
    });
  }

  // ---- プレビュー ---------------------------------------------------------------------------------
  Future<void> _runPreview() async {
    if (busy || table == null || mapping == null || event == null) return;
    // profileから自動生成したmappingが不正になることは無いはずだが、念のため送信前に確認する(内部エラー)。
    final issues = mapping!.validate();
    if (issues.isNotEmpty) {
      setState(
        () => previewError = '内部エラー: 自動生成した列の対応を確認できませんでした。管理者へご連絡ください。',
      );
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

  // program別の集計の概算。サーバーのpreview応答は氏名・人数などの値を返さない(データ最小化)ため、
  // ローカルに保持しているCSVの値(このprogramの人数列)と、サーバーが返す行ごとのprogramIds・分類を
  // 突き合わせて概算する。表示のみに使い、実際の正本(plannedCount)は常にサーバー(commit時)が決める。
  // [include]で対象にする行(分類)を選ぶ(ready行だけ・review行だけ・確定される行だけ、等)。
  ({int participants, int headcount}) _programTotals(
    ProgramMapping g,
    bool Function(PreviewRow r) include,
  ) {
    final p = preview;
    final t = table;
    if (p == null || t == null || g.countColumn == null) {
      return (participants: 0, headcount: 0);
    }
    final countIndex = t.headers.indexOf(g.countColumn!);
    var participants = 0;
    var headcount = 0;
    for (final r in p.rows) {
      if (!include(r)) continue;
      if (!r.programIds.contains(g.programId)) continue;
      participants += 1;
      if (countIndex < 0) continue;
      final position = r.sourceRowNumber - 2;
      if (position < 0 || position >= t.records.length) continue;
      final record = t.records[position];
      if (countIndex >= record.length) continue;
      headcount += displayCountOf(record[countIndex]) ?? 0;
    }
    return (participants: participants, headcount: headcount);
  }

  /// 確定できる予定(ready行だけ)。取り込むと必ずこの件数のattendanceが作られる。
  ({int participants, int headcount}) _readyTotals(ProgramMapping g) =>
      _programTotals(g, (r) => r.classification == RowClass.ready);

  /// 確認が必要なデータ(review行のうち、このprogramへの参加候補があるもの。未承認)。
  ({int participants, int headcount}) _reviewTotals(ProgramMapping g) =>
      _programTotals(g, (r) => r.classification == RowClass.review);

  /// 実際に確定する予定(ready行 + 管理者が承認したreview行)。確認ダイアログで使う。
  ({int participants, int headcount}) _committingTotals(ProgramMapping g) =>
      _programTotals(
        g,
        (r) =>
            r.classification == RowClass.ready ||
            approved.contains(r.sourceRowNumber),
      );

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
    final programs = mapping!.programs;
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
                'program別予定(この内容で確定する分)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final g in programs)
                _confirmRow(
                  g.name,
                  '${_committingTotals(g).headcount}人 / ${_committingTotals(g).participants} participant',
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

  // CSVのheaderが今年度の正式フォーマットと一致しない(通常のUIで列mappingをさせる設計はもう無いため、
  // ここで拒否するのが唯一の対応窓口)。不足している列名はadminへ表示してよい(個人情報ではない)。
  Widget _formatErrorSection() => _section('対応していないCSVです', [
    _notice(formatError!, key: const Key('format-error')),
    if (missingHeadersList.isNotEmpty) ...[
      const SizedBox(height: 6),
      const Text('不足している列', style: TextStyle(fontWeight: FontWeight.bold)),
      for (final h in missingHeadersList)
        Text('・$h', key: ValueKey('missing-header-$h')),
    ],
  ]);

  Widget _autoAnalysisSection() => _section('自動解析結果', [
    const Text(
      'CSVの列を自動で認識しました(列を選ぶ操作は不要です)。',
      key: Key('auto-mapping-ok'),
    ),
    const SizedBox(height: 8),
    for (final g in mapping!.programs)
      Text('・${g.name}: 参加判定と人数を自動で読み取ります', key: ValueKey('auto-program-${g.programId}')),
  ]);

  /// programId → 表示名。programIdそのものは利用者へ表示しない(内部の識別子のため)。
  String _programName(String programId) {
    for (final g in mapping?.programs ?? const <ProgramMapping>[]) {
      if (g.programId == programId) return g.name;
    }
    return programId; // 通常は到達しない(念のためのフォールバック)
  }

  String _rowText(PreviewRow r) {
    final issues = r.issueCodes.map(importIssueLabel).join('、');
    final programs = r.programIds.isEmpty
        ? ''
        : ' / ${r.programIds.map(_programName).join('、')}';
    return '${r.classification.label}${issues.isEmpty ? '' : ' — $issues'}$programs';
  }

  /// 確認が必要な行の、利用者向けの具体的な説明。内部の判定コード(slot-zero-length等)や
  /// programId(program-1等)をそのまま出さない。
  ///
  /// 「不参加なのに人数が入っている」(not-attending-count-present)は、CSVの元の値(参加時間・人数の列)
  /// を突き合わせて、どのprogramのどんな矛盾かを具体的な日本語で示す。プレビュー応答はデータ最小化のため
  /// これらの値そのものを返さないので、ローカルに保持しているCSVの値を使う(判定条件はサーバー
  /// functions/confirmed/import_rows.js の decideParticipation と同じ規則を表示のためだけに再現する。
  /// 実際の分類・確定は常にサーバーが行い、ここでの再現は表示専用)。
  List<String> _reviewMessages(PreviewRow r) {
    final t = table;
    final m = mapping;
    if (t == null || m == null || !r.issueCodes.contains('not-attending-count-present')) {
      return r.issueCodes.map(importIssueLabel).toList();
    }
    final position = r.sourceRowNumber - 2;
    if (position < 0 || position >= t.records.length) {
      return r.issueCodes.map(importIssueLabel).toList();
    }
    final record = t.records[position];
    String cellOf(String? column) {
      if (column == null) return '';
      final i = t.headers.indexOf(column);
      if (i < 0 || i >= record.length) return '';
      return record[i].trim();
    }

    final messages = <String>[];
    for (final g in m.programs) {
      final participationColumn = g.participationColumn;
      if (participationColumn == null) continue;
      final participationValue = cellOf(participationColumn);
      final notAttending =
          participationValue.isEmpty ||
          g.notAttendingValues.contains(participationValue);
      if (!notAttending) continue;
      final countText = cellOf(g.countColumn);
      if (countText.isEmpty) continue;
      final count = displayCountOf(countText);
      if (count == 0) continue; // 0は不参加と矛盾しない
      final countLabel = count != null ? '$count名' : '「$countText」';
      final stateLabel = participationValue.isEmpty ? '空欄' : '『参加を希望しない』';
      messages.add(
        '${g.name}は$stateLabelとなっていますが、参加人数が$countLabelになっています。内容を確認してください。',
      );
    }
    if (messages.isEmpty) return r.issueCodes.map(importIssueLabel).toList();
    final others = r.issueCodes
        .where((c) => c != 'not-attending-count-present')
        .map(importIssueLabel);
    return [...messages, ...others];
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
          'この内容(ファイル)は、既に取り込み済みです(第${p.existingSequence ?? '?'}回)。もう一度取り込んでも、参加者は増えません。',
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
          '参考: 同じファイルが、既に別の回として取り込まれています(${p.sameFileBatches.map((b) => '第${b.sequence}回').join('、')})。取り込みを止めるものではありません。',
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
      const SizedBox(height: 6),
      const Text('program別予定', style: TextStyle(fontWeight: FontWeight.bold)),
      const Text(
        '「確定できる予定」は今すぐ取り込める件数、「確認が必要」は下の行を承認しないと取り込まれない件数です。'
        '「確認が必要」を含めた合計が、このイベントの参加予定の実態に近い数字です。',
        style: TextStyle(fontSize: 12, color: Color(0xff5c6670)),
      ),
      for (final g in mapping!.programs)
        Builder(
          key: ValueKey('program-summary-${g.programId}'),
          builder: (context) {
            final ready = _readyTotals(g);
            final review = _reviewTotals(g);
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    '　確定できる予定: ${ready.headcount}人 / ${ready.participants} participant',
                    key: ValueKey('program-summary-ready-${g.programId}'),
                  ),
                  if (review.participants > 0)
                    Text(
                      '　確認が必要: ${review.headcount}人 / ${review.participants} participant(未承認)',
                      key: ValueKey('program-summary-review-${g.programId}'),
                      style: const TextStyle(color: Color(0xffb54708)),
                    ),
                ],
              ),
            );
          },
        ),
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
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, msg) in _reviewMessages(r).indexed)
                  Text(
                    msg,
                    key: ValueKey('review-${r.sourceRowNumber}-message-$i'),
                  ),
              ],
            ),
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
          child: Text('取り込める行がありません。CSVの内容を見直してください。'),
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

  // eventIdを持たずに開かれた場合(直リンク等)。イベントIDの入力・選択は求めず、
  // 管理画面からやり直す案内だけを表示する。
  Widget _missingEventSection() => _section('取り込み先のイベントが分かりません', [
    const Text('イベント管理画面からCSV取込を選択してください。', key: Key('no-event-id-notice')),
    const SizedBox(height: 12),
    OutlinedButton(
      key: const Key('back-to-console'),
      onPressed: () => Navigator.of(context).pushReplacementNamed('/console'),
      child: const Text('イベント管理画面へ戻る'),
    ),
  ]);

  @override
  Widget build(BuildContext context) {
    if (!_eventFixed) {
      return PageFrame(title: '参加者CSVの取込', child: _missingEventSection());
    }
    return PageFrame(
      title: '参加者CSVの取込',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section('取り込み先のイベント', [
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
              if (eventProgramMismatch.isNotEmpty)
                _notice(
                  'このイベントには、CSVで想定しているprogramがありません(${eventProgramMismatch.join('、')})。イベントの設定をご確認ください。',
                  key: const Key('event-program-mismatch'),
                ),
            ],
          ]),
          if (event != null && eventProgramMismatch.isEmpty)
            _section('CSVファイル', [
              const Text('UTF-8(BOMあり・なし)のCSVを選択してください。列は自動で解析します(選ぶ操作は不要です)。'),
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
          if (formatError != null) _formatErrorSection(),
          if (mapping != null && table != null) _autoAnalysisSection(),
          if (mapping != null && table != null)
            _section('プレビュー', [
              const Text('プレビューでは何も取り込まれません。内容を確認してから取り込みます。'),
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
}
