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
  /// Returns the native side's own report of what happened, or null
  /// when the bridge is unavailable.
  static Future<String?> startKeepAlive() async {
    try {
      return await _channel.invokeMethod<String>('startKeepAlive');
    } catch (_) {
      // No native side: nothing to start.
      return null;
    }
  }

  /// Whether the keep-alive service is running right now, and what
  /// it last recorded about itself (started, crashed, destroyed).
  /// This is the evidence that separates "the service never
  /// started" from "the vendor power manager killed it later".
  static Future<String?> keepAliveStatus() async {
    try {
      return await _channel.invokeMethod<String>('keepAliveStatus');
    } catch (_) {
      return null;
    }
  }

  /// Open the vendor autostart page (Xiaomi's HyperOS / MIUI keeps
  /// its own switch for background survival) or, failing that, this
  /// app's system details page. Returns false when neither opened.
  static Future<bool> openAutostartSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAutostartSettings') ??
          false;
    } catch (_) {
      return false;
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

  /// Open this app's page in the system notification settings,
  /// where the persistent (keep-alive) notification and the
  /// pairing notifications are switched on or off. This is the
  /// settings page's "Persistent notification" row.
  static Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } catch (_) {}
  }
}
