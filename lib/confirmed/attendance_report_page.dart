import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/download_service.dart' as download;
import '../widgets/common.dart';
import 'attendance_report_service.dart';
import 'attendance_report_xlsx.dart';
import 'winner_send_service.dart';
import 'xlsx_writer.dart';

/// ファイルを保存させる処理(既定はブラウザのダウンロード。テストでは差し替える)。
typedef AttendanceReportSaver =
    void Function(Uint8List bytes, String fileName, String mimeType);

void _saveWithBrowser(Uint8List bytes, String fileName, String mimeType) =>
    download.downloadBytes(bytes, fileName, mimeType: mimeType);

/// イベント終了後の「最終実績Excel」の出力(`/console?eventId=…` のイベント管理画面から開く)。
/// システム管理者・このイベントのイベント管理者だけ(サーバー getConfirmedAttendanceReport も同じ権限で拒否する)。
/// サーバーから正本の明細を受け取り、Excelはブラウザ上で作って保存させる(サーバー・Storageに保存しない。URLも作らない)。
/// データは一切変更しない。
class AttendanceReportPage extends StatefulWidget {
  const AttendanceReportPage({
    super.key,
    required this.eventId,
    required this.eventName,
    required this.service,
    AttendanceReportSaver? saver,
    DateTime Function()? now,
  }) : saver = saver ?? _saveWithBrowser,
       now = now ?? DateTime.now;

  final String eventId;
  final String eventName;
  final AttendanceReportService service;
  final AttendanceReportSaver saver;
  final DateTime Function() now;

  @override
  State<AttendanceReportPage> createState() => _AttendanceReportPageState();
}

class _AttendanceReportPageState extends State<AttendanceReportPage> {
  bool busy = false;
  String? error;

  /// 直前に出力したファイル(ファイル名・件数だけ。明細は画面に残さない)。
  ({String fileName, int count})? done;

  Future<void> _export() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      done = null;
    });
    try {
      final report = await widget.service.getReport(widget.eventId);
      final file = buildAttendanceReportXlsx(report, exportedAt: widget.now());
      widget.saver(file.bytes, file.fileName, xlsxMimeType);
      if (mounted) {
        setState(
          () => done = (fileName: file.fileName, count: file.participantCount),
        );
      }
    } on WinnerSendException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'Excelを出力できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '最終実績Excel出力',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.eventName,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '参加者・受付結果をExcelで出力します。データは変更されません。',
              key: Key('final-report-description'),
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              '参加者全員(未来場の方を含む)について、取込回・氏名・かな・メールアドレス・HEBEL属性と、'
              'programごとの予定人数・予定時間・受付状況・実来場人数・受付時刻(日本時間)を1行ずつ出力します。',
            ),
            const SizedBox(height: 6),
            const Text(
              '個人情報を含むファイルです。保存先・共有先に注意してください(このファイルはサーバーには保存されません)。',
              style: TextStyle(color: Color(0xffb42318)),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('export-final-report'),
                onPressed: busy ? null : _export,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: const Text('最終実績Excelを出力'),
              ),
            ),
            if (done != null)
              Container(
                key: const Key('final-report-done'),
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                color: const Color(0xffeef3f8),
                child: Text('「${done!.fileName}」を出力しました(参加者${done!.count}名)。'),
              ),
            if (error != null)
              Container(
                key: const Key('final-report-error'),
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.all(12),
                color: const Color(0xffffe8e8),
                child: Text(error!),
              ),
          ],
        ),
      ),
    ),
  );
}
