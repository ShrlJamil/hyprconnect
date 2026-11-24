//! Plugin settings page (menu titik tiga > Pengesetan plugin): the
//! per-device on/off switches for the 11 plugins, in the daemon's
//! PLUGIN_NAMES order. Switching a plugin off greys out its tile on
//! the device page and drops its packet types from the capabilities
//! this phone advertises to that device on the next connection.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import '../settings/plugin_settings.dart';
import 'app_state.dart';
import 'plugin_text.dart';

class PluginSettingsPage extends StatelessWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const PluginSettingsPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.pluginSettingsTitle)),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final settings = appState.pluginSettings;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  context.l10n.pluginSettingsHeader(
                    entry.name.isEmpty ? entry.deviceId : entry.name,
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              for (final plugin in pluginCatalog) ...[
                SwitchListTile(
                  title: Text(pluginTitle(context.l10n, plugin.id)),
                  subtitle: Text(pluginDescription(context.l10n, plugin.id)),
                  value: settings.isEnabled(entry.deviceId, plugin.id),
                  onChanged: (enabled) {
                    appState.setPluginEnabled(
                      entry.deviceId,
                      plugin.id,
                      enabled,
                    );
                  },
                ),
                if (plugin.id == 'sftp') _sftpAccessTile(context),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The sftp plugin serves this phone's storage to the
  /// desktop, which needs the system's all-files access. The
  /// row sits next to the plugin's own switch and refreshes
  /// whenever this page rebuilds.
  Widget _sftpAccessTile(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<bool>(
      future: NativeBridge.hasAllFilesAccess(),
      builder: (context, snapshot) {
        final granted = snapshot.data ?? false;
        return ListTile(
          leading: const Icon(Icons.folder_shared_outlined),
          title: Text(l.sftpAccessTitle),
          subtitle: Text(
            granted ? l.sftpAccessGranted : l.sftpAccessMissing,
          ),
          trailing: granted ? null : const Icon(Icons.chevron_right),
          enabled: !granted,
          onTap: granted
              ? null
              : () => NativeBridge.openAllFilesAccessSettings(),
        );
      },
    );
  }
}
