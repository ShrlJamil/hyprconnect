//! Encryption info page (menu titik tiga > Info Enkripsi): what the
//! channel to this device actually is — TLS or not, whose certificates,
//! and the verification key the two sides compare when pairing.

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import 'app_state.dart';

String _fingerprintHex(List<int> der) {
  final digest = sha256.convert(der);
  final hex = digest.toString();
  final chunks = <String>[];
  for (var i = 0; i < hex.length; i += 4) {
    final end = i + 4 < hex.length ? i + 4 : hex.length;
    chunks.add(hex.substring(i, end));
  }
  return chunks.join(' ');
}

class EncryptionInfoPage extends StatelessWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const EncryptionInfoPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    final identity = appState.identity;
    final conn = appState.connectionFor(entry.deviceId);
    final connected = conn != null && conn.isConnected;
    final paired = conn?.isPaired ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.encryptionInfo)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                connected ? Icons.lock : Icons.lock_open,
                color: connected ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Text(
                connected
                    ? context.l10n.encryptedConnection
                    : context.l10n.notConnected,
              ),
              subtitle: Text(
                connected
                    ? paired
                          ? context.l10n.encryptionPairedBody
                          : context.l10n.encryptionUnpairedBody
                    : context.l10n.encryptionDisconnectedBody,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Section(
            title: context.l10n.thisDevice,
            rows: [
              (
                context.l10n.deviceIdLabel,
                identity?.deviceId ?? context.l10n.notLoaded,
              ),
              (
                context.l10n.certFingerprint,
                identity == null
                    ? context.l10n.notLoaded
                    : _fingerprintHex(identity.certDer),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Section(
            title: entry.name.isEmpty ? context.l10n.peerDevice : entry.name,
            rows: [
              (context.l10n.deviceIdLabel, entry.deviceId),
              (
                context.l10n.certFingerprint,
                conn?.peerCertDer == null
                    ? context.l10n.unknownNotConnected
                    : _fingerprintHex(conn!.peerCertDer!),
              ),
              (
                context.l10n.verificationKey,
                conn?.verificationKey ?? context.l10n.unknownUntilPairing,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: Text(context.l10n.howPairingWorksTitle),
              subtitle: Text(context.l10n.howPairingWorksBody),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final (label, value) in rows) ...[
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: SelectableText(value)),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: context.l10n.copy,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: value));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}
