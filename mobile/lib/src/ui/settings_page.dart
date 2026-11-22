//! Settings: this device's identity and status, where received files
//! land, and the session log (all previously shown on the home page).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import 'app_state.dart';

class SettingsPage extends StatelessWidget {
  final AppState appState;

  const SettingsPage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settings)),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final identity = appState.identity;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.smartphone, size: 36),
                  title: Text(context.l10n.thisDevice),
                  subtitle: identity == null
                      ? Text(appState.status)
                      : SelectableText(
                          '${identity.deviceName}\n'
                          '${identity.deviceId}\n${appState.status}',
                        ),
                ),
              ),
              const SizedBox(height: 8),
              const _BatteryCard(),
              if (appState.receiveDirPath != null) ...[
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder, size: 36),
                    title: Text(context.l10n.receivedFilesFolder),
                    subtitle: SelectableText(appState.receiveDirPath!),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                context.l10n.log,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Container(
                height: 300,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView(
                  children: [
                    for (final line in appState.log)
                      Text(line, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Battery-optimization status: while the app is restricted, the
/// system can kill it in the background and the connection dies
/// with it. The button opens the system's own exemption dialog.
class _BatteryCard extends StatefulWidget {
  const _BatteryCard();

  @override
  State<_BatteryCard> createState() => _BatteryCardState();
}

class _BatteryCardState extends State<_BatteryCard> {
  late Future<bool> _unrestricted;

  @override
  void initState() {
    super.initState();
    _unrestricted = NativeBridge.isIgnoringBatteryOptimizations();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: FutureBuilder<bool>(
        future: _unrestricted,
        builder: (context, snapshot) {
          final unrestricted = snapshot.data ?? false;
          return ListTile(
            leading: const Icon(Icons.battery_saver, size: 36),
            title: Text(context.l10n.batteryOptimization),
            subtitle: Text(
              unrestricted
                  ? context.l10n.batteryUnrestricted
                  : context.l10n.batteryRestricted,
            ),
            trailing: unrestricted
                ? null
                : TextButton(
                    onPressed: () async {
                      await NativeBridge.openBatteryOptimizationSettings();
                      await Future<void>.delayed(
                        const Duration(seconds: 1),
                      );
                      if (mounted) {
                        setState(() {
                          _unrestricted =
                              NativeBridge.isIgnoringBatteryOptimizations();
                        });
                      }
                    },
                    child: Text(context.l10n.batteryAllow),
                  ),
          );
        },
      ),
    );
  }
}
