import 'dart:typed_data';

import '../services/participant_csv_export_service.dart'
    show safeExportFileName;
import 'attendance_report_service.dart';
import 'reception_status_summary.dart'
    show attendanceStateOf, isReceptionTarget, programEndAt, ReceptionAttendanceState;
import 'xlsx_writer.dart';

/// 最終実績(サーバーの[AttendanceReport])→ Excel(.xlsx)。1行 = 1 participant(同じメールアドレスでも統合しない)。
///
/// 列: 取込回 / 氏名 / かな / メールアドレス / HEBEL属性 / 参加者状態 / 通知種別、
///     programごと(イベントの表示順。program名はevent.programsから)に
///       参加予定 / 予定人数 / 予定時間 / 受付 / 実来場人数 / 受付時刻、
///     最後に イベント来場状況。
/// ■ 受付時刻は日本時間(Excelの日時の値。並べ替え・フィルターができる)。
/// ■ 取消済みのprogramは「未受付」(サーバーの正本で受付状態が戻っている)。人数は訂正後の最新の値。
/// ■ 「受付」列は 受付済 / 未受付 / 欠席。欠席の判定は受付状況一覧と同じ関数(reception_status_summary.dart)で、
///   判定時刻はデータ取得日時。終了時刻が確認できないprogramは欠席にしない(未受付)。
///   受付の対象外の参加者(有効でない・取込回が未確定)は、従来どおり 受付済 / 未受付 だけ(欠席と判定しない)。
/// ■ 2枚目のシート「出力情報」に、データ取得日時(日本時間)等を記録する(1枚目の明細表の列構成・フィルターは変えない)。
/// ■ 文字列はすべて文字列のセル(電話番号風・数字だけ・「=」始まりの値も、数値・数式にしない)。
class AttendanceReportFile {
  const AttendanceReportFile({
    required this.fileName,
    required this.bytes,
    required this.participantCount,
  });
  final String fileName;
  final Uint8List bytes;
  final int participantCount;
}

const attendanceReportSheetName = '最終実績';
const attendanceReportInfoSheetName = '出力情報';

/// 受付画面と同じ意味の表示値(サーバーの表示名を使う)。未知は原文を併記。属性フィールドの無い参加者は空欄。
String hebelCellOf(AttendanceReportParticipant p) {
  final label = p.hebelLabel;
  if (label == null || label.isEmpty) return '';
  final raw = p.hebelRawValue;
  if (p.hebelCategory == 'unknown' && raw != null && raw.isNotEmpty) {
    return '$label（原文：$raw）';
  }
  return label;
}

/// 参加者の状態: 有効 / 取込未完了(取込回が確定していない) / それ以外のstatusはそのまま。
String participantStateOf(AttendanceReportParticipant p) {
  if (p.batchCommitted == false) return '取込未完了';
  if (p.status == 'active') return '有効';
  return p.status.isEmpty ? '' : '無効（${p.status}）';
}

/// 通知種別の表示(項目の無い既存の取込回は通常当選)。
String notificationTypeCellOf(AttendanceReportParticipant p) =>
    p.notificationType == 'waitlistPromotion' ? 'キャンセル待ち繰り上げ当選' : '通常当選';

/// イベント来場状況: 1つでも受付済み → 受付あり / 申込programがあり受付なし → 未来場 / programなし → 空欄。
String eventAttendanceOf(AttendanceReportParticipant p) {
  if (p.programs.isEmpty) return '';
  return p.programs.any((e) => e.checkedIn) ? '受付あり' : '未来場';
}

const _jst = Duration(hours: 9);

/// 日本時間の年月日(yyyyMMdd)。
String _jstDate(DateTime at) {
  final d = at.toUtc().add(_jst);
  return '${d.year.toString().padLeft(4, '0')}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
}

String attendanceReportFileName(String eventName, DateTime exportedAt) =>
    'JM_Quick_${safeExportFileName(eventName)}_最終実績_${_jstDate(exportedAt)}.xlsx';

/// 列幅: 見出しの長さ(全角は2)と最小幅の大きい方。
double _widthFor(String header, double minimum) {
  var units = 0;
  for (final rune in header.runes) {
    units += rune < 0x100 ? 1 : 2;
  }
  final width = units + 2.0;
  return width < minimum ? minimum : (width > 60 ? 60 : width);
}

/// program列の見出しの名前。同じ名前のprogramが複数あれば、2つ目以降にprogramIdを添えて区別する。
List<String> _programNames(List<AttendanceReportProgram> programs) {
  final seen = <String>{};
  return [
    for (final p in programs)
      () {
        final base = p.inEvent ? p.name : '${p.name}（イベント設定に無いprogram）';
        final name = seen.add(base) ? base : '$base（${p.programId}）';
        seen.add(name);
        return name;
      }(),
  ];
}

/// 欠席の判定に使う時点・イベントの開始/終了(受付状況一覧と同じ入力)。
typedef AttendanceJudgement = ({
  DateTime? judgedAt,
  DateTime? eventStartAt,
  DateTime? eventEndAt,
});

/// 「受付」列の値。受付状況一覧と同じ判定(受付済 / 未受付 / 欠席)。受付の対象外の参加者は欠席と判定しない。
String receptionCellOf(
  AttendanceReportParticipant p,
  AttendanceReportEntry entry,
  AttendanceJudgement judgement,
) {
  if (entry.checkedIn) return '受付済';
  if (!isReceptionTarget(p)) return '未受付';
  final state = attendanceStateOf(
    checkedIn: false,
    endAt: programEndAt(
      timeText: entry.timeText?.trim(),
      eventStartAt: judgement.eventStartAt,
      eventEndAt: judgement.eventEndAt,
    ),
    judgedAt: judgement.judgedAt,
  );
  return state == ReceptionAttendanceState.absent ? '欠席' : '未受付';
}

/// 1つのprogramの6列: 参加予定 / 予定人数 / 予定時間 / 受付 / 実来場人数 / 受付時刻(日本時間)。
List<Object?> _programCells(
  AttendanceReportParticipant p,
  AttendanceReportProgram program,
  AttendanceJudgement judgement,
) {
  final entry = p.programs
      .where((e) => e.programId == program.programId)
      .firstOrNull;
  if (entry == null) return const ['なし', null, null, null, null, null];
  final at = entry.checkedIn ? entry.checkedInAt : null;
  return [
    'あり',
    entry.plannedCount,
    entry.timeText,
    receptionCellOf(p, entry, judgement),
    entry.checkedIn ? entry.attendedCount : null,
    at == null ? null : XlsxDateTime(at.toUtc().add(_jst)),
  ];
}

/// [exportedAt] はデータ取得日時(サーバーから明細を受け取った時刻)。欠席の判定時刻にも使い、出力情報シートに記録する。
/// [eventStartAt]・[eventEndAt]: イベントの開始(時間帯の日付)・終了(終了時刻の③)。無ければその方法では判定しない。
AttendanceReportFile buildAttendanceReportXlsx(
  AttendanceReport report, {
  required DateTime exportedAt,
  DateTime? eventStartAt,
  DateTime? eventEndAt,
}) {
  final AttendanceJudgement judgement = (
    judgedAt: exportedAt,
    eventStartAt: eventStartAt,
    eventEndAt: eventEndAt,
  );
  final names = _programNames(report.programs);
  final columns = <XlsxColumn>[
    (header: '取込回', width: 8),
    (header: '氏名', width: 18),
    (header: 'かな', width: 18),
    (header: 'メールアドレス', width: 32),
    (header: 'HEBEL属性', width: 40),
    (header: '参加者状態', width: 12),
    (header: '通知種別', width: 24),
    for (final name in names) ...[
      for (final (suffix, minimum) in const [
        ('参加予定', 10.0),
        ('予定人数', 10.0),
        ('予定時間', 14.0),
        ('受付', 10.0),
        ('実来場人数', 12.0),
        ('受付時刻', 20.0),
      ])
        (header: '$name：$suffix', width: _widthFor('$name：$suffix', minimum)),
    ],
    (header: 'イベント来場状況', width: 16),
  ];
  final rows = <List<Object?>>[
    for (final p in report.participants)
      [
        p.importSequence,
        p.name,
        p.kana,
        p.email,
        hebelCellOf(p),
        participantStateOf(p),
        notificationTypeCellOf(p),
        for (final program in report.programs)
          ..._programCells(p, program, judgement),
        eventAttendanceOf(p),
      ],
  ];
  return AttendanceReportFile(
    fileName: attendanceReportFileName(report.eventName, exportedAt),
    bytes: buildXlsx(
      sheetName: attendanceReportSheetName,
      columns: columns,
      rows: rows,
      infoSheet: (
        name: attendanceReportInfoSheetName,
        columns: const [(header: '項目', width: 22), (header: '値', width: 60)],
        rows: [
          ['イベント名', report.eventName],
          ['イベントID', report.eventId],
          ['データ取得日時（日本時間）', XlsxDateTime(exportedAt.toUtc().add(_jst))],
          ['参加者数', report.participants.length],
          [
            '「受付」列の欠席',
            '受付が無いまま、プログラムの終了時刻(時間帯、無ければイベント終了日時)を、データ取得日時の時点で過ぎたもの。'
                '終了時刻が確認できないプログラムと、受付の対象外の参加者は「未受付」。',
          ],
        ],
      ),
    ),
    participantCount: report.participants.length,
  );
}
