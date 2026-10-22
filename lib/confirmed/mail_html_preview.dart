import 'package:flutter/material.dart';

import 'mail_html_document.dart';
import 'mail_html_preview_stub.dart'
    if (dart.library.js_interop) 'mail_html_preview_web.dart'
    as platform;

class MailHtmlPreview extends StatelessWidget {
  const MailHtmlPreview({
    super.key,
    required this.html,
    required this.qrPngBase64,
    this.allowWithoutQr = false,
  });

  final bool allowWithoutQr;
  final String html;
  final String qrPngBase64;

  @override
  Widget build(BuildContext context) {
    try {
      final document = mailPreviewDocument(
        html,
        qrPngBase64,
        allowWithoutQr: allowWithoutQr,
      );
      return SizedBox(
        width: double.infinity,
        height: 700,
        child: platform.emailFrame(document),
      );
    } on FormatException catch (error) {
      return Text(
        error.message,
        style: const TextStyle(color: Color(0xffb42318)),
      );
    }
  }
}
