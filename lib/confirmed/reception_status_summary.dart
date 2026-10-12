import 'attendance_report_service.dart';

/// 主催者用「受付状況一覧」の集計(純粋関数。通信・Firestoreに依存しない)。
///
/// ■ 入力は最終実績と同じ getConfirmedAttendanceReport の応答。受付状態の正本は programAttendances の現在の値で、
///   取消済みは checkedIn:false(未受付)、人数訂正後は attendedCount が最新の値としてサーバーから返る。
/// ■ 集計対象(受付できる正式な参加者。サーバーの受付・参加証の条件と同じ):
///   participant.status が active で、取込回が確定済み(committed)または取込回なし。
///   申込programが1つも無い参加者は受付できないため、申込件数にも数えない。
/// ■ 1行 = 参加者×program。1人が複数programに申し込んでいれば、その数だけ行・program別の件数に数える。
///   全体の申込件数は参加者(participant)単位で1件。予定人数・実来場人数の全体値はprogramの合計(延べ)。
/// ■ program名・表示順はイベント設定(応答のprograms)から。時間帯は応答の timeText(slotLabel・startAt/endAt由来)。

/// 一覧の1行(参加者×program)。
class ReceptionStatusRow {
  const ReceptionStatusRow({
    required this.participantId,
    required this.name,
    required this.programId,
    required this.programName,
    required this.programIndex,
    required this.order,
    required this.checkedIn,
    this.timeText,
    this.plannedCount,
    this.attendedCount,
    this.checkedInAt,
  });

  final String participantId;
  final String name;
  final String programId;
  final String programName;

  /// programの表示順(イベント設定の順)。
  final int programIndex;

  /// 既定の並び順(サーバーの参加者の順 → programの表示順)。
  final int order;
  final String? timeText;
  final int? plannedCount;

  /// 受付済み(取消済みはfalse)。
  final bool checkedIn;

  /// 実来場人数(受付済みのときだけ。訂正後の最新の値)。
  final int? attendedCount;

  /// 受付時刻(UTC。受付済みのときだけ)。
  final DateTime? checkedInAt;
}

/// 全体の集計。申込件数は参加者単位、予定人数・実来場人数は延べ(program別の合計)。
class ReceptionTotals {
  const ReceptionTotals({
    required this.applications,
    required this.plannedTotal,
    required this.checkedInApplications,
    required this.attendedTotal,
  });

  /// 申込件数(参加者単位。複数programでも1件)。
  final int applications;

  /// 予定人数(延べ)。
  final int plannedTotal;

  /// 受付済み申込件数(いずれかのprogramが受付済みの参加者)。
  final int checkedInApplications;

  /// 実来場人数(延べ)。
  final int attendedTotal;

  /// 未受付申込件数。
  int get notCheckedInApplications => applications - checkedInApplications;

  /// 受付率(%)= 受付済み申込件数 ÷ 申込件数 × 100。申込0件ならnull。
  double? get rate => ratePercent(checkedInApplications, applications);
}

/// 時間帯別の集計(1つのprogramの中の1時間帯)。
class ReceptionSlotStatus {
  const ReceptionSlotStatus({
    required this.label,
    required this.entries,
    required this.checkedInEntries,
    required this.plannedTotal,
    required this.attendedTotal,
  });

  /// 時間帯の表示(時間の無い申込は「時間未設定」)。
  final String label;
  final int entries;
  final int checkedInEntries;
  final int plannedTotal;
  final int attendedTotal;
}

/// program別の集計。件数は参加者×program単位。
class ReceptionProgramStatus {
  const ReceptionProgramStatus({
    required this.programId,
    required this.name,
    required this.inEvent,
    required this.entries,
    required this.checkedInEntries,
    required this.plannedTotal,
    required this.attendedTotal,
    required this.slots,
  });

  final String programId;
  final String name;

  /// イベント設定にあるprogramか(設定から消えたprogramの受付記録はfalse)。
  final bool inEvent;

  /// 対象の参加者×program件数。
  final int entries;

  /// 受付済みの参加者×program件数。
  final int checkedInEntries;
  final int plannedTotal;
  final int attendedTotal;
  final List<ReceptionSlotStatus> slots;

  int get notCheckedInEntries => entries - checkedInEntries;

  /// 受付率(%)= 受付済み件数 ÷ 対象件数 × 100(件数ベース。人数ベースではない)。対象0件ならnull。
  double? get rate => ratePercent(checkedInEntries, entries);
}

class ReceptionStatus {
  const ReceptionStatus({
    required this.totals,
    required this.programs,
    required this.rows,
  });

  final ReceptionTotals totals;
  final List<ReceptionProgramStatus> programs;

  /// 既定の並び順(サーバーの参加者の順 → programの表示順)。
  final List<ReceptionStatusRow> rows;
}

double? ratePercent(int numerator, int denominator) =>
    denominator == 0 ? null : numerator * 100 / denominator;

/// 受付状況の集計対象か(受付・参加証の条件と同じ: 有効な参加者で、取込回が確定済みまたは取込回なし)。
bool isReceptionTarget(AttendanceReportParticipant p) =>
    p.status == 'active' && p.batchCommitted != false;

const noSlotLabel = '時間未設定';

/// 時間帯の表示から開始時刻(分)を読む(「10:30-11:10」「10時30分～」等)。読めなければnull。
int? slotStartMinutes(String label) {
  final m = RegExp(r'(\d{1,2})\s*[:：時]\s*(\d{1,2})').firstMatch(label);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 47 || min > 59) return null;
  return h * 60 + min;
}

int _compareSlots(String a, String b) {
  if (a == b) return 0;
  if (a == noSlotLabel) return 1;
  if (b == noSlotLabel) return -1;
  final ma = slotStartMinutes(a);
  final mb = slotStartMinutes(b);
  if (ma != null && mb != null && ma != mb) return ma - mb;
  if (ma != null && mb == null) return -1;
  if (ma == null && mb != null) return 1;
  return a.compareTo(b);
}

ReceptionStatus buildReceptionStatus(AttendanceReport report) {
  final programIndex = <String, int>{
    for (final (i, p) in report.programs.indexed) p.programId: i,
  };
  final rows = <ReceptionStatusRow>[];
  var applications = 0;
  var checkedInApplications = 0;
  for (final p in report.participants) {
    if (!isReceptionTarget(p) || p.programs.isEmpty) continue;
    applications += 1;
    if (p.programs.any((e) => e.checkedIn)) checkedInApplications += 1;
    final entries = [...p.programs]
      ..sort(
        (a, b) => (programIndex[a.programId] ?? 1 << 30).compareTo(
          programIndex[b.programId] ?? 1 << 30,
        ),
      );
    for (final e in entries) {
      final index = programIndex[e.programId];
      final time = e.timeText?.trim();
      rows.add(
        ReceptionStatusRow(
          participantId: p.participantId,
          name: p.name,
          programId: e.programId,
          // 応答のprogramsに無いprogramId(通常は起きない)は、programIdをそのまま名前にする
          programName: index == null
              ? e.programId
              : report.programs[index].name,
          programIndex: index ?? report.programs.length,
          order: rows.length,
          timeText: time == null || time.isEmpty ? null : time,
          plannedCount: e.plannedCount,
          checkedIn: e.checkedIn,
          attendedCount: e.checkedIn ? e.attendedCount : null,
          checkedInAt: e.checkedIn ? e.checkedInAt : null,
        ),
      );
    }
  }

  final programs = <ReceptionProgramStatus>[];
  final known = [
    for (final p in report.programs) (p.programId, p.name, p.inEvent),
    for (final id in {
      for (final r in rows)
        if (!programIndex.containsKey(r.programId)) r.programId,
    })
      (id, id, false),
  ];
  for (final (programId, name, inEvent) in known) {
    final ofProgram = rows.where((r) => r.programId == programId).toList();
    final bySlot = <String, List<ReceptionStatusRow>>{};
    for (final r in ofProgram) {
      bySlot.putIfAbsent(r.timeText ?? noSlotLabel, () => []).add(r);
    }
    final labels = bySlot.keys.toList()..sort(_compareSlots);
    programs.add(
      ReceptionProgramStatus(
        programId: programId,
        name: name,
        inEvent: inEvent,
        entries: ofProgram.length,
        checkedInEntries: ofProgram.where((r) => r.checkedIn).length,
        plannedTotal: _sum(ofProgram.map((r) => r.plannedCount)),
        attendedTotal: _sum(ofProgram.map((r) => r.attendedCount)),
        slots: [
          for (final label in labels)
            ReceptionSlotStatus(
              label: label,
              entries: bySlot[label]!.length,
              checkedInEntries: bySlot[label]!.where((r) => r.checkedIn).length,
              plannedTotal: _sum(bySlot[label]!.map((r) => r.plannedCount)),
              attendedTotal: _sum(bySlot[label]!.map((r) => r.attendedCount)),
            ),
        ],
      ),
    );
  }

  return ReceptionStatus(
    totals: ReceptionTotals(
      applications: applications,
      plannedTotal: _sum(rows.map((r) => r.plannedCount)),
      checkedInApplications: checkedInApplications,
      attendedTotal: _sum(rows.map((r) => r.attendedCount)),
    ),
    programs: programs,
    rows: rows,
  );
}

int _sum(Iterable<int?> values) =>
    values.fold(0, (total, v) => total + (v ?? 0));

// ---- 一覧の検索・絞り込み・並べ替え ----------------------------------------------------------------

enum ReceptionStateFilter {
  all('すべて'),
  checkedIn('受付済み'),
  notCheckedIn('未受付');

  const ReceptionStateFilter(this.label);
  final String label;
}

enum ReceptionSort {
  standard('既定の順'),
  checkedInAtDesc('受付時刻(新しい順)'),
  checkedInAtAsc('受付時刻(古い順)');

  const ReceptionSort(this.label);
  final String label;
}

String _normalizeName(String value) =>
    value.replaceAll(RegExp(r'[\s　]'), '').toLowerCase();

/// 氏名(空白を無視した部分一致)・program・受付状態で絞り込み、並べ替える。
/// 受付時刻の並べ替えでは、未受付の行は常に末尾(既定の順のまま)。
List<ReceptionStatusRow> filterReceptionRows(
  List<ReceptionStatusRow> rows, {
  String query = '',
  String? programId,
  ReceptionStateFilter state = ReceptionStateFilter.all,
  ReceptionSort sort = ReceptionSort.standard,
}) {
  final q = _normalizeName(query);
  final result = rows.where((r) {
    if (programId != null && r.programId != programId) return false;
    if (state == ReceptionStateFilter.checkedIn && !r.checkedIn) return false;
    if (state == ReceptionStateFilter.notCheckedIn && r.checkedIn) return false;
    if (q.isNotEmpty && !_normalizeName(r.name).contains(q)) return false;
    return true;
  }).toList();
  if (sort == ReceptionSort.standard) return result;
  final descending = sort == ReceptionSort.checkedInAtDesc;
  result.sort((a, b) {
    final x = a.checkedInAt;
    final y = b.checkedInAt;
    if (x == null && y == null) return a.order - b.order;
    if (x == null) return 1;
    if (y == null) return -1;
    final c = descending ? y.compareTo(x) : x.compareTo(y);
    return c != 0 ? c : a.order - b.order;
  });
  return result;
}
