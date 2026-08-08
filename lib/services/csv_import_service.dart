import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

class CsvParticipantRow {
  const CsvParticipantRow({
    required this.name,
    required this.email,
    required this.registeredCount,
    this.furiganaLastName,
    this.furiganaFirstName,
  });
  final String name;
  final String email;
  final int registeredCount;
  final String? furiganaLastName;
  final String? furiganaFirstName;
}

class CsvImportPreview {
  const CsvImportPreview({
    required this.rows,
    required this.errors,
    required this.inputRowCount,
    this.nameHeader,
    this.emailHeader,
    this.registeredCountHeader,
  });

  final List<CsvParticipantRow> rows;
  final List<String> errors;
  final int inputRowCount;
  final String? nameHeader;
  final String? emailHeader;
  final String? registeredCountHeader;

  int get registeredCountTotal =>
      rows.fold(0, (total, row) => total + row.registeredCount);

  int get errorCount => errors.length;
  bool get canImport =>
      nameHeader != null && emailHeader != null && rows.isNotEmpty;
}

const _exactNameHeaders = {
  '氏名',
  '名前',
  '参加者氏名',
  '応募者氏名',
  '申込者氏名',
  '代表者名',
  '作者名',
  '作者本名',
  '作者本名（グループ制作応募の場合は代表者名）',
};
const _nameFragments = {'氏名', '名前', '本名', '代表者名'};
const _exactEmailHeaders = {
  'メールアドレス',
  'メール',
  'メールアドレス（必須）',
  'e-mail',
  'email',
  'mail',
  'mailaddress',
};
const _exactCountHeaders = {
  '参加人数',
  '登録人数',
  '申込人数',
  '申し込み人数',
  '人数',
  'registeredcount',
  'count',
};
const _countFragments = {'参加人数', '登録人数', '申込人数', '申し込み人数'};
const _lastNameHeaders = {'名前(姓)', '名前（姓）', '姓'};
const _firstNameHeaders = {'名前(名)', '名前（名）', '名'};
const _furiganaLastNameHeaders = {'フリガナ(姓)', 'フリガナ（姓）'};
const _furiganaFirstNameHeaders = {'フリガナ(名)', 'フリガナ（名）'};

CsvImportPreview parseParticipantCsv(Uint8List bytes) {
  late final String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false).replaceFirst('\ufeff', '');
  } on FormatException {
    return const CsvImportPreview(
      rows: [],
      errors: ['CSVをUTF-8として読み込めませんでした。UTF-8形式のCSVを選択してください。'],
      inputRowCount: 0,
    );
  }

  late final List<List<dynamic>> records;
  try {
    records = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(text);
  } on FormatException catch (error) {
    return CsvImportPreview(
      rows: const [],
      errors: ['CSV形式を解析できませんでした：${error.message}'],
      inputRowCount: 0,
    );
  }
  if (records.isEmpty) {
    return const CsvImportPreview(
      rows: [],
      errors: ['CSVにヘッダー行がありません。'],
      inputRowCount: 0,
    );
  }

  final headers = records.first.map((value) => '$value').toList();
  final normalized = headers.map(_normalizeHeader).toList();
  final errors = <String>[];
  final nameCandidates = _candidateIndexes(
    normalized,
    exact: _normalizedSet(_exactNameHeaders),
    fragments: _normalizedSet(_nameFragments),
  );
  final emailCandidates = _candidateIndexes(
    normalized,
    exact: _normalizedSet(_exactEmailHeaders),
    fragments: const {'メールアドレス', 'email', 'e-mail', 'mailaddress'},
  );
  final countCandidates = _candidateIndexes(
    normalized,
    exact: _normalizedSet(_exactCountHeaders),
    fragments: _normalizedSet(_countFragments),
  );

  final lastNameCandidates = _exactCandidateIndexes(
    normalized,
    _normalizedSet(_lastNameHeaders),
  );
  final firstNameCandidates = _exactCandidateIndexes(
    normalized,
    _normalizedSet(_firstNameHeaders),
  );
  final hasSplitName =
      lastNameCandidates.length == 1 && firstNameCandidates.length == 1;
  if (lastNameCandidates.length > 1 || firstNameCandidates.length > 1) {
    errors.add('姓または名の候補列が複数あります。');
  } else if (lastNameCandidates.isNotEmpty != firstNameCandidates.isNotEmpty) {
    errors.add('氏名の姓・名列が片方しか見つかりません。');
  }

  final nameIndex = hasSplitName
      ? null
      : _singleCandidate(
          nameCandidates,
          headers,
          '氏名として認識できる列が見つかりません。',
          '氏名候補が複数あります',
          errors,
        );
  final emailIndex = _singleCandidate(
    emailCandidates,
    headers,
    'メールアドレスとして認識できる列が見つかりません。',
    'メールアドレス候補が複数あります',
    errors,
  );
  int? countIndex;
  if (countCandidates.length == 1) {
    countIndex = countCandidates.single;
  } else if (countCandidates.length > 1) {
    errors.add(
      '登録人数候補が複数あります：${countCandidates.map((index) => headers[index]).join('、')}',
    );
  }
  final inputRowCount = records
      .skip(1)
      .where((record) => record.any((value) => '$value'.trim().isNotEmpty))
      .length;
  if ((!hasSplitName && nameIndex == null) ||
      emailIndex == null ||
      countCandidates.length > 1 ||
      lastNameCandidates.length > 1 ||
      firstNameCandidates.length > 1 ||
      lastNameCandidates.isNotEmpty != firstNameCandidates.isNotEmpty) {
    return CsvImportPreview(
      rows: const [],
      errors: errors,
      inputRowCount: inputRowCount,
      nameHeader: hasSplitName
          ? '${headers[lastNameCandidates.single]}＋${headers[firstNameCandidates.single]}'
          : nameIndex == null
          ? null
          : headers[nameIndex],
      emailHeader: emailIndex == null ? null : headers[emailIndex],
      registeredCountHeader: countIndex == null ? null : headers[countIndex],
    );
  }

  final rows = <CsvParticipantRow>[];
  final furiganaLastIndex = _singleExactIndex(
    normalized,
    _normalizedSet(_furiganaLastNameHeaders),
  );
  final furiganaFirstIndex = _singleExactIndex(
    normalized,
    _normalizedSet(_furiganaFirstNameHeaders),
  );
  for (var recordIndex = 1; recordIndex < records.length; recordIndex++) {
    final record = records[recordIndex];
    if (record.every((value) => '$value'.trim().isEmpty)) continue;
    final csvRowNumber = recordIndex + 1;
    String valueAt(int index) =>
        index < record.length ? '${record[index]}'.trim() : '';
    final name = hasSplitName
        ? '${valueAt(lastNameCandidates.single)} ${valueAt(firstNameCandidates.single)}'
              .trim()
        : valueAt(nameIndex!);
    final email = valueAt(emailIndex).toLowerCase();
    if (name.isEmpty) {
      errors.add('$csvRowNumber行目：氏名が空です。');
      continue;
    }
    if (email.isEmpty) {
      errors.add('$csvRowNumber行目：メールアドレスが空です。');
      continue;
    }
    if (!_emailPattern.hasMatch(email)) {
      errors.add('$csvRowNumber行目：メールアドレス形式が不正です。');
      continue;
    }
    var registeredCount = 1;
    if (countIndex != null) {
      final rawCount = valueAt(countIndex);
      final parsed = int.tryParse(rawCount);
      if (rawCount.isEmpty) {
        errors.add('$csvRowNumber行目：人数が正しくありません。');
        continue;
      }
      if (parsed == null || parsed < 1) {
        errors.add('$csvRowNumber行目：人数が正しくありません。');
        continue;
      }
      registeredCount = parsed;
    }
    rows.add(
      CsvParticipantRow(
        name: name,
        email: email,
        registeredCount: registeredCount,
        furiganaLastName: furiganaLastIndex == null
            ? null
            : valueAt(furiganaLastIndex),
        furiganaFirstName: furiganaFirstIndex == null
            ? null
            : valueAt(furiganaFirstIndex),
      ),
    );
  }
  return CsvImportPreview(
    rows: rows,
    errors: errors,
    inputRowCount: inputRowCount,
    nameHeader: hasSplitName
        ? '${headers[lastNameCandidates.single]}＋${headers[firstNameCandidates.single]}'
        : headers[nameIndex!],
    emailHeader: headers[emailIndex],
    registeredCountHeader: countIndex == null ? null : headers[countIndex],
  );
}

List<int> _exactCandidateIndexes(List<String> headers, Set<String> exact) => [
  for (var index = 0; index < headers.length; index++)
    if (exact.contains(headers[index])) index,
];

int? _singleExactIndex(List<String> headers, Set<String> exact) {
  final matches = _exactCandidateIndexes(headers, exact);
  return matches.length == 1 ? matches.single : null;
}

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

Set<String> _normalizedSet(Set<String> values) =>
    values.map(_normalizeHeader).toSet();

String _normalizeHeader(String value) => value
    .replaceAll('\ufeff', '')
    .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '')
    .replaceAll(RegExp(r'[\s\u3000]+'), '')
    .toLowerCase();

List<int> _candidateIndexes(
  List<String> headers, {
  required Set<String> exact,
  required Set<String> fragments,
}) {
  final exactMatches = <int>[];
  final partialMatches = <int>[];
  for (var index = 0; index < headers.length; index++) {
    final header = headers[index];
    if (exact.contains(header)) {
      exactMatches.add(index);
    } else if (fragments.any(header.contains)) {
      partialMatches.add(index);
    }
  }
  return [...exactMatches, ...partialMatches];
}

int? _singleCandidate(
  List<int> candidates,
  List<String> headers,
  String missingMessage,
  String ambiguousMessage,
  List<String> errors,
) {
  if (candidates.isEmpty) {
    errors.add(missingMessage);
    return null;
  }
  if (candidates.length > 1) {
    errors.add(
      '$ambiguousMessage：${candidates.map((index) => headers[index]).join('、')}',
    );
    return null;
  }
  return candidates.single;
}
