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
/// ■ HEBEL属性は、この画面の表示・集計だけ3分類にまとめる([ReceptionHebelGroup])。保存されている分類・原文は変えず、
///   受付画面・最終実績Excel・取込の分類(hebel_residence.js の5分類)にも影響しない。
/// ■ 出欠(表示・集計時に判定する。Firestoreには保存しない・定期的な書込みもしない):
///     受付済み(出席) = checkedIn / 欠席 = 未受付のまま終了時刻を過ぎた / 未受付 = それ以外(終了前・終了時刻が不明)。
///   判定時刻は画面が最後にデータを取得した時刻(画面・絞り込み・CSVで同じ時点)。終了後に受付・取消された場合も、
///   次の取得で受付状態(正本)から判定し直す。終了時刻は [programEndAt] の優先順位で決め、決められなければ欠席にしない。

/// 出欠の表示状態。
enum ReceptionAttendanceState {
  attended('受付済み'),
  pending('未受付'),
  absent('欠席');

  const ReceptionAttendanceState(this.label);
  final String label;
}

const Duration _jstOffset = Duration(hours: 9);

/// 時間帯の表示(「14:10-14:50」「14時10分～14時50分」等)から、終了時刻(UTC)を求める。
/// 開催日([eventStartAt]の日本時間の日付)と組み合わせる。開始・終了とも読み取れ、終了>開始のときだけ返す
/// (日付をまたぐ時間帯・長さ0・読めない文字列・開催日が不明はnull=この方法では決めない)。
/// 時間帯の表示は、サーバーが programAttendances の slotLabel、無ければ startAt/endAt(日本時間)から作ったもの。
DateTime? slotEndAt(String? label, DateTime? eventStartAt) {
  if (label == null || eventStartAt == null) return null;
  final text = _nfkcLite(label).trim();
  final m = RegExp(
    r'^(\d{1,2})\s*(?::|時)\s*(\d{2})\s*分?\s*[-~〜–—−]\s*(\d{1,2})\s*(?::|時)\s*(\d{2})\s*分?$',
  ).firstMatch(text);
  if (m == null) return null;
  final [sh, sm, eh, em] = [for (var i = 1; i <= 4; i++) int.parse(m.group(i)!)];
  if (sh > 23 || eh > 23 || sm > 59 || em > 59) return null;
  if (eh * 60 + em <= sh * 60 + sm) return null;
  final day = eventStartAt.toUtc().add(_jstOffset);
  return DateTime.utc(day.year, day.month, day.day, eh, em).subtract(_jstOffset);
}

/// 全角の数字・コロン・チルダ・ハイフンを半角へ(時間帯の読み取り用。表示は変えない)。
String _nfkcLite(String value) => String.fromCharCodes([
  for (final c in value.runes)
    if (c >= 0xff10 && c <= 0xff19) c - 0xff10 + 0x30
    else if (c == 0xff1a) 0x3a
    else if (c == 0xff5e) 0x7e
    else if (c == 0xff0d) 0x2d
    else if (c == 0x3000) 0x20
    else c,
]);

/// programの終了時刻(UTC)。優先順位:
///   ① 受付記録の終了日時・② slotLabel(いずれも応答の時間帯の表示に反映されている。[slotEndAt]で正確に読めた場合)
///   ③ イベント全体の終了日時。どれも無ければnull(欠席と判定しない)。開催日の24:00等で補完しない。
DateTime? programEndAt({
  String? timeText,
  DateTime? eventStartAt,
  DateTime? eventEndAt,
}) => slotEndAt(timeText, eventStartAt) ?? eventEndAt?.toUtc();

/// 1つの受付記録の出欠。終了時刻ちょうどは未受付(過ぎてから欠席)。
ReceptionAttendanceState attendanceStateOf({
  required bool checkedIn,
  required DateTime? endAt,
  required DateTime? judgedAt,
}) {
  if (checkedIn) return ReceptionAttendanceState.attended;
  if (endAt != null && judgedAt != null && judgedAt.toUtc().isAfter(endAt)) {
    return ReceptionAttendanceState.absent;
  }
  return ReceptionAttendanceState.pending;
}

/// 主催者用受付状況一覧のHEBEL属性(3分類)。
///   hebelHaus → ヘーベルハウス居住(メゾンオーナー含む)、hebelMaison → ヘーベルメゾン居住、
///   それ以外(none・unset・unknown・HEBEL属性の無い参加者)→ 該当なし。
enum ReceptionHebelGroup {
  hebelHaus('ヘーベルハウス居住（メゾンオーナー含む）'),
  hebelMaison('ヘーベルメゾン居住'),
  none('該当なし');

  const ReceptionHebelGroup(this.label);
  final String label;

  /// 最終実績の応答の分類(participant.hebelResidence.category。属性なしはnull)→ 3分類。
  static ReceptionHebelGroup fromCategory(String? category) => switch (category) {
    'hebelHaus' => ReceptionHebelGroup.hebelHaus,
    'hebelMaison' => ReceptionHebelGroup.hebelMaison,
    _ => ReceptionHebelGroup.none,
  };
}

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
    required this.hebel,
    this.state = ReceptionAttendanceState.pending,
    this.endAt,
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

  /// 参加者のHEBEL属性(3分類。同じ参加者の行はすべて同じ)。
  final ReceptionHebelGroup hebel;
  final String? timeText;
  final int? plannedCount;

  /// 受付済み(取消済みはfalse)。
  final bool checkedIn;

  /// 実来場人数(受付済みのときだけ。訂正後の最新の値)。
  final int? attendedCount;

  /// 受付時刻(UTC。受付済みのときだけ)。
  final DateTime? checkedInAt;

  /// 出欠(判定時刻の時点)。
  final ReceptionAttendanceState state;

  /// 判定に使ったprogramの終了時刻(UTC。不明はnull)。
  final DateTime? endAt;
}

/// 全体の集計。申込件数は参加者単位、予定人数・実来場人数は延べ(program別の合計)。
class ReceptionTotals {
  const ReceptionTotals({
    required this.applications,
    required this.plannedTotal,
    required this.checkedInApplications,
    required this.attendedTotal,
    this.absentApplications = 0,
  });

  /// 申込件数(参加者単位。複数programでも1件)。
  final int applications;

  /// 予定人数(延べ)。
  final int plannedTotal;

  /// 受付済み申込件数(いずれかのprogramが受付済みの参加者)。
  final int checkedInApplications;

  /// 実来場人数(延べ)。
  final int attendedTotal;

  /// 未受付申込件数(受付の無い参加者。欠席を含む)。
  int get notCheckedInApplications => applications - checkedInApplications;

  /// 欠席申込件数(受付が無く、申し込んだ全programの終了時刻を過ぎた参加者。未受付申込件数の内数)。
  final int absentApplications;

  /// 受付率(%)= 受付済み申込件数 ÷ 申込件数 × 100。申込0件ならnull。
  double? get rate => ratePercent(checkedInApplications, applications);
}

/// HEBEL属性別の集計(参加者単位。複数programでも1件)。
class ReceptionHebelStatus {
  const ReceptionHebelStatus({
    required this.group,
    required this.applications,
    required this.checkedInApplications,
    this.absentApplications = 0,
  });

  final ReceptionHebelGroup group;

  /// 申込件数(参加者単位)。
  final int applications;

  /// 受付済み件数(いずれかのprogramが受付済みの参加者)。
  final int checkedInApplications;

  int get notCheckedInApplications => applications - checkedInApplications;

  /// 欠席件数(全体と同じ定義。未受付件数の内数)。
  final int absentApplications;

  /// 受付率(%)= 受付済み件数 ÷ 申込件数 × 100。申込0件ならnull。
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
    this.absentEntries = 0,
  });

  /// 時間帯の表示(時間の無い申込は「時間未設定」)。
  final String label;
  final int entries;
  final int checkedInEntries;
  final int plannedTotal;
  final int attendedTotal;

  /// 欠席の参加者×program件数。
  final int absentEntries;
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
    this.absentEntries = 0,
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

  /// 欠席の参加者×program件数(未受付件数の内数)。
  final int absentEntries;

  /// 受付率(%)= 受付済み件数 ÷ 対象件数 × 100(件数ベース。人数ベースではない)。対象0件ならnull。
  double? get rate => ratePercent(checkedInEntries, entries);
}

class ReceptionStatus {
  const ReceptionStatus({
    required this.totals,
    required this.hebelGroups,
    required this.programs,
    required this.rows,
  });

  final ReceptionTotals totals;

  /// HEBEL属性別(3分類を常にこの順で。0件の分類も含む)。申込件数の合計は全体の申込件数と一致する。
  final List<ReceptionHebelStatus> hebelGroups;
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

/// [judgedAt]: 欠席の判定時刻(画面が最後にデータを取得した時刻)。nullなら欠席と判定しない。
/// [eventStartAt]・[eventEndAt]: イベントの開始(時間帯の日付に使う)・終了(終了時刻の③)。
ReceptionStatus buildReceptionStatus(
  AttendanceReport report, {
  DateTime? judgedAt,
  DateTime? eventStartAt,
  DateTime? eventEndAt,
}) {
  final programIndex = <String, int>{
    for (final (i, p) in report.programs.indexed) p.programId: i,
  };
  final rows = <ReceptionStatusRow>[];
  var applications = 0;
  var checkedInApplications = 0;
  final hebelApplications = {for (final g in ReceptionHebelGroup.values) g: 0};
  final hebelCheckedIn = {for (final g in ReceptionHebelGroup.values) g: 0};
  var absentApplications = 0;
  final hebelAbsent = {for (final g in ReceptionHebelGroup.values) g: 0};
  for (final p in report.participants) {
    if (!isReceptionTarget(p) || p.programs.isEmpty) continue;
    final hebel = ReceptionHebelGroup.fromCategory(p.hebelCategory);
    final anyCheckedIn = p.programs.any((e) => e.checkedIn);
    applications += 1;
    hebelApplications[hebel] = hebelApplications[hebel]! + 1;
    if (anyCheckedIn) {
      checkedInApplications += 1;
      hebelCheckedIn[hebel] = hebelCheckedIn[hebel]! + 1;
    }
    final entries = [...p.programs]
      ..sort(
        (a, b) => (programIndex[a.programId] ?? 1 << 30).compareTo(
          programIndex[b.programId] ?? 1 << 30,
        ),
      );
    final firstRow = rows.length;
    for (final e in entries) {
      final index = programIndex[e.programId];
      final time = e.timeText?.trim();
      final endAt = programEndAt(timeText: time, eventStartAt: eventStartAt, eventEndAt: eventEndAt);
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
          hebel: hebel,
          state: attendanceStateOf(checkedIn: e.checkedIn, endAt: endAt, judgedAt: judgedAt),
          endAt: endAt,
          attendedCount: e.checkedIn ? e.attendedCount : null,
          checkedInAt: e.checkedIn ? e.checkedInAt : null,
        ),
      );
    }
    // 参加者単位の欠席: 受付が無く、申し込んだ全programが欠席(終了済み)
    if (rows.sublist(firstRow).every((r) => r.state == ReceptionAttendanceState.absent)) {
      absentApplications += 1;
      hebelAbsent[hebel] = hebelAbsent[hebel]! + 1;
    }
  }
  bool absent(ReceptionStatusRow r) => r.state == ReceptionAttendanceState.absent;

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
        absentEntries: ofProgram.where(absent).length,
        slots: [
          for (final label in labels)
            ReceptionSlotStatus(
              label: label,
              entries: bySlot[label]!.length,
              checkedInEntries: bySlot[label]!.where((r) => r.checkedIn).length,
              plannedTotal: _sum(bySlot[label]!.map((r) => r.plannedCount)),
              attendedTotal: _sum(bySlot[label]!.map((r) => r.attendedCount)),
              absentEntries: bySlot[label]!.where(absent).length,
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
      absentApplications: absentApplications,
    ),
    hebelGroups: [
      for (final g in ReceptionHebelGroup.values)
        ReceptionHebelStatus(
          group: g,
          applications: hebelApplications[g]!,
          checkedInApplications: hebelCheckedIn[g]!,
          absentApplications: hebelAbsent[g]!,
        ),
    ],
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
  notCheckedIn('未受付'),
  absent('欠席');

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

/// 氏名(空白を無視した部分一致)・program・受付状態・HEBEL属性で絞り込み(すべてAND)、並べ替える。
/// 受付時刻の並べ替えでは、未受付の行は常に末尾(既定の順のまま)。
List<ReceptionStatusRow> filterReceptionRows(
  List<ReceptionStatusRow> rows, {
  String query = '',
  String? programId,
  ReceptionStateFilter state = ReceptionStateFilter.all,
  ReceptionHebelGroup? hebel,
  ReceptionSort sort = ReceptionSort.standard,
}) {
  final q = _normalizeName(query);
  final result = rows.where((r) {
    if (programId != null && r.programId != programId) return false;
    if (state == ReceptionStateFilter.checkedIn && !r.checkedIn) return false;
    // 未受付 = 受付が無く、終了前(または終了時刻が不明)。欠席は含めない。
    if (state == ReceptionStateFilter.notCheckedIn && r.state != ReceptionAttendanceState.pending) return false;
    if (state == ReceptionStateFilter.absent && r.state != ReceptionAttendanceState.absent) return false;
    if (hebel != null && r.hebel != hebel) return false;
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
