import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'access_role.dart';
import 'access_service.dart';
import 'assignment_pages.dart';
import 'auth_client.dart';
import 'auth_gate.dart';
import 'import_file.dart';
import 'import_models.dart';
import 'import_profile.dart';
import 'import_service.dart';

/// 選択された参加者ファイル(ファイル名と内容。CSV / Excel(.xlsx))。
typedef PickedCsv = ({String name, Uint8List bytes});

/// 参加者ファイルの選択(既定はブラウザのファイル選択。テストでは差し替える)。キャンセルはnull。
typedef CsvPicker = Future<PickedCsv?> Function();

Future<PickedCsv?> pickCsvWithFilePicker() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['xlsx', 'csv'],
    withData: true,
  );
  final file = result?.files.single;
  if (file == null || file.bytes == null) return null;
  return (name: file.name, bytes: file.bytes!);
}

/// 新方式イベントへの参加者ファイル(CSV / Excel)取込の入口(`/console/import?eventId=…`)。システム管理者、または
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
          title: '参加者ファイルの取込',
          message: 'このイベントの参加者ファイルの取込を行う権限がありません。',
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
      title: '参加者ファイルの取込',
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '参加者ファイルの取込は管理者のみ利用できます',
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

/// 参加者ファイル(CSV / Excel(.xlsx))の取込画面。
///   イベント → ファイル選択(Excelはシートの決定)→ 自動解析 → 検証 → プレビュー → 内容確認 → 「取込を確定」→ 完了
/// ファイルの形式ごとの違いは読み取り(import_file.dart)だけで、読み取った後は共通の表([CsvTable])として、
/// 同じ検証・対処(修正・除外・許可)・プレビュー・取込を使う。
/// 検証(validateConfirmedImport。何も書き込まない)で、エラー・警告・項目別の件数と問題の行を確認する。
/// エラーが0件で、必要な確認(メール重複の許可・取込済みの内容を新しい取込回として取り込むこと)を管理者が済ませた
/// 場合だけプレビューへ進める。CSV・列の対応が変わったら検証は無効になる(再検証が必要)。
/// 検証とプレビューの行の判定はサーバーの同じ計画から作られ、プレビュー時に一致を確認する(食い違えば確定させない)。
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

  /// 通知種別(ファイルを選んだ後に管理者が必ず選ぶ。選ぶまで検証へ進めない)。変えたら検証・対処・プレビューはやり直し。
  NotificationType? notificationType;

  /// 通知種別に合わない(繰り上げ先を判定できない形式等)場合の理由。
  String? notificationError;

  /// ファイルのHEBEL属性の列(通知種別を変えてmappingを作り直すときに使う)。
  String? _hebelColumn;

  /// 読み取ったファイル(形式・シート)。Excelで候補のシートが複数ある間は[sheet]・[table]はnull(管理者が選ぶ)。
  ParsedImportFile? parsedFile;
  ImportSheet? sheet;
  List<ImportSheet> sheetCandidates = [];

  /// 共通の表(CSV、または選んだExcelのシート)。
  CsvTable? table;
  String? fileError;
  String? formatError;
  List<String> missingHeadersList = [];
  ImportMapping? mapping;

  bool validating = false;
  ImportValidation? validation;
  String? validationError;

  /// 検証したCSV(fileHash)と列の対応。プレビュー時にこれと異なれば再検証が必要。
  String? validatedFingerprint;

  /// 取込済みの内容を新しい取込回として取り込むことの、管理者の明示的な確認。
  bool ackNewImport = false;

  /// 検証画面での管理者の対処(原本のCSVは変えない。サーバーが最終的な値を作って検証し直す):
  /// 修正 (行番号, 列) → 値 / 今回の取込から除外 行番号 → 理由。
  final Map<(int, String), String> corrections = {};
  final Map<int, String> exclusions = {};

  /// 警告の許可: (行番号, 種類) → 許可したときの許可の鍵(検証が返した値)。種類は確認が必要な行(review)・
  /// 既存参加者とのメール重複(existingDuplicate)・CSV内のメール重複(csvDuplicate)。
  /// 行を修正したら、その行の許可はすべて解除する。再検証で鍵が変わった許可(重複の相手が変わった等)も解除する。
  /// 行番号が同じでも、古い許可は流用しない(サーバーも鍵で照合する)。不参加の残存人数は参考情報で、許可は無い。
  final Map<(int, String), String> approvals = {};
  static const _review = 'review';
  static const _existingDuplicate = 'existingDuplicate';
  static const _csvDuplicate = 'csvDuplicate';

  /// 検証結果の行(行番号 → 行)。
  Map<int, ValidationRow> _rowIndex = {};

  /// 修正の入力中の行と、その入力欄。
  int? editingRow;
  final Map<String, TextEditingController> _editControllers = {};

  bool previewing = false;
  bool committing = false;
  ImportRequest? previewedRequest;
  ImportPreview? preview;
  String? previewError;
  final Set<int> approved = {};

  ImportResult? result;
  String? commitError;
  bool commitAmbiguous = false;

  bool get busy => validating || previewing || committing;
  bool get _eventFixed => (widget.eventId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_eventFixed) _loadEvent();
  }

  @override
  void dispose() {
    for (final c in _editControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _clearDecisions() {
    corrections.clear();
    exclusions.clear();
    approvals.clear();
    editingRow = null;
  }

  // ---- 警告の許可 ------------------------------------------------------------------------------------
  /// その行に、その種類の許可が必要な警告があるか(今回の取込から除外した行には無い)。
  bool _needsApproval(int n, String kind) {
    final v = validation;
    final r = _rowIndex[n];
    if (v == null || r == null || r.excluded) return false;
    return switch (kind) {
      _review => v.pendingReviewRows.contains(n),
      _existingDuplicate => v.existingDuplicateRowList.contains(n),
      _ => v.csvDuplicateRowList.contains(n),
    };
  }

  String _approvalKeyOf(int n, String kind) => _rowIndex[n]?.approvalKeys[kind] ?? '';

  /// 現在の検証結果の警告を許可しているか(許可したときの鍵が、現在の鍵と同じ)。
  bool _isAllowed(int n, String kind) {
    final key = approvals[(n, kind)];
    return key != null && _needsApproval(n, kind) && key == _approvalKeyOf(n, kind);
  }

  bool _allAllowed(List<int> rows, String kind) => rows.isNotEmpty && rows.every((n) => _isAllowed(n, kind));

  void _setAllowed(Iterable<int> rows, String kind, bool value) {
    for (final n in rows) {
      if (value) {
        approvals[(n, kind)] = _approvalKeyOf(n, kind);
      } else {
        approvals.remove((n, kind));
      }
    }
    _invalidatePreview();
  }

  /// 行を修正した(または修正を取り消した)ら、その行の許可はすべて解除する(再検証の結果で改めて許可させる)。
  void _revokeApprovals(int n) => approvals.removeWhere((k, _) => k.$1 == n);

  bool get ackExistingDuplicates => _allAllowed(validation?.existingDuplicateRowList ?? const [], _existingDuplicate);
  bool get ackCsvDuplicates => _allAllowed(validation?.csvDuplicateRowList ?? const [], _csvDuplicate);

  /// commitへ送る許可の鍵(現在の検証結果で許可している警告の鍵だけ)。
  List<String> get _approvalKeysToSend => {
    for (final e in approvals.entries)
      if (e.value.isNotEmpty && _isAllowed(e.key.$1, e.key.$2)) e.value,
  }.toList()..sort();

  ImportDecisions get _decisions => ImportDecisions(
    corrections: Map.of(corrections),
    exclusions: Map.of(exclusions),
  );

  // 取込profile(=列の対応)が変わったら、mappingを作り直し、検証・プレビューは無効にする(再検証が必要)。
  @override
  void didUpdateWidget(covariant ConfirmedImportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.profile, widget.profile)) return;
    final parsed = table;
    if (parsed == null || event == null) return;
    setState(() {
      formatError = null;
      missingHeadersList = [];
      mapping = null;
      _invalidateValidation();
      _clearDecisions();
      _applyProfile(parsed);
    });
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
    parsedFile = null;
    sheet = null;
    sheetCandidates = [];
    table = null;
    fileError = null;
    formatError = null;
    missingHeadersList = [];
    mapping = null;
    notificationType = null;
    notificationError = null;
    _hebelColumn = null;
    _invalidateValidation();
    _clearDecisions();
    result = null;
    commitError = null;
    commitAmbiguous = false;
  }

  /// 通知種別を選ぶ(変えたら、検証・対処・プレビューはやり直し。mappingも種別に合わせて作り直す)。
  void _selectNotificationType(NotificationType type) {
    if (busy || type == notificationType) return;
    setState(() {
      notificationType = type;
      _invalidateValidation();
      _clearDecisions();
      result = null;
      commitError = null;
      commitAmbiguous = false;
      _rebuildMapping();
    });
  }

  /// 通知種別とファイルから、サーバーへ送るmappingを作る(管理者は列もprogram・時間枠・人数も選ばない)。
  /// 繰り上げ当選は、profileの判定規則(waitlist)を入れるだけで、繰り上げ先はサーバーがファイルから判定する。
  void _rebuildMapping() {
    mapping = null;
    notificationError = null;
    final parsed = table;
    final type = notificationType;
    if (parsed == null || type == null || formatError != null || event == null) return;
    if (type == NotificationType.waitlistPromotion) {
      final w = widget.profile.waitlist;
      if (w == null) {
        notificationError = 'この形式のファイルでは、キャンセル待ち繰り上げ当選を取り込めません。';
        return;
      }
      final missing = [w.optionsColumn, w.countColumn]
          .where((c) => !parsed.headers.contains(c))
          .toList();
      if (missing.isNotEmpty) {
        notificationError = 'このファイルは繰り上げ先を一意に判定できません(列「${missing.join('」「')}」がありません)。';
        return;
      }
      if (parsedFile?.format != ImportFileFormat.xlsx || sheet?.name == null) {
        notificationError = 'このファイルは繰り上げ先を一意に判定できません(キャンセル待ち繰り上げ当選は、Excel(.xlsx)のシート名から時間枠を読み取ります)。';
        return;
      }
      // シートを選ぶ = 時間枠を選ぶことになるため、候補のシートが複数あるファイルは取り込まない(管理者に選ばせない)。
      if (sheetCandidates.length > 1) {
        notificationError = 'このファイルは繰り上げ先を一意に判定できません(対象のシートが${sheetCandidates.length}枚あり、時間枠を1つに決められません)。';
        return;
      }
    }
    mapping = buildMappingFromProfile(
      widget.profile,
      event!.programs,
      hebelResidenceColumn: _hebelColumn,
      autoExcludeCancelled: tableHasCancelledRows(widget.profile, parsed),
      notificationType: type,
    );
  }

  /// 通常当選を選んだのに、繰り上げリストらしいファイル(シート名が時間枠で、全行にキャンセル待ち希望枠がある)なら警告する。
  /// 確実ではないため止めない(繰り上げ当選の指定でシート名が時間枠として読めない場合は、上の判定とサーバーが止める)。
  /// 通知種別は変えない。警告は通知種別の欄・検証結果・プレビュー・取込確定の確認まで表示し続ける(取り違えに確定前に気づけるように)。
  /// 戻り値は理由(警告の本文は[_mixupWarning])。
  String? get _possibleMixup {
    final parsed = table;
    final w = widget.profile.waitlist;
    if (notificationType != NotificationType.normal || parsed == null || w == null) return null;
    if (parseSheetTimeRange(sheet?.name) == null) return null;
    final index = parsed.headers.indexOf(w.optionsColumn);
    final rows = parsed.records.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
    if (index < 0 || rows.isEmpty) return null;
    if (!rows.every((r) => index < r.length && r[index].trim().isNotEmpty)) return null;
    return 'シート名が時間枠(「${sheet!.name}」)で、全行にキャンセル待ち希望枠があります。';
  }

  /// 取り違えの可能性の警告(見落としにくい表示。通知種別の欄・検証結果・プレビュー・確定の確認で同じもの)。
  Widget _mixupWarning(String reason, Key key) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 8, bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xfffff1cf),
      border: Border.all(color: const Color(0xffb54708), width: 2),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded, color: Color(0xffb54708)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'キャンセル待ち繰り上げ用ファイルの可能性があります。通知種別が「通常当選」で正しいか確認してください。',
                style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xffb54708)),
              ),
              Text('理由：$reason'),
              const Text('繰り上げ当選の参加者へ通常当選のメールを送らないよう、違う場合は通知種別を「キャンセル待ち繰り上げ当選」に選び直してください。'),
            ],
          ),
        ),
      ],
    ),
  );

  // ファイル・列の対応が変わったら、検証(と確認)・プレビューは無効。再検証が必要
  void _invalidateValidation() {
    validation = null;
    validationError = null;
    validatedFingerprint = null;
    _rowIndex = {};
    ackNewImport = false;
    _invalidatePreview();
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
      if (mounted) setState(() => fileError = 'ファイルを開けませんでした。もう一度お試しください。');
      return;
    }
    if (picked == null || !mounted) return;
    setState(() {
      _resetFile();
      file = picked;
      try {
        final parsed = parseImportFile(picked!.name, picked.bytes);
        parsedFile = parsed;
        final selection = selectImportSheet(parsed, widget.profile);
        if (selection.selected != null) {
          _useSheet(selection.selected!);
        } else if (selection.candidates.isNotEmpty) {
          // 候補が複数あるときは、先頭のシートを勝手に使わない(管理者が選ぶ)。
          sheetCandidates = selection.candidates;
        } else {
          fileError = selection.problem;
        }
      } on ImportFileException catch (e) {
        fileError = e.message;
      }
    });
  }

  void _useSheet(ImportSheet selected) {
    sheet = selected;
    final parsed = selected.table;
    if (parsed == null) {
      fileError = 'シート「${selected.name ?? ''}」にデータがありません。';
      return;
    }
    table = parsed;
    _applyProfile(parsed);
  }

  /// Excelの候補のシートから、管理者が選んだシートを使う(選び直したら、検証・対処・プレビューはやり直し)。
  void _chooseSheet(ImportSheet selected) {
    if (busy) return;
    setState(() {
      formatError = null;
      fileError = null;
      missingHeadersList = [];
      mapping = null;
      table = null;
      notificationError = null;
      _invalidateValidation();
      _clearDecisions();
      result = null;
      commitError = null;
      commitAmbiguous = false;
      _useSheet(selected);
    });
  }

  // 通常運用ではファイルの列を利用者に選ばせない。headerが今年度の正式フォーマットと一致しない場合は、
  // 検証(サーバーへの問い合わせ)を試みる前に、ここで明確に拒否する(CSV・Excelで同じ規則)。
  // HEBEL属性の列は任意(無ければ取り込まない)。候補に一致する列が複数あれば、どれを使うか決められないため拒否する。
  void _applyProfile(CsvTable parsed) {
    final missing = widget.profile.missingHeaders(parsed.headers);
    if (missing.isNotEmpty) {
      formatError = 'このファイルは対応している参加者リストの形式ではありません。';
      missingHeadersList = missing;
      return;
    }
    final hebel = widget.profile.resolveHebelResidenceColumn(parsed.headers);
    if (hebel.ambiguous) {
      formatError = 'HEBEL属性(「${widget.profile.hebelResidenceHeaders.join('」「')}」)の列が複数あるため、どの列を使うか決められません。列を1つにしてから選び直してください。';
      return;
    }
    _hebelColumn = hebel.column;
    _rebuildMapping();
  }

  ImportRequest _buildRequest({int? newImportSequence}) => buildImportRequest(
    eventId: event!.eventId,
    fileName: file!.name,
    fileBytes: file!.bytes,
    table: table!,
    mapping: mapping!,
    newImportSequence: newImportSequence,
    decisions: _decisions,
    sheetName: parsedFile?.format == ImportFileFormat.xlsx ? sheet?.name : null,
    sheetCandidates: _sheetCandidateNames(),
    notificationType: notificationType ?? NotificationType.normal,
  );

  /// 繰り上げ当選のとき、ファイル内の参加者リストの形式に合うシート名すべて(サーバーが1枚であることを確かめる)。
  List<String>? _sheetCandidateNames() {
    if (notificationType != NotificationType.waitlistPromotion || parsedFile?.format != ImportFileFormat.xlsx) return null;
    final names = sheetCandidates.isNotEmpty ? [for (final s in sheetCandidates) s.name] : [sheet?.name];
    return [for (final n in names) ?n];
  }

  /// 検証した内容(CSV・列の対応・修正・除外)。プレビュー時にこれと異なれば再検証が必要。
  static String _fingerprintOf(ImportRequest request) =>
      '${request.json['fileHash']}\n${canonicalJson(request.json['mapping'])}\n'
      '${canonicalJson({'c': request.json['corrections'], 'e': request.json['excludedRows']})}\n'
      '${request.json['notificationType'] ?? ''}\n${request.json['sourceSheetName'] ?? ''}\n'
      '${canonicalJson(request.json['sourceSheetCandidates'])}';

  /// Excelの読み取りについての注記(結合セル・数式・列名の行の位置・読まなかった非表示のシート)。
  List<Widget> _sheetNotices() {
    final f = parsedFile;
    final s = sheet;
    if (f == null || f.format != ImportFileFormat.xlsx || s == null) return const [];
    const color = Color(0xfffff1cf);
    final hidden = f.sheets.where((x) => x.hidden).map((x) => '「${x.name}」').toList();
    return [
      if (s.mergedRangeCount > 0)
        _notice(
          'このシートには結合セルが${s.mergedRangeCount}か所あります。結合したセルは左上のセルの値だけを読み取ります(他は空欄として扱います)。',
          color: color,
          key: const Key('sheet-merged-notice'),
        ),
      if (s.formulaCellCount > 0)
        _notice(
          'このシートには数式のセルが${s.formulaCellCount}個あります。Excelに保存されている計算結果の値を読み取ります。',
          color: color,
          key: const Key('sheet-formula-notice'),
        ),
      if (s.headerRowNumber != 1)
        _notice(
          '列名の行はシートの${s.headerRowNumber}行目です。検証画面の「n行目」は、列名の行を1行目として数えた番号です'
          '(シートの行番号 = n + ${s.headerRowNumber - 1})。',
          color: color,
          key: const Key('sheet-header-row-notice'),
        ),
      if (hidden.isNotEmpty)
        _notice(
          '非表示のシート(${hidden.join('、')})は読み取りの対象にしていません。',
          color: const Color(0xffeef3f8),
          key: const Key('sheet-hidden-notice'),
        ),
    ];
  }

  /// Excelに参加者リストの形式に合うシートが複数あるとき、管理者に取り込むシートを選ばせる。
  Widget _sheetChooser() => Container(
    key: const Key('sheet-chooser'),
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(10),
    color: const Color(0xfffff1cf),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'このExcelには、参加者リストの形式に合うシートが複数あります。取り込むシートを選んでください。',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final candidate in sheetCandidates)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: OutlinedButton(
                key: ValueKey('choose-sheet-${candidate.name}'),
                onPressed: busy ? null : () => _chooseSheet(candidate),
                child: Text(
                  '${identical(candidate, sheet) ? '✓ ' : ''}「${candidate.name}」'
                  '(データ${candidate.table?.records.length ?? 0}行)',
                ),
              ),
            ),
          ),
      ],
    ),
  );

  // ---- 検証 ---------------------------------------------------------------------------------------
  /// 検証(修正・除外を含めた最終的な内容で、サーバーが判定する)。
  /// [keepConfirmations]: 管理者の対処(修正・除外)による再検証。次の取込回が変わっていなければ、許可の鍵が
  /// 変わっていない許可だけを引き継ぐ(修正した行の許可は修正の時点で解除済み。鍵が変わった許可も解除して、改めて許可させる)。
  Future<void> _runValidate({bool keepConfirmations = false}) async {
    if (busy || table == null || mapping == null || event == null) return;
    // profileから自動生成したmappingが不正になることは無いはずだが、念のため送信前に確認する(内部エラー)。
    if (mapping!.validate().isNotEmpty) {
      setState(
        () => validationError = '内部エラー: 自動生成した列の対応を確認できませんでした。管理者へご連絡ください。',
      );
      return;
    }
    final ImportRequest request;
    try {
      request = _buildRequest();
    } on CsvParseException catch (e) {
      setState(() => validationError = e.message);
      return;
    }
    final previous = keepConfirmations ? validation : null;
    final keptNewImport = ackNewImport;
    setState(() {
      validating = true;
      _invalidateValidation();
      result = null;
      commitError = null;
    });
    try {
      final loaded = await widget.service.validate(request);
      if (!mounted) return;
      setState(() {
        validation = loaded;
        validatedFingerprint = _fingerprintOf(request);
        _rowIndex = {for (final r in loaded.rows) r.sourceRowNumber: r};
        final p = previous;
        final keep = p != null && p.nextImportSequence == loaded.nextImportSequence;
        ackNewImport = keep && keptNewImport && loaded.alreadyImported;
        if (keep) {
          approvals.removeWhere((k, key) => !_isAllowed(k.$1, k.$2));
        } else {
          approvals.clear();
        }
      });
    } on ImportException catch (e) {
      if (mounted) setState(() => validationError = e.message);
    } catch (_) {
      if (mounted) setState(() => validationError = '検証できませんでした。');
    } finally {
      if (mounted) setState(() => validating = false);
    }
  }

  /// 修正・除外を変えたら、最終的な内容でサーバーが検証し直す(修正しただけで正常扱いにはしない)。
  Future<void> _changeDecisions(void Function() change) async {
    if (busy) return;
    setState(() {
      change();
      editingRow = null;
    });
    await _runValidate(keepConfirmations: true);
  }

  Future<void> _exclude(Iterable<int> rows, String reason) => _changeDecisions(() {
    for (final n in rows) {
      exclusions[n] = reason;
    }
  });

  /// 未解決の問題(プレビューへ進む前に、修正・除外・許可のいずれかが必要なもの)。
  ({int errors, int review, int warnings}) get _unresolved {
    final v = validation;
    if (v == null) return (errors: 0, review: 0, warnings: 0);
    // 参考情報(不参加の残存人数など)は数えない(許可は要らない)。
    final warnings =
        v.existingDuplicateRowList.where((n) => !_isAllowed(n, _existingDuplicate)).length +
        v.csvDuplicateRowList.where((n) => !_isAllowed(n, _csvDuplicate)).length;
    return (
      errors: v.pendingErrorRows.isNotEmpty ? v.pendingErrorRows.length : v.errorCount,
      review: v.pendingReviewRows.where((n) => !_isAllowed(n, _review)).length,
      warnings: warnings,
    );
  }

  /// プレビューへ進める条件: 最新の対処で検証済み・未解決の問題0件・取込済みの内容なら新しい取込回の確認済み。
  bool get _validationPassed {
    final v = validation;
    if (v == null || validating || validatedFingerprint == null) return false;
    final u = _unresolved;
    if (u.errors > 0 || u.review > 0 || u.warnings > 0) return false;
    if (v.alreadyImported && !ackNewImport) return false;
    return true;
  }

  /// 新しい取込回として取り込む場合だけ、batchIdへ含める取込回の番号(それ以外は従来どおりのbatchId)。
  int? get _newImportSequence {
    final v = validation;
    return v != null && v.alreadyImported && ackNewImport
        ? v.nextImportSequence
        : null;
  }

  // ---- プレビュー ---------------------------------------------------------------------------------
  Future<void> _runPreview() async {
    if (busy || table == null || mapping == null || event == null) return;
    if (!_validationPassed) return;
    final ImportRequest request;
    try {
      request = _buildRequest(newImportSequence: _newImportSequence);
    } on CsvParseException catch (e) {
      setState(() => previewError = e.message);
      return;
    }
    // 検証した後にCSV・列の対応が変わっていれば、検証結果は使えない(再検証が必要)。
    if (_fingerprintOf(request) != validatedFingerprint) {
      setState(() {
        _invalidateValidation();
        validationError = 'ファイルまたは列の対応が検証時から変わりました。もう一度検証してください。';
      });
      return;
    }
    final checked = validation!;
    setState(() {
      previewing = true;
      _invalidatePreview();
      result = null;
      commitError = null;
    });
    try {
      final loaded = await widget.service.preview(request);
      if (!mounted) return;
      if (!checked.matchesPreview(loaded)) {
        setState(
          () => previewError =
              '検証結果とプレビューの判定が一致しませんでした。取り込まずに、もう一度検証からやり直してください。',
        );
        return;
      }
      setState(() {
        // このプレビューに対応するリクエストをそのまま保持し、確定でもこの内容だけを送る
        previewedRequest = request;
        preview = loaded;
        // 確認が必要な行の許可は検証画面で行う(プレビューでは変えない)
        approved
          ..clear()
          ..addAll(checked.pendingReviewRows.where((n) => _isAllowed(n, _review)));
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
    if (p == null || table == null || g.countColumn == null) {
      return (participants: 0, headcount: 0);
    }
    var participants = 0;
    var headcount = 0;
    for (final r in p.rows) {
      // 今回の取込から除外した行は数えない。人数は修正後の最終的な値で数える。
      if (r.excluded || !include(r)) continue;
      if (!r.programIds.contains(g.programId)) continue;
      participants += 1;
      headcount += displayCountOf(_cellAt(r.sourceRowNumber, g.countColumn)) ?? 0;
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
  /// 取込予定(今回の取込から除外していない行。未解決の問題が無いときだけプレビューできるため、すべて取り込まれる)。
  int get _importCount =>
      preview?.decisionSummary?.importRows ??
      (preview?.readyCount ?? 0) + approved.length;

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
              if (_possibleMixup case final reason?) _mixupWarning(reason, const Key('confirm-mixup')),
              _confirmRow('イベント名', event!.eventName),
              _confirmRow('通知種別', (notificationType ?? NotificationType.normal).label),
              _confirmRow('ファイル名', request.fileName),
              if (sheet?.name != null) _confirmRow('シート', sheet!.name!),
              _confirmRow('総行数', '${p.totalRecords}行'),
              _confirmRow('取込予定', '$_importCount件'),
              _confirmRow('修正した行', '${corrections.keys.map((k) => k.$1).toSet().length}件'),
              _confirmRow('今回の取込から除外した行', '${exclusions.length}件(取り込まれません)'),
              for (final (i, line) in _allowedWarningLines.indexed)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    line,
                    key: ValueKey('confirm-allowed-$i'),
                    style: const TextStyle(color: Color(0xffb54708)),
                  ),
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
              if (validation?.hasEmailDuplicates == true) ...[
                const SizedBox(height: 10),
                const Text(
                  '同じメールアドレスの参加者が複数、有効な参加者になります(別参加者として扱われます)。',
                  key: Key('confirm-duplicate-caution'),
                  style: TextStyle(color: Color(0xffb54708)),
                ),
              ],
              if (_newImportSequence != null)
                _confirmRow('取込回', '新しい取込回(第$_newImportSequence回)として取り込みます'),
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
        validation: validation,
        acknowledgeExistingEmailDuplicates: ackExistingDuplicates,
        acknowledgeCsvEmailDuplicates: ackCsvDuplicates,
        approvalKeys: _approvalKeysToSend,
      );
      if (!mounted) return;
      setState(() => result = done);
    } on ImportException catch (e) {
      if (mounted) {
        setState(() {
          if (_revalidationCodes.contains(e.code)) {
            // サーバーが最新の状態で確認した結果、検証時から状態が変わっていた(別の取込の確定など)。
            // 勝手に次の回として取り込まず、検証からやり直させる(以前の確認はすべて無効)。
            _invalidateValidation();
            validationError = e.message;
            return;
          }
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

  /// サーバーが「検証からやり直す必要がある」と返した理由。
  static const _revalidationCodes = {
    'import-state-changed',
    'validation-required',
    'import-has-errors',
    'existing-email-duplicates-unacknowledged',
    'csv-email-duplicates-unacknowledged',
    'unresolved-review-rows',
    'approvals-outdated',
  };

  /// 管理者が許可した警告(確認ダイアログに示す)。
  List<String> get _allowedWarningLines {
    final v = validation;
    if (v == null) return const [];
    return [
      if (v.existingDuplicateRowList.isNotEmpty && ackExistingDuplicates)
        '既存参加者とのメール重複${v.existingDuplicateRowList.length}件を許可して、別参加者として取り込みます',
      if (v.csvDuplicateRowList.isNotEmpty && ackCsvDuplicates)
        'ファイル内のメール重複${v.csvDuplicateRowList.length}件を許可して、別参加者として取り込みます',
      if (approved.isNotEmpty) '確認が必要な行${approved.length}件を許可して取り込みます',
    ];
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
  Widget _formatErrorSection() => _section('対応していないファイルです', [
    _notice(formatError!, key: const Key('format-error')),
    if (missingHeadersList.isNotEmpty) ...[
      const SizedBox(height: 6),
      const Text('不足している列', style: TextStyle(fontWeight: FontWeight.bold)),
      for (final h in missingHeadersList)
        Text('・$h', key: ValueKey('missing-header-$h')),
    ],
  ]);

  /// 通知種別で使うメール(件名の表示)。送信時もサーバーが取込回の通知種別でこのメールを使う(選び直しはできない)。
  static String _mailLabelOf(NotificationType type) => switch (type) {
    NotificationType.normal => 'ご参加予約確定のお知らせ（現在の通常の当選通知）',
    NotificationType.waitlistPromotion => 'お席のご用意ができました：ご参加予約確定のお知らせ',
  };

  Widget _notificationSection() {
    final mixup = _possibleMixup;
    return _section('通知種別', [
      const Text('このファイルの参加者へ送る当選通知の種類を選んでください(必須)。選ぶまで検証へ進めません。'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final type in NotificationType.values)
            ChoiceChip(
              key: ValueKey('notification-${type.value}'),
              label: Text(type.label),
              selected: notificationType == type,
              onSelected: busy ? null : (_) => _selectNotificationType(type),
            ),
        ],
      ),
      if (notificationType != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '使用メール：${_mailLabelOf(notificationType!)}',
            key: const Key('notification-mail'),
          ),
        ),
      if (notificationType == NotificationType.waitlistPromotion)
        const Text(
          '繰り上げ先(program・時間枠・人数)は、シート名と各行の「キャンセル待ち希望枠」「キャンセル待ち希望人数」から自動で判定します。',
        ),
      if (notificationError != null)
        _notice(notificationError!, key: const Key('notification-error')),
      if (mixup != null) _mixupWarning(mixup, const Key('notification-mixup')),
    ]);
  }

  /// 検証結果の冒頭: 通知種別・使用メール・原本行数・キャンセル自動除外・取込(送信)対象。繰り上げ当選は判定した繰り上げ先も示す。
  Widget _notificationSummary(ImportValidation v) {
    final type = v.notificationType;
    final w = v.waitlistPromotion;
    final programName = w == null
        ? null
        : (event?.programs.where((p) => p.programId == w.programId).firstOrNull?.name ?? w.programId);
    final countsText = w == null
        ? ''
        : ([...w.rows]..sort((a, b) => a.sourceRowNumber - b.sourceRowNumber))
            .map((r) => '${r.sourceRowNumber}行目 ${r.plannedCount}名')
            .join('、');
    return Container(
      key: const Key('notification-summary'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      color: type == NotificationType.waitlistPromotion ? const Color(0xfffff1cf) : const Color(0xffeef3f8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '通知種別：${type.label}',
            key: const Key('summary-notification-type'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Text('使用メール：${_mailLabelOf(type)}', key: const Key('summary-mail')),
          const SizedBox(height: 6),
          InfoRow('原本行数', '${v.totalRows}行', key: const Key('summary-original-rows')),
          InfoRow('キャンセル自動除外', '${v.autoExcludedRowCount}行(原本でキャンセル)', key: const Key('summary-auto-excluded')),
          InfoRow('取込・送信対象', '${v.importRowCount}件', key: const Key('summary-import-rows')),
          if (w != null) ...[
            InfoRow('繰り上げ先', '$programName　${w.slotLabel}', key: const Key('summary-waitlist-target')),
            InfoRow('人数', countsText, key: const Key('summary-waitlist-counts')),
            const Text('元の申込の他のprogram(トークショー等)は、今回の当選に含めません。'),
          ],
        ],
      ),
    );
  }

  Widget _autoAnalysisSection() => _section('自動解析結果', [
    const Text(
      'ファイルの列を自動で認識しました(列を選ぶ操作は不要です)。',
      key: Key('auto-mapping-ok'),
    ),
    const SizedBox(height: 8),
    for (final g in mapping!.programs)
      Text('・${g.name}: 参加判定と人数を自動で読み取ります', key: ValueKey('auto-program-${g.programId}')),
    Text(
      mapping!.hebelResidenceColumn != null
          ? '・HEBEL属性: 「${mapping!.hebelResidenceColumn}」列から読み取ります(受付画面での確認用)'
          : '・HEBEL属性: このファイルには列がありません(取り込みません。受付画面には表示されません)',
      key: const Key('auto-hebel-residence'),
    ),
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
    final typeLabel = preview?.participationTypes.where((t) => t['value'] == r.participationType).firstOrNull?['label'];
    final typeText = preview?.participationTypes.isNotEmpty == true ? ' / 参加タイプ: ${typeLabel ?? '未確定'}' : '';
    return '${r.classification.label}${issues.isEmpty ? '' : ' — $issues'}$programs$typeText';
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
    // 修正があれば修正後の最終的な値で示す
    String cellOf(String? column) => _cellAt(r.sourceRowNumber, column);

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
    // プレビューは「最終的に取り込まれる内容」(修正後の値・今回の取込から除外した行を除く)。
    final review = p.rows
        .where((r) => !r.excluded && r.classification == RowClass.review)
        .toList();
    final errors = p.rows
        .where((r) => !r.excluded && r.classification == RowClass.error)
        .toList();
    final ready = p.rows
        .where((r) => !r.excluded && r.classification == RowClass.ready)
        .toList();
    final summary = p.decisionSummary;
    return _section('プレビュー結果(まだ取り込まれていません)', [
      if (_possibleMixup case final reason?) _mixupWarning(reason, const Key('preview-mixup')),
      if (summary != null)
        Container(
          key: const Key('preview-decision-summary'),
          padding: const EdgeInsets.all(12),
          color: const Color(0xffeef3f8),
          child: Text(
            '原本: ${summary.originalRows}件　修正: ${summary.correctedRows}件　'
            '除外: ${summary.excludedRows}件　取込予定: ${summary.importRows}件',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('back-to-validation'),
          onPressed: busy ? null : () => setState(_invalidatePreview),
          icon: const Icon(Icons.arrow_back),
          label: const Text('検証画面へ戻る(修正・除外・許可を変える)'),
        ),
      ),
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
      InfoRow('総行数', '${p.totalRecords}行'),
      InfoRow('空の行', '${p.blankRecordCount}行'),
      InfoRow('取込対象', '${ready.length}件'),
      InfoRow('確認が必要(検証画面で許可済み)', '${review.length}件'),
      InfoRow('エラー', '${errors.length}件(取り込まれません)'),
      const SizedBox(height: 6),
      if (p.participationTypes.isNotEmpty) ...[
        const Text('参加タイプ別（取込対象の申込者件数・同伴者を除く）', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final type in p.participationTypes)
          InfoRow('${type['label']}', '${type['count']}件'),
        InfoRow('タイプ未確定', '${p.rows.where((r) => r.participationType == null).length}件'),
      ],
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
          '確認が必要な行(${review.length}件)— 検証画面で許可した行だけが取り込まれます',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final r in review)
          Padding(
            key: ValueKey('review-${r.sourceRowNumber}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r.sourceRowNumber}行目: ${approved.contains(r.sourceRowNumber) ? '許可済み' : '未許可(取り込まれません)'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (p.participationTypes.isNotEmpty) const Text('参加タイプ: 未確定'),
                for (final (i, msg) in _reviewMessages(r).indexed)
                  Text(
                    msg,
                    key: ValueKey('review-${r.sourceRowNumber}-message-$i'),
                  ),
              ],
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
        '取り込まれる件数: $_importCount件(取込対象+許可した確認の行)',
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
          child: Text('取り込める行がありません。ファイルの内容を見直してください。'),
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

  /// 手元のCSVの、指定した行・列の原本の値(前後の空白を除く)。
  String _originalCellAt(int sourceRowNumber, String? column) {
    final t = table;
    if (t == null || column == null) return '';
    final position = sourceRowNumber - 2;
    final index = t.headers.indexOf(column);
    if (position < 0 || position >= t.records.length || index < 0) return '';
    final record = t.records[position];
    return index < record.length ? record[index].trim() : '';
  }

  /// 最終的な値(管理者の修正があれば修正後の値、無ければ原本の値)。表示・集計はこの値で行う。
  /// 検証の応答は氏名・メールを含まないため、表示は手元のCSVと修正から作る。
  String _cellAt(int sourceRowNumber, String? column) {
    if (column == null) return '';
    final corrected = corrections[(sourceRowNumber, column)];
    return corrected != null ? corrected.trim() : _originalCellAt(sourceRowNumber, column);
  }

  /// 検証の問題1件の、利用者向けの説明(内部コード・programIdは出さない)。
  String _findingMessage(ValidationRow row, ValidationFinding f) {
    final program = f.programId == null ? null : _programName(f.programId!);
    String countText() {
      final g = mapping?.programs.where((p) => p.programId == f.programId).firstOrNull;
      final raw = _cellAt(row.sourceRowNumber, g?.countColumn);
      final count = displayCountOf(raw);
      return count != null ? '$count' : '「$raw」';
    }

    switch (f.code) {
      case 'email-duplicate-in-csv':
        return row.duplicateRows.isEmpty
            ? 'ファイル内に同じメールアドレスの行があります。'
            : 'ファイル内の${row.duplicateRows.join('、')}行目と同じメールアドレスです。';
      case 'email-duplicate-existing':
        return 'このイベントの既存の有効な参加者と同じメールアドレスです。';
      case 'not-attending-count-ignored':
        return '$program：不参加ですが人数欄に${countText()}が残っています。人数は無視されます。';
      case 'not-attending-count-present':
        return '$program：不参加ですが人数欄に${countText()}が残っています(確認が必要)。';
      case 'hebel-residence-unknown':
        return 'HEBEL属性：「${_cellAt(row.sourceRowNumber, mapping?.hebelResidenceColumn)}」は申込フォームの選択肢と一致しません'
            '(未知のHEBEL属性。修正するか、許可すると原文のまま「未知」として取り込みます)。';
    }
    final label = importIssueLabel(f.code);
    return program == null ? label : '$program：$label';
  }

  String _typeLabel(String? value) {
    final v = validation;
    if (v == null || v.participationTypes.isEmpty) return '';
    final label = v.participationTypes
        .where((t) => t['value'] == value)
        .firstOrNull?['label'];
    return '参加タイプ: ${label ?? '判定できません'}';
  }

  /// 問題の種類から、検証画面で修正できる列(検証で問題になった入力値だけ。汎用のCSV編集はしない)。
  List<String> _editableColumns(ValidationRow r) {
    final m = mapping!;
    final columns = <String>[];
    void add(String? c) {
      if (c != null && !columns.contains(c)) columns.add(c);
    }

    ProgramMapping? programOf(String? id) =>
        m.programs.where((p) => p.programId == id).firstOrNull;
    for (final f in r.findings) {
      switch (f.code) {
        case 'email-missing' || 'email-invalid' || 'email-duplicate-existing' || 'email-duplicate-in-csv':
          add(m.emailColumn);
        case 'name-missing':
          add(m.nameColumn);
        case 'hebel-residence-unknown':
          add(m.hebelResidenceColumn);
        case 'count-invalid' || 'attending-count-missing' || 'not-attending-count-present' || 'not-attending-count-ignored':
          add(programOf(f.programId)?.countColumn);
        case 'participation-empty' || 'participation-unknown':
          add(programOf(f.programId)?.participationColumn);
        case 'slot-missing' || 'slot-unparsed' || 'slot-zero-length' || 'slot-reversed' || 'slot-too-long':
          add(programOf(f.programId)?.slotColumn);
        case 'no-program' || 'participation-type-undetermined':
          for (final p in m.programs) {
            add(p.participationColumn);
            add(p.countColumn);
          }
      }
    }
    for (final key in corrections.keys) {
      if (key.$1 == r.sourceRowNumber) add(key.$2);
    }
    return columns;
  }

  void _startEdit(ValidationRow r) {
    setState(() {
      editingRow = r.sourceRowNumber;
      for (final c in _editControllers.values) {
        c.dispose();
      }
      _editControllers
        ..clear()
        ..addAll({
          for (final column in _editableColumns(r))
            column: TextEditingController(text: _cellAt(r.sourceRowNumber, column)),
        });
    });
  }

  /// 入力した値を修正として登録し、サーバーで検証し直す(原本と同じ値に戻した列は修正を取り消す)。
  Future<void> _applyEdit(int row) => _changeDecisions(() {
    _revokeApprovals(row);
    for (final entry in _editControllers.entries) {
      final value = entry.value.text;
      if (value == _originalCellAt(row, entry.key) || value.trim() == _originalCellAt(row, entry.key)) {
        corrections.remove((row, entry.key));
      } else {
        corrections[(row, entry.key)] = value;
      }
    }
  });

  static const _shownProblemRows = 300;
  static const _excludeReason = '検証画面で管理者が除外';

  /// 種類ごとの一括処理(許可・今回の取込から除外)。
  Widget _bulkPanel({
    required Key key,
    required String text,
    required List<int> rows,
    Widget? allow,
    required String excludeKey,
    required String excludeLabel,
  }) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(10),
    color: const Color(0xfffff1cf),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(text),
        ?allow,
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: Key(excludeKey),
            onPressed: busy || rows.isEmpty ? null : () => _exclude(rows, '一括除外: $excludeLabel'),
            child: Text('該当行(${rows.length}件)をすべて今回の取込から除外'),
          ),
        ),
      ],
    ),
  );

  Widget _validationSection() {
    final v = validation!;
    final m = mapping!;
    // 問題のある行・修正した行・除外した行を表示する(正常で対処の無い行は操作不要)。
    final shown = v.rows
        .where((r) => r.result != ValidationResult.ok || r.excluded || r.corrected ||
            corrections.keys.any((k) => k.$1 == r.sourceRowNumber))
        .toList()
      ..sort((a, b) => a.sourceRowNumber - b.sourceRowNumber);
    // 項目別の件数は、エラー → 警告の順に表示する(0件の項目は出さない)。
    final severityOf = <String, ValidationResult>{
      for (final r in v.rows)
        for (final f in r.findings) f.code: f.severity,
    };
    final findingEntries = v.findingCounts.entries.toList()
      ..sort((a, b) {
        final sa = severityOf[a.key] == ValidationResult.error ? 0 : 1;
        final sb = severityOf[b.key] == ValidationResult.error ? 0 : 1;
        return sa != sb ? sa - sb : b.value - a.value;
      });
    final u = _unresolved;
    const warnColor = Color(0xfffff1cf);
    final pendingReview = v.pendingReviewRows;
    return _section('検証結果(まだ取り込まれていません)', [
      if (_possibleMixup case final reason?) _mixupWarning(reason, const Key('validation-mixup')),
      _notificationSummary(v),
      InfoRow('総行数', '${v.totalRows}件(ファイル ${v.totalRecords}行・空の行${v.blankRecordCount}行を除く)', key: const Key('validation-total')),
      InfoRow('正常', '${v.okCount}件', key: const Key('validation-ok')),
      InfoRow('警告', '${v.warningCount}件', key: const Key('validation-warning')),
      InfoRow('エラー', '${v.errorCount}件', key: const Key('validation-error-count')),
      if (v.infoRowList.isNotEmpty)
        InfoRow('参考情報', '${v.infoRowList.length}件(取込には影響しません。許可は不要です)', key: const Key('validation-info')),
      if (v.correctedRowCount > 0 || v.excludedRowCount > 0) ...[
        InfoRow('修正した行', '${v.correctedRowCount}件', key: const Key('validation-corrected')),
        InfoRow('今回の取込から除外した行', '${v.excludedRowCount}件', key: const Key('validation-excluded')),
        InfoRow('取込予定', '${v.importRowCount}件', key: const Key('validation-import')),
      ],
      Container(
        key: const Key('unresolved-summary'),
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(10),
        color: u.errors + u.review + u.warnings == 0 ? const Color(0xffe7f5ec) : const Color(0xffffe8e8),
        child: Text(
          u.errors + u.review + u.warnings == 0
              ? '未解決の問題はありません。'
              : '未解決: エラー${u.errors}件・確認待ち${u.review}件・未許可の警告${u.warnings}件(修正・今回の取込から除外・許可のいずれかで対処してください)',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      if (findingEntries.isNotEmpty) ...[
        const SizedBox(height: 6),
        const Text('項目別', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final e in findingEntries)
          Text(
            '・${severityOf[e.key] == ValidationResult.error ? 'エラー' : severityOf[e.key] == ValidationResult.info ? '参考' : '警告'} ${importIssueLabel(e.key)}: ${e.value}件',
            key: ValueKey('finding-count-${e.key}'),
          ),
      ],
      if (v.participationTypes.isNotEmpty) ...[
        const SizedBox(height: 6),
        const Text('参加タイプ別（取込対象の行・同伴者を除く）', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final type in v.participationTypes)
          InfoRow('${type['label']}', '${type['count']}件'),
        InfoRow('タイプ判定不能', '${v.findingCounts['participation-type-undetermined'] ?? 0}件'),
      ],
      if (v.hebelResidenceSummary.isNotEmpty) _hebelResidenceSummary(v, m),
      if (v.importedBatches.isNotEmpty)
        _notice(
          '既に取り込まれている回: ${v.importedBatches.map((b) => '第${b.sequence}回${b.status == 'committed' ? '' : '(未完了)'}').join('、')}\n'
          '次に新規取込すると: 第${v.nextImportSequence}回',
          color: const Color(0xffeef3f8),
          key: const Key('imported-batches'),
        ),
      if (v.existingStatus == 'committing' || v.existingStatus == 'failed')
        _notice(
          '前回の取込が完了していません(${v.existingStatus == 'failed' ? '失敗' : '処理中'})。同じ内容で取り込むと、続きから安全に完了できます(二重には作られません)。',
          color: warnColor,
          key: const Key('validation-existing-incomplete'),
        ),
      if (v.alreadyImported) ...[
        _notice(
          'このファイル(同じ内容・同じ列の対応)は、既に第${v.existingSequence ?? '?'}回として取り込まれています。'
          'もう一度取り込む場合は、新しい取込回(第${v.nextImportSequence}回)として、別の参加者が作られます。'
          '第${v.existingSequence ?? '?'}回の参加者・送信履歴は変更されません。',
          color: warnColor,
          key: const Key('already-imported'),
        ),
        CheckboxListTile(
          key: const Key('ack-new-import'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text('第${v.nextImportSequence}回として新しく取り込みます。'),
          value: ackNewImport,
          onChanged: busy
              ? null
              : (value) => setState(() {
                  ackNewImport = value == true;
                  _invalidatePreview();
                }),
        ),
      ] else if (v.sameFileSequences.isNotEmpty && v.existingStatus == null)
        _notice(
          '参考: 同じファイルが、既に別の回として取り込まれています(${v.sameFileSequences.map((n) => '第$n回').join('、')})。',
          color: warnColor,
        ),
      if (u.errors > 0)
        _bulkPanel(
          key: const Key('validation-blocked'),
          text: '未解決のエラーの行が${u.errors}件あります。各行で修正するか、今回の取込から除外してください(エラーは許可できません)。',
          rows: v.pendingErrorRows,
          excludeKey: 'exclude-all-errors',
          excludeLabel: 'エラーの行',
        ),
      if (pendingReview.isNotEmpty)
        _bulkPanel(
          key: const Key('review-panel'),
          text: '確認が必要な行: ${pendingReview.length}件(許可した行だけが取り込まれます)',
          rows: pendingReview,
          allow: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('allow-all-review'),
              onPressed: busy
                  ? null
                  : () => setState(() => _setAllowed(pendingReview, _review, true)),
              child: Text('確認が必要な行${pendingReview.length}件をすべて許可'),
            ),
          ),
          excludeKey: 'exclude-all-review',
          excludeLabel: '確認が必要な行',
        ),
      if (v.hasEmailDuplicates)
        _notice(
          [
            if (v.existingDuplicateRowList.isNotEmpty)
              'このイベントの既存の有効な参加者(${v.existingActiveParticipantCount}件)とメールアドレスが重複する行: ${v.existingDuplicateRowList.length}件',
            if (v.csvDuplicateRowList.isNotEmpty)
              'ファイル内でメールアドレスが重複する行: ${v.csvDuplicateRowList.length}件',
            '取り込むと、同じメールアドレスの参加者が複数、有効(active)になります。'
                'イベント全体への配信・前日リマインド・受付名簿等でも別参加者として扱われ、同じアドレスへ複数通届くことがあります。',
          ].join('\n'),
          color: warnColor,
          key: const Key('duplicate-caution'),
        ),
      if (v.existingDuplicateRowList.isNotEmpty)
        _bulkPanel(
          key: const Key('existing-duplicates-panel'),
          text: '既存参加者とのメール重複: ${v.existingDuplicateRowList.length}件',
          rows: v.existingDuplicateRowList,
          allow: CheckboxListTile(
            key: const Key('ack-existing-duplicates'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('${v.existingDuplicateRowList.length}件すべて許可(既存参加者とは別の参加者として取り込みます)'),
            value: ackExistingDuplicates,
            onChanged: busy
                ? null
                : (value) => setState(() => _setAllowed(v.existingDuplicateRowList, _existingDuplicate, value == true)),
          ),
          excludeKey: 'exclude-all-existing-duplicates',
          excludeLabel: '既存参加者とのメール重複',
        ),
      if (v.csvDuplicateRowList.isNotEmpty)
        _bulkPanel(
          key: const Key('csv-duplicates-panel'),
          text: 'ファイル内のメール重複: ${v.csvDuplicateRowList.length}件',
          rows: v.csvDuplicateRowList,
          allow: CheckboxListTile(
            key: const Key('ack-csv-duplicates'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text('${v.csvDuplicateRowList.length}件すべて許可(それぞれ別の参加者として取り込みます)'),
            value: ackCsvDuplicates,
            onChanged: busy
                ? null
                : (value) => setState(() => _setAllowed(v.csvDuplicateRowList, _csvDuplicate, value == true)),
          ),
          excludeKey: 'exclude-all-csv-duplicates',
          excludeLabel: 'ファイル内のメール重複',
        ),
      // 参考情報: 見せるだけ(参加扱いにはせず、人数は無視する)。許可は要らず、プレビュー・取込を妨げない。
      if (v.ignoredCountRowList.isNotEmpty)
        _notice(
          '参考情報: 不参加のprogramに人数が残っている行: ${v.ignoredCountRowList.length}件'
          '(${v.ignoredCountRowList.map((n) => '$n行目').join('、')})\n'
          '参加扱いにはせず、人数は無視されます。許可は不要です(各行の内容は下の一覧で確認できます)。',
          color: const Color(0xffeef3f8),
          key: const Key('ignored-counts-panel'),
        ),
      if (shown.isNotEmpty) ...[
        const Divider(),
        Text(
          '問題のある行・対処した行(${shown.length}件)',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final r in shown.take(_shownProblemRows)) _validationRow(v, m, r),
        if (shown.length > _shownProblemRows)
          Text('ほか${shown.length - _shownProblemRows}件(ファイルを修正して再検証してください)'),
      ],
    ]);
  }

  /// HEBEL属性の分類別の件数(サーバーの集計。今回の取込から除外した行は含まない)と、行ごとの分類。
  /// 未知の値は件数を強調し、行の一覧では原文を示す(丸めない)。
  Widget _hebelResidenceSummary(ImportValidation v, ImportMapping m) {
    const unknown = 'unknown';
    final unknownCount = v.hebelResidenceSummary.where((h) => h.category == unknown).firstOrNull?.count ?? 0;
    final rows = v.rows.where((r) => !r.excluded && r.hebelResidence != null).toList()
      ..sort((a, b) => a.sourceRowNumber - b.sourceRowNumber);
    return Container(
      key: const Key('hebel-residence-summary'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      color: unknownCount > 0 ? const Color(0xffffe8e8) : const Color(0xffeef3f8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('HEBEL属性（取込予定の行・受付画面での確認用）', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final h in v.hebelResidenceSummary)
            InfoRow(
              h.label,
              '${h.count}件',
              key: ValueKey('hebel-residence-count-${h.category}'),
            ),
          if (unknownCount > 0)
            Text(
              '未知のHEBEL属性が$unknownCount件あります。各行で修正するか、確認のうえ許可してください(許可すると原文のまま「未知」として取り込みます)。',
              key: const Key('hebel-residence-unknown-notice'),
              style: const TextStyle(color: Color(0xffb42318), fontWeight: FontWeight.bold),
            ),
          ExpansionTile(
            key: const Key('hebel-residence-rows'),
            tilePadding: EdgeInsets.zero,
            title: Text('行ごとのHEBEL属性(${rows.length}件)'),
            children: [
              SizedBox(
                height: 240,
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final n = r.sourceRowNumber;
                    final raw = _cellAt(n, m.hebelResidenceColumn);
                    final isUnknown = r.hebelResidence == unknown;
                    return Text(
                      '$n行目　${_cellAt(n, m.nameColumn)}　${v.hebelResidenceLabel(r.hebelResidence!)}'
                      '${isUnknown ? '(原文:「$raw」)' : ''}',
                      key: ValueKey('hebel-residence-row-$n'),
                      style: isUnknown ? const TextStyle(color: Color(0xffb42318)) : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _validationRow(ImportValidation v, ImportMapping m, ValidationRow r) {
    final n = r.sourceRowNumber;
    final rowCorrections = corrections.entries.where((e) => e.key.$1 == n).toList();
    final status = r.autoExcluded
        ? '今回の取込から除外(原本でキャンセル・自動除外)'
        : r.excluded
        ? '今回の取込から除外(${exclusions[n] ?? ''})'
        : r.classification == RowClass.review && _isAllowed(n, _review)
        ? '${r.result.label}(許可済み)'
        : r.result.label;
    final color = r.excluded
        ? const Color(0xffeceff1)
        : r.result == ValidationResult.error
        ? const Color(0xffffe8e8)
        : r.result == ValidationResult.warning
        ? const Color(0xfffff1cf)
        : r.result == ValidationResult.info
        ? const Color(0xffeef3f8)
        : const Color(0xffe7f5ec);
    final editable = _editableColumns(r);
    return Container(
      key: ValueKey('validation-row-$n'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$n行目　$status', style: const TextStyle(fontWeight: FontWeight.bold)),
          SelectableText('${_cellAt(n, m.nameColumn)}　${_cellAt(n, m.emailColumn)}'),
          if (v.participationTypes.isNotEmpty && !r.excluded) Text(_typeLabel(r.participationType)),
          for (final (i, f) in r.findings.indexed)
            Text(
              '・${f.severity == ValidationResult.error ? '[エラー] ' : f.severity == ValidationResult.info ? '[参考] ' : ''}${_findingMessage(r, f)}',
              key: ValueKey('validation-row-$n-finding-$i'),
            ),
          for (final e in rowCorrections)
            Text(
              '修正: ${e.key.$2}「${_originalCellAt(n, e.key.$2)}」→「${e.value}」',
              key: ValueKey('correction-$n-${e.key.$2}'),
              style: const TextStyle(color: Color(0xff175cd3)),
            ),
          if (editingRow == n) ...[
            for (final column in _editControllers.keys)
              TextField(
                key: ValueKey('edit-$n-$column'),
                controller: _editControllers[column],
                decoration: InputDecoration(
                  labelText: column,
                  helperText: '原本: 「${_originalCellAt(n, column)}」',
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  key: ValueKey('apply-edit-$n'),
                  onPressed: busy ? null : () => _applyEdit(n),
                  child: const Text('修正して再検証'),
                ),
                TextButton(
                  key: ValueKey('cancel-edit-$n'),
                  onPressed: busy ? null : () => setState(() => editingRow = null),
                  child: const Text('キャンセル'),
                ),
              ],
            ),
          ] else
            Wrap(
              spacing: 8,
              children: [
                // 自動除外(原本でキャンセル)はサーバーが決める。取り消しはできない。
                if (r.autoExcluded)
                  const SizedBox.shrink()
                else if (r.excluded)
                  TextButton(
                    key: ValueKey('unexclude-$n'),
                    onPressed: busy ? null : () => _changeDecisions(() => exclusions.remove(n)),
                    child: const Text('除外を取り消す'),
                  )
                else ...[
                  // 許可は警告(確認が必要な行)だけ。エラーは許可できない(修正か除外)。
                  if (r.classification == RowClass.review)
                    FilterChip(
                      key: ValueKey('allow-$n'),
                      label: const Text('許可'),
                      selected: _isAllowed(n, _review),
                      onSelected: busy ? null : (value) => setState(() => _setAllowed([n], _review, value)),
                    ),
                  if (editable.isNotEmpty)
                    TextButton(
                      key: ValueKey('edit-$n'),
                      onPressed: busy ? null : () => _startEdit(r),
                      child: const Text('修正'),
                    ),
                  TextButton(
                    key: ValueKey('exclude-$n'),
                    onPressed: busy ? null : () => _exclude([n], _excludeReason),
                    child: const Text('今回の取込から除外'),
                  ),
                ],
                if (rowCorrections.isNotEmpty)
                  TextButton(
                    key: ValueKey('uncorrect-$n'),
                    onPressed: busy
                        ? null
                        : () => _changeDecisions(() {
                            _revokeApprovals(n);
                            corrections.removeWhere((k, _) => k.$1 == n);
                          }),
                    child: const Text('修正を取り消す'),
                  ),
              ],
            ),
        ],
      ),
    );
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
    const Text('イベント管理画面から参加者の取込を選択してください。', key: Key('no-event-id-notice')),
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
      return PageFrame(title: '参加者ファイルの取込', child: _missingEventSection());
    }
    return PageFrame(
      title: '参加者ファイルの取込',
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
                  'このイベントには、参加者リストで想定しているprogramがありません(${eventProgramMismatch.join('、')})。イベントの設定をご確認ください。',
                  key: const Key('event-program-mismatch'),
                ),
            ],
          ]),
          if (event != null && eventProgramMismatch.isEmpty)
            _section('参加者ファイル', [
              const Text('対応形式: Excel（.xlsx）/ CSV（.csv、UTF-8(BOMあり・なし)）'),
              const Text('列は自動で解析します(選ぶ操作は不要です)。'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('pick-file'),
                onPressed: busy ? null : _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(file == null ? '参加者ファイルを選択' : 'ファイルを選び直す'),
              ),
              if (file != null && parsedFile != null) ...[
                const SizedBox(height: 8),
                Text('選択中: ${file!.name}'),
                Text('形式: ${parsedFile!.format.label}', key: const Key('file-format')),
                if (sheet?.name != null) Text('シート: ${sheet!.name}', key: const Key('file-sheet')),
                if (table != null)
                  Text(
                    'データ行数: ${table!.records.length}行(列数: ${table!.headers.length}列)',
                    key: const Key('file-rows'),
                  ),
                ..._sheetNotices(),
              ],
              if (sheetCandidates.isNotEmpty) _sheetChooser(),
              if (fileError != null)
                _notice(fileError!, key: const Key('file-error')),
            ]),
          if (formatError != null) _formatErrorSection(),
          if (table != null && formatError == null) _notificationSection(),
          if (mapping != null && table != null) _autoAnalysisSection(),
          if (mapping != null && table != null)
            _section('検証', [
              const Text('取り込む前に、重複・人数・時間枠などを検証します。検証では何も取り込まれません。'),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('run-validate'),
                onPressed: busy ? null : _runValidate,
                child: Text(
                  validating
                      ? '検証中…'
                      : (validation == null ? '検証する' : 'もう一度検証する'),
                ),
              ),
              if (validationError != null)
                _notice(validationError!, key: const Key('validation-error')),
            ]),
          if (validation != null && mapping != null && table != null)
            _validationSection(),
          if (validation != null && mapping != null && table != null)
            _section('プレビュー', [
              const Text('プレビューでは何も取り込まれません。内容を確認してから取り込みます。'),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('run-preview'),
                onPressed: busy || !_validationPassed ? null : _runPreview,
                child: Text(previewing ? 'プレビュー中…' : 'プレビューする'),
              ),
              if (!_validationPassed)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '検証でエラーが0件になり、必要な確認を済ませると、プレビューへ進めます。',
                    key: Key('preview-locked'),
                  ),
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
