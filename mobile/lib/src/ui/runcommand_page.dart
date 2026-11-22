//! M3: run the desktop's predefined commands (kdeconnect.runcommand)
//! and watch their output stream back, upstream-style: a started
//! line, batched stdout/stderr lines, then a finished line with the
//! exit code. The stop button kills every command this phone started.

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';

class RunCommandPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const RunCommandPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  State<RunCommandPage> createState() => _RunCommandPageState();
}

class _RunCommandPageState extends State<RunCommandPage> {
  final _scroll = ScrollController();
  int _seenEvents = 0;

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _appState.requestRunCommands(_entry.deviceId);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeScrollToEnd(int eventCount) {
    if (eventCount == _seenEvents) return;
    _seenEvents = eventCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final commands = _appState.commandsFor(_entry.deviceId);
        final events = _appState.commandEventsFor(_entry.deviceId);
        final runningId = _appState.runningCommandIdFor(_entry.deviceId);
        final canAdd = _appState.canAddCommandFor(_entry.deviceId);
        _maybeScrollToEnd(events.length);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Jalankan Perintah'),
            actions: [
              IconButton(
                tooltip: 'Muat ulang daftar perintah',
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    _appState.requestRunCommands(_entry.deviceId),
              ),
              if (canAdd)
                IconButton(
                  tooltip: 'Ubah daftar di desktop',
                  icon: const Icon(Icons.edit),
                  onPressed: () =>
                      _appState.requestCommandSetup(_entry.deviceId),
                ),
            ],
          ),
          body: conn == null
              ? const Center(
                  child: Text('Tidak ada koneksi ke perangkat ini.'),
                )
              : Column(
                  children: [
                    if (commands.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Desktop belum punya perintah yang bisa dijalankan.\n'
                          'Tambah lewat editor di desktop.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      SizedBox(
                        height: 148,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: commands.length,
                          itemBuilder: (context, index) {
                            final command = commands[index];
                            final running = runningId != null;
                            return ListTile(
                              leading: const Icon(Icons.terminal),
                              title: Text(command.name),
                              subtitle: Text(
                                command.command,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: running
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow),
                              onTap: running
                                  ? null
                                  : () => _appState.runCommand(
                                        _entry.deviceId,
                                        command.key,
                                      ),
                            );
                          },
                        ),
                      ),
                    if (runningId != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.stop),
                            label: const Text('Hentikan perintah'),
                            onPressed: () =>
                                _appState.stopCommands(_entry.deviceId),
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: events.isEmpty
                          ? const Center(
                              child: Text(
                                'Belum ada perintah dijalankan.\n'
                                'Ketuk salah satu perintah di atas.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.all(12),
                              itemCount: events.length,
                              itemBuilder: (context, index) {
                                return _eventTile(events[index]);
                              },
                            ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _eventTile(RunCommandOutput event) {
    switch (event.kind) {
      case RunCommandOutput.started:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '\u25b6 Menjalankan: ${event.command ?? ''}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      case RunCommandOutput.output:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in event.stdoutLines)
              Text(line, style: const TextStyle(fontFamily: 'monospace')),
            for (final line in event.stderrLines)
              Text(
                line,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.red,
                ),
              ),
          ],
        );
      case RunCommandOutput.finished:
        final ok = event.success ?? false;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            ok
                ? 'Selesai (kode keluar ${event.exitCode ?? 0})'
                : 'Gagal (kode keluar ${event.exitCode ?? 1})',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: ok ? Colors.green : Colors.red,
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
