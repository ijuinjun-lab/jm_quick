import 'package:flutter/material.dart';

import '../services/demo_repository.dart';
import '../services/legacy_api.dart';
import '../widgets/common.dart';

/// 従来方式(legacy)の受付画面。受付スタッフ(staff)または管理者(admin)としてログインしている場合だけ表示される
/// (入口の ReceptionRoutePage が AuthGate で包む)。Phase 10C以降、Firestoreは直接読み書きせず、
/// サーバーの受付API(表示・受付・人数修正)を呼ぶ。QRのeventId・participantId・publicIdはサーバーが毎回再検証する。
class ReceptionPage extends StatefulWidget {
  const ReceptionPage({
    super.key,
    this.eventId,
    this.participantId,
    this.publicId,
    this.repository,
  });
  final String? eventId;
  final String? participantId;
  final String? publicId;

  /// テスト用。既定は認証つきの受付APIを使う。
  final DemoRepository? repository;
  @override
  State<ReceptionPage> createState() => _ReceptionPageState();
}

class _ReceptionPageState extends State<ReceptionPage> {
  late final repository =
      widget.repository ?? DemoRepository(selectedEventId: widget.eventId);
  final countController = TextEditingController();
  ReceptionView? view;
  Object? loadError;
  bool loading = true;
  bool saving = false;
  int? lastShownCount;
  String? saveError;

  bool get _hasKey =>
      (widget.eventId ?? '').isNotEmpty &&
      (widget.participantId ?? '').isNotEmpty &&
      (widget.publicId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool initial = true}) async {
    if (!_hasKey) {
      // 従来どおり「有効な受付用QRコードまたはリンクから開いてください」と案内する(通信しない)
      if (mounted) setState(() => loading = false);
      return;
    }
    try {
      final loaded = await repository.receptionView(
        widget.participantId!,
        widget.publicId!,
      );
      view = loaded;
      loadError = null;
      if (initial) {
        countController.text = '${loaded.registeredCount}';
      } else if (loaded.checkedIn && !saving) {
        lastShownCount = loaded.attendedCount;
        countController.text = '${loaded.attendedCount ?? 0}';
      }
    } catch (error) {
      // 受付できないQR(publicId不一致・別イベント・新方式・存在しない参加者)は、表示可能な同じ案内にする
      if (error is LegacyApiException &&
          (error.isFailedPrecondition || error.isNotFound)) {
        view = null;
      } else {
        loadError = error;
      }
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
        await repository.updateAttendedCountByKey(
          participantId: widget.participantId!,
          publicId: widget.publicId!,
          attendedCount: count,
        );
      } else {
        await repository.checkInByKey(
          participantId: widget.participantId!,
          publicId: widget.publicId!,
          attendedCount: count,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(update ? '実参加人数を修正しました。' : '受付が完了しました。')),
        );
      }
    } on StateError {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('この参加者は既に受付済みです。')));
      }
    } on LegacyApiException catch (error) {
      if (mounted) {
        setState(() => saveError = error.message);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.message),
            duration: const Duration(seconds: 10),
          ),
        );
      }
    } catch (error) {
      // 内部の情報(参加者ID・publicId・スタックトレース)は表示にもログにも出さない
      final detail = '保存できませんでした。もう一度お試しください。(${error.runtimeType})';
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
    // 受付・修正の結果(または既に受付済みだった場合の現在の状態)を、サーバーの値で表示し直す
    await _load(initial: false);
  }

  @override
  Widget build(BuildContext context) =>
      PageFrame(title: '受付画面', child: _body());

  Widget _body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (loadError != null) return ErrorPanel(loadError!);
    if (view == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('有効な受付用QRコードまたはリンクから開いてください。'),
        ),
      );
    }
    final current = view!;
    final checkedIn = current.checkedIn;
    return Builder(
      builder: (context) {
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
                  '${current.participantName}様',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                InfoRow('申込人数', '${current.registeredCount}名'),
                InfoRow('参加予定確認', current.reconfirmed ? '参加予定確認済み' : '参加予定未確認'),
                InfoRow('受付状態', checkedIn ? '受付済み' : '未受付'),
                if (checkedIn)
                  InfoRow('前回受付日時', formatDateTime(current.checkedInAt)),
                if (checkedIn)
                  InfoRow('現在の実参加人数', '${current.attendedCount ?? 0}名'),
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
