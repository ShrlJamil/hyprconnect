//! Plugin settings: defaults, persistence across reload, per-device
//! independence, and corrupt-file tolerance.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hyprconnect_mobile/src/settings/plugin_settings.dart';

final _deviceA = 'a' * 32;
final _deviceB = 'b' * 32;

Future<Directory> _tempDir() {
  return Directory.systemTemp.createTemp('hyprconnect-plugins-');
}

void main() {
  test('everything is enabled by default', () async {
    final dir = await _tempDir();
    try {
      final settings = await PluginSettings.load(dir);
      for (final plugin in pluginCatalog) {
        expect(settings.isEnabled(_deviceA, plugin.id), isTrue);
      }
      expect(settings.disabledPluginsFor(_deviceA), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a toggle persists across reload', () async {
    final dir = await _tempDir();
    try {
      final settings = await PluginSettings.load(dir);
      await settings.setEnabled(_deviceA, 'share', false);
      expect(settings.isEnabled(_deviceA, 'share'), isFalse);
      expect(settings.isEnabled(_deviceA, 'clipboard'), isTrue);

      final reloaded = await PluginSettings.load(dir);
      expect(reloaded.isEnabled(_deviceA, 'share'), isFalse);
      expect(reloaded.isEnabled(_deviceA, 'clipboard'), isTrue);

      await reloaded.setEnabled(_deviceA, 'share', true);
      final reloadedAgain = await PluginSettings.load(dir);
      expect(reloadedAgain.isEnabled(_deviceA, 'share'), isTrue);
      expect(reloadedAgain.disabledPluginsFor(_deviceA), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('settings are per device', () async {
    final dir = await _tempDir();
    try {
      final settings = await PluginSettings.load(dir);
      await settings.setEnabled(_deviceA, 'mpris', false);
      expect(settings.isEnabled(_deviceA, 'mpris'), isFalse);
      expect(settings.isEnabled(_deviceB, 'mpris'), isTrue);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('unknown plugin ids are ignored, corrupt file means empty', () async {
    final dir = await _tempDir();
    try {
      final settings = await PluginSettings.load(dir);
      await settings.setEnabled(_deviceA, 'tidak-ada', false);
      expect(settings.disabledPluginsFor(_deviceA), isEmpty);

      await File('${dir.path}/plugin_settings.json')
          .writeAsString('bukan json {');
      final reloaded = await PluginSettings.load(dir);
      expect(reloaded.disabledPluginsFor(_deviceA), isEmpty);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('catalog matches the daemon plugin list and order', () {
    expect(pluginCatalog.map((p) => p.id).toList(), [
      'clipboard',
      'share',
      'notification',
      'mpris',
      'systemvolume',
      'sftp',
      'presenter',
      'remoteinput',
      'battery',
      'findmyphone',
      'runcommand',
    ]);
    // The six device-page tiles each map to exactly one plugin.
    expect(deviceTiles.map((t) => t.pluginId).toList(), [
      'share',
      'clipboard',
      'presenter',
      'mpris',
      'remoteinput',
      'runcommand',
    ]);
  });
}
