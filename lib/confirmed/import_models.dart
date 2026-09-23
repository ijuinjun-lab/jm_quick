import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:csv/csv.dart';

/// 新方式(confirmed)の当選者CSV取込の、クライアント側のモデル。
/// サーバー(previewConfirmedImport / commitConfirmedImport)の契約(functions/confirmed/import_request.js・import_mapping.js)が正本で、
/// ここでは(1) CSVの読み込み (2) 列の対応(mapping) (3) サーバーへ送るリクエストの組み立て、だけを行う。
/// 列名の推測・人物の同一性(メール・氏名による統合)・publicIdの生成は一切しない(サーバーが決める)。

/// サーバーの上限(import_request.js)と同じ値。UI側がサーバーより緩い値を許可しない。
const int importMaxRows = 5000;
const int importMaxHeaders = 60;
const int importMaxValueLength = 2000;
const int importMaxFileNameLength = 255;

class CsvParseException implements Exception {
  const CsvParseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 読み込んだCSV。headersは先頭行(前後の空白を除いた列名)、recordsはデータ行(元のセル値のまま)。
class CsvTable {
  const CsvTable({required this.headers, required this.records});
  final List<String> headers;
  final List<List<String>> records;
}

/// UTF-8(BOMあり・なし)のCSVを読み込む。それ以外の文字コード(Shift_JIS等)は対応していない(サーバーAPIも文字コードを扱わない)。
CsvTable parseCsvBytes(Uint8List bytes) {
  var data = bytes;
  if (data.length >= 3 &&
      data[0] == 0xEF &&
      data[1] == 0xBB &&
      data[2] == 0xBF) {
    data = Uint8List.sublistView(data, 3);
  }
  final String text;
  try {
    text = utf8.decode(data);
  } on FormatException {
    throw const CsvParseException(
      'このファイルはUTF-8ではないため読み込めません。CSVをUTF-8(BOMあり・なし)で保存し直してください。',
    );
  }
  if (text.trim().isEmpty) throw const CsvParseException('CSVが空です。');
  // 改行コードは、ファイルに現れるもの(CRLF・LF・CR)に合わせる(csvパッケージは既定でCRLFしか行の区切りにしないため)
  final eol = text.contains('\r\n')
      ? '\r\n'
      : (text.contains('\n') ? '\n' : '\r');
  final List<List<dynamic>> rows;
  try {
    rows = CsvToListConverter(
      shouldParseNumbers: false,
      eol: eol,
    ).convert(text);
  } catch (_) {
    throw const CsvParseException('CSVの形式を読み取れませんでした。');
  }
  final cells = [
    for (final row in rows) [for (final cell in row) cell?.toString() ?? ''],
  ];
  // 末尾の改行だけによる空の行は、レコードではない
  while (cells.length > 1 &&
      cells.last.length <= 1 &&
      (cells.last.isEmpty || cells.last.first.isEmpty) &&
      RegExp(r'[\r\n]\s*$').hasMatch(text)) {
    cells.removeLast();
    break;
  }
  if (cells.isEmpty) throw const CsvParseException('CSVが空です。');
  final headers = cells.first.map((h) => h.trim()).toList();
  if (headers.every((h) => h.isEmpty)) {
    throw const CsvParseException('先頭行(列名)が空です。');
  }
  final records = cells.sublist(1);
  if (records.length > importMaxRows) {
    throw const CsvParseException(
      'CSVの行数が上限($importMaxRows行)を超えています。ファイルを分けて取り込んでください。',
    );
  }
  return CsvTable(headers: headers, records: records);
}

String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

/// サーバー(import_request.js の canonical)と同じ、キー順を固定したJSON文字列。
String canonicalJson(Object? value) {
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

/// 取込の単位(batchId)。イベント・ファイルの内容(ハッシュ)・列の対応から決定的に決める(英数字31文字)。
/// - 同じ内容の再送(二重クリック・応答が届かなかった後の再操作・画面の再読み込み後の再選択)は同じbatchIdになり、
///   サーバーの冪等性(同じclientRequestIdの再送は既存の取込を返す/続きから完了する)がそのまま働く。参加者は二重に作られない。
/// - ファイル名は含めない(同名でも内容が違うことがあるため)。
String deriveBatchId({
  required String eventId,
  required String fileHash,
  required Map<String, dynamic> mappingJson,
}) {
  final digest = sha256.convert(
    utf8.encode('$eventId\n$fileHash\n${canonicalJson(mappingJson)}'),
  );
  return 'b${digest.toString().substring(0, 30)}';
}

class RowCheck {
  RowCheck({this.column, List<String>? allowedValues})
    : allowedValues = allowedValues ?? [];
  String? column;
  List<String> allowedValues;
}

/// program1つ分の列の対応。programIdは作成済みイベントの program(サーバーが返す)から選ぶ。
///
/// ■ Phase 11B-4から、通常運用ではこれらの値を利用者が選ばない(画面には出さない)。
///   [ConfirmedImportProfile](import_profile.dart)が、今年度の正式CSVフォーマットのheader名から
///   自動的に組み立てる(programIdとCSV列名を利用者に結び付けさせない)。
///   participationColumn / attendingValues / notAttendingValues / emptyMeans は、サーバー
///   (functions/confirmed/import_mapping.js・import_rows.js)の既存の分岐(参加/不参加を示す値で判定、
///   省略時は人数だけで判定)をそのまま使うために必要な値で、サーバー契約・検証ロジックは変更していない。
class ProgramMapping {
  ProgramMapping({required this.programId, required this.name});
  final String programId;
  final String name;
  bool enabled = true;
  String? countColumn;
  String? slotColumn;
  String slotFormat = 'label';
  String? participationColumn;
  List<String> attendingValues = [];
  List<String> notAttendingValues = [];
  bool emptyMeansNotAttending = false;

  /// 既定false(既存の安全チェックのまま): 不参加と判定した場合、人数列に値が残っていれば
  /// not-attending-count-presentとしてreviewに残す。trueを明示したときだけ、参加意思の列を正本として、
  /// 不参加と判定したprogramの人数列を無視する(サーバー functions/confirmed/import_rows.js の
  /// 既存の安全チェックは、これを明示しない限り変更しない)。
  bool ignoreCountWhenNotAttending = false;

  Map<String, dynamic> toJson() => {
    'programId': programId,
    if (participationColumn != null) 'participationColumn': participationColumn,
    if (attendingValues.isNotEmpty) 'attendingValues': attendingValues,
    if (notAttendingValues.isNotEmpty) 'notAttendingValues': notAttendingValues,
    if (emptyMeansNotAttending) 'emptyMeans': 'notAttending',
    if (slotColumn != null) 'slotColumn': slotColumn,
    if (slotColumn != null) 'slotFormat': slotFormat,
    'countColumn': countColumn,
    if (ignoreCountWhenNotAttending) 'ignoreCountWhenNotAttending': true,
  };
}

/// 列の対応(サーバーの mapping と同じ構造)。
class ImportMapping {
  ImportMapping({required this.programs});
  static const int version = 1;
  String? nameColumn;
  String? emailColumn;
  String? kanaColumn;
  String? externalIdColumn;
  String? registeredAtColumn;
  final List<RowCheck> rowChecks = [];
  final List<ProgramMapping> programs;

  List<ProgramMapping> get enabledPrograms =>
      programs.where((p) => p.enabled).toList();

  Map<String, dynamic> toJson() => {
    'version': version,
    'participant': {
      if (externalIdColumn != null) 'externalIdColumn': externalIdColumn,
      'nameColumn': nameColumn,
      if (kanaColumn != null) 'kanaColumn': kanaColumn,
      'emailColumn': emailColumn,
      if (registeredAtColumn != null) 'registeredAtColumn': registeredAtColumn,
    },
    if (rowChecks.any((c) => c.column != null && c.allowedValues.isNotEmpty))
      'rowChecks': [
        for (final c in rowChecks)
          if (c.column != null && c.allowedValues.isNotEmpty)
            {'column': c.column, 'allowedValues': c.allowedValues},
      ],
    'programs': [for (final p in enabledPrograms) p.toJson()],
  };

  /// マッピングが読む列(サーバーの mappedColumns と同じ順序・重複なし)。ここに無い列は送らない。
  List<String> mappedColumns() {
    final columns = <String>[];
    void add(String? value) {
      if (value != null &&
          value.trim().isNotEmpty &&
          !columns.contains(value.trim())) {
        columns.add(value.trim());
      }
    }

    add(externalIdColumn);
    add(nameColumn);
    add(kanaColumn);
    add(emailColumn);
    add(registeredAtColumn);
    for (final c in rowChecks) {
      if (c.column != null && c.allowedValues.isNotEmpty) add(c.column);
    }
    for (final p in enabledPrograms) {
      // サーバー(functions/confirmed/import_mapping.js の mappedColumns)と同じ順序
      // (participationColumn → slotColumn → countColumn)。同じ列名を複数回指定しても重複させない。
      add(p.participationColumn);
      add(p.slotColumn);
      add(p.countColumn);
    }
    return columns;
  }

  /// 画面で確認するための検査(サーバーの検査と同じ規則。最終的な判定はサーバー)。問題の一覧(空ならOK)。
  List<String> validate() {
    final issues = <String>[];
    if (nameColumn == null) issues.add('氏名の列を選択してください。');
    if (emailColumn == null) issues.add('メールアドレスの列を選択してください。');
    final participant = [
      nameColumn,
      emailColumn,
      kanaColumn,
      externalIdColumn,
      registeredAtColumn,
    ].whereType<String>().toList();
    if (participant.toSet().length != participant.length) {
      issues.add('参加者の項目(氏名・メールアドレス等)に、同じ列を重複して選ぶことはできません。');
    }
    if (enabledPrograms.isEmpty) issues.add('取り込むprogramを1つ以上選択してください。');
    for (final p in enabledPrograms) {
      final label = '「${p.name}」';
      if (p.countColumn == null) issues.add('$labelの人数の列を選択してください。');
    }
    for (final c in rowChecks) {
      if (c.column != null && c.allowedValues.isEmpty) {
        issues.add('行の確認の列「${c.column}」には、許可する値を入力してください。');
      }
    }
    return issues;
  }
}

/// サーバーへ送るリクエスト(previewとcommitで共通の本体)。preview成功時のこの内容をそのまま保持し、commitへ渡す。
class ImportRequest {
  const ImportRequest({
    required this.json,
    required this.fileName,
    required this.batchId,
    required this.totalRecords,
  });
  final Map<String, dynamic> json;
  final String fileName;
  final String batchId;
  final int totalRecords;
}

/// CSVとmappingから、サーバーへ送るリクエストを組み立てる。
/// mappingが読む列だけを送り(それ以外の列は送らない)、全項目が空のレコードはblankRecordNumbersに入れ、
/// 全レコード(2〜totalRecords+1)を過不足なく数える。人物の同一性は見ない(同じメール・氏名の行も別の行)。
ImportRequest buildImportRequest({
  required String eventId,
  required String fileName,
  required Uint8List fileBytes,
  required CsvTable table,
  required ImportMapping mapping,
}) {
  final columns = mapping.mappedColumns();
  if (columns.length > importMaxHeaders) {
    throw const CsvParseException('取り込む列が多すぎます。');
  }
  final indexes = <int>[];
  for (final column in columns) {
    final found = <int>[
      for (var i = 0; i < table.headers.length; i++)
        if (table.headers[i] == column) i,
    ];
    if (found.isEmpty) throw CsvParseException('列「$column」がCSVにありません。');
    if (found.length > 1) {
      throw CsvParseException('列「$column」と同じ名前の列がCSVに複数あるため、指定できません。');
    }
    indexes.add(found.single);
  }
  if (fileName.length > importMaxFileNameLength) {
    throw const CsvParseException('ファイル名が長すぎます。');
  }
  final rows = <Map<String, dynamic>>[];
  final blank = <int>[];
  for (var position = 0; position < table.records.length; position++) {
    final record = table.records[position];
    final rowNumber = position + 2;
    if (record.every((cell) => cell.trim().isEmpty)) {
      blank.add(rowNumber);
      continue;
    }
    // 値の個数が足りない行は、途中までの値だけを送る(サーバーが row-length-mismatch として確認対象にする)
    final values = <String>[];
    for (final index in indexes) {
      if (index >= record.length) break;
      final value = record[index];
      if (value.length > importMaxValueLength) {
        throw CsvParseException(
          '$rowNumber行目に、長すぎる値($importMaxValueLength文字超)があります。',
        );
      }
      values.add(value);
    }
    rows.add({'rowNumber': rowNumber, 'values': values});
  }
  final mappingJson = mapping.toJson();
  final fileHash = sha256Hex(fileBytes);
  final batchId = deriveBatchId(
    eventId: eventId,
    fileHash: fileHash,
    mappingJson: mappingJson,
  );
  return ImportRequest(
    fileName: fileName,
    batchId: batchId,
    totalRecords: table.records.length,
    json: {
      'eventId': eventId,
      'clientRequestId': batchId,
      'sourceFileName': fileName,
      'fileHash': fileHash,
      'mapping': mappingJson,
      'headers': columns,
      'rows': rows,
      'totalRecords': table.records.length,
      'blankRecordNumbers': blank,
    },
  );
}

/// 行の判定(サーバーの分類)。
enum RowClass {
  ready('ready', '取込対象'),
  review('review', '確認が必要'),
  error('error', 'エラー');

  const RowClass(this.value, this.label);
  final String value;
  final String label;
  static RowClass fromValue(Object? value) =>
      values.firstWhere((c) => c.value == value, orElse: () => RowClass.error);
}

class PreviewRow {
  const PreviewRow({
    required this.sourceRowNumber,
    required this.classification,
    required this.issueCodes,
    required this.programIds,
  });
  final int sourceRowNumber;
  final RowClass classification;
  final List<String> issueCodes;
  final List<String> programIds;
}

/// previewConfirmedImport の応答(サーバーが返す項目だけ。氏名・メール・publicId・人数は含まれない)。
class ImportPreview {
  const ImportPreview({
    required this.batchId,
    required this.totalRecords,
    required this.totalRows,
    required this.readyCount,
    required this.reviewCount,
    required this.errorCount,
    required this.blankRecordCount,
    required this.participantCandidateCount,
    required this.attendanceCandidateCount,
    required this.issueCounts,
    required this.sameFileBatches,
    required this.existingStatus,
    required this.existingSequence,
    required this.warningColumns,
    required this.rows,
  });

  factory ImportPreview.fromJson(Map<String, dynamic> json) {
    int number(String key) => (json[key] as num?)?.toInt() ?? 0;
    List<Map<String, dynamic>> maps(Object? value) => value is List
        ? [
            for (final item in value)
              if (item is Map) Map<String, dynamic>.from(item),
          ]
        : const [];
    final existing = json['existingBatch'] is Map
        ? Map<String, dynamic>.from(json['existingBatch'] as Map)
        : null;
    final counts = json['issueCounts'] is Map
        ? {
            for (final e in (json['issueCounts'] as Map).entries)
              e.key.toString(): (e.value as num?)?.toInt() ?? 0,
          }
        : <String, int>{};
    return ImportPreview(
      batchId: json['batchId'] as String? ?? '',
      totalRecords: number('totalRecords'),
      totalRows: number('totalRows'),
      readyCount: number('readyCount'),
      reviewCount: number('reviewCount'),
      errorCount: number('errorCount'),
      blankRecordCount: number('blankRecordCount'),
      participantCandidateCount: number('participantCandidateCount'),
      attendanceCandidateCount: number('attendanceCandidateCount'),
      issueCounts: counts,
      sameFileBatches: [
        for (final b in maps(json['sameFileBatches']))
          (
            sequence: (b['sequence'] as num?)?.toInt() ?? 0,
            status: b['status'] as String? ?? '',
          ),
      ],
      existingStatus: existing?['status'] as String?,
      existingSequence: (existing?['sequence'] as num?)?.toInt(),
      warningColumns: [
        for (final w in maps(json['mappingWarnings']))
          if (w['column'] is String) w['column'] as String,
      ],
      rows: [
        for (final r in maps(json['rows']))
          PreviewRow(
            sourceRowNumber: (r['sourceRowNumber'] as num?)?.toInt() ?? 0,
            classification: RowClass.fromValue(r['classification']),
            issueCodes: [
              for (final c
                  in (r['issueCodes'] is List
                      ? r['issueCodes'] as List
                      : const []))
                c.toString(),
            ],
            programIds: [
              for (final c
                  in (r['programIds'] is List
                      ? r['programIds'] as List
                      : const []))
                c.toString(),
            ],
          ),
      ],
    );
  }

  final String batchId;
  final int totalRecords;
  final int totalRows;
  final int readyCount;
  final int reviewCount;
  final int errorCount;
  final int blankRecordCount;
  final int participantCandidateCount;
  final int attendanceCandidateCount;
  final Map<String, int> issueCounts;
  final List<({int sequence, String status})> sameFileBatches;

  /// 同じ取込(batchId)が既にサーバーにある場合の状態(committing / committed / failed)。
  final String? existingStatus;
  final int? existingSequence;
  final List<String> warningColumns;
  final List<PreviewRow> rows;
}

/// commitConfirmedImport の応答(氏名・メール・publicIdは含まれない)。
class ImportResult {
  const ImportResult({
    required this.batchId,
    required this.status,
    required this.sequence,
    required this.label,
    required this.totalRows,
    required this.totalRecords,
    required this.createdCount,
    required this.reviewPendingCount,
    required this.errorCount,
    required this.excludedCount,
    required this.blankRecordCount,
    required this.idempotentReplay,
  });

  factory ImportResult.fromJson(Map<String, dynamic> json) {
    int number(String key) => (json[key] as num?)?.toInt() ?? 0;
    return ImportResult(
      batchId: json['batchId'] as String? ?? '',
      status: json['status'] as String? ?? '',
      sequence: number('sequence'),
      label: json['label'] as String? ?? '',
      totalRows: number('totalRows'),
      totalRecords: number('totalRecords'),
      createdCount: number('createdCount'),
      reviewPendingCount: number('reviewPendingCount'),
      errorCount: number('errorCount'),
      excludedCount: number('excludedByOperatorCount'),
      blankRecordCount: number('blankRecordCount'),
      idempotentReplay: json['idempotentReplay'] == true,
    );
  }

  final String batchId;
  final String status;
  final int sequence;
  final String label;
  final int totalRows;
  final int totalRecords;
  final int createdCount;
  final int reviewPendingCount;
  final int errorCount;
  final int excludedCount;
  final int blankRecordCount;
  final bool idempotentReplay;
  bool get committed => status == 'committed';
}

/// 取込先のイベント(getConfirmedEventSummary の応答。テンプレート等は含まれない)。
class ImportEventSummary {
  const ImportEventSummary({
    required this.eventId,
    required this.eventName,
    required this.startAt,
    required this.venue,
    required this.programs,
  });
  factory ImportEventSummary.fromJson(Map<String, dynamic> json) =>
      ImportEventSummary(
        eventId: json['eventId'] as String? ?? '',
        eventName: json['eventName'] as String? ?? '',
        startAt: DateTime.tryParse(json['startAt'] as String? ?? '')?.toLocal(),
        venue: json['venue'] as String? ?? '',
        programs: [
          for (final p
              in (json['programs'] is List
                  ? json['programs'] as List
                  : const []))
            if (p is Map && p['programId'] is String)
              (
                programId: p['programId'] as String,
                name: p['name'] as String? ?? '',
                order: (p['order'] as num?)?.toInt() ?? 0,
              ),
        ],
      );
  final String eventId;
  final String eventName;
  final DateTime? startAt;
  final String venue;
  final List<({String programId, String name, int order})> programs;
}

/// preview・commitの判定コード(サーバーの issueCodes)の表示名。未知のコードはそのまま表示する。
const Map<String, String> importIssueLabels = {
  'name-missing': '氏名が空です',
  'email-missing': 'メールアドレスが空です',
  'email-invalid': 'メールアドレスの形式が不正です',
  'count-invalid': '人数が不正です',
  'attending-count-missing': '参加なのに人数がありません',
  'not-attending-count-present': '不参加なのに人数が入っています',
  'participation-empty': '参加の列が空です',
  'participation-unknown': '参加の列に、指定していない値があります',
  'review-empty': '参加の列が空です(確認が必要)',
  'review-unknown': '参加の列に、指定していない値があります(確認が必要)',
  'row-check-failed': '行の確認(区分など)に合いません',
  'row-length-mismatch': '列の数がヘッダーと合いません',
  'slot-missing': '時間枠がありません',
  'slot-too-long': '時間枠の値が長すぎます',
  'no-program': '参加するprogramがありません',
  'attendance-invalid': '参加情報が不正です',
  'too-long': '値が長すぎます',
  'zero-length': '人数が0です',
  'registered-at-unparsed': '登録日時を解釈できませんでした',
  'column-missing': '指定した列がCSVにありません',
  'column-ambiguous': '指定した列名がCSVに複数あります',
  'internal-error': '内容を判定できませんでした',
};

String importIssueLabel(String code) => importIssueLabels[code] ?? code;
