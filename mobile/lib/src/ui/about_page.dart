//! About page, reached from the drawer like in KDE Connect Android.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../platform/native_bridge.dart';
import 'update_dialog.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.about)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.devices,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'HyprConnect',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              FutureBuilder<String?>(
                future: NativeBridge.appVersion(),
                builder: (context, snapshot) => Text(
                  context.l10n.versionLabel(snapshot.data ?? '...'),
                ),
              ),
              const SizedBox(height: 16),
              Text(context.l10n.aboutBody, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const Text('Lisensi GPL-3.0-or-later'),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: () => checkUpdatesManually(context),
                icon: const Icon(Icons.system_update),
                label: Text(context.l10n.checkForUpdates),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
