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

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../protocol/protocol.dart';
import '../settings/plugin_settings.dart';
import 'app_state.dart';
import 'encryption_info_page.dart';
import 'feature_placeholder_page.dart';
import 'multimedia_page.dart';
import 'runcommand_page.dart';
import 'remote_input_page.dart';
import 'plugin_settings_page.dart';
import 'plugin_text.dart';
import 'presenter_page.dart';

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

class DevicePage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  /// Drawer shown when this page is the app root (KDE Connect style
  /// sidebar navigation); null when pushed above another page.
  final Widget? drawer;

  /// True when this page is the root page: the app bar leads with the
  /// drawer button instead of a back button.
  final bool isRoot;

  const DevicePage({
    super.key,
    required this.appState,
    required this.entry,
    this.drawer,
    this.isRoot = false,
  });

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  /// A paired device that is in range connects on its own when its
  /// page opens; nobody should have to press Connect for a device
  /// the phone already knows. The attempt runs once per page.
  bool _autoConnectInFlight = false;
  bool _autoConnectTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  Future<void> _autoConnect() async {
    if (!mounted || _autoConnectTried) return;
    if (!_entry.trusted || !_entry.online) return;
    final conn = _appState.connectionFor(_entry.deviceId);
    if (conn != null && conn.isConnected) return;
    _autoConnectTried = true;
    setState(() => _autoConnectInFlight = true);
    await _appState.connectTo(_entry);
    if (mounted) setState(() => _autoConnectInFlight = false);
  }

  /// Toast-style notice, KDE Connect style: a floating rounded pill
  /// near the bottom of the screen instead of a full-width bar.
  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _connect() async {
    final outcome = await _appState.connectTo(_entry);
    if (!mounted) return;
    if (outcome == ConnectOutcome.failed) {
      _snack(context.l10n.connectFailed);
      return;
    }
    // One tap does the whole first pairing: with the channel up, ask
    // for pairing right away. The desktop then shows its accept
    // prompt with the same verification key this page displays.
    final conn = _appState.connectionFor(_entry.deviceId);
    if (conn != null &&
        !conn.isPaired &&
        conn.pairState == PairState.unpaired) {
      await _appState.requestPair(_entry.deviceId);
    }
  }

  Future<void> _confirmUnpair() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.unpairTitle),
        content: Text(context.l10n.unpairBody(_entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.unpair),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _appState.unpair(_entry.deviceId);
      if (mounted) _snack(context.l10n.unpaired);
    }
  }

  /// Kirim file, KDE Connect style: the tile opens the system file
  /// picker directly and the picked file is sent right away, with a
  /// progress dialog while it uploads and a snackbar when it lands.
  Future<void> _pickAndSendFile() async {
    final picked = await FilePicker.pickFile();
    if (picked == null || !mounted) return;
    final knownSize = await picked.length();
    final buffered = knownSize != null ? null : await picked.readAsBytes();
    final size = buffered?.length ?? knownSize ?? 0;
    final Stream<List<int>> bytes = buffered != null
        ? Stream<List<int>>.value(buffered)
        : picked.readAsByteStream();
    if (!mounted) return;
    final progress = ValueNotifier<double?>(0);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.sendingFile),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(picked.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 12),
              ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, child) =>
                    LinearProgressIndicator(value: value),
              ),
            ],
          ),
        ),
      ),
    );
    try {
      await _appState.sendFile(
        _entry.deviceId,
        filename: picked.name,
        size: size,
        bytes: bytes,
        onProgress: (sent) {
          progress.value = size == 0 ? 1 : sent / size;
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      _snack(context.l10n.fileSent(picked.name));
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _snack(context.l10n.fileSendFailed('$e'));
    }
  }

  /// Kirim papan klip, instant: send whatever text the phone
  /// clipboard currently holds and report with a snackbar. No page.
  Future<void> _sendClipboardNow() async {
    try {
      final text = await _appState.readClipboardText();
      if (!mounted) return;
      if (text == null || text.isEmpty) {
        _snack(context.l10n.clipboardEmpty);
        return;
      }
      final sent = await _appState.sendClipboard(_entry.deviceId, text);
      if (!mounted) return;
      _snack(sent ? context.l10n.clipboardSent : context.l10n.noConnection);
    } catch (e) {
      if (!mounted) return;
      _snack(context.l10n.clipboardSendFailed('$e'));
    }
  }

  void _onTileTap(String pluginId, String title) {
    final conn = _appState.connectionFor(_entry.deviceId);
    final paired = conn?.isPaired ?? false;
    if (!paired) {
      _snack(context.l10n.pairFirst(_entry.name, title));
      return;
    }
    if (!_appState.pluginSettings.isEnabled(_entry.deviceId, pluginId)) {
      _snack(context.l10n.pluginDisabledSnack(title));
      return;
    }
    if (pluginId == 'share') {
      unawaited(_pickAndSendFile());
      return;
    }
    if (pluginId == 'mpris') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) =>
              MultimediaPage(appState: _appState, entry: _entry),
        ),
      );
      return;
    }
    if (pluginId == 'runcommand') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) =>
              RunCommandPage(appState: _appState, entry: _entry),
        ),
      );
      return;
    }
    if (pluginId == 'remoteinput') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) =>
              RemoteInputPage(appState: _appState, entry: _entry),
        ),
      );
      return;
    }
    if (pluginId == 'clipboard') {
      unawaited(_sendClipboardNow());
      return;
    }
    if (pluginId == 'presenter') {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) =>
              PresenterPage(appState: _appState, entry: _entry),
        ),
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
          description: pluginDescription(context.l10n, pluginId),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final paired = conn?.isPaired ?? false;
        final pendingIn = conn?.pairState == PairState.pendingIn;
        final pendingOut = conn?.pairState == PairState.pendingOut;
        final connected = conn != null && conn.isConnected;
        final name = _entry.name.isEmpty ? _entry.deviceId : _entry.name;
        return Scaffold(
          drawer: widget.drawer,
          appBar: AppBar(
            title: Text(name),
            automaticallyImplyLeading: !widget.isRoot,
            leading: widget.isRoot
                ? Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu),
                      tooltip: context.l10n.devices,
                      onPressed: () => Scaffold.of(context).openDrawer(),
                    ),
                  )
                : null,
            actions: [
              PopupMenuButton<String>(
                tooltip: context.l10n.deviceMenu,
                onSelected: (value) async {
                  switch (value) {
                    case 'ping':
                      await _appState.sendPing(_entry.deviceId);
                      if (context.mounted) {
                        _snack(context.l10n.pingSent(name));
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
                    child: Text(context.l10n.sendPing),
                  ),
                  PopupMenuItem(
                    value: 'plugins',
                    child: Text(context.l10n.pluginSettingsTitle),
                  ),
                  PopupMenuItem(
                    value: 'encryption',
                    child: Text(context.l10n.encryptionInfo),
                  ),
                  PopupMenuItem(
                    value: 'unpair',
                    enabled: paired,
                    child: Text(context.l10n.unpair),
                  ),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
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
                          context.l10n.pairingRequest,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(context.l10n.pairingRequestBody),
                        const SizedBox(height: 12),
                        Center(
                          child: SelectableText(
                            conn.verificationKey ?? '-',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(letterSpacing: 4),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton(
                                onPressed: () =>
                                    _appState.requestPair(_entry.deviceId),
                                child: Text(context.l10n.accept),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    _appState.rejectPair(_entry.deviceId),
                                child: Text(context.l10n.reject),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (!connected && _entry.trusted) ...[
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: _autoConnectInFlight
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Icon(Icons.link_off),
                    title: Text(
                      _autoConnectInFlight
                          ? context.l10n.connecting
                          : _entry.online
                          ? context.l10n.sectionNotConnected
                          : context.l10n.deviceOffline,
                    ),
                    trailing: _entry.online && !_autoConnectInFlight
                        ? TextButton(
                            onPressed: _connect,
                            child: Text(context.l10n.connect),
                          )
                        : null,
                  ),
                ),
              ],
              if (!connected && !_entry.trusted) ...[
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _entry.online ? _connect : null,
                  child: Text(
                    _entry.online
                        ? context.l10n.connect
                        : context.l10n.deviceOffline,
                  ),
                ),
              ],
              if (pendingOut && conn != null) ...[
                const SizedBox(height: 8),
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.waitingForDesktop,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(context.l10n.waitingForDesktopBody),
                        const SizedBox(height: 12),
                        Center(
                          child: SelectableText(
                            conn.verificationKey ?? '-',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(letterSpacing: 4),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () =>
                              _appState.rejectPair(_entry.deviceId),
                          child: Text(context.l10n.cancelRequest),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              if (connected && !paired && !pendingIn && !pendingOut) ...[
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _appState.requestPair(_entry.deviceId),
                  child: Text(context.l10n.requestPairing),
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
                      title: pluginTileTitle(context.l10n, tile.pluginId),
                      enabled: _appState.pluginSettings.isEnabled(
                        _entry.deviceId,
                        tile.pluginId,
                      ),
                      onTap: () => _onTileTap(
                        tile.pluginId,
                        pluginTileTitle(context.l10n, tile.pluginId),
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

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool enabled;
  final VoidCallback onTap;

  const _FeatureTile({
    required this.icon,
    required this.title,
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
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
