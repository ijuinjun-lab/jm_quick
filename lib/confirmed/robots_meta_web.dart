// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

const _marker = 'data-jm-quick-noindex';

/// 個人の参加証を検索エンジンに載せないための `<meta name="robots" content="noindex,nofollow">` を、
/// 参加証を表示している間だけ付ける(アプリ全体のindex.htmlは変更しない。離れると外す)。
void setNoIndex(bool enabled) {
  final head = html.document.head;
  if (head == null) return;
  final existing = head.querySelector('meta[$_marker]');
  if (!enabled) {
    existing?.remove();
    return;
  }
  if (existing != null) return;
  head.append(
    html.MetaElement()
      ..name = 'robots'
      ..content = 'noindex,nofollow'
      ..setAttribute(_marker, 'true'),
  );
}
