import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'reception_service.dart';

/// 実来場人数の上限(サーバーの上限と同じ)。
const maxAttendedCount = 999;

/// 受付時刻の表示(JST・HH:mm)。
String jstTime(DateTime at) {
  final jst = at.toUtc().add(const Duration(hours: 9));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(jst.hour)}:${two(jst.minute)}';
}

/// 新方式(confirmed)の受付画面(スマートフォン優先・staff/admin専用)。
/// 1人の参加者(QRは1つ)が参加するprogramを、programごとのカードで表示し、programごとに独立して受付する。
/// 受付済みのprogramには「受付する」ボタンを出さない。二重受付の防止は、サーバーのtransactionが正本。
/// 受付の前後の状態は、Firestoreを直接監視せず、callable経由で取得する。
class ConfirmedReceptionPage extends StatefulWidget {
  const ConfirmedReceptionPage({
    super.key,
    required this.service,
    required this.eventId,
    required this.participantId,
    required this.publicId,
    this.signOut,
  });
  final ReceptionService service;
  final String eventId;
  final String participantId;
  final String publicId;
  final Future<void> Function()? signOut;

  @override
  State<ConfirmedReceptionPage> createState() => _ConfirmedReceptionPageState();
}

class _ConfirmedReceptionPageState extends State<ConfirmedReceptionPage> {
  ReceptionView? view;
  bool loading = true;
  ReceptionException? loadError;
  final Set<String> busy = {};
  final Map<String, String> programNotices = {};
  final Map<String, String> programErrors = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final result = await widget.service.getView(
        eventId: widget.eventId,
        participantId: widget.participantId,
        publicId: widget.publicId,
      );
      if (mounted) {
        setState(() {
          view = result;
          programNotices.clear();
          programErrors.clear();
        });
      }
    } on ReceptionException catch (e) {
      if (mounted) setState(() => loadError = e);
    } catch (_) {
      if (mounted) {
        setState(
          () => loadError = const ReceptionException('処理に失敗しました。もう一度お試しください。'),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _checkIn(ReceptionProgram program, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('受付の確認'),
        content: Text('「${program.name}」を $count名で受付します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('受付する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      busy.add(program.programId);
      programErrors.remove(program.programId);
      programNotices.remove(program.programId);
    });
    try {
      final result = await widget.service.checkIn(
        eventId: widget.eventId,
        participantId: widget.participantId,
        publicId: widget.publicId,
        programId: program.programId,
        attendedCount: count,
      );
      if (!mounted) return;
      // 受付したprogramのカードだけを、サーバーが確定した内容へ更新する(他のprogramは変更しない)。
      setState(() {
        view = ReceptionView(
          eventName: view!.eventName,
          participantName: view!.participantName,
          programs: [
            for (final p in view!.programs)
              if (p.programId == program.programId)
                ReceptionProgram(
                  programId: p.programId,
                  name: p.name,
                  timeText: p.timeText,
                  plannedCount: result.program.plannedCount,
                  checkedIn: result.program.checkedIn,
                  checkedInAt: result.program.checkedInAt,
                  attendedCount: result.program.attendedCount,
                )
              else
                p,
          ],
        );
        if (result.alreadyCheckedIn) {
          programNotices[program.programId] = 'すでに受付済みです(先に受付された内容を表示しています)。';
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.alreadyCheckedIn
                ? '「${program.name}」はすでに受付済みです。'
                : '「${program.name}」を受付しました。',
          ),
        ),
      );
    } on ReceptionException catch (e) {
      if (mounted) setState(() => programErrors[program.programId] = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => programErrors[program.programId] = '受付できませんでした。受付状況を確認してください。',
        );
      }
    } finally {
      if (mounted) setState(() => busy.remove(program.programId));
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(title: '受付', child: _body());

  Widget _body() {
    if (loading && view == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (loadError != null && view == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                loadError!.notAllowed ? 'この参加証は受付できません。' : loadError!.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (loadError!.notAllowed)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'QRコードを確認し、受付できない場合は責任者へお声がけください。',
                    textAlign: TextAlign.center,
                  ),
                ),
              if (!loadError!.notAllowed) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: _load, child: const Text('再試行')),
              ],
            ],
          ),
        ),
      );
    }
    final current = view!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          current.eventName,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xff5c6670)),
        ),
        const SizedBox(height: 4),
        Text(
          '${current.participantName} 様',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        for (final program in current.programs) ...[
          _ProgramCard(
            key: ValueKey(program.programId),
            program: program,
            busy: busy.contains(program.programId),
            notice: programNotices[program.programId],
            error: programErrors[program.programId],
            onCheckIn: (count) => _checkIn(program, count),
          ),
          const SizedBox(height: 10),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: loading ? null : _load,
            child: const Text('最新の状態に更新'),
          ),
        ),
      ],
    );
  }
}

class _ProgramCard extends StatefulWidget {
  const _ProgramCard({
    super.key,
    required this.program,
    required this.busy,
    required this.onCheckIn,
    this.notice,
    this.error,
  });
  final ReceptionProgram program;
  final bool busy;
  final String? notice;
  final String? error;
  final void Function(int count) onCheckIn;

  @override
  State<_ProgramCard> createState() => _ProgramCardState();
}

class _ProgramCardState extends State<_ProgramCard> {
  // 実来場人数の初期値は予定人数(スタッフが実際の人数に変更できる。予定人数そのものは変わらない)。
  late final controller = TextEditingController(
    text: '${widget.program.plannedCount}',
  );
  String? inputError;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final count = int.tryParse(controller.text.trim());
    if (count == null || count < 1 || count > maxAttendedCount) {
      setState(() => inputError = '来場人数は1〜$maxAttendedCount名の整数で入力してください。');
      return;
    }
    setState(() => inputError = null);
    widget.onCheckIn(count);
  }

  @override
  Widget build(BuildContext context) {
    final program = widget.program;
    final time = program.timeText;
    return Card(
      color: program.checkedIn ? const Color(0xffe8f5ec) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              program.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (time != null && time.trim().isNotEmpty) Text(time),
            const SizedBox(height: 4),
            Text('予定人数 ${program.plannedCount}名'),
            const SizedBox(height: 10),
            if (program.checkedIn) ...[
              const Text(
                '受付済み',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xff067647),
                ),
              ),
              if (program.checkedInAt != null)
                Text('受付時刻 ${jstTime(program.checkedInAt!)}'),
              if (program.attendedCount != null)
                Text('実来場人数 ${program.attendedCount}名'),
            ] else ...[
              const Text(
                '未受付',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '来場人数',
                  suffixText: '名',
                ),
              ),
              if (inputError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    inputError!,
                    style: const TextStyle(color: Color(0xffb42318)),
                  ),
                ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: widget.busy ? null : _submit,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(widget.busy ? '受付中…' : '受付する'),
                ),
              ),
            ],
            if (widget.notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.notice!,
                  style: const TextStyle(color: Color(0xffb54708)),
                ),
              ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  widget.error!,
                  style: const TextStyle(color: Color(0xffb42318)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
