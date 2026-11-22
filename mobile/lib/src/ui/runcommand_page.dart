//! M3: run the desktop's predefined commands (kdeconnect.runcommand)
//! and watch their output stream back. Restyled 2026-11-22 to the
//! stock app's run-command screen (his reference screenshot): a
//! console card on top that echoes every run as a green
//! dollar-prefixed line followed by its output, the command list
//! below with big bold names and the command string underneath, an
//! overflow menu for refresh and stop, and an edit FAB that asks
//! the desktop to open its own command editor (the setup request)
//! when the desktop says commands can be added.

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

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, textAlign: TextAlign.center),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        margin: const EdgeInsets.only(left: 48, right: 48, bottom: 24),
        duration: const Duration(seconds: 2),
      ),
    );
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
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Jalankan Perintah'),
                Text(_entry.name, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            actions: [
              PopupMenuButton<String>(
                tooltip: 'Menu',
                onSelected: (value) {
                  if (value == 'refresh') {
                    _appState.requestRunCommands(_entry.deviceId);
                  } else if (value == 'stop') {
                    _appState.stopCommands(_entry.deviceId);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'refresh',
                    child: Text('Muat ulang daftar'),
                  ),
                  if (runningId != null)
                    const PopupMenuItem(
                      value: 'stop',
                      child: Text('Hentikan perintah'),
                    ),
                ],
              ),
            ],
          ),
          body: conn == null
              ? const Center(child: Text('Tidak ada koneksi ke perangkat ini.'))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      Expanded(flex: 5, child: _consoleCard(events)),
                      const SizedBox(height: 12),
                      Expanded(
                        flex: 6,
                        child: _commandList(commands, runningId),
                      ),
                    ],
                  ),
                ),
          floatingActionButton: canAdd && conn != null
              ? FloatingActionButton(
                  tooltip: 'Ubah daftar perintah di desktop',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  onPressed: () {
                    _appState.requestCommandSetup(_entry.deviceId);
                    _toast('Membuka editor perintah di desktop');
                  },
                  child: const Icon(Icons.edit),
                )
              : null,
        );
      },
    );
  }

  /// The console card: one continuous session log. A run starts
  /// with its green dollar echo, output lines follow in the plain
  /// text colour (stderr in the error colour), and a finished event
  /// adds nothing, like the stock app.
  Widget _consoleCard(List<RunCommandOutput> events) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: events.isEmpty
          ? Center(
              child: Text(
                'Ketuk perintah di bawah untuk menjalankannya.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: events.length,
              itemBuilder: (context, index) => _consoleLine(events[index]),
            ),
    );
  }

  Widget _consoleLine(RunCommandOutput event) {
    final scheme = Theme.of(context).colorScheme;
    switch (event.kind) {
      case RunCommandOutput.started:
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            '\$ ${event.command ?? ''}',
            style: TextStyle(
              color: Colors.green.shade700,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
        );
      case RunCommandOutput.output:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in event.stdoutLines)
              Text(line, style: const TextStyle(fontSize: 15)),
            for (final line in event.stderrLines)
              Text(line, style: TextStyle(fontSize: 15, color: scheme.error)),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// The command list below the console: a big bold name with the
  /// command string muted underneath, nothing else. Tapping runs;
  /// while anything runs, taps wait and the running row spins.
  Widget _commandList(List<RunCommand> commands, int? runningId) {
    final scheme = Theme.of(context).colorScheme;
    if (commands.isEmpty) {
      return Center(
        child: Text(
          'Desktop belum punya perintah yang bisa dijalankan.\n'
          'Tambah lewat editor di desktop.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      itemCount: commands.length,
      itemBuilder: (context, index) {
        final command = commands[index];
        final running = runningId != null;
        return InkWell(
          onTap: running
              ? null
              : () => _appState.runCommand(_entry.deviceId, command.key),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        command.name,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        command.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (running)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
