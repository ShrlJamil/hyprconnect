//! Encryption info page (menu titik tiga > Info Enkripsi): what the
//! channel to this device actually is — TLS or not, whose certificates,
//! and the verification key the two sides compare when pairing.

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      appBar: AppBar(title: const Text('Info Enkripsi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                connected ? Icons.lock : Icons.lock_open,
                color: connected
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(
                connected
                    ? 'Koneksi terenkripsi (TLS)'
                    : 'Belum terhubung',
              ),
              subtitle: Text(
                connected
                    ? paired
                        ? 'Perangkat ini sudah dipair. Semua paket '
                            'berjalan di atas TLS dengan sertifikat '
                            'self-signed yang saling dikenali saat pairing.'
                        : 'Kanal TLS sudah naik, tapi perangkat ini belum '
                            'dipair. Pair dulu supaya sertifikatnya '
                            'dipercaya.'
                    : 'Hubungkan perangkat dulu untuk melihat detail '
                        'enkripsi kanal ini.',
              ),
            ),
          ),
          const SizedBox(height: 8),
          _Section(
            title: 'Perangkat ini',
            rows: [
              ('ID perangkat', identity?.deviceId ?? 'Belum dimuat'),
              (
                'Sidik jari sertifikat (SHA-256)',
                identity == null
                    ? 'Belum dimuat'
                    : _fingerprintHex(identity.certDer),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Section(
            title: entry.name.isEmpty ? 'Perangkat lawan' : entry.name,
            rows: [
              ('ID perangkat', entry.deviceId),
              (
                'Sidik jari sertifikat (SHA-256)',
                conn?.peerCertDer == null
                    ? 'Belum diketahui (belum terhubung)'
                    : _fingerprintHex(conn!.peerCertDer!),
              ),
              (
                'Kunci verifikasi',
                conn?.verificationKey ??
                    'Belum diketahui (muncul saat pairing)',
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              title: Text('Cara kerja pairing'),
              subtitle: Text(
                'Sertifikat dibuat sendiri oleh tiap perangkat dan '
                'tidak ditandatangani otoritas mana pun. Kepercayaan '
                'dibangun sekali saat pairing: kunci verifikasi di atas '
                'dihitung dari kunci publik kedua perangkat, dan kamu '
                'membandingkannya di kedua sisi sebelum menekan Terima. '
                'Setelah itu sertifikat lawan disimpan dan koneksi '
                'berikutnya otomatis terpercaya.',
              ),
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
                    tooltip: 'Salin',
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
