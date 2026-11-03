import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Polls native automatic-update state while the app is visible.
///
/// Network checks and large downloads run in Android background workers. This
/// service only brings system install authorization and confirmation back to
/// the app UI when Android requires user action.
class AutomaticUpdateService {
  static const MethodChannel _channel = MethodChannel(
    'com.miyin.app/automatic-update',
  );

  Timer? _timer;
  void Function(Map<String, Object?> state)? _onState;
  bool _checking = false;

  Future<void> start(void Function(Map<String, Object?> state) onState) async {
    if (!Platform.isAndroid) return;
    _onState = onState;
    await refresh();
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    if (!Platform.isAndroid || _checking) return;
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
    if (!Platform.isAndroid) return false;
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
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scheduleCheck');
    } on PlatformException {
      // Native background scheduling remains available on the next launch.
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _onState = null;
  }
}
