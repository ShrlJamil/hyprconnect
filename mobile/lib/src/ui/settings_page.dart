//! Settings, modelled on the stock KDE Connect settings page:
//! one flat list of rows. This device's name (editable), the
//! theme, the persistent notification, devices added by IP, the
//! log export, where received files land, and a closing note
//! pointing at the per-device plugin settings. Battery and
//! autostart no longer live here: they are the first-run setup
//! gate now (see setup_gate_page.dart).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import 'app_state.dart';
import 'manual_devices_page.dart';

class SettingsPage extends StatelessWidget {
  final AppState appState;

  /// The navigation drawer, when reached from it: the page then
  /// keeps the hamburger instead of a back arrow, like KDE Connect.
  final Widget? drawer;

  const SettingsPage({super.key, required this.appState, this.drawer});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: drawer,
      appBar: AppBar(
        leading: drawer == null
            ? null
            : Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: context.l10n.devices,
                  onPressed: () => Scaffold.of(context).openDrawer(),
                ),
              ),
        title: Text(context.l10n.settings),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([appState, appState.prefs]),
        builder: (context, _) {
          final l = context.l10n;
          final prefs = appState.prefs;
          return ListView(
            children: [
              ListTile(
                title: Text(l.deviceName),
                subtitle: Text(appState.identity?.deviceName ?? ''),
                onTap: appState.identity == null
                    ? null
                    : () => _editDeviceName(context),
              ),
              ListTile(
                title: Text(l.chooseTheme),
                subtitle: Text(
                  switch (prefs.themeMode) {
                    ThemeMode.light => l.themeLight,
                    ThemeMode.dark => l.themeDark,
                    ThemeMode.system => l.themeSystem,
                  },
                ),
                onTap: () => _chooseTheme(context),
              ),
              ListTile(
                title: Text(l.persistentNotification),
                subtitle: Text(l.persistentNotificationBody),
                onTap: () => NativeBridge.openNotificationSettings(),
              ),
              ListTile(
                title: Text(l.addDeviceByIp),
                subtitle: Text(
                  l.manualDevicesCount(prefs.manualAddresses.length),
                ),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) =>
                          ManualDevicesPage(appState: appState),
                    ),
                  );
                },
              ),
              ListTile(
                title: Text(l.exportLogs),
                subtitle: Text(l.exportLogsBody),
                onTap: () async {
                  final path = await appState.exportLog();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        path == null
                            ? l.exportLogsFailed
                            : l.exportLogsSaved(path),
                      ),
                    ),
                  );
                },
              ),
              if (appState.receiveDirPath != null)
                ListTile(
                  title: Text(l.receivedFilesFolder),
                  subtitle: Text(appState.receiveDirPath!),
                ),
              const Divider(),
              ListTile(
                title: Text(l.moreSettings),
                subtitle: Text(l.moreSettingsBody),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editDeviceName(BuildContext context) async {
    final l = context.l10n;
    final controller = TextEditingController(
      text: appState.identity?.deviceName ?? '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.deviceName),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(l.save),
          ),
        ],
      ),
    );
    if (name != null) await appState.setDeviceName(name);
  }

  Future<void> _chooseTheme(BuildContext context) async {
    final l = context.l10n;
    final current = appState.prefs.themeMode;
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.chooseTheme),
        children: [
          for (final option in <(ThemeMode, String)>[
            (ThemeMode.system, l.themeSystem),
            (ThemeMode.light, l.themeLight),
            (ThemeMode.dark, l.themeDark),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(option.$1),
              child: Row(
                children: [
                  Icon(
                    option.$1 == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  Text(option.$2),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) await appState.prefs.setThemeMode(picked);
  }
}
