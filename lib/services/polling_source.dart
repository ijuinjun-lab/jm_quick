import 'dart:async';

/// サーバーAPIの結果を、購読されている間だけ一定間隔で取得し直して配信する「Firestoreの購読(snapshots)の代わり」。
/// Phase 10Cで、従来方式の管理画面がFirestoreを直接購読する経路をなくし、認証つきのサーバーAPIに置き換えるために使う。
///  - 購読者がいない間は通信しない(最初の購読で即時に取得し、最後の購読が外れたら止める)
///  - 後から購読した側にも、最後に取得した値(またはエラー)をすぐ渡す
///  - 取得の重複実行はしない。失敗しても次の周期で再試行する(エラーは購読者へ流す)
///  - [refresh]で、操作の直後に手動で取り直せる
class PollingSource<T> {
  PollingSource(
    this._fetch, {
    this.interval = const Duration(seconds: 8),
    void Function()? onFirstListen,
  }) : _onFirstListen = onFirstListen;

  final Future<T> Function() _fetch;
  final Duration interval;
  final void Function()? _onFirstListen;

  final Set<MultiStreamController<T>> _listeners = {};
  Timer? _timer;
  bool _fetching = false;
  bool _hasValue = false;
  T? _last;
  Object? _lastError;
  bool _stale = false;

  late final Stream<T> stream = Stream<T>.multi((controller) {
    if (_hasValue) {
      controller.add(_last as T);
    } else if (_lastError != null) {
      controller.addError(_lastError!);
    }
    _listeners.add(controller);
    controller.onCancel = () {
      _listeners.remove(controller);
      if (_listeners.isEmpty) _stop();
    };
    if (_listeners.length == 1) {
      _onFirstListen?.call();
      _start();
    }
  }, isBroadcast: true);

  /// 最後に取得できた値(まだ無ければnull)。
  T? get latest => _hasValue ? _last : null;

  /// 取得済みの値があればそれを、無ければ1回取得して返す(失敗は例外)。
  Future<T> current() async {
    if (_hasValue && !_stale) return _last as T;
    return _run(rethrowErrors: true);
  }

  /// すぐに取り直す。購読者がいなくても最新の値を返す。
  Future<T> refresh() => _run(rethrowErrors: true);

  void _start() {
    _timer?.cancel();
    _run(rethrowErrors: false);
    _timer = Timer.periodic(interval, (_) => _run(rethrowErrors: false));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    // 購読者がいない間は値が古くなる。次の購読・currentでは取り直す。
    _stale = true;
  }

  Future<T> _run({required bool rethrowErrors}) async {
    if (_fetching) {
      // 実行中の取得が終わるのを待つ(重複して通信しない)
      while (_fetching) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (_hasValue && !_stale) return _last as T;
    }
    _fetching = true;
    try {
      final value = await _fetch();
      _last = value;
      _hasValue = true;
      _lastError = null;
      _stale = false;
      for (final listener in _listeners.toList()) {
        listener.add(value);
      }
      return value;
    } catch (error) {
      _lastError = error;
      for (final listener in _listeners.toList()) {
        listener.addError(error);
      }
      if (rethrowErrors) rethrow;
      return _last as T;
    } finally {
      _fetching = false;
    }
  }
}
