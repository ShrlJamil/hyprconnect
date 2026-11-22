//! About page, reached from the drawer like in KDE Connect Android.

import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tentang')),
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
              const Text('Versi 1.0.0'),
              const SizedBox(height: 16),
              const Text(
                'Aplikasi pendamping daemon HyprConnect di desktop. '
                'Memakai protokol KDE Connect, jadi tetap bisa '
                'berkomunikasi dengan KDE Connect bawaan di desktop '
                'maupun HP lain.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text('Lisensi GPL-3.0-or-later'),
            ],
          ),
        ),
      ),
    );
  }
}
