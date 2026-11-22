//! HyprConnect mobile — M2: M1 shell plus file sharing and clipboard
//! (see lib/src/ui/share_page.dart and clipboard_page.dart). The
//! protocol foundation (identity, discovery, TLS, pairing, ping) is M0;
//! the remaining tiles' features land in M3-M5.

import 'package:flutter/material.dart';

import 'src/protocol/protocol.dart';
import 'src/ui/app_state.dart';
import 'src/ui/device_page.dart';

void main() {
  runApp(const HyprConnectApp());
}

class HyprConnectApp extends StatelessWidget {
  const HyprConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyprConnect',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    _appState.initialize();
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final identity = _appState.identity;
        final entries = _appState.entries;
        return Scaffold(
          appBar: AppBar(title: const Text('HyprConnect')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(Icons.smartphone, size: 36),
                  title: const Text('Perangkat ini'),
                  subtitle: identity == null
                      ? Text(_appState.status)
                      : SelectableText(
                          '${identity.deviceName}\n'
                          '${identity.deviceId}\n${_appState.status}',
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Perangkat (${entries.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (entries.isEmpty)
                const ListTile(
                  title: Text('Belum ada perangkat di jaringan ini'),
                  subtitle: Text(
                    'Pastikan desktop dan HP berada di Wi-Fi yang sama.',
                  ),
                ),
              for (final entry in entries)
                _DeviceRow(
                  entry: entry,
                  appState: _appState,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => DevicePage(
                          appState: _appState,
                          entry: entry,
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('Log'),
                children: [
                  Container(
                    height: 220,
                    padding: const EdgeInsets.all(8),
                    child: ListView(
                      children: [
                        for (final line in _appState.log)
                          Text(
                            line,
                            style: const TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final DeviceListEntry entry;
  final AppState appState;
  final VoidCallback onTap;

  const _DeviceRow({
    required this.entry,
    required this.appState,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final conn = appState.connectionFor(entry.deviceId);
    final paired = conn?.isPaired ?? false;
    final pendingIn =
        conn != null &&
        conn.pairState == PairState.pendingIn;
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
        title: Text(
          entry.name.isEmpty ? entry.deviceId : entry.name,
        ),
        subtitle: Text(
          '${entry.deviceType} - $status'
          '${entry.trusted && !paired ? ' - pernah dipair' : ''}',
        ),
        trailing: paired
            ? const Icon(Icons.check_circle, color: Colors.green)
            : pendingIn
            ? const Icon(Icons.mark_email_unread, color: Colors.orange)
            : null,
        onTap: onTap,
      ),
    );
  }
}
