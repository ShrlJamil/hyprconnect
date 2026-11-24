//! Navigation drawer, mirroring KDE Connect Android: a header with
//! this device, the paired devices under "Peranti" with the pill
//! highlight on the selected device, then pair-new-device, settings
//! and about.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'about_page.dart';
import 'app_state.dart';
import 'pair_new_page.dart';
import 'settings_page.dart';

class AppDrawer extends StatelessWidget {
  final AppState appState;
  final String? selectedDeviceId;
  final ValueChanged<String> onSelectDevice;

  const AppDrawer({
    super.key,
    required this.appState,
    required this.selectedDeviceId,
    required this.onSelectDevice,
  });

  bool _isPaired(DeviceListEntry entry) {
    final conn = appState.connectionFor(entry.deviceId);
    return entry.trusted || (conn?.isPaired ?? false);
  }

  void _push(BuildContext context, Widget page) {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(MaterialPageRoute<void>(builder: (context) => page));
  }

  @override
  Widget build(BuildContext context) {
    final identity = appState.identity;
    final pairedDevices = appState.entries
        .where(_isPaired)
        .where(
          (entry) =>
              entry.online ||
              (appState.connectionFor(entry.deviceId)?.isConnected ?? false),
        )
        .toList();
    final colorScheme = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.smartphone, size: 40, color: colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'HyprConnect',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          identity?.deviceName ?? '...',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                context.l10n.devices,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ),
            for (final entry in pairedDevices)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Material(
                  color: entry.deviceId == selectedDeviceId
                      ? colorScheme.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                  child: ListTile(
                    leading: Icon(
                      entry.deviceType.contains('phone')
                          ? Icons.smartphone
                          : Icons.desktop_windows,
                    ),
                    title: Text(
                      entry.name.isEmpty ? entry.deviceId : entry.name,
                    ),
                    selected: entry.deviceId == selectedDeviceId,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelectDevice(entry.deviceId);
                    },
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: Text(context.l10n.pairNewDevice),
              onTap: () {
                final navigator = Navigator.of(context);
                navigator.pop();
                navigator.push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => PairNewPage(
                      appState: appState,
                      // The pair page keeps the drawer: picking a
                      // device there leaves the page and selects the
                      // device on the home page underneath.
                      drawer: AppDrawer(
                        appState: appState,
                        selectedDeviceId: selectedDeviceId,
                        onSelectDevice: (id) {
                          Navigator.of(pageContext).pop();
                          onSelectDevice(id);
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: Text(context.l10n.settings),
              onTap: () => _push(context, SettingsPage(appState: appState)),
            ),
            ListTile(
              leading: const Icon(Icons.info),
              title: Text(context.l10n.about),
              onTap: () => _push(context, const AboutPage()),
            ),
          ],
        ),
      ),
    );
  }
}
