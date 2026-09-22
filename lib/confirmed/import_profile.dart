import 'import_models.dart';

/// 「今年度の当選・参加確定者CSV」の正式フォーマット向けの取込profile(Phase 11B-4)。
///
/// ■ 目的: 通常運用ではCSVの列を利用者(admin)に選ばせない。programIdとCSV列名の対応は、
///   このファイルの中だけにまとめておき、[buildMappingFromProfile] が [ImportMapping]
///   (サーバー functions/confirmed/import_mapping.js と同じ構造)を自動的に組み立てる。
/// ■ 「program-1という文字列なら必ず午前」という判定を、このファイル以外のコード(画面・request組み立て・
///   サーバー)へハードコードしない。下の [sipposample2026Profile] はあくまで「今回のイベント(programId:
///   program-1/2/3)」向けの1つのprofile(データ)であり、別のイベント・別のCSV形式を使うときは、
///   別の[ConfirmedImportProfile]を用意して[currentConfirmedImportProfile]を差し替える
///   (現時点では利用者向けのprofile編集・切替UIは無い。複数profileが必要になれば、
///   イベントIDなどで選ぶ仕組みをこのファイルへ追加する)。
/// ■ 参加/不参加の判定・plannedCountの扱いは、サーバー(functions/confirmed/import_rows.js の
///   decideParticipation)の既存ロジックをそのまま使う。サーバー・Rulesは変更していない。
class ConfirmedImportProfile {
  const ConfirmedImportProfile({
    required this.label,
    required this.nameColumn,
    required this.kanaColumn,
    required this.emailColumn,
    this.registeredAtColumn,
    required this.programs,
  });

  /// 管理画面に表示する名前(この形式の呼び名)。
  final String label;
  final String nameColumn;
  final String kanaColumn;
  final String emailColumn;
  final String? registeredAtColumn;
  final List<ConfirmedImportProfileProgram> programs;

  /// このprofileが実際に読む、すべてのCSV列名(重複なし)。
  List<String> get requiredHeaders {
    final headers = <String>{nameColumn, kanaColumn, emailColumn};
    if (registeredAtColumn != null) headers.add(registeredAtColumn!);
    for (final p in programs) {
      headers.addAll(p.requiredHeaders);
    }
    return headers.toList();
  }

  /// CSVのheader一覧に対して、このprofileが必要とする列がすべて揃っているか確認する。
  /// 欠けている列名の一覧を返す(空なら一致=対応しているフォーマット)。列順は問わない。
  List<String> missingHeaders(List<String> csvHeaders) {
    final present = csvHeaders.map((h) => h.trim()).toSet();
    final missing = requiredHeaders.where((h) => !present.contains(h)).toList()
      ..sort();
    return missing;
  }
}

/// profile内、program1つ分の列の対応。
class ConfirmedImportProfileProgram {
  const ConfirmedImportProfileProgram({
    required this.programId,
    required this.countColumn,
    this.slotColumn,
    this.slotFormat = 'timeRange',
    this.participationColumn,
    this.attendingValues,
    this.notAttendingValues,
    this.emptyMeansNotAttending = false,
  });

  /// このprofileが対象とするイベントで、実際に(event.programsに)定義されているprogramId。
  final String programId;
  final String countColumn;
  final String? slotColumn;
  final String slotFormat;
  final String? participationColumn;
  final List<String>? attendingValues;
  final List<String>? notAttendingValues;
  final bool emptyMeansNotAttending;

  List<String> get requiredHeaders => {
    countColumn,
    if (slotColumn != null) slotColumn!,
    if (participationColumn != null) participationColumn!,
  }.toList();
}

/// 今回(2026年度)の当選・参加確定者CSV(実CSVで確認した90行・28列の形式)向けprofile。
///
/// 実CSVから確認した実際の列名をそのまま使う: 氏名・かな・メールアドレス・登録日時、
/// 午前参加時間/午前参加人数(program-1=午前の譲渡会)、午後参加時間/午後参加人数(program-2=午後の譲渡会)、
/// トークショー/トークショー人数(program-3=トークショー)。
///
/// 区分・rd(参照コード)・都道府県・性別・年代・午前相談・午後相談・キャンセル待希望枠・
/// キャンセル待希望人数・備考、その他の列は読み込まない(このCSVに存在しても取込を妨げない)。
/// - rd(参照コード)は、既存のparticipant.sourceReferenceに任意で入れられる項目だが、今回ご指定の
///   正式対応の一覧には含まれていないため、このprofileでは取り込まない。
/// - 備考は、現在のparticipant/programAttendanceスキーマに対応する保存先が無いため、今回は取り込まない
///   (新しいフィールドを追加していない)。
///
/// 参加判定:
/// - program-1・program-2: 参加時間の列(午前/午後参加時間)を参加列としても使う。「参加を希望しない」
///   または空は不参加、それ以外(有効な時間枠文字列を含む)は参加とみなす。plannedCountは対応する人数列。
///   時間枠は既存のprogramAttendance.slotLabel(・timeRange形式ならstartAt/endAt)として保存される
///   (新しいフィールドは追加していない)。
/// - program-3(トークショー): 「トークショー」列が「参加を希望する」なら参加、「参加を希望しない」または
///   空なら不参加。plannedCountはトークショー人数。
const sipposample2026Profile = ConfirmedImportProfile(
  label: '当選・参加確定者リスト(sipposample形式)',
  nameColumn: '氏名',
  kanaColumn: 'かな',
  emailColumn: 'メールアドレス',
  registeredAtColumn: '登録日時',
  programs: [
    ConfirmedImportProfileProgram(
      programId: 'program-1',
      countColumn: '午前参加人数',
      slotColumn: '午前参加時間',
      slotFormat: 'timeRange',
      participationColumn: '午前参加時間',
      notAttendingValues: ['参加を希望しない'],
      emptyMeansNotAttending: true,
    ),
    ConfirmedImportProfileProgram(
      programId: 'program-2',
      countColumn: '午後参加人数',
      slotColumn: '午後参加時間',
      slotFormat: 'timeRange',
      participationColumn: '午後参加時間',
      notAttendingValues: ['参加を希望しない'],
      emptyMeansNotAttending: true,
    ),
    ConfirmedImportProfileProgram(
      programId: 'program-3',
      countColumn: 'トークショー人数',
      participationColumn: 'トークショー',
      attendingValues: ['参加を希望する'],
      notAttendingValues: ['参加を希望しない'],
      emptyMeansNotAttending: true,
    ),
  ],
);

/// 現在の通常運用で使うprofile。将来、別イベント・別CSV形式が増えたら、選べるようにこの参照先を差し替える。
const ConfirmedImportProfile currentConfirmedImportProfile = sipposample2026Profile;

/// event.programsとprofileを突き合わせ、profileが想定するprogramIdのうちイベントに無いものの一覧を返す
/// (空なら一致)。
List<String> missingProfileProgramsInEvent(
  ConfirmedImportProfile profile,
  List<({String programId, String name, int order})> eventPrograms,
) {
  final ids = eventPrograms.map((p) => p.programId).toSet();
  return [
    for (final p in profile.programs)
      if (!ids.contains(p.programId)) p.programId,
  ];
}

/// profileとイベントのprogram一覧から、サーバーへ送る[ImportMapping]を自動的に組み立てる。
/// 利用者はCSVの列を一切選ばない。呼び出す前に[missingProfileProgramsInEvent]が空であることを確認すること。
ImportMapping buildMappingFromProfile(
  ConfirmedImportProfile profile,
  List<({String programId, String name, int order})> eventPrograms,
) {
  final nameById = {for (final p in eventPrograms) p.programId: p.name};
  final mapping = ImportMapping(
    programs: [
      for (final pp in profile.programs)
        ProgramMapping(
            programId: pp.programId,
            name: nameById[pp.programId] ?? pp.programId,
          )
          ..countColumn = pp.countColumn
          ..slotColumn = pp.slotColumn
          ..slotFormat = pp.slotFormat
          ..participationColumn = pp.participationColumn
          ..attendingValues = List.of(pp.attendingValues ?? const [])
          ..notAttendingValues = List.of(pp.notAttendingValues ?? const [])
          ..emptyMeansNotAttending = pp.emptyMeansNotAttending,
    ],
  )
    ..nameColumn = profile.nameColumn
    ..kanaColumn = profile.kanaColumn
    ..emailColumn = profile.emailColumn
    ..registeredAtColumn = profile.registeredAtColumn;
  return mapping;
}

/// 全角数字・全角スペースを含むことがある人数のセル値を、画面表示用に概算する。
/// (サーバー functions/confirmed/import_rows.js の parseCount と同じ規則の簡易版。
///  実際の判定・保存は必ずサーバー側のparseCountが行う。ここでの結果は「program別予定」の目安表示にのみ使う。)
int? displayCountOf(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 0;
  const zenkaku = '０１２３４５６７８９';
  const hankaku = '0123456789';
  final buffer = StringBuffer();
  for (final rune in trimmed.runes) {
    final ch = String.fromCharCode(rune);
    final zIndex = zenkaku.indexOf(ch);
    buffer.write(zIndex >= 0 ? hankaku[zIndex] : ch);
  }
  final normalized = buffer.toString().trim();
  final match = RegExp(r'^(\d+)\s*(?:名|人)?$').firstMatch(normalized);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
