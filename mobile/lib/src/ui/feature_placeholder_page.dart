//! Placeholder for a device-page tile whose feature lands in a later
//! phase (M2-M5). The tile still opens something honest instead of
//! doing nothing: what the feature will do, and when it arrives.

import 'package:flutter/material.dart';

class FeaturePlaceholderPage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String phase;
  final String description;

  const FeaturePlaceholderPage({
    super.key,
    required this.icon,
    required this.title,
    required this.phase,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 32),
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          Center(
            child: Chip(label: Text('Hadir di fase $phase')),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Kembali'),
          ),
        ],
      ),
    );
  }
}
