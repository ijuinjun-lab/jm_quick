import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/download_service.dart' as download;
import 'attendance_report_service.dart';
import 'qualification_change_dialog.dart';
import 'qualification_change_service.dart';
import 'reception_status_csv.dart';
import 'reception_status_summary.dart';
import 'winner_send_service.dart';

/// CSVを保存させる処理(既定はブラウザのダウンロード。サーバーには送らない。テストでは差し替える)。
typedef ReceptionStatusCsvSaver =
    void Function(Uint8List bytes, String fileName, String mimeType);

void _saveWithBrowser(Uint8List bytes, String fileName, String mimeType) =>
    download.downloadBytes(bytes, fileName, mimeType: mimeType);

const _csvMimeType = 'text/csv;charset=utf-8';

/// 表示切替。初期表示は参加者一覧。
enum ReceptionStatusView {
  list('参加者一覧'),
  summary('受付集計');

  const ReceptionStatusView(this.label);
  final String label;
}

/// 主催者用「受付状況一覧」(`/console?eventId=…` のイベント管理画面から開く。氏名選択で資格管理)。
/// システム管理者・このイベントのイベント管理者だけ(サーバー getConfirmedAttendanceReport が同じ権限で拒否する)。
///
/// ■ 取得は最終実績Excelと同じ getConfirmedAttendanceReport(受付状態の正本 programAttendances の現在の値)。
///   一覧は読取専用。資格変更は管理者専用APIと確認ダイアログを使用する。
/// ■ 更新は手動のみ: 画面を開いたときに1回、以降は「最新の状態に更新」を押したときだけ取得する(タイマー・自動更新なし)。
///   取得中は二重に取得しない。失敗しても前回取得した内容は残し、エラーを表示する。
/// ■ 表示する個人情報は氏名と、HEBEL属性の3分類(この画面だけの表示・集計上の分類。保存データ・原文は表示も変更もしない)。
///   メールアドレス・かなは表示しない。HEBEL属性の絞り込みも取得済みのデータで行う(追加の通信なし)。
/// ■ 「表示中の一覧をCSV出力」: 取得済みのデータに検索・絞り込み・並び順を適用した全行(描画範囲に依存しない)を、
///   ブラウザ内でCSVにして保存させる(reception_status_csv.dart)。追加の通信・Firestoreの読取はしない。
///   CSVの先頭には、押した時点の抽出条件・データ最終更新日時・CSV出力日時・抽出件数を記録する。
/// ■ 表示切替(参加者一覧 / 受付集計): 同じ取得済みデータの表示だけを切り替える(切替では通信しない)。
///   検索・絞り込み・並び順は画面の状態として保持し、切り替えて戻っても変わらない(CSVの出力対象も同じ)。
class ReceptionStatusPage extends StatefulWidget {
  const ReceptionStatusPage({
    super.key,
    required this.eventId,
    required this.eventName,
    required this.service,
    DateTime Function()? now,
    ReceptionStatusCsvSaver? csvSaver,
    this.eventStartAt,
    this.eventEndAt,
  }) : now = now ?? DateTime.now,
       csvSaver = csvSaver ?? _saveWithBrowser;

  final String eventId;
  final String eventName;
  final AttendanceReportService service;
  final DateTime Function() now;
  final ReceptionStatusCsvSaver csvSaver;

  /// イベントの開始(時間帯の日付)・終了(終了時刻の③)。イベント管理画面が取得済みの値を渡す(この画面では取得しない)。
  final DateTime? eventStartAt;
  final DateTime? eventEndAt;

  @override
  State<ReceptionStatusPage> createState() => _ReceptionStatusPageState();
}

const Color _muted = Color(0xff5c6670);
const Color _checkedInColor = Color(0xff067647);
const Color _checkedInBackground = Color(0xffe7f5ec);
const Color _pendingColor = Color(0xffb54708);
const Color _pendingBackground = Color(0xfffff1cf);
const Color _absentColor = Color(0xff5c6670);
const Color _absentBackground = Color(0xffe5e7eb);
const Duration _jst = Duration(hours: 9);

String _two(int v) => v.toString().padLeft(2, '0');

/// 日本時間の「yyyy/MM/dd HH:mm:ss」。
String formatJstDateTime(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${t.year}/${_two(t.month)}/${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// 日本時間の「MM/dd HH:mm」(一覧の受付時刻)。
String formatJstShort(DateTime at) {
  final t = at.toUtc().add(_jst);
  return '${_two(t.month)}/${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}

String formatRate(double? rate) =>
    rate == null ? '—' : '${rate.toStringAsFixed(1)}%';

class _ReceptionStatusPageState extends State<ReceptionStatusPage> {
  ReceptionStatus? status;
  DateTime? updatedAt;
  bool loading = false;
  String? error;

  final query = TextEditingController();
  String? programFilter;
  ReceptionStateFilter stateFilter = ReceptionStateFilter.all;
  ReceptionHebelGroup? hebelFilter;
  ReceptionSort sort = ReceptionSort.standard;
  List<ReceptionStatusRow> visible = const [];

  /// 表示中のモード(切り替えても通信しない。絞り込み等の状態はそのまま)。
  ReceptionStatusView view = ReceptionStatusView.list;

  Future<void> _change(String participantId) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => QualificationChangeDialog(
        service: widget.service as QualificationChangeService,
        eventId: widget.eventId,
        participantId: participantId,
      ),
    );
    if (changed == true && mounted) await _load();
  }

  /// CSV出力中(連続クリックで二重に保存させない)。
  bool exporting = false;

  /// 直前のCSV出力の結果(成功・失敗)。
  ({bool ok, String message})? exportResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (loading) return; // 取得中は二重に取得しない
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final report = await widget.service.getReport(widget.eventId);
      // 欠席の判定時刻 = このデータを取得した時刻(最終更新)。画面・絞り込み・CSVで同じ時点になる。
      final fetchedAt = widget.now();
      final built = buildReceptionStatus(
        report,
        judgedAt: fetchedAt,
        eventStartAt: widget.eventStartAt,
        eventEndAt: widget.eventEndAt,
      );
      if (!mounted) return;
      setState(() {
        status = built;
        updatedAt = fetchedAt;
        if (programFilter != null &&
            !built.programs.any((p) => p.programId == programFilter)) {
          programFilter = null;
        }
        _applyFilters();
      });
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '受付状況を取得できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// 表示中の一覧(検索・絞り込み・並び順を反映した全行)をCSVで保存させる。取得済みのデータだけを使う。
  Future<void> _exportCsv() async {
    if (exporting || visible.isEmpty) return;
    final rows = visible;
    // 出力ボタンを押した時点の画面の条件(CSVの情報欄に記録する。rowsと同じ状態から取る)
    final programName = programFilter == null
        ? null
        : status?.programs
              .where((p) => p.programId == programFilter)
              .firstOrNull
              ?.name;
    final conditions = ReceptionStatusCsvConditions(
      eventName: widget.eventName,
      dataUpdatedAt: updatedAt,
      query: query.text,
      programName: programName ?? programFilter,
      state: stateFilter,
      hebel: hebelFilter,
      sort: sort,
    );
    setState(() {
      exporting = true;
      exportResult = null;
    });
    try {
      final csv = buildReceptionStatusCsv(
        eventId: widget.eventId,
        rows: rows,
        exportedAt: widget.now(),
        conditions: conditions,
      );
      widget.csvSaver(csv.bytes, csv.fileName, _csvMimeType);
      if (mounted) {
        setState(
          () => exportResult = (
            ok: true,
            message: '「${csv.fileName}」を出力しました(${csv.rowCount}行)。',
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => exportResult = (
            ok: false,
            message: 'CSVを出力できませんでした。もう一度お試しください。',
          ),
        );
      }
    }
    // 保存の直後の連続クリックで、同じCSVを二重に保存させない
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (mounted) setState(() => exporting = false);
  }

  void _applyFilters() {
    final s = status;
    visible = s == null
        ? const []
        : filterReceptionRows(
            s.rows,
            query: query.text,
            programId: programFilter,
            state: stateFilter,
            hebel: hebelFilter,
            sort: sort,
          );
  }

  void _update(VoidCallback change) => setState(() {
    change();
    _applyFilters();
  });

  @override
  Widget build(BuildContext context) {
    final s = status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('受付状況一覧'),
        backgroundColor: Colors.white,
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: CustomScrollView(
            key: const Key('reception-status-scroll'),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                sliver: SliverList.list(
                  children: [
                    _header(),
                    if (error != null) _errorBox(error!),
                    if (s == null && loading)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (s != null && view == ReceptionStatusView.summary) ...[
                      _TotalsSection(totals: s.totals),
                      _HebelSection(groups: s.hebelGroups),
                      _ProgramSection(programs: s.programs),
                      _SlotSection(programs: s.programs),
                    ],
                    if (s != null && view == ReceptionStatusView.list) ...[
                      _listControls(s),
                      const _RowHeader(),
                    ],
                  ],
                ),
              ),
              if (s != null && view == ReceptionStatusView.list)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: visible.isEmpty
                      ? SliverToBoxAdapter(
                          child: Container(
                            key: const Key('reception-status-empty'),
                            color: Colors.white,
                            padding: const EdgeInsets.all(20),
                            child: Text(
                              s.rows.isEmpty
                                  ? '受付の対象となる参加者はいません。'
                                  : '条件に一致する参加者はいません。',
                              style: const TextStyle(color: _muted),
                            ),
                          ),
                        )
                      // 表示中の行だけを作る(参加者が多くても重くならない)
                      : SliverList.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, i) => _StatusRowTile(
                            row: visible[i],
                            striped: i.isOdd,
                            onSelect:
                                widget.service is QualificationChangeService
                                ? () => _change(visible[i].participantId)
                                : null,
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.eventName,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '受付状況を確認する画面です(閲覧のみ。データは変更されません)。自動では更新されません。'
            '最新の状況を見るときは「最新の状態に更新」を押してください。',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const Key('reception-status-refresh'),
                onPressed: loading ? null : _load,
                icon: loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(loading ? '取得中…' : '最新の状態に更新'),
              ),
              Text(
                updatedAt == null
                    ? '最終更新：—'
                    : '最終更新：${formatJstDateTime(updatedAt!)}（日本時間）',
                key: const Key('reception-status-updated-at'),
                style: const TextStyle(color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in ReceptionStatusView.values)
                ChoiceChip(
                  key: ValueKey('reception-status-view-${v.name}'),
                  label: Text(v.label),
                  avatar: Icon(
                    v == ReceptionStatusView.list
                        ? Icons.list_alt
                        : Icons.bar_chart,
                    size: 18,
                  ),
                  selected: view == v,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => view = v),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _errorBox(String message) => Container(
    key: const Key('reception-status-error'),
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    color: const Color(0xffffe8e8),
    child: Text(status == null ? message : '$message(表示中の内容は前回取得したものです)'),
  );

  Widget _listControls(ReceptionStatus s) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('参加者一覧（1行 = 参加者 × プログラム）'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  key: const Key('reception-status-search'),
                  controller: query,
                  decoration: const InputDecoration(
                    labelText: '氏名で検索',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _update(() {}),
                ),
              ),
              _dropdown<String?>(
                key: const Key('reception-status-program'),
                label: 'プログラム',
                value: programFilter,
                items: [
                  (null, 'すべて'),
                  for (final p in s.programs) (p.programId, p.name),
                ],
                onChanged: (v) => _update(() => programFilter = v),
              ),
              _dropdown<ReceptionStateFilter>(
                key: const Key('reception-status-state'),
                label: '受付状態',
                value: stateFilter,
                items: [
                  for (final f in ReceptionStateFilter.values) (f, f.label),
                ],
                onChanged: (v) => _update(() => stateFilter = v!),
              ),
              _dropdown<ReceptionHebelGroup?>(
                key: const Key('reception-status-hebel'),
                label: 'HEBEL属性',
                value: hebelFilter,
                items: [
                  (null, 'すべて'),
                  for (final g in ReceptionHebelGroup.values) (g, g.label),
                ],
                onChanged: (v) => _update(() => hebelFilter = v),
              ),
              _dropdown<ReceptionSort>(
                key: const Key('reception-status-sort'),
                label: '並び順',
                value: sort,
                items: [for (final o in ReceptionSort.values) (o, o.label)],
                onChanged: (v) => _update(() => sort = v!),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '表示中 ${visible.length}行 / 全${s.rows.length}行',
            key: const Key('reception-status-count'),
            style: const TextStyle(color: _muted, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('reception-status-export-csv'),
                onPressed: exporting || visible.isEmpty ? null : _exportCsv,
                icon: const Icon(Icons.download),
                label: const Text('表示中の一覧をCSV出力'),
              ),
              Text(
                '出力対象：${visible.length}行',
                key: const Key('reception-status-export-count'),
                style: const TextStyle(color: _muted, fontSize: 13),
              ),
            ],
          ),
          if (exportResult case final result?)
            Container(
              key: Key(
                result.ok
                    ? 'reception-status-export-done'
                    : 'reception-status-export-error',
              ),
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              color: result.ok
                  ? const Color(0xffeef3f8)
                  : const Color(0xffffe8e8),
              child: Text(result.message),
            ),
        ],
      ),
    ),
  );

  Widget _dropdown<T>({
    required Key key,
    required String label,
    required T value,
    required List<(T, String)> items,
    required ValueChanged<T?> onChanged,
  }) => SizedBox(
    // 値が変わったら作り直す(再取得でprogramが無くなり絞り込みを解除したときも、表示を合わせる)
    key: ValueKey('$key|$value'),
    width: 200,
    child: DropdownButtonFormField<T>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final (v, text) in items)
          DropdownMenuItem<T>(
            value: v,
            child: Text(text, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
  );
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.tileKey,
    required this.label,
    required this.value,
    this.note,
  });
  final Key tileKey;
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) => Container(
    key: tileKey,
    width: 170,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xfff7f9fb),
      border: Border.all(color: const Color(0xffdde3ea)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 13)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        if (note != null)
          Text(note!, style: const TextStyle(color: _muted, fontSize: 11)),
      ],
    ),
  );
}

class _TotalsSection extends StatelessWidget {
  const _TotalsSection({required this.totals});
  final ReceptionTotals totals;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('全体'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatTile(
                tileKey: const Key('total-applications'),
                label: '申込件数',
                value: '${totals.applications}件',
              ),
              _StatTile(
                tileKey: const Key('total-planned'),
                label: '予定人数（延べ）',
                value: '${totals.plannedTotal}名',
                note: '複数プログラムの参加を含む',
              ),
              _StatTile(
                tileKey: const Key('total-checked-in'),
                label: '受付済み申込件数',
                value: '${totals.checkedInApplications}件',
              ),
              _StatTile(
                tileKey: const Key('total-attended'),
                label: '実来場人数（延べ）',
                value: '${totals.attendedTotal}名',
                note: '複数プログラムの参加を含む',
              ),
              _StatTile(
                tileKey: const Key('total-not-checked-in'),
                label: '未受付申込件数',
                value: '${totals.notCheckedInApplications}件',
              ),
              _StatTile(
                tileKey: const Key('total-absent'),
                label: '欠席申込件数',
                value: '${totals.absentApplications}件',
                note: '未受付のうち、全プログラムが終了',
              ),
              _StatTile(
                tileKey: const Key('total-rate'),
                label: '受付率',
                value: formatRate(totals.rate),
                note: '受付済み申込件数 ÷ 申込件数',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '申込件数は参加者単位です(複数のプログラムに申し込んだ方も1件)。いずれかのプログラムを受付済みなら「受付済み」です。'
            '欠席は、受付が無いままプログラムの終了時刻を過ぎたものです(判定時点は最終更新。終了時刻が分からないプログラムは欠席にしません)。',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

/// 表の1行(見出し・データ共通)。flexで列幅を揃える。
class _TableLine extends StatelessWidget {
  const _TableLine({
    required this.cells,
    required this.flexes,
    this.header = false,
    this.lineKey,
  });
  final List<String> cells;
  final List<int> flexes;
  final bool header;
  final Key? lineKey;

  @override
  Widget build(BuildContext context) => Container(
    key: lineKey,
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
    decoration: BoxDecoration(
      color: header ? const Color(0xffeef3f8) : null,
      border: const Border(bottom: BorderSide(color: Color(0xffe5e7eb))),
    ),
    child: Row(
      children: [
        for (final (i, text) in cells.indexed)
          Expanded(
            flex: flexes[i],
            child: Text(
              text,
              textAlign: i == 0 ? TextAlign.start : TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: header
                  ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)
                  : null,
            ),
          ),
      ],
    ),
  );
}

/// HEBEL属性別受付状況(3分類を常に表示。参加者単位)。
class _HebelSection extends StatelessWidget {
  const _HebelSection({required this.groups});
  final List<ReceptionHebelStatus> groups;

  static const _flexes = [5, 2, 2, 2, 2, 2];

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('HEBEL属性別受付状況'),
          const SizedBox(height: 4),
          const Text(
            '件数は参加者単位です(複数のプログラムに申し込んだ方も1件)。受付率は 受付済み件数 ÷ 申込件数。'
            '回答なし・属性データなし・判定できない回答は「該当なし」に含めます。',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const _TableLine(
            header: true,
            flexes: _flexes,
            cells: ['HEBEL属性', '申込件数', '受付済み件数', '未受付件数', 'うち欠席', '受付率'],
          ),
          for (final g in groups)
            _TableLine(
              lineKey: ValueKey('hebel-status-${g.group.name}'),
              flexes: _flexes,
              cells: [
                g.group.label,
                '${g.applications}件',
                '${g.checkedInApplications}件',
                '${g.notCheckedInApplications}件',
                '${g.absentApplications}件',
                formatRate(g.rate),
              ],
            ),
        ],
      ),
    ),
  );
}

class _ProgramSection extends StatelessWidget {
  const _ProgramSection({required this.programs});
  final List<ReceptionProgramStatus> programs;

  static const _flexes = [4, 2, 2, 2, 2, 2, 2];

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('プログラム別'),
          const SizedBox(height: 4),
          const Text(
            '件数は「参加者 × プログラム」単位です。受付率は 受付済み件数 ÷ 対象件数(人数ベースではありません)。',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const _TableLine(
            header: true,
            flexes: _flexes,
            cells: ['プログラム', '予定人数', '受付済み件数', '実来場人数', '未受付件数', 'うち欠席', '受付率'],
          ),
          for (final p in programs)
            _TableLine(
              lineKey: ValueKey('program-status-${p.programId}'),
              flexes: _flexes,
              cells: [
                p.inEvent ? p.name : '${p.name}（イベント設定に無いプログラム）',
                '${p.plannedTotal}名',
                '${p.checkedInEntries}件',
                '${p.attendedTotal}名',
                '${p.notCheckedInEntries}件',
                '${p.absentEntries}件',
                formatRate(p.rate),
              ],
            ),
        ],
      ),
    ),
  );
}

class _SlotSection extends StatelessWidget {
  const _SlotSection({required this.programs});
  final List<ReceptionProgramStatus> programs;

  static const _flexes = [4, 2, 2, 2, 2, 2];

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SectionTitle('時間帯別'),
          for (final p in programs.where((p) => p.slots.isNotEmpty)) ...[
            const SizedBox(height: 12),
            Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const _TableLine(
              header: true,
              flexes: _flexes,
              cells: ['時間帯', '予定人数', '実来場人数', '受付済み件数', '対象件数', '欠席件数'],
            ),
            for (final slot in p.slots)
              _TableLine(
                lineKey: ValueKey('slot-status-${p.programId}-${slot.label}'),
                flexes: _flexes,
                cells: [
                  slot.label,
                  '${slot.plannedTotal}名',
                  '${slot.attendedTotal}名',
                  '${slot.checkedInEntries}件',
                  '${slot.entries}件',
                  '${slot.absentEntries}件',
                ],
              ),
          ],
          if (programs.every((p) => p.slots.isEmpty))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('申込はまだありません。', style: TextStyle(color: _muted)),
            ),
        ],
      ),
    ),
  );
}

const _rowFlexes = [4, 4, 4, 3, 2, 2, 2, 3];

class _RowHeader extends StatelessWidget {
  const _RowHeader();
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xffeef3f8),
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
    child: Row(
      children: [
        for (final (i, text) in const [
          '氏名',
          'HEBEL属性',
          '参加プログラム',
          '参加時間',
          '予定人数',
          '実来場人数',
          '受付状態',
          '受付時刻(日本時間)',
        ].indexed)
          Expanded(
            flex: _rowFlexes[i],
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
      ],
    ),
  );
}

class _StatusRowTile extends StatelessWidget {
  const _StatusRowTile({
    required this.row,
    required this.striped,
    this.onSelect,
  });
  final VoidCallback? onSelect;
  final ReceptionStatusRow row;
  final bool striped;

  @override
  Widget build(BuildContext context) {
    Widget cell(int i, Widget child) =>
        Expanded(flex: _rowFlexes[i], child: child);
    Widget text(String value, {int maxLines = 1}) =>
        Text(value, maxLines: maxLines, overflow: TextOverflow.ellipsis);
    return Container(
      key: ValueKey('status-row-${row.participantId}-${row.programId}'),
      color: striped ? const Color(0xfff9fafb) : Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          cell(
            0,
            onSelect == null
                ? text(row.name)
                : TextButton(onPressed: onSelect, child: Text(row.name)),
          ),
          cell(1, text(row.hebel.label, maxLines: 2)),
          cell(
            2,
            text(
              '${row.programName}${row.revoked ? '（資格取消）' : ''}${row.notificationType == null
                  ? ''
                  : row.notificationType == 'waitlistPromotion'
                  ? '［繰り上げ］'
                  : '［通常］'}',
            ),
          ),
          cell(3, text(row.timeText ?? '—')),
          cell(
            4,
            text(row.plannedCount == null ? '—' : '${row.plannedCount}名'),
          ),
          cell(
            5,
            text(row.attendedCount == null ? '—' : '${row.attendedCount}名'),
          ),
          cell(
            6,
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: switch (row.state) {
                    ReceptionAttendanceState.attended => _checkedInBackground,
                    ReceptionAttendanceState.pending => _pendingBackground,
                    ReceptionAttendanceState.absent => _absentBackground,
                    ReceptionAttendanceState.cancelled => _pendingBackground,
                  },
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  row.state.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: switch (row.state) {
                      ReceptionAttendanceState.attended => _checkedInColor,
                      ReceptionAttendanceState.pending => _pendingColor,
                      ReceptionAttendanceState.absent => _absentColor,
                      ReceptionAttendanceState.cancelled => _pendingColor,
                    },
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
          cell(
            7,
            text(
              row.checkedInAt == null ? '—' : formatJstShort(row.checkedInAt!),
            ),
          ),
        ],
      ),
    );
  }
}
