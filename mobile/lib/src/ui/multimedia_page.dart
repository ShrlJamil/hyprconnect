//! M3: control the desktop's media players (kdeconnect.mpris) and
//! its audio outputs (kdeconnect.systemvolume). The page asks for
//! the player list and the sink list on open; the daemon pushes
//! fresh state packets after every action, so the display follows
//! the desktop without polling. Album art, when the daemon offers
//! a file:// url, is pulled once and shown from the app's art dir.
//!
//! Layout follows the KDE Connect app: the "Putar" tab carries the
//! artwork, a player dropdown under it, the track title, a wide
//! play/pause button, a transport row (seek buttons join when the
//! player can seek), the seek bar with both times, and the player
//! volume. The "Peranti" tab is NOT a player picker: it lists the
//! desktop's audio outputs, the selected one being the default
//! sink, each with its own global volume slider. With no player
//! at all, Putar shows the same skeleton greyed out under a big
//! music note, like the stock app's empty state. Colours are the
//! app's own theme.

import 'dart:io';

import 'package:flutter/material.dart';

import '../protocol/protocol.dart';
import 'app_state.dart';

String _formatMs(int ms) {
  final total = ms ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class MultimediaPage extends StatefulWidget {
  final AppState appState;
  final DeviceListEntry entry;

  const MultimediaPage({
    super.key,
    required this.appState,
    required this.entry,
  });

  @override
  State<MultimediaPage> createState() => _MultimediaPageState();
}

class _MultimediaPageState extends State<MultimediaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  double? _dragPos;
  double? _dragVolume;
  final Map<String, double> _dragSinkVolumes = {};

  AppState get _appState => widget.appState;
  DeviceListEntry get _entry => widget.entry;

  @override
  void initState() {
    super.initState();
    _appState.requestMprisPlayers(_entry.deviceId);
    _appState.requestSinks(_entry.deviceId);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _refresh() {
    _appState.requestMprisPlayers(_entry.deviceId);
    _appState.requestSinks(_entry.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        final conn = _appState.connectionFor(_entry.deviceId);
        final players = _appState.playerListFor(_entry.deviceId);
        final selected = _appState.selectedPlayerFor(_entry.deviceId);
        final state = selected == null
            ? null
            : _appState.playerStateFor(_entry.deviceId, selected);
        final artPath = selected == null
            ? null
            : _appState.albumArtPathFor(_entry.deviceId, selected);
        final sinks = _appState.sinksFor(_entry.deviceId);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Kendali multimedia'),
                Text(
                  _entry.name,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Muat ulang',
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
              ),
            ],
            bottom: conn == null
                ? null
                : TabBar(
                    controller: _tabs,
                    tabs: const [
                      Tab(text: 'Putar'),
                      Tab(text: 'Peranti'),
                    ],
                  ),
          ),
          body: conn == null
              ? const Center(child: Text('Tidak ada koneksi ke perangkat ini.'))
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _playTab(players, selected, state, artPath),
                    _devicesTab(sinks),
                  ],
                ),
        );
      },
    );
  }

  // -------------------------------------------------------------------
  // Putar tab
  // -------------------------------------------------------------------

  Widget _playTab(
    List<String> players,
    String? selected,
    MprisPlayerState? state,
    String? artPath,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        children: [
          Expanded(
            child: state == null && players.isEmpty
                ? _emptyCentre(players)
                : _artwork(artPath),
          ),
          if (players.isNotEmpty) ...[
            _playerDropdown(players, selected),
            const SizedBox(height: 4),
          ],
          if (state != null) ...[_trackInfo(state), const SizedBox(height: 12)],
          _widePlayButton(state),
          const SizedBox(height: 12),
          _transportRow(state),
          if (state != null) ...[const SizedBox(height: 8), _seek(state)],
          const SizedBox(height: 8),
          _volumeRow(state),
        ],
      ),
    );
  }

  /// The empty state: a giant music note and the explanation, with
  /// the control skeleton below it disabled.
  Widget _emptyCentre(List<String> players) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.music_note,
          size: 180,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.35),
        ),
        const SizedBox(height: 24),
        Text(
          players.isEmpty
              ? 'Tidak ada pemutar yang ditemukan'
              : 'Menunggu status player dari desktop...',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _artwork(String? artPath) {
    final file = artPath == null ? null : File(artPath);
    final hasArt = file != null && file.existsSync();
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260, maxHeight: 260),
        width: 260,
        height: 260,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          image: hasArt
              ? DecorationImage(image: FileImage(file), fit: BoxFit.cover)
              : null,
        ),
        child: hasArt
            ? null
            : Icon(
                Icons.music_note,
                size: 120,
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.5),
              ),
      ),
    );
  }

  /// Pick the controlled player, under the artwork like the stock
  /// app (and the desktop panel) do it.
  Widget _playerDropdown(List<String> players, String? selected) {
    return SizedBox(
      width: double.infinity,
      child: DropdownButton<String>(
        value: players.contains(selected) ? selected : players.first,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        items: [
          for (final name in players)
            DropdownMenuItem(value: name, child: Text(name)),
        ],
        onChanged: (name) {
          if (name != null) {
            _appState.selectMprisPlayer(_entry.deviceId, name);
          }
        },
      ),
    );
  }

  Widget _trackInfo(MprisPlayerState state) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.title.isEmpty ? '(tanpa judul)' : state.title,
            style: theme.textTheme.titleLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          if (state.artist.isNotEmpty)
            Text(
              state.artist,
              style: theme.textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (state.album.isNotEmpty)
            Text(
              state.album,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _widePlayButton(MprisPlayerState? state) {
    final playing = state?.isPlaying ?? false;
    final enabled = state != null && (playing ? state.canPause : state.canPlay);
    return Tooltip(
      message: playing ? 'Jeda' : 'Putar',
      child: SizedBox(
        width: double.infinity,
        height: 64,
        child: FilledButton(
          onPressed: enabled
              ? () => _appState.sendMprisAction(
                  _entry.deviceId,
                  playing ? 'Pause' : 'Play',
                )
              : null,
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 32),
        ),
      ),
    );
  }

  Widget _transportRow(MprisPlayerState? state) {
    Widget button({
      required String tooltip,
      required IconData icon,
      required bool enabled,
      required VoidCallback action,
    }) {
      return Expanded(
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            height: 52,
            child: FilledButton.tonal(
              onPressed: enabled ? action : null,
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Icon(icon, size: 26),
            ),
          ),
        ),
      );
    }

    final canSeek = state?.canSeek ?? false;
    return Row(
      children: [
        button(
          tooltip: 'Sebelumnya',
          icon: Icons.skip_previous,
          enabled: state?.canGoPrevious ?? false,
          action: () => _appState.sendMprisAction(_entry.deviceId, 'Previous'),
        ),
        if (canSeek) ...[
          const SizedBox(width: 12),
          button(
            tooltip: 'Mundur 10 detik',
            icon: Icons.fast_rewind,
            enabled: true,
            action: () => _appState.seekMpris(_entry.deviceId, -10),
          ),
        ],
        const SizedBox(width: 12),
        button(
          tooltip: 'Berhenti',
          icon: Icons.stop,
          enabled: state != null,
          action: () => _appState.sendMprisAction(_entry.deviceId, 'Stop'),
        ),
        if (canSeek) ...[
          const SizedBox(width: 12),
          button(
            tooltip: 'Maju 10 detik',
            icon: Icons.fast_forward,
            enabled: true,
            action: () => _appState.seekMpris(_entry.deviceId, 10),
          ),
        ],
        const SizedBox(width: 12),
        button(
          tooltip: 'Berikutnya',
          icon: Icons.skip_next,
          enabled: state?.canGoNext ?? false,
          action: () => _appState.sendMprisAction(_entry.deviceId, 'Next'),
        ),
      ],
    );
  }

  /// Seek bar with the current time and the total flanking it.
  Widget _seek(MprisPlayerState state) {
    final length = state.lengthMs;
    final pos = _dragPos ?? state.posMs.toDouble();
    return Row(
      children: [
        SizedBox(width: 44, child: Text(_formatMs(pos.toInt()))),
        Expanded(
          child: Slider(
            value: length > 0 ? pos.clamp(0, length.toDouble()) : 0,
            max: length > 0 ? length.toDouble() : 1,
            onChanged: state.canSeek
                ? (value) => setState(() => _dragPos = value)
                : null,
            onChangeEnd: state.canSeek
                ? (value) {
                    setState(() => _dragPos = null);
                    _appState.setMprisPosition(_entry.deviceId, value ~/ 1000);
                  }
                : null,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(_formatMs(length), textAlign: TextAlign.right),
        ),
      ],
    );
  }

  Widget _volumeRow(MprisPlayerState? state) {
    final volume = _dragVolume ?? (state?.volume ?? 0).toDouble();
    final icon = volume <= 0
        ? Icons.volume_off
        : volume < 50
        ? Icons.volume_down
        : Icons.volume_up;
    return Row(
      children: [
        Icon(
          icon,
          color: state == null
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
        ),
        Expanded(
          child: Slider(
            value: volume.clamp(0, 100),
            max: 100,
            divisions: 100,
            label: '${volume.round()}%',
            onChanged: state == null
                ? null
                : (value) => setState(() => _dragVolume = value),
            onChangeEnd: state == null
                ? null
                : (value) {
                    setState(() => _dragVolume = null);
                    _appState.setMprisVolume(_entry.deviceId, value.round());
                  },
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------
  // Peranti tab: the desktop's audio outputs (system volume)
  // -------------------------------------------------------------------

  Widget _devicesTab(List<SinkState> sinks) {
    if (sinks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tidak ada perangkat audio yang ditemukan',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [for (final sink in sinks) _sinkCard(sink)],
    );
  }

  Widget _sinkCard(SinkState sink) {
    final scheme = Theme.of(context).colorScheme;
    final percent =
        _dragSinkVolumes[sink.name] ?? sink.volumePercent.toDouble();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          children: [
            InkWell(
              onTap: sink.enabled
                  ? null
                  : () => _appState.selectSink(_entry.deviceId, sink),
              child: Row(
                children: [
                  Icon(
                    sink.enabled
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: sink.enabled ? scheme.primary : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      sink.label,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: sink.muted ? 'Bunyikan' : 'Bisukan',
                  icon: Icon(sink.muted ? Icons.volume_off : Icons.volume_up),
                  onPressed: () => _appState.setSinkMuted(
                    _entry.deviceId,
                    sink,
                    !sink.muted,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: percent.clamp(0, 100),
                    max: 100,
                    divisions: 100,
                    label: '${percent.round()}%',
                    onChanged: (value) =>
                        setState(() => _dragSinkVolumes[sink.name] = value),
                    onChangeEnd: (value) {
                      setState(() => _dragSinkVolumes.remove(sink.name));
                      _appState.setSinkVolume(
                        _entry.deviceId,
                        sink,
                        value.round(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
