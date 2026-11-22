//! Pair a new device: every discovered device that is not paired yet.
//! Tapping one opens its device page, where the connect button sends
//! the pairing request (see device_page.dart).

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';
import 'device_page.dart';

class PairNewPage extends StatelessWidget {
  final AppState appState;

  const PairNewPage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sandingkan peranti baru')),
      body: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final candidates = appState.entries
              .where((entry) => !entry.trusted && entry.online)
              .toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (candidates.isEmpty)
                const ListTile(
                  title: Text('Belum ada perangkat di jaringan ini'),
                  subtitle: Text(
                    'Pastikan desktop dan HP berada di Wi-Fi yang sama.',
                  ),
                ),
              for (final entry in candidates)
                _DiscoveredRow(
                  entry: entry,
                  appState: appState,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) =>
                            DevicePage(appState: appState, entry: entry),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DiscoveredRow extends StatelessWidget {
  final DeviceListEntry entry;
  final AppState appState;
  final VoidCallback onTap;

  const _DiscoveredRow({
    required this.entry,
    required this.appState,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final conn = appState.connectionFor(entry.deviceId);
    final paired = conn?.isPaired ?? false;
    final pendingIn = conn != null && conn.pairState == PairState.pendingIn;
    final status = !entry.online
        ? 'Luring'
        : conn == null
        ? 'Ditemukan'
        : paired
        ? 'Terhubung, paired'
        : pendingIn
        ? 'Minta pairing, cek kunci'
        : 'Terhubung, belum dipair';
    return Card(
      child: ListTile(
        leading: Icon(
          entry.deviceType.contains('phone')
              ? Icons.smartphone
              : Icons.desktop_windows,
          size: 32,
        ),
        title: Text(entry.name.isEmpty ? entry.deviceId : entry.name),
        subtitle: Text('${entry.deviceType} - $status'),
        trailing: pendingIn
            ? const Icon(Icons.mark_email_unread, color: Colors.orange)
            : null,
        onTap: onTap,
      ),
    );
  }
}
