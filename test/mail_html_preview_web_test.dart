@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:jm_quick/confirmed/mail_html_document.dart';
import 'package:jm_quick/confirmed/mail_html_preview_web.dart';
import 'package:web/web.dart' as web;

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH2kAAAAASUVORK5CYII=';
const html =
    '<!DOCTYPE html><html><head></head><body style="margin:0">'
    '<p style="margin:20px">メール全文</p><img width="240" height="240" src="cid:jm-quick-reception-qr">'
    '<a href="https://example.invalid/private">参加証</a>'
    '<script>parent.document.body.setAttribute("data-preview-script-ran","yes")</script>'
    '</body></html>';

void main() {
  for (final width in [390, 1280]) {
    test(
      'Real browser iframe at ${width}px: isolation, image and navigation protection',
      () async {
        final container = web.HTMLDivElement()
          ..style.width = '${width - 68}px'
          ..style.height = '700px';
        final frame = web.HTMLIFrameElement();
        final loaded = Completer<void>();
        frame.addEventListener(
          'load',
          ((web.Event _) {
            if (!loaded.isCompleted) loaded.complete();
          }).toJS,
        );
        configureEmailFrame(frame, mailPreviewDocument(html, png));
        container.append(frame);
        web.document.body!.append(container);
        addTearDown(() => container.remove());
        await loaded.future.timeout(const Duration(seconds: 5));
        expect(frame.getAttribute('sandbox'), '');
        expect(frame.referrerPolicy, 'no-referrer');
        expect(
          frame.contentDocument,
          isNull,
          reason: 'Opaque sandbox origin cannot access admin DOM/auth',
        );
        final document = (frame.srcdoc as JSString).toDart;
        expect(document, contains('<body inert '));
        expect(document, contains('data:image/png;base64,$png'));
        expect(document, contains('width="240" height="240"'));
        expect(document, contains('メール全文'));
        expect(
          web.document.body!.hasAttribute('data-preview-script-ran'),
          isFalse,
        );
        expect(frame.getBoundingClientRect().width, width - 68);
        expect(frame.getBoundingClientRect().height, 700);
      },
    );
  }
}
