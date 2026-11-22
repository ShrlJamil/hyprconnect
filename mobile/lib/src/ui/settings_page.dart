//! Settings: this device's identity and status, where received files
//! land, and the session log (all previously shown on the home page).

import 'package:flutter/material.dart';

import 'app_state.dart';

class SettingsPage extends StatelessWidget {
  final AppState appState;

  const SettingsPage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan')),
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
                  title: const Text('Perangkat ini'),
                  subtitle: identity == null
                      ? Text(appState.status)
                      : SelectableText(
                          '${identity.deviceName}\n'
                          '${identity.deviceId}\n${appState.status}',
                        ),
                ),
              ),
              if (appState.receiveDirPath != null) ...[
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.folder, size: 36),
                    title: const Text('Folder file diterima'),
                    subtitle: SelectableText(appState.receiveDirPath!),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text('Log', style: Theme.of(context).textTheme.titleMedium),
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
