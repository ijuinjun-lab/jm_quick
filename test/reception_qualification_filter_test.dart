import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/attendance_report_service.dart';
import 'package:jm_quick/confirmed/reception_status_page.dart';
import 'package:jm_quick/confirmed/reception_status_csv.dart';

import 'qualification_change_test.dart' show Changes;

// Synthetic data and a service fake: any mutation is recorded, no Firebase client.
class FilterService extends Changes {
  @override
  Future<AttendanceReport> getReport(String eventId) async {
    reads++;
    return AttendanceReport.fromJson({
      'eventId': eventId,
      'programs': [
        {'programId': 'cat', 'name': '猫'},
        {'programId': 'dog', 'name': '犬'},
        {'programId': 'talk', 'name': 'トーク'},
      ],
      'participants': [
        for (final name in ['架空田中', '架空佐藤'])
          {
            'participantId': name == '架空田中' ? 'p1' : 'p2',
            'name': name,
            'status': 'active',
            'batchCommitted': true,
            'hebelResidence': {
              'category': name == '架空田中' ? 'hebelHaus' : 'none',
            },
            'programs': [
              {
                'programId': 'cat',
                'plannedCount': 1,
                'entitlementStatus': 'revoked',
              },
              {
                'programId': 'dog',
                'plannedCount': 2,
                'checkedIn': true,
                'attendedCount': 2,
                'checkedInAt': name == '架空田中'
                    ? '2026-10-24T01:00:00Z'
                    : '2026-10-24T02:00:00Z',
              },
              {'programId': 'talk', 'plannedCount': 3, 'checkedIn': false},
            ],
          },
      ],
    });
  }
}

void main() {
  for (final size in [const Size(1280, 900), const Size(390, 600)]) {
    testWidgets(
      'qualification display, combined filters, CSV and unchanged totals $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = FilterService();
        Uint8List? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: ReceptionStatusPage(
              eventId: 'event1',
              eventName: '架空イベント',
              service: service,
              now: () => DateTime.utc(2026, 10, 24, 3),
              csvSaver: (bytes, _, _) => saved = bytes,
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> show(String key) async {
          final f = find.byKey(Key(key));
          if (f.evaluate().isEmpty) {
            tester
                .state<ScrollableState>(
                  find
                      .descendant(
                        of: find.byKey(const Key('reception-status-scroll')),
                        matching: find.byType(Scrollable),
                      )
                      .first,
                )
                .position
                .jumpTo(0);
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(
              f,
              180,
              scrollable: find
                  .descendant(
                    of: find.byKey(const Key('reception-status-scroll')),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
          }
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
        }

        Future<void> choose(String key, String label) async {
          await show('reception-status-$key');
          await tester.tap(find.byKey(Key('reception-status-$key')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(label).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        Future<void> verify(List<String> expected) async {
          await show('reception-status-count');
          expect(find.text('表示中 ${expected.length}行 / 全6行'), findsOneWidget);
          expect(find.text('出力対象：${expected.length}行'), findsOneWidget);
          await show('reception-status-export-csv');
          final button = find.byKey(const Key('reception-status-export-csv'));
          if (expected.isEmpty) {
            expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
          } else {
            await tester.tap(button);
            await tester.pumpAndSettle();
            await tester.pump(const Duration(seconds: 1));
            final table = const CsvToListConverter(
              eol: '\r\n',
            ).convert(utf8.decode(saved!.sublist(3)));
            final withRevoked = expected.any((r) => r.endsWith('/猫'));
            expect(table[11], [
              ...receptionStatusCsvHeaders,
              if (withRevoked) ...['資格の当選区分', '資格状態'],
            ]);
            final rows = table.skip(12).toList();
            expect(
              rows.every((r) => r.length == (withRevoked ? 10 : 8)),
              isTrue,
            );
            expect(rows.map((r) => '${r[0]}/${r[2]}').toList(), expected);
            expect(table[9][1], expected.length);
          }
          expect(service.reads, 1);
          expect(service.requests, isEmpty);
          expect(tester.takeException(), isNull);
        }

        Future<void> search(String value) async {
          await show('reception-status-search');
          await tester.enterText(
            find.byKey(const Key('reception-status-search')),
            value,
          );
          await tester.pumpAndSettle();
        }

        final active = ['架空田中/犬', '架空田中/トーク', '架空佐藤/犬', '架空佐藤/トーク'];
        await verify(active);
        await choose('qualification', '取消済みを含む');
        await verify([
          '架空田中/猫',
          ...active.take(2),
          '架空佐藤/猫',
          ...active.skip(2),
        ]);
        await choose('qualification', '取消済みのみ');
        await verify(['架空田中/猫', '架空佐藤/猫']);
        await search('田中');
        await verify(['架空田中/猫']);
        await choose('program', '犬');
        await verify([]);
        await choose('qualification', '取消済みを含む');
        await verify(['架空田中/犬']);
        await choose('state', '未受付');
        await verify([]);
        await choose('state', '受付済み');
        await search('');
        await choose('sort', '受付時刻(新しい順)');
        await verify(['架空佐藤/犬', '架空田中/犬']);
        await choose('hebel', '該当なし');
        await verify(['架空佐藤/犬']);
        await choose('qualification', '取消済みのみ');
        await verify([]);
        await choose('state', 'すべて');
        await choose('program', 'すべて');
        await verify(['架空佐藤/猫']);
        await choose('hebel', 'すべて');
        await choose('sort', '既定の順');
        await verify(['架空田中/猫', '架空佐藤/猫']);
        // Summary is always computed from the full report, regardless of display.
        for (final mode in ['取消済みのみ', '有効な資格のみ', '取消済みを含む']) {
          await choose('qualification', mode);
          await show('reception-status-view-summary');
          await tester.tap(
            find.byKey(const Key('reception-status-view-summary')),
          );
          await tester.pumpAndSettle();
          await show('total-planned');
          expect(
            find.descendant(
              of: find.byKey(const Key('total-planned')),
              matching: find.text('10名'),
            ),
            findsOneWidget,
          );
          await show('reception-status-view-list');
          await tester.tap(find.byKey(const Key('reception-status-view-list')));
          await tester.pumpAndSettle();
        }
        await choose('qualification', '取消済みのみ');
        final name = find.widgetWithText(TextButton, '架空田中').first;
        await tester.scrollUntilVisible(
          name,
          180,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('reception-status-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(name);
        await tester.pumpAndSettle();
        expect(find.text('参加資格の変更・取消'), findsOneWidget);
        expect(find.byKey(const Key('cancel-cat')), findsOneWidget);
        expect(service.requests, isEmpty);
        expect(service.reads, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
