// Phase 11F: JM Quickのトップ(https://jm-quick.web.app/ を直接開いた場合)の導線不具合の修正。
//
// ■ 何が起きていたか: main.dartのルーティング表(onGenerateRoute)には '/' に一致するcaseが無かった。
//   一致しないURLはすべて catch-all の _HomePage(「お探しのページは見つかりませんでした。」)へ落ちる。
//   '/' もこのcatch-allに落ちていたため、トップページが実質的な404画面になっていた
//   (未知のURLと '/' が区別されておらず、同じ画面が出ていた)。
// ■ 修正: '/' を、新方式(confirmed)の正式入口である '/console' と同じ画面(ConfirmedConsolePage)にした。
//   ConfirmedConsolePageの内部(AuthGate)が、未ログインならログイン画面、ログイン済みならサーバーが
//   確認したロール(admin/staff)に応じた機能を自動的に出し分ける。新しい画面は増やしていない(最小変更)。
//
// ■ このテストの構成: main.dartの`resolveRoute(Uri)`(onGenerateRouteの本体を切り出した純粋関数)を直接呼び、
//   結果のWidgetの型だけを確認する。Widgetをbuild(pumpWidget)すると各画面がFirebaseへ実際に触れてしまい、
//   このテスト環境(Firebase未初期化)では失敗するため、意図的にbuildしない(型の確認だけで足りる)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/confirmed_event_list_page.dart';
import 'package:jm_quick/confirmed/console_page.dart';
import 'package:jm_quick/confirmed/event_create_page.dart';
import 'package:jm_quick/confirmed/import_page.dart';
import 'package:jm_quick/confirmed/pass_page.dart';
import 'package:jm_quick/confirmed/qr_scanner_page.dart';
import 'package:jm_quick/confirmed/reception_route.dart';
import 'package:jm_quick/main.dart';
import 'package:jm_quick/pages/legacy_admin_gate.dart';
import 'package:jm_quick/pages/walk_in_page.dart';

Widget _resolve(String path) => resolveRoute(Uri.parse(path));

void main() {
  group('JM Quickのトップ(/)', () {
    test('/ はNot Found(catch-all)にならない。/consoleと同じConfirmedConsolePageになる', () {
      final root = _resolve('/');
      expect(root, isA<ConfirmedConsolePage>());
      expect(root.runtimeType, _resolve('/console').runtimeType);
    });

    test('/ ?eventId=… でもConfirmedConsolePage(eventIdはConsole同様に内部で引き継ぐ)', () {
      final page = _resolve('/?eventId=ev1') as ConfirmedConsolePage;
      expect(page.initialEventId, 'ev1');
    });
  });

  group('管理者・受付スタッフの導線(URL→画面の型の対応)', () {
    test('/console → 管理トップ(ConfirmedConsolePage、eventId未指定)', () {
      final page = _resolve('/console') as ConfirmedConsolePage;
      expect(page.initialEventId, isNull);
    });

    test('/console/events → confirmedイベント一覧(ConfirmedEventListRoute)', () {
      expect(_resolve('/console/events'), isA<ConfirmedEventListRoute>());
    });

    test('/console?eventId=… → 選択イベントの管理画面(ConfirmedConsolePage、eventId付き)', () {
      final page = _resolve('/console?eventId=ev404dfc7') as ConfirmedConsolePage;
      expect(page.initialEventId, 'ev404dfc7');
    });

    test('/console/import?eventId=… → CSV取込(ConfirmedImportRoute、eventId引き継ぎ)', () {
      final page = _resolve('/console/import?eventId=ev1') as ConfirmedImportRoute;
      expect(page.eventId, 'ev1');
    });

    test('/console/scan → QR scanner(ConfirmedScanReceptionRoute)', () {
      expect(_resolve('/console/scan'), isA<ConfirmedScanReceptionRoute>());
    });

    test('/console/scan?eventId=… → QR scanner(eventId引き継ぎ)', () {
      final page = _resolve('/console/scan?eventId=ev1') as ConfirmedScanReceptionRoute;
      expect(page.eventId, 'ev1');
    });

    test('/console/events/new → 新方式イベント作成(ConfirmedEventCreateRoute)', () {
      expect(_resolve('/console/events/new'), isA<ConfirmedEventCreateRoute>());
    });
  });

  group('既存の公開URL・受付URLは維持されている', () {
    test('/reception?… → ReceptionRoutePage(維持)', () {
      final page =
          _resolve('/reception?eventId=e1&participantId=p1&publicId=q1')
              as ReceptionRoutePage;
      expect(page.eventId, 'e1');
      expect(page.participantId, 'p1');
      expect(page.publicId, 'q1');
    });

    test('/p/{participantId} → PassRoutePage(維持)', () {
      final page = _resolve('/p/participant1?publicId=q1') as PassRoutePage;
      expect(page.participantId, 'participant1');
      expect(page.publicId, 'q1');
    });

    test('/admin・/demo-admin → 従来方式の管理画面(LegacyAdminGate。維持)', () {
      expect(_resolve('/admin'), isA<LegacyAdminGate>());
      expect(_resolve('/demo-admin'), isA<LegacyAdminGate>());
    });

    test('/admin/events/{id} → 従来方式のイベント管理(LegacyAdminGate。維持)', () {
      expect(_resolve('/admin/events/ev1'), isA<LegacyAdminGate>());
    });

    test('/e/{eventId}/walk-in → 当日参加登録(WalkInPage。維持)', () {
      final page = _resolve('/e/ev1/walk-in') as WalkInPage;
      expect(page.eventId, 'ev1');
    });
  });

  group('未知のURL', () {
    test('一致しないパスは引き続きNot Found(_HomePage相当)になる。/だけを特別扱いする', () {
      final unknown = _resolve('/no-such-page');
      expect(unknown, isNot(isA<ConfirmedConsolePage>()));
      expect(unknown.runtimeType, isNot(_resolve('/').runtimeType));
      // 未知のURL同士は同じ画面(_HomePage)になる(比較のため2回解決しても型が同じ)。
      expect(unknown.runtimeType, _resolve('/also-unknown').runtimeType);
    });
  });
}
