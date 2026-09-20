import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/services/demo_repository.dart';
import 'package:jm_quick/models/event_status.dart';
import 'package:jm_quick/services/csv_import_service.dart';
import 'package:jm_quick/services/participant_csv_export_service.dart';
import 'package:jm_quick/models/demo_models.dart';
import 'package:jm_quick/pages/demo_admin_page.dart';
import 'package:jm_quick/widgets/common.dart';

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

  test('参加予定確認メール送信日時は開催日前日と指定時刻から計算する', () {
    final result = previousDayAt(
      DateTime(2026, 8, 10),
      const TimeOfDay(hour: 10, minute: 0),
    );
    expect(result, DateTime(2026, 8, 9, 10));
    expect(formatDateTimeMinute(result), '2026/08/09 10:00');
    expect(formatTime24(const TimeOfDay(hour: 16, minute: 0)), '16:00');
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

  test('参加者一覧CSVは現在のイベントだけを日本語状態で出力する', () {
    const event = DemoEvent(
      id: 'event-A',
      name: 'ペット防災/イベント',
      senderName: 'ペット防災イベント',
      venue: '会場A',
      contact: '',
      reconfirmEnabled: true,
    );
    Participant participant({
      required String id,
      required String eventId,
      required String name,
      required bool invitationSent,
      String? invitationMailStatus,
      required bool confirmed,
      AttendanceResponse? response,
      String? furigana,
      int count = 1,
    }) => Participant(
      id: id,
      eventId: eventId,
      publicId: 'public-$id',
      name: name,
      email: '$id@example.com',
      furiganaLastName: furigana,
      registeredCount: count,
      registrationType: 'preRegistered',
      invitationSent: invitationSent,
      invitationMailStatus: invitationMailStatus,
      participationConfirmed: confirmed,
      reconfirmed: false,
      attendanceResponse: response,
      reconfirmationMailSent: false,
    );
    final export = buildParticipantCsv(
      event: event,
      participants: [
        participant(
          id: 'a2',
          eventId: 'event-A',
          name: '伊集院 純',
          furigana: 'イジュウイン',
          invitationSent: true,
          confirmed: true,
          response: AttendanceResponse.attending,
          count: 2,
        ),
        participant(
          id: 'a1',
          eventId: 'event-A',
          name: '松井 花子',
          furigana: 'マツイ',
          invitationSent: false,
          invitationMailStatus: 'failed',
          confirmed: false,
        ),
        participant(
          id: 'a3',
          eventId: 'event-A',
          name: '渡辺 太郎',
          invitationSent: false,
          confirmed: true,
          response: AttendanceResponse.notAttending,
        ),
        participant(
          id: 'b1',
          eventId: 'event-B',
          name: '別イベント参加者',
          invitationSent: true,
          confirmed: true,
        ),
      ],
      checkIns: const [
        CheckIn(
          participantId: 'a2',
          eventId: 'event-A',
          checkedIn: true,
          attendedCount: 2,
        ),
        CheckIn(participantId: 'a1', eventId: 'event-A', checkedIn: false),
        CheckIn(
          participantId: 'b1',
          eventId: 'event-B',
          checkedIn: true,
          attendedCount: 9,
        ),
      ],
      exportedAt: DateTime(2026, 8, 8),
    );
    final text = utf8.decode(export.bytes);
    expect(export.bytes.take(3), [0xef, 0xbb, 0xbf]);
    expect(export.fileName, 'ペット防災_イベント_参加者一覧_20260808.csv');
    expect(text, contains('伊集院 純,a2@example.com,2,送信済み,登録済み,参加予定,受付済み,2'));
    expect(text, contains('松井 花子,a1@example.com,1,送信失敗,未登録,未回答,未受付,'));
    expect(text, contains('渡辺 太郎,a3@example.com,1,未送信,登録済み,不参加予定,未受付,'));
    expect(text, isNot(contains('別イベント参加者')));
    expect(text.indexOf('伊集院 純'), lessThan(text.indexOf('松井 花子')));
  });

  group('参加者一覧CSVの数式インジェクション対策', () {
    const event = DemoEvent(
      id: 'event-A',
      name: '数式テスト',
      senderName: '数式テスト',
      venue: '会場A',
      contact: '',
      reconfirmEnabled: false,
    );
    Participant participant(String id, String name, {String? email}) =>
        Participant(
          id: id,
          eventId: 'event-A',
          publicId: 'public-$id',
          name: name,
          email: email ?? '$id@example.com',
          registeredCount: 2,
          registrationType: 'preRegistered',
          invitationSent: false,
          participationConfirmed: false,
          reconfirmed: false,
          reconfirmationMailSent: false,
        );
    List<List<dynamic>> parse(ParticipantCsvExport export) =>
        const CsvToListConverter(shouldParseNumbers: false).convert(
          utf8.decode(export.bytes).replaceFirst('﻿', ''),
        );
    ParticipantCsvExport export(List<Participant> participants) =>
        buildParticipantCsv(
          event: event,
          participants: participants,
          checkIns: const [],
          exportedAt: DateTime(2026, 8, 8),
        );

    test('数式として解釈される先頭文字の氏名を無害化し、通常の氏名は変えない', () {
      final result = export([
        participant('p1', '=1+1'),
        participant('p2', '+SUM(A1:A2)'),
        participant('p3', '-1+1'),
        participant('p4', '@SUM(A1:A2)'),
        participant('p5', '\t=cmd'),
        participant('p6', '山田 太郎'),
      ]);
      final rows = parse(result);
      final names = {for (final row in rows.skip(1)) row[2]: row[1]};
      expect(names['p1@example.com'], "'=1+1");
      expect(names['p2@example.com'], "'+SUM(A1:A2)");
      expect(names['p3@example.com'], "'-1+1");
      expect(names['p4@example.com'], "'@SUM(A1:A2)");
      expect(names['p5@example.com'], "'\t=cmd");
      expect(names['p6@example.com'], '山田 太郎');
      expect(result.bytes.take(3), [0xef, 0xbb, 0xbf]);
    });

    test('氏名以外のユーザー由来列（メール）にも同じ処理が適用され、数値列は変わらない', () {
      final rows = parse(
        export([participant('p1', '山田 太郎', email: '=HYPERLINK@example.com')]),
      );
      expect(rows[1][2], "'=HYPERLINK@example.com");
      expect(rows[1][3], '2');
      expect(rows[0], contains('申込人数'));
    });

    test('CRで始まる値も無害化され、CSV上でテキストとして出力される', () {
      final text = utf8.decode(export([participant('p1', '\r=cmd')]).bytes);
      expect(text, contains("'\r=cmd"));
    });

    test('無害化してもカンマ・引用符・改行を含む値は正しく読み込める', () {
      final rows = parse(
        export([
          participant('p1', '田中, "太郎"'),
          participant('p2', '=A1,B1'),
          participant('p3', '山田\n花子'),
        ]),
      );
      final names = {for (final row in rows.skip(1)) row[2]: row[1]};
      expect(names['p1@example.com'], '田中, "太郎"');
      expect(names['p2@example.com'], "'=A1,B1");
      expect(names['p3@example.com'], '山田\n花子');
    });

    test('neutralizeSpreadsheetFormulaは先頭文字だけを対象にし、文字列以外を変更しない', () {
      for (final value in ['=1+1', '+1', '-1', '@a', '\ta', '\ra']) {
        expect(neutralizeSpreadsheetFormula(value), "'$value");
      }
      for (final value in ['', '山田-太郎', 'a=b', ' =1', "'=1"]) {
        expect(neutralizeSpreadsheetFormula(value), value);
      }
      expect(neutralizeSpreadsheetFormula(2), 2);
      expect(neutralizeSpreadsheetFormula(null), isNull);
    });
  });
}
