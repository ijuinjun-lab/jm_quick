import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_client.dart';
import 'import_models.dart';

/// 取込のサーバー呼び出しで起きた、画面へそのまま表示できるエラー(内部情報を含まない)。
class ImportException implements Exception {
  const ImportException(this.message, {this.code, this.ambiguous = false});
  final String message;

  /// サーバーが返した理由コード。
  final String? code;

  /// 通信の失敗など、サーバーで処理が行われたかどうか分からない場合。
  /// 同じ内容でもう一度「取込を確定」すると、サーバーの冪等性で、二重に作られず続きから完了する。
  final bool ambiguous;
  @override
  String toString() => message;
}

/// 新方式の取込(admin専用のサーバーAPI: getConfirmedEventSummary / validateConfirmedImport / previewConfirmedImport / commitConfirmedImport)。
/// 画面はこの抽象にだけ依存する(テストでは差し替える)。Firestoreは直接使わない。
abstract class ImportService {
  Future<ImportEventSummary> getEvent(String eventId);

  /// 取込前の検証(何も書き込まない)。
  Future<ImportValidation> validate(ImportRequest request);
  Future<ImportPreview> preview(ImportRequest request);

  /// [approvedReviewRows]は、管理者が明示的に承認した「確認が必要」な行の番号。
  /// [validation]は、このリクエストの内容を検証した結果(新しい取込回を作るときに、サーバーへ期待する取込回の番号と
  /// 検証の指紋を送る。サーバーは最新の状態で再計算して照合し、変わっていれば拒否する)。
  /// [acknowledgeExistingEmailDuplicates]・[acknowledgeCsvEmailDuplicates]は、既存の有効な参加者との/CSV内の
  /// メール重複を、別参加者として取り込むことの管理者の明示的な許可(検証画面での確認)。無ければサーバーが拒否する。
  /// [approvalKeys]は、管理者が許可した警告の許可の鍵(検証が行ごとに返した値)。サーバーは許可が必要な警告すべてについて、
  /// 現在の鍵が含まれていることを確認する(許可した後に行を修正した等で鍵が変われば拒否し、改めて許可させる)。
  /// 不参加のprogramに残っている人数は参考情報で、確認は要らない(送らない)。
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
    ImportValidation? validation,
    bool acknowledgeExistingEmailDuplicates = false,
    bool acknowledgeCsvEmailDuplicates = false,
    List<String> approvalKeys = const [],
  });
}

class CallableImportService implements ImportService {
  CallableImportService({
    required this.authClient,
    http.Client? httpClient,
    String? baseUrl,
  }) : _httpClient = httpClient ?? http.Client(),
       baseUrl = baseUrl ?? defaultBaseUrl;

  static const defaultBaseUrl =
      'https://asia-northeast1-jm-quick.cloudfunctions.net';

  final AuthClient authClient;
  final http.Client _httpClient;
  final String baseUrl;

  @override
  Future<ImportEventSummary> getEvent(String eventId) async =>
      ImportEventSummary.fromJson(
        await _call('getConfirmedEventSummary', {'eventId': eventId}),
      );

  @override
  Future<ImportValidation> validate(ImportRequest request) async =>
      ImportValidation.fromJson(
        await _call('validateConfirmedImport', request.json),
      );

  @override
  Future<ImportPreview> preview(ImportRequest request) async =>
      ImportPreview.fromJson(
        await _call('previewConfirmedImport', request.json),
      );

  @override
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
    ImportValidation? validation,
    bool acknowledgeExistingEmailDuplicates = false,
    bool acknowledgeCsvEmailDuplicates = false,
    List<String> approvalKeys = const [],
  }) async => ImportResult.fromJson(
    await _call('commitConfirmedImport', {
      ...request.json,
      if (approvedReviewRows.isNotEmpty)
        'approvedReviewRows': ([...approvedReviewRows]..sort()),
      if (validation != null) ...{
        'expectedImportSequence': validation.nextImportSequence,
        'validationFingerprint': validation.validationFingerprint,
      },
      if (acknowledgeExistingEmailDuplicates)
        'acknowledgeExistingEmailDuplicates': true,
      if (acknowledgeCsvEmailDuplicates) 'acknowledgeCsvEmailDuplicates': true,
      if (approvalKeys.isNotEmpty) 'approvalKeys': ([...approvalKeys]..sort()),
    }),
  );

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    final token = await authClient.idToken();
    if (token == null) throw const ImportException('ログインが必要です。');
    http.Response response;
    try {
      response = await _httpClient.post(
        Uri.parse('$baseUrl/$name'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'data': data}),
      );
    } catch (_) {
      throw const ImportException(
        '通信に失敗しました。取込が行われたかどうか分かりません。同じ内容でもう一度「取込を確定」しても、参加者が二重に作られることはありません。',
        ambiguous: true,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode == 200 && decoded is Map) {
      final result = decoded['result'] ?? decoded['data'];
      if (result is Map) return Map<String, dynamic>.from(result);
    }
    throw errorFrom(response.statusCode, decoded);
  }

  static const _waitlistReasons = {
    'sheet-name-missing': 'シート名がありません(Excel(.xlsx)のシート名から時間枠を読み取ります)',
    'sheet-name-not-time-range': 'シート名を時間枠(例: 15時30分～16時10分)として読み取れません',
    'sheet-list-missing': 'ファイルのシートの一覧がありません(対象のシートが1枚であることを確認できません)',
    'sheet-not-in-list': '取り込むシートが、ファイルのシートの一覧にありません',
    'multiple-sheets': '参加者リストの形式に合うシートが複数あり、時間枠を1つに決められません',
    'no-target-rows': '取込対象の行がありません(全員がキャンセル等)',
    'slot-not-in-waitlist-options': 'キャンセル待ち希望枠に、シート名の時間枠と一致する選択肢がありません',
    'slot-matches-multiple-options': 'シート名の時間枠に一致する選択肢が複数あります',
    'count-missing': 'キャンセル待ち希望人数が空です',
    'count-unparsable': 'キャンセル待ち希望人数を「N名」として読み取れません',
    'count-not-positive': 'キャンセル待ち希望人数が0以下です',
    'count-over-limit': 'キャンセル待ち希望人数が上限を超えています',
    'programs-not-uniform': '行によって繰り上げ先のprogramが異なります',
    'file-name-kind-conflict': 'ファイル名の種別(犬・猫など)と、判定した繰り上げ先が一致しません',
  };

  static const _messages = {
    'notification-type-mapping-mismatch': '通知種別と列の対応が一致しません。画面を読み込み直してください。',
    'exclusion-already-automatic': 'この行は自動で除外されています(原本でキャンセル)。画面を読み込み直してください。',
    'invalid-mapping': '列の対応(mapping)に問題があります。選択した列と値を確認してください。',
    'program-not-in-event': '列の対応に、このイベントに定義されていないprogramが含まれています。',
    'column-missing': '指定した列がファイルにありません。',
    'unexpected-column': '列の指定に不整合があります。画面を読み込み直してください。',
    'record-accounting-mismatch': 'ファイルの行数の確認が一致しませんでした。画面を読み込み直して、もう一度お試しください。',
    'event-start-missing': 'イベントの開催日時が未設定のため、時間枠を解釈できません。',
    'batch-content-mismatch':
        '同じファイル・同じ列の対応の取込が、異なる内容(ファイル名または承認した行)で既に存在します。内容を確認してください。',
    'record-id-conflict': '取込先のIDに既存のデータがあります。取込を中止しました。',
    'commit-interrupted':
        '取込が途中で止まりました。同じ内容でもう一度「取込を確定」すると、続きから安全に完了できます(二重には作られません)。',
    'conservation-violated':
        '取込結果が元のファイルの全行と一致しなかったため、取込を完了させませんでした。管理者へ連絡してください。',
    'error-row-cannot-be-approved': 'エラーの行は承認できません。',
    'approval-not-review': '承認できない行が含まれています。',
    'existing-email-duplicates-unacknowledged':
        'このイベントの既存の参加者とメールアドレスが同じ参加者が含まれています。検証からやり直し、重複を確認してください。',
    'csv-email-duplicates-unacknowledged':
        'ファイル内に同じメールアドレスの行があります。検証からやり直し、重複を確認してください。',
    'import-state-changed': '取込状況が変更されました。再度検証してください。',
    'validation-required': '検証が済んでいないため取り込めません。検証からやり直してください。',
    'import-has-errors': '未解決のエラーの行があるため取り込めません。検証画面で修正するか、今回の取込から除外してください。',
    'unresolved-review-rows': '確認が必要な行が解決されていません。検証画面で許可するか、今回の取込から除外してください。',
    'approvals-outdated': '許可した後に内容が変わった警告があります。検証画面で改めて確認し、許可してください。',
    'correction-unchanged': '修正した値が元の値と同じです。',
    'correction-column-not-allowed': 'この項目は検証画面では修正できません。',
  };

  static ImportException errorFrom(int statusCode, Object? decoded) {
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
    // キャンセル待ち繰り上げ当選: 繰り上げ先を一意に判定できない(管理者の入力では補わず、取込を止める)。理由を具体的に示す。
    if (code == 'waitlist-undetermined') {
      final reasons = details['reasons'] is List ? details['reasons'] as List : const [];
      final lines = [
        for (final r in reasons.take(20))
          if (r is Map)
            '・${r['sourceRowNumber'] is num ? '${r['sourceRowNumber']}行目: ' : ''}'
                '${_waitlistReasons[r['code']] ?? '判定できない理由があります(${r['code']})'}',
      ];
      return ImportException(
        ['このファイルは繰り上げ先を一意に判定できません。', ...lines].join('\n'),
        code: code,
      );
    }
    switch (error['status']) {
      case 'PERMISSION_DENIED':
        return ImportException('この操作を行う権限がありません。', code: code);
      case 'UNAUTHENTICATED':
        return ImportException('ログインが必要です。', code: code);
      case 'NOT_FOUND':
        return ImportException('イベントが見つかりません。', code: code);
    }
    final known = _messages[code];
    final ambiguous = statusCode >= 500 || code == 'commit-interrupted';
    if (known != null) {
      return ImportException(known, code: code, ambiguous: ambiguous);
    }
    if (error['status'] == 'FAILED_PRECONDITION') {
      return ImportException('新方式のイベントを確認できませんでした。', code: code);
    }
    return ImportException(
      ambiguous
          ? '処理に失敗しました。取込が行われたかどうか分かりません。同じ内容でもう一度「取込を確定」しても、参加者が二重に作られることはありません。'
          : '入力内容を確認してください。',
      code: code,
      ambiguous: ambiguous,
    );
  }
}
