//! Bridge to the Android side: the keep-alive foreground service,
//! pairing-request notifications, and the battery-optimization
//! exemption flow. Every call is best-effort: where the native side
//! does not exist (tests, other platforms) it silently does nothing.

import 'package:flutter/services.dart';

class NativeBridge {
  static const _channel = MethodChannel(
    'io.github.shrljamil.hyprconnect/native',
  );

  /// Start the foreground service that keeps this process (and with
  /// it discovery and the TCP listener) alive in the background.
  static Future<void> startKeepAlive() async {
    try {
      await _channel.invokeMethod<void>('startKeepAlive');
    } catch (_) {
      // No native side: nothing to start.
    }
  }

  /// Post a system notification for an incoming pairing request, so
  /// it is seen even when the app is not open on the device page.
  static Future<void> showPairingNotification({
    required String deviceName,
    required String deviceId,
  }) async {
    try {
      await _channel.invokeMethod<void>('showPairingNotification', {
        'deviceName': deviceName,
        'deviceId': deviceId,
      });
    } catch (_) {}
  }

  static Future<void> cancelPairingNotification(String deviceId) async {
    try {
      await _channel.invokeMethod<void>('cancelPairingNotification', {
        'deviceId': deviceId,
      });
    } catch (_) {}
  }

  /// True when the system already lets the app run without battery
  /// restrictions; false elsewhere (and on any error).
  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Ask the user to exempt the app from battery optimization. This
  /// must only be called from a user action.
  static Future<void> openBatteryOptimizationSettings() async {
    try {
      await _channel.invokeMethod<void>('openBatteryOptimizationSettings');
    } catch (_) {}
  }
}
