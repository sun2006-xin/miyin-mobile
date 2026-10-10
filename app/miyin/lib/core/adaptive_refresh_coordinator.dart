import 'dart:async';

/// Requests the device's preferred high refresh rate while the UI is active,
/// then returns control to Android after a short idle window.
class AdaptiveRefreshCoordinator {
  AdaptiveRefreshCoordinator({
    required Future<void> Function(bool active) requestHighRefresh,
    this.idleDelay = const Duration(milliseconds: 1200),
  }) : _setHighRefresh = requestHighRefresh;

  final Future<void> Function(bool active) _setHighRefresh;
  final Duration idleDelay;

  Timer? _idleTimer;
  bool _highRefreshActive = false;
  bool _disposed = false;

  void onActivitySignal(String signal) {
    if (_disposed) return;

    if (signal == 'active') {
      _idleTimer?.cancel();
      _idleTimer = null;
      _setActive(true);
    } else if (signal == 'idle') {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleDelay, () {
        _idleTimer = null;
        _setActive(false);
      });
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _setActive(false);
  }

  /// Immediately returns refresh-rate selection to Android's normal policy.
  void returnToSystemPolicy() {
    if (_disposed) return;
    _idleTimer?.cancel();
    _idleTimer = null;
    _setActive(false);
  }

  void _setActive(bool active) {
    if (_highRefreshActive == active) return;
    _highRefreshActive = active;
    unawaited(_setHighRefresh(active));
  }
}
