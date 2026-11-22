//! About page, reached from the drawer like in KDE Connect Android.

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

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
              Text(context.l10n.versionLabel('1.0.0')),
              const SizedBox(height: 16),
              Text(context.l10n.aboutBody, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const Text('Lisensi GPL-3.0-or-later'),
            ],
          ),
        ),
      ),
    );
  }
}
