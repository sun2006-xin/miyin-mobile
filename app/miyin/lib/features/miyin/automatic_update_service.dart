import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Polls native automatic-update state while the app is visible.
///
/// Network checks and large downloads run in Android background workers. This
/// service only brings system install authorization and confirmation back to
/// the app UI when Android requires user action.
class AutomaticUpdateService {
  AutomaticUpdateService({
    bool? isAndroid,
    Duration initialCheckDelay = const Duration(seconds: 20),
    Duration statusPollInterval = const Duration(seconds: 30),
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _initialCheckDelay = initialCheckDelay,
       _statusPollInterval = statusPollInterval;

  static const MethodChannel _channel = MethodChannel(
    'com.miyin.app/automatic-update',
  );

  final bool _isAndroid;
  final Duration _initialCheckDelay;
  final Duration _statusPollInterval;
  Timer? _timer;
  Timer? _startupCheck;
  void Function(Map<String, Object?> state)? _onState;
  bool _checking = false;

  Future<void> start(void Function(Map<String, Object?> state) onState) {
    if (!_isAndroid) return Future<void>.value();
    _onState = onState;
    // Let the first screen become usable before checking GitHub or touching
    // DownloadManager. The download itself remains managed by Android in the
    // background after this delayed, non-blocking check.
    _startupCheck ??= Timer(_initialCheckDelay, () {
      _startupCheck = null;
      unawaited(scheduleCheck());
    });
    _timer ??= Timer.periodic(_statusPollInterval, (_) {
      unawaited(refresh());
    });
    return Future<void>.value();
  }

  Future<void> refresh() async {
    if (!_isAndroid || _checking) return;
    _checking = true;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('status');
      if (raw == null) return;
      final state = <String, Object?>{
        for (final entry in raw.entries)
          if (entry.key is String) entry.key! as String: entry.value,
      };
      _onState?.call(state);
    } on MissingPluginException {
      // Older builds and non-Android hosts do not have the update channel.
    } on PlatformException {
      // The native host will retry on the next poll or app resume.
    } finally {
      _checking = false;
    }
  }

  Future<bool> openInstallPermissionSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openInstallPermissionSettings',
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> scheduleCheck() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scheduleCheck');
    } on PlatformException {
      // Native background scheduling remains available on the next launch.
    }
  }

  void dispose() {
    _startupCheck?.cancel();
    _startupCheck = null;
    _timer?.cancel();
    _timer = null;
    _onState = null;
  }
}
