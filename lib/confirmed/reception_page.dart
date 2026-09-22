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
    this.adminService,
    this.onScanNext,
  });
  final ReceptionService service;

  /// 受付後の「人数を訂正」「受付を取り消す」(adminだけ)。null(staff)なら、これらの操作は描画しない。
  /// 認可はサーバーが必ず検証する(この画面での非表示だけに依存しない)。
  final ReceptionAdminService? adminService;
  final String eventId;
  final String participantId;
  final String publicId;
  final Future<void> Function()? signOut;

  /// QRカメラスキャナー(Phase 11C)から開かれた場合だけ渡される。「次のQRを読み取る」ボタンを表示し、
  /// 押すとscanner側へ戻る(トップ画面まで戻らない)。null(/reception への直接アクセス)なら何も表示しない。
  final VoidCallback? onScanNext;

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

  // そのprogramのカードだけを、サーバーが確定した内容へ更新する(他のprogramは変更しない)。
  void _applyProgram(String programId, ReceptionProgram updated) {
    view = ReceptionView(
      eventName: view!.eventName,
      participantName: view!.participantName,
      programs: [
        for (final p in view!.programs)
          if (p.programId == programId)
            ReceptionProgram(
              programId: p.programId,
              name: p.name,
              timeText: p.timeText,
              plannedCount: updated.plannedCount,
              checkedIn: updated.checkedIn,
              checkedInAt: updated.checkedInAt,
              attendedCount: updated.attendedCount,
            )
          else
            p,
      ],
    );
  }

  Future<void> _runAdminAction(
    ReceptionProgram program,
    Future<AttendanceChange> Function(ReceptionAdminService service) action,
    String Function(AttendanceChange result) successMessage,
  ) async {
    final admin = widget.adminService;
    if (admin == null || busy.contains(program.programId)) return;
    setState(() {
      busy.add(program.programId);
      programErrors.remove(program.programId);
      programNotices.remove(program.programId);
    });
    try {
      final result = await action(admin);
      if (!mounted) return;
      setState(() {
        _applyProgram(program.programId, result.program);
        if (!result.changed) {
          programNotices[program.programId] = result.noop == 'not-checked-in'
              ? 'すでに未受付です(変更はありません)。'
              : '変更はありません(すでに同じ人数です)。';
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage(result))));
    } on ReceptionException catch (e) {
      if (mounted) setState(() => programErrors[program.programId] = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => programErrors[program.programId] = '処理できませんでした。受付状況を確認してください。',
        );
      }
    } finally {
      if (mounted) setState(() => busy.remove(program.programId));
    }
  }

  // 人数の訂正(adminのみ)。予定人数は変わらず、実来場人数だけを訂正する。確認ダイアログで「現在 → 新しい人数」を確認する。
  Future<void> _correct(ReceptionProgram program) async {
    final current = program.attendedCount;
    if (current == null) return;
    final next = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CorrectionDialog(
        programName: program.name,
        plannedCount: program.plannedCount,
        currentCount: current,
      ),
    );
    if (next == null || !mounted) return;
    await _runAdminAction(
      program,
      (admin) => admin.correct(
        eventId: widget.eventId,
        participantId: widget.participantId,
        publicId: widget.publicId,
        programId: program.programId,
        attendedCount: next,
      ),
      (result) => result.changed
          ? '「${program.name}」の実来場人数を $current名 → $next名 に訂正しました。'
          : '「${program.name}」は変更ありません。',
    );
  }

  // 受付の取消(adminのみ・破壊的操作)。このprogramの受付記録だけを取り消す(参加者のキャンセルではない)。
  Future<void> _cancel(ReceptionProgram program) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('受付を取り消します'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('参加者：${view!.participantName} 様'),
            Text('program：${program.name}'),
            Text('現在の実来場人数：${program.attendedCount ?? '-'}名'),
            const SizedBox(height: 10),
            const Text(
              'このprogramの受付を取り消します',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xffb42318),
              ),
            ),
            const Text(
              '(参加者のキャンセルではありません。他のprogramの受付は変わりません。取り消した後は、もう一度受付できます。)',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffb42318),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('この受付を取り消す'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runAdminAction(
      program,
      (admin) => admin.cancel(
        eventId: widget.eventId,
        participantId: widget.participantId,
        publicId: widget.publicId,
        programId: program.programId,
      ),
      (result) => result.changed
          ? '「${program.name}」の受付を取り消しました。'
          : '「${program.name}」はすでに未受付です。',
    );
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '受付',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _body(),
        // 初期読み込み中(まだ何も表示できていない)は出さない。それ以外(成功・エラーのいずれも)は常に次へ進める。
        if (widget.onScanNext != null && !(loading && view == null)) ...[
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('scan-next'),
            onPressed: widget.onScanNext,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('次のQRを読み取る'),
          ),
        ],
      ],
    ),
  );

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
            // 受付状態が変わったら(取消→未受付 など)カードの状態(入力欄の初期値)を作り直す
            key: ValueKey('${program.programId}-${program.checkedIn}'),
            program: program,
            busy: busy.contains(program.programId),
            notice: programNotices[program.programId],
            error: programErrors[program.programId],
            onCheckIn: (count) => _checkIn(program, count),
            onCorrect: widget.adminService == null
                ? null
                : () => _correct(program),
            onCancel: widget.adminService == null
                ? null
                : () => _cancel(program),
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
    this.onCorrect,
    this.onCancel,
    this.notice,
    this.error,
  });
  final ReceptionProgram program;
  final bool busy;
  final String? notice;
  final String? error;
  final void Function(int count) onCheckIn;

  /// adminだけ(staffにはnull=ボタンを描画しない)。受付済みのprogramにだけ表示する。
  final VoidCallback? onCorrect;
  final VoidCallback? onCancel;

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
              if (widget.onCorrect != null && widget.onCancel != null) ...[
                const SizedBox(height: 12),
                // 通常の操作(人数の訂正)と、破壊的な操作(受付の取消)は、間隔と見た目を分けて誤操作を避ける
                OutlinedButton(
                  onPressed: widget.busy ? null : widget.onCorrect,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Text('人数を訂正'),
                  ),
                ),
                const SizedBox(height: 20),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xffb42318),
                  ),
                  onPressed: widget.busy ? null : widget.onCancel,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('受付を取り消す'),
                  ),
                ),
              ],
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

/// 人数訂正の確認ダイアログ。予定人数・現在の実来場人数・新しい実来場人数を確認でき、「○名 → ○名」が表示される。
/// 現在と同じ人数・範囲外では確定できない(変更なしの訂正は送らない)。予定人数は訂正の対象ではない。
class _CorrectionDialog extends StatefulWidget {
  const _CorrectionDialog({
    required this.programName,
    required this.plannedCount,
    required this.currentCount,
  });
  final String programName;
  final int plannedCount;
  final int currentCount;

  @override
  State<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<_CorrectionDialog> {
  late final controller = TextEditingController(text: '${widget.currentCount}');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  int? get value {
    final n = int.tryParse(controller.text.trim());
    return n != null && n >= 1 && n <= maxAttendedCount ? n : null;
  }

  @override
  Widget build(BuildContext context) {
    final next = value;
    final changed = next != null && next != widget.currentCount;
    return AlertDialog(
      title: const Text('実来場人数を訂正'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.programName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text('予定人数：${widget.plannedCount}名(変わりません)'),
            Text('現在の実来場人数：${widget.currentCount}名'),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '新しい実来場人数',
                suffixText: '名',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              next == null
                  ? '1〜$maxAttendedCount名の整数で入力してください。'
                  : changed
                  ? '${widget.currentCount}名 → $next名'
                  : '変更がありません(現在と同じ人数です)。',
              key: const ValueKey('correction-arrow'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: next == null ? const Color(0xffb42318) : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('やめる'),
        ),
        FilledButton(
          onPressed: changed ? () => Navigator.of(context).pop(next) : null,
          child: const Text('訂正する'),
        ),
      ],
    );
  }
}
