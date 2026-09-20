import 'package:cloud_firestore/cloud_firestore.dart';

// 新方式(event.flow == 'confirmed')のprogramと、participant×programの参加記録。
//
// 人数の正本は ProgramAttendance.plannedCount(Firestore: programAttendances/{participantId}_{programId})
// だけである。このファイルおよび新方式のコード全般は、旧参加者ドキュメントの人数フィールドを
// 参照してはならない(test/confirmed_flow_test.dart がソースを走査して検査する)。
//
// 検証規則とエラーコードは functions/programs.js と同一で、
// functions/test/fixtures/program_cases.json を両側のテストが共有して一致を保つ。

/// programIdは英小文字・数字・ハイフンのslug(1〜40文字、先頭末尾はハイフン不可)。
/// "/" や "_" を許さないため、Firestoreの文書パスを壊さず、文書IDの区切り("_")とも衝突しない。
final RegExp _programIdPattern = RegExp(
  r'^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$',
);

/// participantIdはFirestoreの自動ID(英数字)を想定。"_" は許さない。
final RegExp _participantIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');

/// plannedCountの上限。入力ミス(桁違いなど)を防ぐための運用上の上限。
const int maxPlannedCount = 999;

const int _maxNameLength = 100;
const int _maxNoteLength = 500;
const int _maxSlotLabelLength = 60;

bool isValidProgramId(Object? value) =>
    value is String && _programIdPattern.hasMatch(value);

bool isValidParticipantId(Object? value) =>
    value is String && _participantIdPattern.hasMatch(value);

/// 0は「参加しない」を意味するため不正。参加しないprogramのattendanceは作らない。
bool isValidPlannedCount(Object? value) =>
    value is int && value >= 1 && value <= maxPlannedCount;

/// programAttendancesの文書ID。participantIdとprogramIdから決定的に生成される。
/// どちらかが不正なら ArgumentError(不正なIDで文書パスを組み立てない)。
String programAttendanceId(String participantId, String programId) {
  if (!isValidParticipantId(participantId)) {
    throw ArgumentError.value(participantId, 'participantId', 'invalid');
  }
  if (!isValidProgramId(programId)) {
    throw ArgumentError.value(programId, 'programId', 'invalid');
  }
  return '${participantId}_$programId';
}

/// 文書IDを(participantId, programId)へ戻す。正規の形でなければnull。
({String participantId, String programId})? parseProgramAttendanceId(
  String id,
) {
  final parts = id.split('_');
  if (parts.length != 2) return null;
  if (!isValidParticipantId(parts[0]) || !isValidProgramId(parts[1])) {
    return null;
  }
  return (participantId: parts[0], programId: parts[1]);
}

DateTime? _toDate(Object? value) => value is Timestamp
    ? value.toDate()
    : value is DateTime
    ? value
    : null;

bool _timeRangeInvalid(Object? startAt, Object? endAt) {
  final start = _toDate(startAt);
  final end = _toDate(endAt);
  return start != null && end != null && !end.isAfter(start);
}

bool _isBlank(Object? value) => value is! String || value.trim().isEmpty;

/// イベントに設定するprogram(例: 譲渡会(ねこ)、トークセッション)の定義。
/// startAt/endAtはprogram共通の時間。参加者ごとの時間枠は ProgramAttendance 側で上書きする。
class EventProgram {
  const EventProgram({
    required this.programId,
    required this.name,
    this.order = 0,
    this.startAt,
    this.endAt,
    this.note,
  });

  final String programId;
  final String name;
  final int order;
  final DateTime? startAt;
  final DateTime? endAt;
  final String? note;

  /// 検証エラーのコード一覧(空なら有効)。順序は固定。
  List<String> validate() => validateData({
    'programId': programId,
    'name': name,
    'order': order,
    'startAt': startAt,
    'endAt': endAt,
    'note': note,
  });

  /// 生のMapの検証(functions/programs.js の validateProgram と同じ規則)。
  static List<String> validateData(Map<String, dynamic> data) {
    final errors = <String>[];
    if (!isValidProgramId(data['programId'])) errors.add('programId');
    final name = data['name'];
    if (_isBlank(name) || (name as String).trim().length > _maxNameLength) {
      errors.add('name');
    }
    final order = data['order'];
    if (order != null && !(order is int && order >= 0)) errors.add('order');
    if (_timeRangeInvalid(data['startAt'], data['endAt'])) {
      errors.add('timeRange');
    }
    final note = data['note'];
    if (note != null && (note is! String || note.length > _maxNoteLength)) {
      errors.add('note');
    }
    return errors;
  }

  /// 検証つきの生成。不正なら ArgumentError(エラーコードを含む)。
  factory EventProgram.create({
    required String programId,
    required String name,
    int order = 0,
    DateTime? startAt,
    DateTime? endAt,
    String? note,
  }) {
    final program = EventProgram(
      programId: programId,
      name: name.trim(),
      order: order,
      startAt: startAt,
      endAt: endAt,
      note: note,
    );
    final errors = program.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError('invalid program: ${errors.join(',')}');
    }
    return program;
  }

  Map<String, dynamic> toMap() => {
    'programId': programId,
    'name': name,
    'order': order,
    if (startAt != null) 'startAt': Timestamp.fromDate(startAt!),
    if (endAt != null) 'endAt': Timestamp.fromDate(endAt!),
    if (note != null && note!.isNotEmpty) 'note': note,
  };

  /// 読み取り用の寛容なパース。不正な形なら null(読み取り側で落とさない)。
  static EventProgram? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final data = Map<String, dynamic>.from(raw);
    final order = data['order'];
    final normalized = {
      ...data,
      'order': order is num && order == order.toInt() ? order.toInt() : order,
      'startAt': _toDate(data['startAt']),
      'endAt': _toDate(data['endAt']),
    };
    if (validateData(normalized).isNotEmpty) return null;
    return EventProgram(
      programId: normalized['programId'] as String,
      name: (normalized['name'] as String).trim(),
      order: (normalized['order'] as int?) ?? 0,
      startAt: normalized['startAt'] as DateTime?,
      endAt: normalized['endAt'] as DateTime?,
      note: normalized['note'] as String?,
    );
  }

  /// イベント文書のprograms配列を読む。未設定・不正な要素・重複programIdは無視し、
  /// order→programIdの順に並べる。未設定なら空配列(旧イベントはprogramsを持たない)。
  static List<EventProgram> listFromData(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    final programs = <EventProgram>[];
    for (final item in raw) {
      final program = tryFromMap(item);
      if (program != null && seen.add(program.programId)) programs.add(program);
    }
    programs.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.programId.compareTo(b.programId);
    });
    return List.unmodifiable(programs);
  }
}

/// participant×program の参加記録(programAttendances/{participantId}_{programId})。
/// 「参加しないprogram」のドキュメントは作らない(plannedCountは常に1以上)。
/// plannedCountがプログラム別参加予定人数の唯一の正本。
class ProgramAttendance {
  const ProgramAttendance({
    required this.eventId,
    required this.participantId,
    required this.programId,
    required this.plannedCount,
    this.slotLabel,
    this.startAt,
    this.endAt,
    this.checkedIn = false,
    this.checkedInAt,
    this.attendedCount,
    this.checkedInBy,
    this.updatedAt,
  });

  final String eventId;
  final String participantId;
  final String programId;
  final int plannedCount;

  /// この参加者だけの時間枠表示(例: "10:00枠")。未設定ならprogramの時間を使う。
  final String? slotLabel;
  final DateTime? startAt;
  final DateTime? endAt;
  final bool checkedIn;
  final DateTime? checkedInAt;
  final int? attendedCount;
  final String? checkedInBy;
  final DateTime? updatedAt;

  /// 決定的な文書ID。participantId/programIdが不正なら ArgumentError。
  String get id => programAttendanceId(participantId, programId);

  List<String> validate() => validateData({
    'eventId': eventId,
    'participantId': participantId,
    'programId': programId,
    'plannedCount': plannedCount,
    'slotLabel': slotLabel,
    'startAt': startAt,
    'endAt': endAt,
    'checkedIn': checkedIn,
    'attendedCount': attendedCount,
  });

  /// 生のMapの検証(functions/programs.js の validateProgramAttendance と同じ規則)。
  static List<String> validateData(Map<String, dynamic> data) {
    final errors = <String>[];
    if (_isBlank(data['eventId'])) errors.add('eventId');
    if (!isValidParticipantId(data['participantId'])) {
      errors.add('participantId');
    }
    if (!isValidProgramId(data['programId'])) errors.add('programId');
    if (!isValidPlannedCount(data['plannedCount'])) errors.add('plannedCount');
    final slotLabel = data['slotLabel'];
    if (slotLabel != null &&
        (_isBlank(slotLabel) ||
            (slotLabel as String).length > _maxSlotLabelLength)) {
      errors.add('slotLabel');
    }
    if (_timeRangeInvalid(data['startAt'], data['endAt'])) {
      errors.add('timeRange');
    }
    final attended = data['attendedCount'];
    final attendedPresent = attended != null;
    if ((attendedPresent && !(attended is int && attended >= 0)) ||
        (data['checkedIn'] == true && !attendedPresent)) {
      errors.add('attendedCount');
    }
    return errors;
  }

  /// 検証つきの新規(未受付)作成。不正なら ArgumentError(エラーコードを含む)。
  factory ProgramAttendance.create({
    required String eventId,
    required String participantId,
    required String programId,
    required int plannedCount,
    String? slotLabel,
    DateTime? startAt,
    DateTime? endAt,
  }) {
    final attendance = ProgramAttendance(
      eventId: eventId,
      participantId: participantId,
      programId: programId,
      plannedCount: plannedCount,
      slotLabel: slotLabel,
      startAt: startAt,
      endAt: endAt,
    );
    final errors = attendance.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError('invalid programAttendance: ${errors.join(',')}');
    }
    return attendance;
  }

  /// Firestoreへ書くMap(受付前の初期状態を含む)。
  /// updatedAtにはサーバータイムスタンプ等を呼び出し側から渡す(このモデルはFirestoreへ接続しない)。
  Map<String, dynamic> toMap({Object? updatedAtValue}) => {
    'eventId': eventId,
    'participantId': participantId,
    'programId': programId,
    'plannedCount': plannedCount,
    'slotLabel': slotLabel,
    'startAt': startAt == null ? null : Timestamp.fromDate(startAt!),
    'endAt': endAt == null ? null : Timestamp.fromDate(endAt!),
    'checkedIn': checkedIn,
    'checkedInAt': checkedInAt == null
        ? null
        : Timestamp.fromDate(checkedInAt!),
    'attendedCount': attendedCount,
    'checkedInBy': checkedInBy,
    'updatedAt':
        updatedAtValue ??
        (updatedAt == null ? null : Timestamp.fromDate(updatedAt!)),
  };

  /// 読み取り用の寛容なパース(不正値は落とさず検証側で検出する)。
  factory ProgramAttendance.fromData(Map<String, dynamic> data) {
    int? intOf(Object? value) => value is num ? value.toInt() : null;
    return ProgramAttendance(
      eventId: data['eventId'] as String? ?? '',
      participantId: data['participantId'] as String? ?? '',
      programId: data['programId'] as String? ?? '',
      plannedCount: intOf(data['plannedCount']) ?? 0,
      slotLabel: data['slotLabel'] as String?,
      startAt: _toDate(data['startAt']),
      endAt: _toDate(data['endAt']),
      checkedIn: data['checkedIn'] as bool? ?? false,
      checkedInAt: _toDate(data['checkedInAt']),
      attendedCount: intOf(data['attendedCount']),
      checkedInBy: data['checkedInBy'] as String?,
      updatedAt: _toDate(data['updatedAt']),
    );
  }

  factory ProgramAttendance.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) => ProgramAttendance.fromData(doc.data() ?? {});
}
