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

  /// This install's full version as "1.0.0+4" (version name plus
  /// build number), or null when the bridge is unavailable. The
  /// update checker compares it against the latest release tag.
  static Future<String?> appVersion() async {
    try {
      return await _channel.invokeMethod<String>('appVersion');
    } catch (_) {
      return null;
    }
  }

  /// Whether Android currently lets this app install packages
  /// (the per-app "install unknown apps" switch). True below
  /// Android 8, where no such switch exists.
  static Future<bool> canInstallPackages() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Open the system page where the user allows this app to
  /// install packages.
  static Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallPermissionSettings');
    } catch (_) {}
  }

  /// Hand an APK file to the system package installer. Returns
  /// false when the installer could not be opened.
  static Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>('installApk', {
            'path': path,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// The phone's current battery state as {level: 0-100,
  /// charging: bool}, or null when it cannot be read. The battery
  /// plugin answers kdeconnect.battery.request packets with this
  /// and reports changes with it.
  static Future<Map<String, dynamic>?> batteryStatus() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'batteryStatus',
      );
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return null;
    }
  }

  /// Copy a received file from the app's private staging folder
  /// into the public Download/HyprConnect folder through
  /// MediaStore, so it shows up in the file manager like a normal
  /// download. Returns the public display path (for example
  /// "Download/HyprConnect/name.ext"), or null when the export
  /// failed and the staged copy is the only one.
  static Future<String?> exportToDownloads(String path, String name) async {
    try {
      return await _channel.invokeMethod<String>('exportToDownloads', {
        'path': path,
        'name': name,
      });
    } catch (_) {
      return null;
    }
  }

  /// Whether the system grants this app access to all files,
  /// which the SFTP server needs to serve the shared storage.
  /// True below Android 11, where the broad access does not
  /// exist as a separate grant.
  static Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Open the system page where the user grants all-files
  /// access to this app.
  static Future<void> openAllFilesAccessSettings() async {
    try {
      await _channel.invokeMethod<void>('openAllFilesAccessSettings');
    } catch (_) {}
  }

  /// Start the embedded SFTP server that lets a paired desktop
  /// browse this phone's shared storage. Returns {port, user,
  /// password} for the kdeconnect.sftp parameter packet, or null
  /// when the server could not start.
  static Future<Map<String, dynamic>?> startSftpServer() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'startSftpServer',
      );
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return null;
    }
  }

  /// Stop the embedded SFTP server, if it is running.
  static Future<void> stopSftpServer() async {
    try {
      await _channel.invokeMethod<void>('stopSftpServer');
    } catch (_) {}
  }
}
