import 'package:flutter/material.dart';

import 'attendance_report_service.dart';
import 'reception_status_summary.dart';
import 'winner_send_service.dart';

/// 主催者用「受付状況一覧」(`/console?eventId=…` のイベント管理画面から開く。閲覧のみ)。
/// システム管理者・このイベントのイベント管理者だけ(サーバー getConfirmedAttendanceReport が同じ権限で拒否する)。
///
/// ■ 取得は最終実績Excelと同じ getConfirmedAttendanceReport(受付状態の正本 programAttendances の現在の値)。
///   新しいAPI・Firestoreの直接読取・購読は使わない。データは一切変更しない。
/// ■ 更新は手動のみ: 画面を開いたときに1回、以降は「最新の状態に更新」を押したときだけ取得する(タイマー・自動更新なし)。
///   取得中は二重に取得しない。失敗しても前回取得した内容は残し、エラーを表示する。
/// ■ 表示する個人情報は氏名だけ(メールアドレス・かな・HEBEL属性は表示しない)。
class ReceptionStatusPage extends StatefulWidget {
  const ReceptionStatusPage({
    super.key,
    required this.eventId,
    required this.eventName,
    required this.service,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final String eventId;
  final String eventName;
  final AttendanceReportService service;
  final DateTime Function() now;

  @override
  State<ReceptionStatusPage> createState() => _ReceptionStatusPageState();
}

const Color _muted = Color(0xff5c6670);
const Color _checkedInColor = Color(0xff067647);
const Color _checkedInBackground = Color(0xffe7f5ec);
const Color _pendingColor = Color(0xffb54708);
const Color _pendingBackground = Color(0xfffff1cf);
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
  ReceptionSort sort = ReceptionSort.standard;
  List<ReceptionStatusRow> visible = const [];

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
      final built = buildReceptionStatus(report);
      if (!mounted) return;
      setState(() {
        status = built;
        updatedAt = widget.now();
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

  void _applyFilters() {
    final s = status;
    visible = s == null
        ? const []
        : filterReceptionRows(
            s.rows,
            query: query.text,
            programId: programFilter,
            state: stateFilter,
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
      appBar: AppBar(title: const Text('受付状況一覧'), backgroundColor: Colors.white),
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
                    if (s != null) ...[
                      _TotalsSection(totals: s.totals),
                      _ProgramSection(programs: s.programs),
                      _SlotSection(programs: s.programs),
                      _listControls(s),
                      const _RowHeader(),
                    ],
                  ],
                ),
              ),
              if (s != null)
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
                          itemBuilder: (context, i) =>
                              _StatusRowTile(row: visible[i], striped: i.isOdd),
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
        ],
      ),
    ),
  );

  Widget _errorBox(String message) => Container(
    key: const Key('reception-status-error'),
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(12),
    color: const Color(0xffffe8e8),
    child: Text(
      status == null ? message : '$message(表示中の内容は前回取得したものです)',
    ),
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
                items: [for (final f in ReceptionStateFilter.values) (f, f.label)],
                onChanged: (v) => _update(() => stateFilter = v!),
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
                tileKey: const Key('total-rate'),
                label: '受付率',
                value: formatRate(totals.rate),
                note: '受付済み申込件数 ÷ 申込件数',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '申込件数は参加者単位です(複数のプログラムに申し込んだ方も1件)。いずれかのプログラムを受付済みなら「受付済み」です。',
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

class _ProgramSection extends StatelessWidget {
  const _ProgramSection({required this.programs});
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
            cells: ['プログラム', '予定人数', '受付済み件数', '実来場人数', '未受付件数', '受付率'],
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

  static const _flexes = [4, 2, 2, 2, 2];

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
              cells: ['時間帯', '予定人数', '実来場人数', '受付済み件数', '対象件数'],
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

const _rowFlexes = [4, 4, 3, 2, 2, 2, 3];

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
  const _StatusRowTile({required this.row, required this.striped});
  final ReceptionStatusRow row;
  final bool striped;

  @override
  Widget build(BuildContext context) {
    Widget cell(int i, Widget child) => Expanded(flex: _rowFlexes[i], child: child);
    Widget text(String value) => Text(value, overflow: TextOverflow.ellipsis);
    return Container(
      key: ValueKey('status-row-${row.participantId}-${row.programId}'),
      color: striped ? const Color(0xfff9fafb) : Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          cell(0, text(row.name)),
          cell(1, text(row.programName)),
          cell(2, text(row.timeText ?? '—')),
          cell(3, text(row.plannedCount == null ? '—' : '${row.plannedCount}名')),
          cell(4, text(row.attendedCount == null ? '—' : '${row.attendedCount}名')),
          cell(
            5,
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: row.checkedIn ? _checkedInBackground : _pendingBackground,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  row.checkedIn ? '受付済み' : '未受付',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: row.checkedIn ? _checkedInColor : _pendingColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
          cell(6, text(row.checkedInAt == null ? '—' : formatJstShort(row.checkedInAt!))),
        ],
      ),
    );
  }
}
