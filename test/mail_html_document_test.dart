import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/mail_html_document.dart';
import 'package:jm_quick/confirmed/winner_mail_service.dart';

void main() {
  final png = base64Encode([137, 80, 78, 71, 13, 10, 26, 10, 0]);
  const html =
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body style="padding:20px"><p style="line-height:1.8">宛名<br>本文</p>'
      '<hr style="border-top:1px dotted #9ca3af;margin:20px 0">'
      '<img src="cid:jm-quick-reception-qr" width="240" height="240">'
      '<a href="https://example.invalid/p/id?publicId=pub_test">こちら</a>'
      'お申し込み日時：2026年10月01日 09:30</body></html>';

  test(
    'API HTML is retained verbatim; display changes only CID and security metadata',
    () {
      final model = WinnerMailPreview.fromJson({
        'ready': true,
        'html': html,
        'text': 'テキスト',
        'qrPngBase64': png,
      });
      expect(model.html, html);
      final displayed = mailPreviewDocument(model.html, model.qrPngBase64);
      expect(displayed.contains('cid:'), isFalse);
      expect(displayed.contains('data:image/png;base64,$png'), isTrue);
      final original = displayed
          .replaceFirst(mailPreviewSecurityHead, '')
          .replaceFirst('<body inert ', '<body ')
          .replaceAll(
            'data:image/png;base64,$png',
            'cid:jm-quick-reception-qr',
          );
      expect(
        original,
        html,
        reason:
            'Every layout, text, date, URL and image size byte is preserved',
      );
      expect(displayed, contains("script-src 'none'"));
      expect(displayed, contains("img-src data:"));
      expect(displayed, contains('no-referrer'));
    },
  );

  test(
    'Missing HTML, missing/invalid image and unexpected document fail visibly',
    () {
      for (final input in [
        ('', png),
        (html, ''),
        (html, 'not-base64'),
        (html, base64Encode([1, 2, 3])),
        ('<p>not a complete email</p>', png),
      ]) {
        expect(
          () => mailPreviewDocument(input.$1, input.$2),
          throwsFormatException,
        );
      }
    },
  );
}
