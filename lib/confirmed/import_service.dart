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

/// 新方式の取込(admin専用のサーバーAPI: getConfirmedEventSummary / previewConfirmedImport / commitConfirmedImport)。
/// 画面はこの抽象にだけ依存する(テストでは差し替える)。Firestoreは直接使わない。
abstract class ImportService {
  Future<ImportEventSummary> getEvent(String eventId);
  Future<ImportPreview> preview(ImportRequest request);

  /// [approvedReviewRows]は、管理者が明示的に承認した「確認が必要」な行の番号。
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
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
  Future<ImportPreview> preview(ImportRequest request) async =>
      ImportPreview.fromJson(
        await _call('previewConfirmedImport', request.json),
      );

  @override
  Future<ImportResult> commit(
    ImportRequest request, {
    List<int> approvedReviewRows = const [],
  }) async => ImportResult.fromJson(
    await _call('commitConfirmedImport', {
      ...request.json,
      if (approvedReviewRows.isNotEmpty)
        'approvedReviewRows': ([...approvedReviewRows]..sort()),
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

  static const _messages = {
    'invalid-mapping': '列の対応(mapping)に問題があります。選択した列と値を確認してください。',
    'program-not-in-event': '列の対応に、このイベントに定義されていないprogramが含まれています。',
    'column-missing': '指定した列がCSVにありません。',
    'unexpected-column': '列の指定に不整合があります。画面を読み込み直してください。',
    'record-accounting-mismatch': 'CSVの行数の確認が一致しませんでした。画面を読み込み直して、もう一度お試しください。',
    'event-start-missing': 'イベントの開催日時が未設定のため、時間枠を解釈できません。',
    'batch-content-mismatch':
        '同じファイル・同じ列の対応の取込が、異なる内容(ファイル名または承認した行)で既に存在します。内容を確認してください。',
    'record-id-conflict': '取込先のIDに既存のデータがあります。取込を中止しました。',
    'commit-interrupted':
        '取込が途中で止まりました。同じ内容でもう一度「取込を確定」すると、続きから安全に完了できます(二重には作られません)。',
    'conservation-violated':
        '取込結果が元のCSVの全行と一致しなかったため、取込を完了させませんでした。管理者へ連絡してください。',
    'error-row-cannot-be-approved': 'エラーの行は承認できません。',
    'approval-not-review': '承認できない行が含まれています。',
  };

  static ImportException errorFrom(int statusCode, Object? decoded) {
    final error = decoded is Map && decoded['error'] is Map
        ? Map<String, dynamic>.from(decoded['error'] as Map)
        : const <String, dynamic>{};
    final details = error['details'] is Map
        ? Map<String, dynamic>.from(error['details'] as Map)
        : const <String, dynamic>{};
    final code = details['code'] as String?;
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
