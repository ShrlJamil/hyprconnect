//! Device page, KDE Connect style: a status header, the two-column
//! tile grid (Kirim file, Kirim papan klip, Presentation remote,
//! Kendali multimedia, Masukan jarak jauh, Jalankan Perintah), and the
//! three-dot menu (Kirim ping, Pengesetan plugin, Info Enkripsi,
//! Leraikan).
//!
//! Tiles whose feature lands in a later phase open a placeholder page
//! that says so; tiles whose plugin is switched off explain that
//! instead. Nothing here sends a packet the daemon does not already
//! understand: ping and pair:false (unpair/reject) are core traffic.

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import '../settings/plugin_settings.dart';
import 'app_state.dart';
import 'encryption_info_page.dart';
import 'feature_placeholder_page.dart';
import 'plugin_settings_page.dart';

IconData _tileIcon(String pluginId) {
  return switch (pluginId) {
    'share' => Icons.file_upload,
    'clipboard' => Icons.content_paste,
    'presenter' => Icons.slideshow,
    'mpris' => Icons.music_note,
    'remoteinput' => Icons.mouse,
    'runcommand' => Icons.terminal,
    _ => Icons.extension,
  };
}

IconData _deviceIcon(String deviceType) {
  final type = deviceType.toLowerCase();
  if (type.contains('laptop')) return Icons.laptop;
  if (type.contains('phone')) return Icons.smartphone;
  if (type.contains('tablet')) return Icons.tablet;
  if (type.contains('tv')) return Icons.tv;
  return Icons.desktop_windows;
}

class DevicePage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const DevicePage({super.key, required this.appState, required this.entry});

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _connect() async {
    final outcome = await _appState.connectTo(_entry);
    if (!mounted) return;
    if (outcome == ConnectOutcome.needsDesktopPair) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Pairing pertama'),
          content: Text(
            'Perangkat ini belum dikenal. Pairing pertama harus dimulai '
            'dari desktop, jalankan di sana:\n\n'
            'hyprconnect pair ${_entry.deviceId}\n\n'
            'Setelah desktop meminta pairing, kunci verifikasi muncul di '
            'sini dan kamu bisa menekan Terima.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } else if (outcome == ConnectOutcome.failed) {
      _snack('Gagal terhubung. Cek log di halaman utama.');
    }
  }

  Future<void> _confirmUnpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leraikan pairing?'),
        content: Text(
          'Pairing dengan ${_entry.name} akan dilepas dan sertifikatnya '
          'dihapus dari HP ini. Untuk memakai perangkat ini lagi, '
          'pairing harus diulang dari awal.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Leraikan'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _appState.unpair(_entry.deviceId);
      if (mounted) _snack('Pairing dilepas.');
    }
  }

  void _onTileTap(String pluginId, String title) {
    final conn = _appState.connectionFor(_entry.deviceId);
    final paired = conn?.isPaired ?? false;
    if (!paired) {
      _snack('Pair dulu dengan ${_entry.name} untuk memakai $title.');
      return;
    }
    if (!_appState.pluginSettings.isEnabled(_entry.deviceId, pluginId)) {
      _snack(
        'Plugin $title nonaktif. Aktifkan di Pengesetan plugin.',
      );
      return;
    }
    final plugin = pluginById(pluginId);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FeaturePlaceholderPage(
          icon: _tileIcon(pluginId),
          title: title,
          phase: plugin?.tilePhase ?? '?',
          description: plugin?.description ?? '',
        ),
      ),
    );
  }

  String _statusText(DeviceConnection? conn) {
    if (conn == null) {
      return _entry.online
          ? 'Ditemukan, belum terhubung'
          : 'Luring, terakhir dikenal';
    }
    if (conn.isPaired) return 'Terhubung dan dipair';
    return switch (conn.pairState) {
      PairState.pendingIn => 'Menunggu jawaban pairing',
      PairState.pendingOut => 'Permintaan pairing terkirim',
      _ => 'Terhubung, belum dipair',
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final paired = conn?.isPaired ?? false;
        final pendingIn = conn?.pairState == PairState.pendingIn;
        final connected = conn != null && conn.isConnected;
        final name = _entry.name.isEmpty ? _entry.deviceId : _entry.name;
        return Scaffold(
          appBar: AppBar(
            title: Text(name),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Menu perangkat',
                onSelected: (value) async {
                  switch (value) {
                    case 'ping':
                      await _appState.sendPing(_entry.deviceId);
                      if (context.mounted) {
                        _snack('Ping terkirim ke $name.');
                      }
                    case 'plugins':
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => PluginSettingsPage(
                            appState: _appState,
                            entry: _entry,
                          ),
                        ),
                      );
                    case 'encryption':
                      if (!context.mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) => EncryptionInfoPage(
                            appState: _appState,
                            entry: _entry,
                          ),
                        ),
                      );
                    case 'unpair':
                      await _confirmUnpair();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'ping',
                    enabled: paired,
                    child: const Text('Kirim ping'),
                  ),
                  const PopupMenuItem(
                    value: 'plugins',
                    child: Text('Pengesetan plugin'),
                  ),
                  const PopupMenuItem(
                    value: 'encryption',
                    child: Text('Info Enkripsi'),
                  ),
                  PopupMenuItem(
                    value: 'unpair',
                    enabled: paired,
                    child: const Text('Leraikan'),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: ListTile(
                  leading: Icon(
                    _deviceIcon(_entry.deviceType),
                    size: 36,
                  ),
                  title: Text(name),
                  subtitle: Text(
                    '${_entry.deviceType}'
                    '${_entry.address == null ? '' : ' - ${_entry.address!.address}'}\n'
                    '${_statusText(conn)}',
                  ),
                  isThreeLine: true,
                ),
              ),
              if (pendingIn && conn != null) ...[
                const SizedBox(height: 8),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Permintaan pairing',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Desktop meminta pairing. Cocokkan kunci ini '
                          'dengan yang tampil di desktop, lalu tekan Terima.',
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: SelectableText(
                            conn.verificationKey ?? '-',
                            style: Theme.of(context)
                                .textTheme
                                .headlineMedium
                                ?.copyWith(letterSpacing: 4),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: () => _appState.requestPair(
                                  _entry.deviceId,
                                ),
                                child: const Text('Terima'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _appState.rejectPair(
                                  _entry.deviceId,
                                ),
                                child: const Text('Tolak'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (!connected) ...[
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _entry.online ? _connect : null,
                  child: Text(
                    _entry.online ? 'Hubungkan' : 'Perangkat luring',
                  ),
                ),
              ],
              if (connected && !paired && !pendingIn) ...[
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _appState.requestPair(_entry.deviceId),
                  child: const Text('Minta pairing'),
                ),
              ],
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
                children: [
                  for (final tile in deviceTiles)
                    _FeatureTile(
                      icon: _tileIcon(tile.pluginId),
                      title: tile.title,
                      subtitle:
                          _appState.pluginSettings.isEnabled(
                            _entry.deviceId,
                            tile.pluginId,
                          )
                          ? pluginById(tile.pluginId)?.description ?? ''
                          : 'Plugin nonaktif',
                      enabled: _appState.pluginSettings.isEnabled(
                        _entry.deviceId,
                        tile.pluginId,
                      ),
                      onTap: () => _onTileTap(tile.pluginId, tile.title),
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

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = enabled ? null : Theme.of(context).disabledColor;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 28,
                color: enabled ? colorScheme.primary : foreground,
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: foreground,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
