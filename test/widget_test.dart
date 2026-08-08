import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/services/demo_repository.dart';
import 'package:jm_quick/models/event_status.dart';
import 'package:jm_quick/services/csv_import_service.dart';
import 'package:jm_quick/models/demo_models.dart';
import 'package:jm_quick/pages/demo_admin_page.dart';

void main() {
  test('公開IDは推測困難で毎回異なる', () {
    final first = DemoRepository.randomPublicId();
    final second = DemoRepository.randomPublicId();
    expect(first, startsWith('pub_'));
    expect(first.length, greaterThanOrEqualTo(35));
    expect(second, isNot(first));
  });

  test('当日参加QRはイベント固有の本人入力ページへ遷移する', () {
    expect(walkInPathForEvent('event-A'), '/e/event-A/walk-in');
    expect(
      walkInPathForEvent('イベント A'),
      '/e/%E3%82%A4%E3%83%99%E3%83%B3%E3%83%88%20A/walk-in',
    );
  });

  test('参加予定回答はFirestore値から日本語表示へ変換できる', () {
    expect(AttendanceResponse.fromValue('attending')?.label, '参加予定');
    expect(AttendanceResponse.fromValue('notAttending')?.label, '不参加予定');
    expect(AttendanceResponse.fromValue(null), isNull);
  });

  test('イベント状態は設定日時に従って自動遷移する', () {
    final start = DateTime(2026, 11, 30, 10);
    final end = DateTime(2026, 11, 30, 16);
    final deadline = DateTime(2026, 11, 20, 23, 59);
    final confirmation = DateTime(2026, 11, 29, 10);

    EventStatus status(DateTime now) => calculateEventStatus(
      now: now,
      startAt: start,
      endAt: end,
      registrationDeadline: deadline,
      confirmationSendAt: confirmation,
    );

    expect(status(DateTime(2026, 11, 20, 12)), EventStatus.registration);
    expect(status(DateTime(2026, 11, 21)), EventStatus.awaitingConfirmation);
    expect(status(confirmation), EventStatus.confirmation);
    expect(status(DateTime(2026, 11, 30, 9)), EventStatus.eventDay);
    expect(status(end), EventStatus.ended);
  });

  test('参加者CSVは基本3項目を検証して読み込む', () {
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode(
          '氏名,メールアドレス,参加人数\n'
          'イベントA参加者,a@example.com,2\n'
          '不正行,invalid,0\n',
        ),
      ),
    );
    expect(preview.rows, hasLength(1));
    expect(preview.rows.single.registeredCount, 2);
    expect(preview.errorCount, 1);
  });

  test('実データの作者本名列とメール列から10名を認識する', () {
    final rows = List.generate(
      10,
      (index) => '作者${index + 1},creator${index + 1}@example.com,未使用',
    ).join('\n');
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode('作者本名（グループ制作応募の場合は代表者名）,メールアドレス,作品名\n$rows\n'),
      ),
    );
    expect(preview.rows, hasLength(10));
    expect(preview.errorCount, 0);
    expect(preview.nameHeader, '作者本名（グループ制作応募の場合は代表者名）');
    expect(preview.emailHeader, 'メールアドレス');
    expect(preview.registeredCountHeader, isNull);
    expect(preview.rows.first.name, '作者1');
    expect(preview.rows.first.email, 'creator1@example.com');
    expect(preview.rows.every((row) => row.registeredCount == 1), isTrue);
  });

  test('ヘッダーを正規化し未使用列を無視する', () {
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode(
          '\ufeff作品番号,　応募者 氏名　, E-mail ,備考\n1,山田太郎,YAMADA@example.com,任意\n',
        ),
      ),
    );
    expect(preview.rows.single.name, '山田太郎');
    expect(preview.rows.single.email, 'yamada@example.com');
    expect(preview.rows.single.registeredCount, 1);
    expect(preview.errors, isEmpty);
  });

  test('候補列が曖昧な場合は自動確定しない', () {
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode('氏名,代表者名,メールアドレス\n山田太郎,山田花子,a@example.com\n'),
      ),
    );
    expect(preview.rows, isEmpty);
    expect(preview.canImport, isFalse);
    expect(preview.errors.single, contains('氏名候補が複数あります'));
  });

  test('ヘッダー不足と行エラーの理由を具体的に返す', () {
    final missingHeader = parseParticipantCsv(
      Uint8List.fromList(utf8.encode('作品名,連絡先\n作品A,a@example.com\n')),
    );
    expect(missingHeader.errors, contains('氏名として認識できる列が見つかりません。'));
    expect(missingHeader.errors, contains('メールアドレスとして認識できる列が見つかりません。'));

    final invalidRows = parseParticipantCsv(
      Uint8List.fromList(utf8.encode('氏名,メールアドレス\n山田太郎,\n山田花子,invalid\n')),
    );
    expect(invalidRows.errors, contains('2行目：メールアドレスが空です。'));
    expect(invalidRows.errors, contains('3行目：メールアドレス形式が不正です。'));
  });

  test('姓・名の分割列と人数列を389件読み込む', () {
    final dataRows = List.generate(389, (index) {
      final count = index % 6 + 1;
      return '2026/08/01,姓$index,名$index,セイ$index,メイ$index,'
          'person$index@example.com,$count';
    }).join('\n');
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode(
          '申込日,名前(姓),名前(名),フリガナ(姓),フリガナ(名),メールアドレス,人数\n'
          '$dataRows\n',
        ),
      ),
    );
    expect(preview.inputRowCount, 389);
    expect(preview.rows, hasLength(389));
    expect(preview.errorCount, 0);
    expect(preview.rows.first.name, '姓0 名0');
    expect(preview.rows.first.furiganaLastName, 'セイ0');
    expect(preview.rows.first.furiganaFirstName, 'メイ0');
    expect(preview.rows.last.registeredCount, 5);
    expect(preview.registeredCountTotal, 1359);
  });

  test('人数列がある場合は空欄・0・非数値を1へ置換しない', () {
    final preview = parseParticipantCsv(
      Uint8List.fromList(
        utf8.encode(
          '氏名,メールアドレス,人数\n'
          '空欄,a@example.com,\n'
          'ゼロ,b@example.com,0\n'
          '文字,c@example.com,複数\n',
        ),
      ),
    );
    expect(preview.rows, isEmpty);
    expect(preview.errorCount, 3);
    expect(preview.errors, everyElement(contains('人数が正しくありません')));
  });
}
