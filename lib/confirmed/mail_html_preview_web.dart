import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

Widget emailFrame(String document) => HtmlElementView.fromTagName(
  // A changed response must create a new iframe, never retain the old person's
  // email. The key is private widget state, not a DOM attribute or log entry.
  key: ValueKey(document),
  tagName: 'iframe',
  onElementCreated: (element) =>
      configureEmailFrame(element as web.HTMLIFrameElement, document),
);

/// Applies isolation before inserting either HTML or the frame into the DOM.
void configureEmailFrame(web.HTMLIFrameElement frame, String document) {
  frame
    ..title = 'HTMLメール完成形'
    ..setAttribute('sandbox', '')
    ..referrerPolicy = 'no-referrer'
    ..setAttribute(
      'allow',
      "camera 'none'; microphone 'none'; geolocation 'none'",
    )
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.border = '0'
    ..style.display = 'block'
    ..srcdoc = document.toJS;
}
