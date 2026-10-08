import 'dart:typed_data';

import 'import_models.dart';
import 'import_profile.dart';
import 'xlsx_reader.dart';

/// 参加者ファイル(CSV / Excel)の入口。ここで形式ごとに読み取り、共通の表([CsvTable]: 列名の行 + データ行の文字列)
/// にそろえる。その後の列の対応(profile)・検証・対処・プレビュー・取込は、形式に関係なく同じ処理を使う
/// (Excel専用の取込の仕組みは作らない):
///
///   CSV  ─┐
///         ├→ 共通の表(CsvTable) → profile → 検証 → 対処 → プレビュー → 取込
///   XLSX ─┘
enum ImportFileFormat {
  csv('CSV（.csv）'),
  xlsx('Excel（.xlsx）');

  const ImportFileFormat(this.label);
  final String label;
}

/// ファイルを読めなかった(形式・内容の問題)。画面へそのまま表示できる文言。
class ImportFileException implements Exception {
  const ImportFileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 取込に使える表1つ(CSVはファイル全体、Excelはシート1つ)。
class ImportSheet {
  const ImportSheet({
    this.name,
    this.hidden = false,
    this.table,
    this.headerRowNumber = 1,
    this.mergedRangeCount = 0,
    this.formulaCellCount = 0,
  });

  /// シート名(Excelのみ)。
  final String? name;
  final bool hidden;

  /// データが無いシートはnull。
  final CsvTable? table;

  /// 列名の行の、シート上の行番号(Excelで先頭に空の行がある場合だけ1以外)。
  final int headerRowNumber;
  final int mergedRangeCount;
  final int formulaCellCount;

  bool get isEmpty => table == null;
}

class ParsedImportFile {
  const ParsedImportFile({required this.format, required this.sheets});
  final ImportFileFormat format;

  /// CSVは1件(名前なし)。Excelはブック内の全シート(順序どおり)。
  final List<ImportSheet> sheets;
}

/// 拡張子から形式を決める。対応していない形式は[ImportFileException]。
ImportFileFormat importFileFormatOf(String fileName) {
  final lower = fileName.trim().toLowerCase();
  if (lower.endsWith('.csv')) return ImportFileFormat.csv;
  if (lower.endsWith('.xlsx')) return ImportFileFormat.xlsx;
  if (lower.endsWith('.xls')) {
    throw const ImportFileException(
      '古い形式のExcel(.xls)は読み込めません。Excelで「.xlsx」形式で保存し直してから選択してください。',
    );
  }
  throw const ImportFileException(
    '対応していないファイル形式です。Excel（.xlsx）またはCSV（.csv）を選択してください。',
  );
}

/// ファイルを読み取り、共通の表にする(この時点ではprofile・サーバーには触れない)。
ParsedImportFile parseImportFile(String fileName, Uint8List bytes) {
  final format = importFileFormatOf(fileName);
  switch (format) {
    case ImportFileFormat.csv:
      try {
        return ParsedImportFile(
          format: format,
          sheets: [ImportSheet(table: parseCsvBytes(bytes))],
        );
      } on CsvParseException catch (e) {
        throw ImportFileException(e.message);
      }
    case ImportFileFormat.xlsx:
      final List<XlsxSheet> sheets;
      try {
        sheets = readXlsxSheets(bytes);
      } on XlsxParseException catch (e) {
        throw ImportFileException(e.message);
      }
      return ParsedImportFile(
        format: format,
        sheets: [for (final s in sheets) _sheetOf(s)],
      );
  }
}

/// Excelのシート → 共通の表。列名の行 = 値のある最初の行。データ行はその次の行からで、間の空の行も
/// 空のレコードとして残す(CSVと同じく、空のレコードは黙って捨てずに件数に出す)。末尾の空の行(書式だけの行)は含めない。
/// 値の無い末尾のセルは、列名の数まで空の値で埋める(Excelは空のセルを保存しないため。CSVの「,,」と同じ扱い)。
ImportSheet _sheetOf(XlsxSheet sheet) {
  bool blank(List<String> row) => row.every((c) => c.trim().isEmpty);
  final headerIndex = sheet.rows.indexWhere((r) => !blank(r));
  if (headerIndex < 0) {
    return ImportSheet(name: sheet.name, hidden: sheet.hidden);
  }
  final headerCells = [...sheet.rows[headerIndex]];
  while (headerCells.isNotEmpty && headerCells.last.trim().isEmpty) {
    headerCells.removeLast();
  }
  final headers = headerCells.map((h) => h.trim()).toList();
  final dataRows = sheet.rows.sublist(headerIndex + 1);
  var end = dataRows.length;
  while (end > 0 && blank(dataRows[end - 1])) {
    end--;
  }
  final records = [
    for (final row in dataRows.take(end))
      blank(row)
          ? <String>[]
          : [...row, for (var i = row.length; i < headers.length; i++) ''],
  ];
  if (records.length > importMaxRows) {
    throw ImportFileException(
      'シート「${sheet.name}」の行数が上限($importMaxRows行)を超えています。ファイルを分けて取り込んでください。',
    );
  }
  return ImportSheet(
    name: sheet.name,
    hidden: sheet.hidden,
    table: CsvTable(headers: headers, records: records),
    headerRowNumber: headerIndex + 1,
    mergedRangeCount: sheet.mergedRangeCount,
    formulaCellCount: sheet.formulaCellCount,
  );
}

/// 使うシートの決め方の結果。
/// - [selected]があれば、それを使う(CSV、または一意に決まったExcelのシート)。
/// - [candidates]が2件以上あれば、管理者に選ばせる(先頭のシートを勝手に使わない)。
/// - どちらも無ければ[problem]を表示する。
class SheetSelection {
  const SheetSelection({
    this.selected,
    this.candidates = const [],
    this.problem,
  });
  final ImportSheet? selected;
  final List<ImportSheet> candidates;
  final String? problem;
}

/// profileの列名がすべて揃っている(かつHEBEL属性の列が一意に決まる)表示中のシートが1つなら、それを自動で選ぶ。
/// 複数あれば管理者に選ばせる。1つも無ければ、データのある表示中のシートが1つだけならそれを選び
/// (不足している列を通常の「対応していない形式」の表示で示す)、それ以外は選べない理由を返す。
SheetSelection selectImportSheet(
  ParsedImportFile file,
  ConfirmedImportProfile profile,
) {
  if (file.format == ImportFileFormat.csv) {
    return SheetSelection(selected: file.sheets.single);
  }
  final usable = file.sheets.where((s) => !s.hidden && !s.isEmpty).toList();
  final matching = usable
      .where(
        (s) =>
            profile.missingHeaders(s.table!.headers).isEmpty &&
            !profile.resolveHebelResidenceColumn(s.table!.headers).ambiguous,
      )
      .toList();
  if (matching.length == 1) return SheetSelection(selected: matching.single);
  if (matching.length > 1) return SheetSelection(candidates: matching);
  if (usable.length == 1) return SheetSelection(selected: usable.single);
  if (usable.isEmpty) {
    return const SheetSelection(
      problem: 'Excelファイルに、データのある(表示されている)シートがありません。',
    );
  }
  return SheetSelection(
    problem:
        'Excelファイルに、参加者リストの形式に合うシートがありません(シート: ${usable.map((s) => '「${s.name}」').join('、')})。',
  );
}
