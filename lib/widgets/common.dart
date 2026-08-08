import 'package:flutter/material.dart';

class PageFrame extends StatelessWidget {
  const PageFrame({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), backgroundColor: Colors.white),
    body: Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: child,
        ),
      ),
    ),
  );
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(color: Color(0xff5c6670))),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel(this.error, {super.key});
  final Object error;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'データを取得できませんでした。\n$error',
        style: const TextStyle(color: Colors.red),
      ),
    ),
  );
}

String formatDateTime(DateTime? date) {
  if (date == null) return '未設定';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}
