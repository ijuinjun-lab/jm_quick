import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../models/demo_models.dart';
import '../services/demo_repository.dart';
import '../widgets/common.dart';

class ReceptionPage extends StatefulWidget {
  const ReceptionPage({
    super.key,
    this.eventId,
    this.participantId,
    this.publicId,
  });
  final String? eventId;
  final String? participantId;
  final String? publicId;
  @override
  State<ReceptionPage> createState() => _ReceptionPageState();
}

class _ReceptionPageState extends State<ReceptionPage> {
  late final repository = DemoRepository(selectedEventId: widget.eventId);
  final countController = TextEditingController();
  Participant? participant;
  Object? loadError;
  bool loading = true;
  bool saving = false;
  int? lastShownCount;
  String? saveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      participant = await repository.resolveParticipant(
        widget.participantId,
        widget.publicId,
      );
      if (participant != null && participant!.eventId != widget.eventId) {
        participant = null;
        loadError = StateError('event-mismatch');
      }
      if (participant != null) {
        countController.text = '${participant!.registeredCount}';
      }
    } catch (error) {
      loadError = error;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    countController.dispose();
    super.dispose();
  }

  int? validCount() {
    final count = int.tryParse(countController.text.trim());
    return count != null && count >= 0 ? count : null;
  }

  Future<void> save({required bool update}) async {
    final count = validCount();
    if (count == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('実参加人数は0以上の整数で入力してください。')));
      return;
    }
    setState(() {
      saving = true;
      saveError = null;
    });
    try {
      if (update) {
        await repository.updateAttendedCount(participant!, count);
      } else {
        await repository.checkIn(
          participant: participant!,
          attendedCount: count,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(update ? '実参加人数を修正しました。' : '受付が完了しました。')),
        );
      }
    } on StateError catch (error, stackTrace) {
      _logSaveFailure(error, stackTrace, update: update);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('この参加者は既に受付済みです。')));
      }
    } on FirebaseException catch (error, stackTrace) {
      _logSaveFailure(error, stackTrace, update: update);
      final detail =
          'Firebase保存エラー\n'
          'code: ${error.code}\n'
          'message: ${error.message ?? '詳細メッセージなし'}';
      if (mounted) {
        setState(() => saveError = detail);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(detail),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } catch (error, stackTrace) {
      _logSaveFailure(error, stackTrace, update: update);
      final detail =
          'コード上の保存エラー\n'
          'type: ${error.runtimeType}\n'
          'message: $error';
      if (mounted) {
        setState(() => saveError = detail);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(detail),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _logSaveFailure(
    Object error,
    StackTrace stackTrace, {
    required bool update,
  }) {
    final targetParticipantId = participant?.id ?? widget.participantId;
    debugPrint('=== JM Quick 受付保存失敗 ===');
    debugPrint(
      'operation: ${update ? 'attendedCount update' : 'initial check-in'}',
    );
    debugPrint('Firestore path: checkIns/$targetParticipantId');
    debugPrint('participantId: $targetParticipantId');
    debugPrint('publicId: ${participant?.publicId ?? widget.publicId}');
    if (error is FirebaseException) {
      debugPrint('FirebaseException.code: ${error.code}');
      debugPrint('FirebaseException.message: ${error.message}');
      debugPrint('FirebaseException.plugin: ${error.plugin}');
    } else {
      debugPrint('exception type: ${error.runtimeType}');
      debugPrint('exception: $error');
    }
    debugPrintStack(stackTrace: stackTrace);
  }

  @override
  Widget build(BuildContext context) =>
      PageFrame(title: '受付画面', child: _body());

  Widget _body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (loadError != null) return ErrorPanel(loadError!);
    if (participant == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('有効な受付用QRコードまたはリンクから開いてください。'),
        ),
      );
    }
    return StreamBuilder<CheckIn?>(
      stream: repository.watchCheckIn(participant!.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) return ErrorPanel(snapshot.error!);
        final checkIn = snapshot.data;
        final checkedIn = checkIn?.checkedIn ?? false;
        if (checkedIn && checkIn?.attendedCount != lastShownCount && !saving) {
          lastShownCount = checkIn?.attendedCount;
          countController.text = '${checkIn?.attendedCount ?? 0}';
        }
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (checkedIn) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xfffff1cf),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      '受付済みです',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],
                Text(
                  '${participant!.name}様',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                InfoRow('申込人数', '${participant!.registeredCount}名'),
                InfoRow(
                  '参加予定確認',
                  participant!.reconfirmed ? '参加予定確認済み' : '参加予定未確認',
                ),
                InfoRow('受付状態', checkedIn ? '受付済み' : '未受付'),
                if (checkedIn)
                  InfoRow('前回受付日時', formatDateTime(checkIn?.checkedInAt)),
                if (checkedIn)
                  InfoRow('現在の実参加人数', '${checkIn?.attendedCount ?? 0}名'),
                const SizedBox(height: 16),
                if (saveError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xffffe8e8),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xffb42318)),
                    ),
                    child: SelectableText(
                      saveError!,
                      style: const TextStyle(color: Color(0xff8a1c13)),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: countController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: checkedIn ? '実参加人数を修正' : '実参加人数',
                    suffixText: '名',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: saving ? null : () => save(update: checkedIn),
                  child: Text(checkedIn ? '実参加人数を修正' : '受付する'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
