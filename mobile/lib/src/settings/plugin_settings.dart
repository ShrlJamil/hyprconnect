//! Per-device plugin settings: which KDE Connect plugins are enabled
//! for one peer device. Mirrors the daemon's plugin model
//! (src/packet.rs PLUGIN_NAMES, same ids and order): the daemon filters
//! a disabled plugin out of the capabilities it advertises, and this
//! app does the same on the per-connection identity packet
//! (see Packet.identity, disabledPlugins). The UDP discovery broadcast
//! keeps advertising the full list; only the encrypted identity sent
//! over a channel to one peer carries that peer's filtered list.
//!
//! Storage: plugin_settings.json in the app documents directory,
//! {"<deviceId>": ["<disabled plugin id>", ...]}. Only disabled
//! plugins are stored; everything defaults to enabled. No secrets
//! live here, only on/off flags.

import 'dart:convert';
import 'dart:io';

/// One plugin the user can switch on or off for a device. Display
/// strings live in the ARB files now (English first, Indonesian
/// translation) and are resolved by plugin id in
/// lib/src/ui/plugin_text.dart.
class PluginInfo {
  /// Stable id, identical to the daemon's plugin names.
  final String id;

  /// Which build phase delivers the tile's feature, if it has one.
  final String? tilePhase;

  const PluginInfo({required this.id, this.tilePhase});
}

/// The plugin catalog, in the daemon's PLUGIN_NAMES order.
const List<PluginInfo> pluginCatalog = [
  PluginInfo(id: 'clipboard', tilePhase: 'M2'),
  PluginInfo(id: 'share', tilePhase: 'M2'),
  PluginInfo(id: 'notification'),
  PluginInfo(id: 'mpris', tilePhase: 'M3'),
  PluginInfo(id: 'systemvolume'),
  PluginInfo(id: 'sftp'),
  PluginInfo(id: 'presenter', tilePhase: 'M5'),
  PluginInfo(id: 'remoteinput', tilePhase: 'M4'),
  PluginInfo(id: 'battery'),
  PluginInfo(id: 'findmyphone'),
  PluginInfo(id: 'runcommand', tilePhase: 'M3'),
];

PluginInfo? pluginById(String id) {
  for (final plugin in pluginCatalog) {
    if (plugin.id == id) return plugin;
  }
  return null;
}

/// The six device-page tiles, in the order the M1 shell shows them.
/// Each tile is powered by one plugin.
const List<({String pluginId})> deviceTiles = [
  (pluginId: 'share'),
  (pluginId: 'clipboard'),
  (pluginId: 'presenter'),
  (pluginId: 'mpris'),
  (pluginId: 'remoteinput'),
  (pluginId: 'runcommand'),
];

class PluginSettings {
  final Directory? _dir;

  /// deviceId -> ids of disabled plugins.
  final Map<String, Set<String>> _disabled;

  PluginSettings._(this._dir, this._disabled);

  /// Load from [dir]/plugin_settings.json; empty when the file is
  /// missing or corrupt (all plugins enabled).
  static Future<PluginSettings> load(Directory dir) async {
    await dir.create(recursive: true);
    final disabled = <String, Set<String>>{};
    final file = File('${dir.path}/plugin_settings.json');
    if (await file.exists()) {
      try {
        final json =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        for (final entry in json.entries) {
          final list = (entry.value as List)
              .whereType<String>()
              .where((id) => pluginById(id) != null)
              .toSet();
          if (list.isNotEmpty) disabled[entry.key] = list;
        }
      } catch (_) {
        // A corrupt settings file is treated as empty; toggling a
        // plugin re-creates it.
      }
    }
    return PluginSettings._(dir, disabled);
  }

  /// In-memory settings (no persistence), for tests and previews.
  factory PluginSettings.inMemory() => PluginSettings._(null, {});

  bool isEnabled(String deviceId, String pluginId) {
    return !(_disabled[deviceId]?.contains(pluginId) ?? false);
  }

  /// Ids of the plugins disabled for [deviceId].
  Set<String> disabledPluginsFor(String deviceId) {
    return Set.of(_disabled[deviceId] ?? const <String>{});
  }

  Future<void> setEnabled(
    String deviceId,
    String pluginId,
    bool enabled,
  ) async {
    if (pluginById(pluginId) == null) return;
    final set = _disabled.putIfAbsent(deviceId, () => <String>{});
    if (enabled) {
      set.remove(pluginId);
      if (set.isEmpty) _disabled.remove(deviceId);
    } else {
      set.add(pluginId);
    }
    await _save();
  }

  Future<void> _save() async {
    final dir = _dir;
    if (dir == null) return;
    final file = File('${dir.path}/plugin_settings.json');
    final tmp = File('${dir.path}/plugin_settings.json.tmp');
    final json = <String, List<String>>{};
    for (final entry in _disabled.entries) {
      json[entry.key] = entry.value.toList()..sort();
    }
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename(file.path);
  }
}
