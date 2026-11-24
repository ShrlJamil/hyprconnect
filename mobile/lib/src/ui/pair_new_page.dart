//! Pair a new device: every discovered device that is not paired yet.
//! Tapping one opens its device page, where the connect button sends
//! the pairing request (see device_page.dart).

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../protocol/protocol.dart';
import 'app_state.dart';
import 'device_page.dart';

class PairNewPage extends StatelessWidget {
  final AppState appState;

  /// The home navigation drawer, when pushed from it: the page then
  /// keeps the hamburger instead of a back arrow, like KDE Connect.
  final Widget? drawer;

  const PairNewPage({super.key, required this.appState, this.drawer});

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
        title: Text(context.l10n.pairNewDevice),
      ),
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
                ListTile(
                  title: Text(context.l10n.noDeviceOnNetwork),
                  subtitle: Text(context.l10n.sameWifiHint),
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
    final l = context.l10n;
    final status = !entry.online
        ? l.statusOffline
        : conn == null
        ? l.statusDiscovered
        : paired
        ? l.statusConnectedPaired
        : pendingIn
        ? l.statusPairRequestCheckKey
        : l.statusConnectedUnpaired;
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
