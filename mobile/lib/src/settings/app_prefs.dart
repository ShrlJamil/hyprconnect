//! App-wide preferences that do not belong to one device: the
//! theme choice, the devices added by IP, and whether the
//! first-run setup gate has been passed. Storage follows the
//! PluginSettings pattern: app_prefs.json in the app documents
//! directory, written through a temp file so a crash mid-write
//! cannot corrupt it. No secrets live here.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class AppPrefs extends ChangeNotifier {
  final Directory? _dir;
  ThemeMode _themeMode;
  final List<String> _manualAddresses;
  bool _setupComplete;
  int _lastUpdateCheckMillis;

  AppPrefs._(
    this._dir,
    this._themeMode,
    this._manualAddresses,
    this._setupComplete,
    this._lastUpdateCheckMillis,
  );

  /// Load from [dir]/app_prefs.json; defaults when the file is
  /// missing or corrupt (system theme, no manual devices, setup
  /// gate not yet passed).
  static Future<AppPrefs> load(Directory dir) async {
    await dir.create(recursive: true);
    var themeMode = ThemeMode.system;
    var addresses = <String>[];
    var setupComplete = false;
    var lastUpdateCheckMillis = 0;
    final file = File('${dir.path}/app_prefs.json');
    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        themeMode = switch (json['themeMode'] as String?) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
        final raw = json['manualAddresses'];
        if (raw is List) {
          addresses = raw.whereType<String>().toList();
        }
        setupComplete = json['setupComplete'] as bool? ?? false;
        lastUpdateCheckMillis =
            (json['lastUpdateCheckMillis'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // A corrupt prefs file falls back to the defaults; the
        // next change re-creates it.
      }
    }
    return AppPrefs._(
      dir,
      themeMode,
      addresses,
      setupComplete,
      lastUpdateCheckMillis,
    );
  }

  /// In-memory prefs (no persistence), for tests and previews.
  /// The setup gate counts as passed here so test shells are not
  /// blocked by it.
  factory AppPrefs.inMemory({bool setupComplete = true}) =>
      AppPrefs._(null, ThemeMode.system, <String>[], setupComplete, 0);

  ThemeMode get themeMode => _themeMode;

  /// Addresses added by hand on the "Add device by IP" page, in
  /// the order they were added.
  List<String> get manualAddresses => List.unmodifiable(_manualAddresses);

  /// Whether the first-run setup gate (battery exemption plus
  /// autostart) has been completed on this install.
  bool get setupComplete => _setupComplete;

  /// When the last automatic update check ran (epoch millis), so
  /// the check can throttle itself to about once a day.
  int get lastUpdateCheckMillis => _lastUpdateCheckMillis;

  Future<void> markUpdateChecked(int millis) async {
    _lastUpdateCheckMillis = millis;
    await _save();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _save();
  }

  Future<void> addManualAddress(String address) async {
    if (_manualAddresses.contains(address)) return;
    _manualAddresses.add(address);
    notifyListeners();
    await _save();
  }

  Future<void> removeManualAddress(String address) async {
    if (!_manualAddresses.remove(address)) return;
    notifyListeners();
    await _save();
  }

  Future<void> markSetupComplete() async {
    if (_setupComplete) return;
    _setupComplete = true;
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final dir = _dir;
    if (dir == null) return;
    final file = File('${dir.path}/app_prefs.json');
    final tmp = File('${dir.path}/app_prefs.json.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'themeMode': switch (_themeMode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
        'manualAddresses': _manualAddresses,
        'setupComplete': _setupComplete,
        'lastUpdateCheckMillis': _lastUpdateCheckMillis,
      }),
    );
    await tmp.rename(file.path);
  }
}
