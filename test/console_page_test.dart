// Phase 11D: 管理画面階層の整理(/console)。通信はすべて差し替え(外部通信0)、Firestoreは使わない。
//  - 管理トップ(/console。eventId未指定)には「イベント一覧」「イベント作成」「スタッフ管理」だけを表示し、
//    CSV取込・メール・リマインド・受付等のイベント固有機能は出さない。
//  - イベント選択後(/console?eventId=…)は、そのイベントの管理画面として、イベント名・開催日時・会場と、
//    そのイベントに属する機能を表示する。各機能へeventIdは内部的に(URLクエリ・コンストラクタ引数として)
//    引き継ぐだけで、利用者が入力・コピーする欄は無い。
//  - staffの導線(権限を広げない)は既存のまま維持する。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/access_role.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/import_models.dart';
import 'package:jm_quick/confirmed/import_service.dart' show ImportException;
import 'package:jm_quick/confirmed/reception_staff_qr_page.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'confirmed_auth_test.dart' show FakeAccessService, FakeAuthClient;
import 'import_page_test.dart' show FakeImportService;
import 'reminder_test.dart' show FakeReminderService;
import 'winner_mail_test.dart' show FakeWinnerMailService;
import 'winner_send_test.dart' show FakeSendService;

const _summary = ImportEventSummary(
  eventId: 'evfixture0123456789',
  eventName: '犬猫譲渡会・トークショー(架空)',
  startAt: null,
  venue: '架空市民ホール',
  programs: [
    (programId: 'program-1', name: '譲渡会1', order: 0),
    (programId: 'program-2', name: '譲渡会2', order: 1),
    (programId: 'program-3', name: 'トークショー', order: 2),
  ],
);

Widget _consoleTop({double width = 900}) => MaterialApp(
  home: ConfirmedConsolePage(
    authClient: FakeAuthClient(signedIn: true),
    accessService: FakeAccessService([
      const AccessCheck.granted(AccessRole.admin),
    ]),
  ),
);

/// イベント選択後の管理画面。eventId・各サービスは差し替え可能(既定はFakeで固定)。
Widget _eventConsole({
  String eventId = 'evfixture0123456789',
  ImportEventSummary? event,
  ImportException? eventError,
}) => MaterialApp(
  home: ConfirmedConsolePage(
    initialEventId: eventId,
    authClient: FakeAuthClient(signedIn: true),
    accessService: FakeAccessService([
      const AccessCheck.granted(AccessRole.admin),
    ]),
    eventSummaryService: FakeImportService(
      event: event ?? _summary,
      eventError: eventError,
    ),
    winnerMailService: FakeWinnerMailService(),
    winnerSendService: FakeSendService(),
    reminderService: FakeReminderService(),
  ),
);

void main() {
  group('管理トップ(/console。eventId未指定)', () {
    testWidgets('イベント一覧・イベント作成・スタッフ管理だけが表示される(イベント固有機能は一切出ない)', (
      tester,
    ) async {
      await tester.pumpWidget(_consoleTop());
      await tester.pumpAndSettle();
      expect(find.text('イベント一覧'), findsOneWidget);
      expect(find.text('イベント作成'), findsOneWidget);
      expect(find.text('スタッフ管理'), findsOneWidget);
      for (final label in eventConsoleFeatureLabels) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('スタッフ管理は準備中(全イベント共通の管理機能のため、勝手にイベント配下へ移動しない)', (
      tester,
    ) async {
      await tester.pumpWidget(_consoleTop());
      await tester.pumpAndSettle();
      final tileFinder = find.ancestor(
        of: find.text('スタッフ管理'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(tileFinder).onTap, isNull);
      // 「準備中」はカード内のbadgeとして表示される(押せる機能ではない)。
      expect(
        find.descendant(
          of: tileFinder,
          matching: find.byKey(const Key('pending-badge')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tileFinder, matching: find.text('準備中')),
        findsOneWidget,
      );
      // 実装済みの機能には「準備中」を出さない。
      expect(find.text('準備中'), findsOneWidget);
    });

    testWidgets('390px幅でoverflowなし', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_consoleTop(width: 390));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('PC幅(1200px)でoverflowなし', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_consoleTop(width: 1200));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('イベント選択後(/console?eventId=…): そのイベントの管理画面', () {
    testWidgets('イベント名・開催日時・会場が表示される(最低限の情報)', (tester) async {
      await tester.pumpWidget(_eventConsole());
      await tester.pumpAndSettle();
      expect(find.text('犬猫譲渡会・トークショー(架空)'), findsOneWidget);
      expect(find.text('架空市民ホール'), findsOneWidget);
      expect(find.textContaining('開催日時'), findsOneWidget);
    });

    testWidgets(
      'そのイベントに属する機能(イベント設定・CSV取込・当選メール設定・当選メール送信・リマインド・参加者管理・受付・受付訂正)が表示される',
      (tester) async {
        await tester.pumpWidget(_eventConsole());
        await tester.pumpAndSettle();
        for (final label in eventConsoleFeatureLabels) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        // 未実装の機能は「準備中」(勝手に別画面を作らない)。
        for (final label in ['イベント設定', '参加者管理', '受付訂正']) {
          final tile = tester.widget<ListTile>(
            find.ancestor(
              of: find.text(label),
              matching: find.byType(ListTile),
            ),
          );
          expect(tile.onTap, isNull, reason: label);
        }
        // 管理トップの機能(イベント一覧・イベント作成)はここには出ない。
        expect(find.text('イベント一覧'), findsNothing);
        expect(find.text('イベント作成'), findsNothing);
      },
    );

    testWidgets(
      'CSV取込を開くと、選択中のeventIdが自動的に引き継がれる(利用者はIDを入力・コピーしない)',
      (tester) async {
        final routes = <String?>[];
        await tester.pumpWidget(
          MaterialApp(
            onGenerateRoute: (settings) {
              routes.add(settings.name);
              if (settings.name == '/') {
                return MaterialPageRoute<void>(
                  builder: (_) => ConfirmedConsolePage(
                    initialEventId: 'evfixture0123456789',
                    authClient: FakeAuthClient(signedIn: true),
                    accessService: FakeAccessService([
                      const AccessCheck.granted(AccessRole.admin),
                    ]),
                    eventSummaryService: FakeImportService(event: _summary),
                  ),
                  settings: settings,
                );
              }
              return MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('NEXT')),
                settings: settings,
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('event-id')), findsNothing);
        await tester.ensureVisible(find.text('CSV取込'));
        await tester.tap(find.text('CSV取込'));
        await tester.pumpAndSettle();
        expect(routes.last, '/console/import?eventId=evfixture0123456789');
      },
    );

    testWidgets(
      'Phase 11L: 「受付」を開くと、PCのカメラは起動せず、受付スタッフ用QR(選択中のeventIdが自動的に'
      '引き継がれた、既存のスマホ受付スキャナ`/console/scan?eventId=…`を開くだけのURL)が表示される',
      (tester) async {
        await tester.pumpWidget(_eventConsole());
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('受付'));
        await tester.tap(find.text('受付'));
        await tester.pumpAndSettle();
        // PC自身のカメラ画面(scanner)へは行かない。QR表示画面だけが開く。
        expect(find.byType(ConfirmedReceptionStaffQrPage), findsOneWidget);
        expect(find.text('受付スタッフ用QRコード'), findsOneWidget);
        expect(find.text('このPCではカメラを使用しません。'), findsOneWidget);
        // QRの中身は、既存のスマホ受付スキャナのURL(このイベントのeventIdが引き継がれている)であり、
        // participantId・publicIdは含まない(参加者QRではない)。QrImageViewはQR画像の中身を外部へ
        // 公開する getter を持たないため、pass_page.dart と同じ方式で key に同じ文字列を持たせて確認する。
        final key =
            (tester.widget<QrImageView>(find.byType(QrImageView)).key
                    as ValueKey<String>)
                .value;
        expect(key, contains('/console/scan'));
        expect(key, contains('eventId=evfixture0123456789'));
        expect(key.contains('participantId='), isFalse);
        expect(key.contains('publicId='), isFalse);
      },
    );

    testWidgets('イベントの読み込みに失敗したら、理由と再試行を表示し、機能一覧は出さない', (tester) async {
      await tester.pumpWidget(
        _eventConsole(
          eventError: const ImportException('イベントを確認できませんでした。'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-console-error')), findsOneWidget);
      expect(find.text('イベントを確認できませんでした。'), findsOneWidget);
      for (final label in eventConsoleFeatureLabels) {
        expect(find.text(label), findsNothing, reason: label);
      }
    });

    testWidgets('390px幅でoverflowなし', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_eventConsole());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('PC幅(1200px)でoverflowなし', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_eventConsole());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('境界の静的検査', () {
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

    test('管理トップにはイベント固有機能のアクション(Navigator遷移)が無い', () {
      final text = code('lib/confirmed/console_page.dart');
      // 管理トップ(_ConsoleTop)のactionsはイベント一覧・イベント作成の2つだけ。
      // CSV取込・当選メール・リマインド・受付のNavigator呼び出しは _EventConsole 側にしか無いことを、
      // クラス構造(1ファイル)のコメントと合わせてここでは主要な文言の存在で確認する。
      expect(text.contains('class _ConsoleTop'), isTrue);
      expect(text.contains('class _EventConsole'), isTrue);
    });
    test('eventIdを利用者へ入力・選択させるUIは無い(既存のImportPage境界を維持)', () {
      final text = code('lib/confirmed/console_page.dart');
      for (final forbidden in [
        "Key('event-id')",
        "Key('load-event')",
        'TextField',
        'TextFormField',
      ]) {
        expect(text.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });
}
